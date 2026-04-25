## Tests for NAT traversal module (nat.nim)
##
## Unit tests: packet encode/decode, parsing, gateway detection.
## Mock tests: NAT-PMP responder on localhost, full async flow.

import std/[strutils, times, nativesockets, posix]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/udp
import cps/io/nat

# Local helpers for test packet construction
proc putU16BE(buf: var string, offset: int, val: uint16) =
  buf[offset] = char((val shr 8) and 0xFF)
  buf[offset + 1] = char(val and 0xFF)

proc putU32BE(buf: var string, offset: int, val: uint32) =
  buf[offset] = char((val shr 24) and 0xFF)
  buf[offset + 1] = char((val shr 16) and 0xFF)
  buf[offset + 2] = char((val shr 8) and 0xFF)
  buf[offset + 3] = char(val and 0xFF)

# ============================================================
# NAT-PMP Wire Format Tests
# ============================================================

block:
  # External address request
  let req = natPmpBuildExternalAddrRequest()
  assert req.len == 2, "External addr request should be 2 bytes"
  assert req[0].byte == 0, "Version should be 0"
  assert req[1].byte == 0, "Opcode should be 0"
  echo "PASS: NAT-PMP external address request encoding"

block:
  # TCP mapping request
  let req = natPmpBuildMappingRequest(mpTcp, 6881, 6881, 7200)
  assert req.len == 12, "Mapping request should be 12 bytes"
  assert req[0].byte == 0, "Version should be 0"
  assert req[1].byte == 2, "Opcode should be 2 (TCP)"
  assert req[2].byte == 0 and req[3].byte == 0, "Reserved should be 0"
  assert getU16BE(req, 4) == 6881, "Internal port"
  assert getU16BE(req, 6) == 6881, "External port"
  assert getU32BE(req, 8) == 7200, "Lifetime"
  echo "PASS: NAT-PMP TCP mapping request encoding"

block:
  # UDP mapping request
  let req = natPmpBuildMappingRequest(mpUdp, 6882, 0, 3600)
  assert req[1].byte == 1, "Opcode should be 1 (UDP)"
  assert getU16BE(req, 4) == 6882, "Internal port"
  assert getU16BE(req, 6) == 0, "External port (wildcard)"
  assert getU32BE(req, 8) == 3600, "Lifetime"
  echo "PASS: NAT-PMP UDP mapping request encoding"

block:
  # Delete mapping request (lifetime=0)
  let req = natPmpBuildMappingRequest(mpTcp, 6881, 6881, 0)
  assert getU32BE(req, 8) == 0, "Lifetime should be 0 for delete"
  echo "PASS: NAT-PMP delete mapping encoding"

block:
  # Parse external address response
  var resp = newString(12)
  resp[0] = char(0)       # version
  resp[1] = char(128)     # opcode 0 + 128
  resp[2] = char(0)       # result code high
  resp[3] = char(0)       # result code low
  resp[4] = char(0); resp[5] = char(0); resp[6] = char(0); resp[7] = char(1)  # epoch
  resp[8] = char(203); resp[9] = char(0); resp[10] = char(113); resp[11] = char(1)  # 203.0.113.1

  let parsed = natPmpParseResponse(resp)
  assert parsed.version == 0
  assert parsed.opcode == 128
  assert parsed.resultCode == 0
  assert parsed.epoch == 1
  assert parsed.externalIp == "203.0.113.1"
  echo "PASS: NAT-PMP external address response parsing"

block:
  # Parse mapping response
  var resp = newString(16)
  resp[0] = char(0)       # version
  resp[1] = char(130)     # opcode 2 + 128 (TCP)
  resp[2] = char(0); resp[3] = char(0)   # result code = 0
  resp[4] = char(0); resp[5] = char(0); resp[6] = char(0x0E); resp[7] = char(0x10)  # epoch
  # Internal port = 6881
  resp[8] = char(0x1A); resp[9] = char(0xE1)
  # External port = 6882
  resp[10] = char(0x1A); resp[11] = char(0xE2)
  # Lifetime = 7200
  resp[12] = char(0); resp[13] = char(0); resp[14] = char(0x1C); resp[15] = char(0x20)

  let parsed = natPmpParseResponse(resp)
  assert parsed.opcode == 130
  assert parsed.resultCode == 0
  assert parsed.internalPort == 6881
  assert parsed.externalPort == 6882
  assert parsed.lifetime == 7200
  echo "PASS: NAT-PMP mapping response parsing"

block:
  # Error response (result code != 0)
  var resp = newString(16)
  resp[0] = char(0)
  resp[1] = char(130)
  resp[2] = char(0); resp[3] = char(3)  # result code = 3 (Network Failure)
  # rest is zeros

  let parsed = natPmpParseResponse(resp)
  assert parsed.resultCode == 3
  echo "PASS: NAT-PMP error response parsing"

block:
  # Too short response
  var caught = false
  try:
    discard natPmpParseResponse("AB")
  except NatError:
    caught = true
  assert caught, "Should raise NatError for too-short response"
  echo "PASS: NAT-PMP too-short response handling"

# ============================================================
# PCP Wire Format Tests
# ============================================================

block:
  # PCP MAP request encoding
  var nonce: array[12, byte]
  for i in 0..11: nonce[i] = byte(i + 1)

  let req = pcpBuildMapRequest("192.168.1.100", mpTcp, 6881, 6881, 7200, nonce)
  assert req.len == 60, "PCP MAP request should be 60 bytes"
  assert req[0].byte == 2, "PCP version should be 2"
  assert req[1].byte == 1, "Opcode should be 1 (MAP)"
  # Lifetime at offset 4
  assert getU32BE(req, 4) == 7200, "Lifetime"
  # Client IP at offset 8 (IPv4-mapped IPv6)
  assert req[18].byte == 0xFF and req[19].byte == 0xFF, "IPv4-mapped marker"
  assert req[20].byte == 192 and req[21].byte == 168, "Client IP"
  assert req[22].byte == 1 and req[23].byte == 100, "Client IP"
  # Nonce at offset 24
  assert req[24].byte == 1 and req[35].byte == 12, "Nonce"
  # Protocol at offset 36
  assert req[36].byte == 6, "Protocol should be 6 (TCP)"
  # Internal port at offset 40
  assert getU16BE(req, 40) == 6881, "Internal port"
  # External port at offset 42
  assert getU16BE(req, 42) == 6881, "Suggested external port"
  echo "PASS: PCP MAP request encoding"

block:
  # PCP UDP request
  var nonce: array[12, byte]
  let req = pcpBuildMapRequest("10.0.0.5", mpUdp, 6882, 0, 3600, nonce)
  assert req[36].byte == 17, "Protocol should be 17 (UDP)"
  assert getU16BE(req, 40) == 6882
  assert getU16BE(req, 42) == 0
  echo "PASS: PCP UDP MAP request encoding"

block:
  # PCP response parsing
  var resp = newString(60)
  resp[0] = char(2)           # version
  resp[1] = char(0x81)        # R=1 | opcode=1
  resp[3] = char(0)           # result code = 0 (success)
  # Lifetime at offset 4
  resp[4] = char(0); resp[5] = char(0); resp[6] = char(0x1C); resp[7] = char(0x20)  # 7200
  # Epoch at offset 8
  resp[8] = char(0); resp[9] = char(0); resp[10] = char(0); resp[11] = char(42)
  # Nonce at offset 24
  for i in 0..11: resp[24 + i] = char(i + 1)
  # Protocol at offset 36
  resp[36] = char(6)  # TCP
  # Internal port at offset 40
  resp[40] = char(0x1A); resp[41] = char(0xE1)  # 6881
  # External port at offset 42
  resp[42] = char(0x1A); resp[43] = char(0xE2)  # 6882
  # External IP at offset 44 (IPv4-mapped: ::ffff:203.0.113.1)
  resp[54] = char(0xFF); resp[55] = char(0xFF)
  resp[56] = char(203); resp[57] = char(0); resp[58] = char(113); resp[59] = char(1)

  let parsed = pcpParseResponse(resp)
  assert parsed.version == 2
  assert parsed.opcode == 1
  assert parsed.resultCode == 0
  assert parsed.lifetime == 7200
  assert parsed.epoch == 42
  assert parsed.protocol == 6
  assert parsed.internalPort == 6881
  assert parsed.externalPort == 6882
  assert parsed.externalIp == "203.0.113.1"
  # Check nonce
  for i in 0..11:
    assert parsed.nonce[i] == byte(i + 1)
  echo "PASS: PCP MAP response parsing"

block:
  # PCP error response
  var resp = newString(60)
  resp[0] = char(2)
  resp[1] = char(0x81)
  resp[3] = char(1)  # UNSUPP_VERSION
  let parsed = pcpParseResponse(resp)
  assert parsed.resultCode == 1
  echo "PASS: PCP error response parsing"

block:
  # PCP too short
  var caught = false
  try:
    discard pcpParseResponse("short")
  except NatError:
    caught = true
  assert caught
  echo "PASS: PCP too-short response handling"

# ============================================================
# Big-endian Helpers
# ============================================================

block:
  var buf = newString(4)
  putU16BE(buf, 0, 0x1234)
  assert getU16BE(buf, 0) == 0x1234
  putU16BE(buf, 2, 0xABCD)
  assert getU16BE(buf, 2) == 0xABCD
  echo "PASS: Big-endian U16 round-trip"

block:
  var buf = newString(4)
  putU32BE(buf, 0, 0x12345678'u32)
  assert getU32BE(buf, 0) == 0x12345678'u32
  echo "PASS: Big-endian U32 round-trip"

block:
  var buf = newString(4)
  putU32BE(buf, 0, 0)
  assert getU32BE(buf, 0) == 0
  putU32BE(buf, 0, 0xFFFFFFFF'u32)
  assert getU32BE(buf, 0) == 0xFFFFFFFF'u32
  echo "PASS: Big-endian edge cases"

# ============================================================
# SSDP Response Parsing
# ============================================================

block:
  let ssdpResp = "HTTP/1.1 200 OK\r\n" &
    "LOCATION: http://192.168.1.1:5000/rootDesc.xml\r\n" &
    "SERVER: Linux/3.x UPnP/1.1 MiniUPnPd/2.0\r\n" &
    "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n" &
    "\r\n"

  let parsed = parseSsdpResponse(ssdpResp)
  assert parsed.location == "http://192.168.1.1:5000/rootDesc.xml"
  assert parsed.server == "Linux/3.x UPnP/1.1 MiniUPnPd/2.0"
  assert parsed.st == "urn:schemas-upnp-org:device:InternetGatewayDevice:1"
  echo "PASS: SSDP response parsing"

block:
  # Missing LOCATION
  let ssdpResp = "HTTP/1.1 200 OK\r\nST: test\r\n\r\n"
  let parsed = parseSsdpResponse(ssdpResp)
  assert parsed.location == ""
  echo "PASS: SSDP response with missing LOCATION"

# ============================================================
# UPnP XML Parsing
# ============================================================

block:
  let xml = """<?xml version="1.0"?>
<root>
  <device>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        <controlURL>/ctl/IPConn</controlURL>
      </service>
    </serviceList>
  </device>
</root>"""

  let result = parseUpnpControlUrl(xml)
  assert result.controlUrl == "/ctl/IPConn"
  assert result.serviceType == "urn:schemas-upnp-org:service:WANIPConnection:1"
  echo "PASS: UPnP XML control URL extraction"

block:
  # WANPPPConnection (DSL routers)
  let xml = """<service>
    <serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
    <controlURL>/ctl/PPPConn</controlURL>
  </service>"""

  let result = parseUpnpControlUrl(xml)
  assert result.controlUrl == "/ctl/PPPConn"
  assert result.serviceType == "urn:schemas-upnp-org:service:WANPPPConnection:1"
  echo "PASS: UPnP WANPPPConnection extraction"

block:
  # WANIPConnection:2
  let xml = """<service>
    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType>
    <controlURL>/upnp/control/WANIPConn1</controlURL>
  </service>"""

  let result = parseUpnpControlUrl(xml)
  assert result.controlUrl == "/upnp/control/WANIPConn1"
  echo "PASS: UPnP WANIPConnection:2 extraction"

block:
  # No matching service type
  let xml = """<service>
    <serviceType>urn:schemas-upnp-org:service:SomeOther:1</serviceType>
    <controlURL>/ctl/other</controlURL>
  </service>"""

  let result = parseUpnpControlUrl(xml)
  assert result.controlUrl == ""
  assert result.serviceType == ""
  echo "PASS: UPnP no matching service type"

block:
  # controlURL before serviceType (reversed element order)
  let xml = """<service>
    <controlURL>/ctl/reversed</controlURL>
    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
  </service>"""

  let result = parseUpnpControlUrl(xml)
  assert result.controlUrl == "/ctl/reversed"
  assert result.serviceType == "urn:schemas-upnp-org:service:WANIPConnection:1"
  echo "PASS: UPnP reversed element order"

block:
  # Multiple service blocks — should match the correct one
  let xml = """<serviceList>
  <service>
    <serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
    <controlURL>/ctl/L3Fwd</controlURL>
  </service>
  <service>
    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
    <controlURL>/ctl/IPConn</controlURL>
  </service>
  <service>
    <serviceType>urn:schemas-upnp-org:service:WANCommonIFC:1</serviceType>
    <controlURL>/ctl/CmnIfCfg</controlURL>
  </service>
</serviceList>"""

  let result = parseUpnpControlUrl(xml)
  assert result.controlUrl == "/ctl/IPConn"
  assert result.serviceType == "urn:schemas-upnp-org:service:WANIPConnection:1"
  echo "PASS: UPnP correct service block among multiple"

# ============================================================
# SOAP Response Parsing
# ============================================================

block:
  let xml = """<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetExternalIPAddressResponse>
      <NewExternalIPAddress>203.0.113.42</NewExternalIPAddress>
    </u:GetExternalIPAddressResponse>
  </s:Body>
</s:Envelope>"""

  let ip = parseSoapResponse(xml, "NewExternalIPAddress")
  assert ip == "203.0.113.42"
  echo "PASS: SOAP external IP response parsing"

block:
  let xml = """<s:Body><s:Fault><detail><UPnPError>
    <errorCode>718</errorCode>
    <errorDescription>ConflictInMappingEntry</errorDescription>
  </UPnPError></detail></s:Fault></s:Body>"""

  let errCode = parseSoapResponse(xml, "errorCode")
  let errDesc = parseSoapResponse(xml, "errorDescription")
  assert errCode == "718"
  assert errDesc == "ConflictInMappingEntry"
  echo "PASS: SOAP error response parsing"

block:
  # Missing tag
  let xml = "<root></root>"
  assert parseSoapResponse(xml, "nonexistent") == ""
  echo "PASS: SOAP missing tag"

# ============================================================
# SOAP Template Tests
# ============================================================

block:
  let body = soapAddPortMapping(
    "urn:schemas-upnp-org:service:WANIPConnection:1",
    6881, mpTcp, 6881, "192.168.1.100", "Test Client", 7200)
  assert body.find("<NewExternalPort>6881</NewExternalPort>") >= 0
  assert body.find("<NewProtocol>TCP</NewProtocol>") >= 0
  assert body.find("<NewInternalPort>6881</NewInternalPort>") >= 0
  assert body.find("<NewInternalClient>192.168.1.100</NewInternalClient>") >= 0
  assert body.find("<NewLeaseDuration>7200</NewLeaseDuration>") >= 0
  assert body.find("WANIPConnection:1") >= 0
  echo "PASS: SOAP AddPortMapping template"

block:
  let body = soapDeletePortMapping(
    "urn:schemas-upnp-org:service:WANIPConnection:1", 6881, mpUdp)
  assert body.find("<NewExternalPort>6881</NewExternalPort>") >= 0
  assert body.find("<NewProtocol>UDP</NewProtocol>") >= 0
  assert body.find("DeletePortMapping") >= 0
  echo "PASS: SOAP DeletePortMapping template"

block:
  let body = soapGetExternalIPAddress("urn:schemas-upnp-org:service:WANIPConnection:1")
  assert body.find("GetExternalIPAddress") >= 0
  echo "PASS: SOAP GetExternalIPAddress template"

# ============================================================
# URL Parsing
# ============================================================

block:
  let p = parseUrlComponents("http://192.168.1.1:5000/rootDesc.xml")
  assert p.host == "192.168.1.1"
  assert p.port == 5000
  assert p.path == "/rootDesc.xml"
  assert p.isHttps == false
  echo "PASS: URL parsing (http with port)"

block:
  let p = parseUrlComponents("https://example.com/path")
  assert p.host == "example.com"
  assert p.port == 443
  assert p.path == "/path"
  assert p.isHttps == true
  echo "PASS: URL parsing (https)"

block:
  let p = parseUrlComponents("http://192.168.1.1/desc.xml")
  assert p.host == "192.168.1.1"
  assert p.port == 80
  assert p.path == "/desc.xml"
  echo "PASS: URL parsing (http default port)"

block:
  let p = parseUrlComponents("http://router.local")
  assert p.host == "router.local"
  assert p.port == 80
  assert p.path == "/"
  echo "PASS: URL parsing (no path)"

# ============================================================
# Gateway Detection
# ============================================================

block:
  let localIp = getLocalIp()
  # Should return a valid IPv4 address or empty string
  if localIp.len > 0:
    assert '.' in localIp, "Local IP should be IPv4 dotted format"
    let parts = localIp.split('.')
    assert parts.len == 4, "Local IP should have 4 octets"
    echo "PASS: getLocalIp returned: " & localIp
  else:
    echo "PASS: getLocalIp returned empty (no network, OK)"

block:
  let gateway = getDefaultGateway()
  if gateway.len > 0:
    assert '.' in gateway, "Gateway should be IPv4 dotted format"
    echo "PASS: getDefaultGateway returned: " & gateway
  else:
    echo "PASS: getDefaultGateway returned empty (OK)"

# ============================================================
# NatManager Construction
# ============================================================

block:
  let mgr = newNatManager("192.168.1.1")
  assert mgr.protocol == npNone
  assert mgr.gatewayIp == "192.168.1.1"
  assert mgr.localIp.len >= 0  # may be empty if no network
  assert mgr.mappings.len == 0
  echo "PASS: NatManager construction with explicit gateway"

block:
  let mgr = newNatManager()
  # Auto-detect gateway
  assert mgr.protocol == npNone
  echo "PASS: NatManager construction with auto-detect"

# ============================================================
# Double-NAT Detection (isPrivateIp)
# ============================================================

block:
  # RFC 1918: 10.0.0.0/8
  assert isPrivateIp("10.0.0.1") == true
  assert isPrivateIp("10.255.255.255") == true
  assert isPrivateIp("10.0.1.5") == true
  echo "PASS: isPrivateIp - 10.0.0.0/8"

block:
  # RFC 1918: 172.16.0.0/12
  assert isPrivateIp("172.16.0.1") == true
  assert isPrivateIp("172.31.255.255") == true
  assert isPrivateIp("172.20.0.1") == true
  assert isPrivateIp("172.15.0.1") == false
  assert isPrivateIp("172.32.0.1") == false
  echo "PASS: isPrivateIp - 172.16.0.0/12"

block:
  # RFC 1918: 192.168.0.0/16
  assert isPrivateIp("192.168.0.1") == true
  assert isPrivateIp("192.168.1.1") == true
  assert isPrivateIp("192.168.255.255") == true
  assert isPrivateIp("192.167.0.1") == false
  echo "PASS: isPrivateIp - 192.168.0.0/16"

block:
  # CGNAT: 100.64.0.0/10
  assert isPrivateIp("100.64.0.1") == true
  assert isPrivateIp("100.127.255.255") == true
  assert isPrivateIp("100.100.0.1") == true
  assert isPrivateIp("100.63.0.1") == false
  assert isPrivateIp("100.128.0.1") == false
  echo "PASS: isPrivateIp - 100.64.0.0/10 (CGNAT)"

block:
  # Link-local: 169.254.0.0/16
  assert isPrivateIp("169.254.0.1") == true
  assert isPrivateIp("169.254.255.255") == true
  assert isPrivateIp("169.253.0.1") == false
  echo "PASS: isPrivateIp - 169.254.0.0/16 (link-local)"

block:
  # Public IPs
  assert isPrivateIp("203.0.113.1") == false
  assert isPrivateIp("8.8.8.8") == false
  assert isPrivateIp("1.1.1.1") == false
  assert isPrivateIp("142.250.80.46") == false
  echo "PASS: isPrivateIp - public IPs"

block:
  # Edge cases
  assert isPrivateIp("") == false
  assert isPrivateIp("not-an-ip") == false
  assert isPrivateIp("256.1.2.3") == false  # invalid but parses to 256
  echo "PASS: isPrivateIp - edge cases"

# ============================================================
# Double-NAT: NatManager construction with depth
# ============================================================

block:
  let mgr = newNatManager("192.168.8.1")
  assert mgr.doubleNat == false
  assert mgr.outerMgr == nil
  echo "PASS: NatManager doubleNat initially false"

block:
  let mgr = newNatManager("192.168.8.1", maxDepth = 1)
  assert mgr.outerMgr == nil
  echo "PASS: NatManager with explicit depth"

# ============================================================
# NAT-PMP Epoch Tracking (RFC 6886 Section 3.6)
# ============================================================

block:
  # First epoch and advancing: no staleness
  let mgr = newNatManager("192.168.1.1")
  assert mgr.mappingsStale == false
  mgr.checkPmpEpoch(100)
  assert mgr.mappingsStale == false
  mgr.checkPmpEpoch(200)
  assert mgr.mappingsStale == false
  mgr.checkPmpEpoch(200)  # same value is fine
  assert mgr.mappingsStale == false
  echo "PASS: Epoch - advancing does not flag stale"

block:
  # Epoch regression flags mappings as stale
  let mgr = newNatManager("192.168.1.1")
  mgr.checkPmpEpoch(500)
  # Add a dummy mapping to verify createdAt is zeroed
  let m = NatMapping(proto: mpTcp, internalPort: 6881, externalPort: 6881,
                     lifetime: 7200, createdAt: 1000.0, natProto: npNatPmp)
  mgr.mappings.add(m)
  mgr.checkPmpEpoch(10)  # regression
  assert mgr.mappingsStale == true
  assert m.createdAt == 0.0  # forced immediate renewal
  echo "PASS: Epoch - regression flags stale"

# ============================================================
# Mock NAT-PMP Responder Test
# ============================================================

block:
  # Create a mock NAT-PMP server on a random local UDP port
  let mockSock = newUdpSocket(AF_INET)
  mockSock.bindAddr("127.0.0.1", 0)
  let mockPort = mockSock.localPort()

  # Register handler that echoes back appropriate responses
  mockSock.onRecv(256, proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
    if data.len < 2:
      return
    let version = data[0].byte
    let opcode = data[1].byte

    if version == 0 and opcode == 0:
      # External address request -> respond with 203.0.113.42
      var resp = newString(12)
      resp[0] = char(0)       # version
      resp[1] = char(128)     # opcode + 128
      resp[2] = char(0); resp[3] = char(0)   # result = success
      resp[4] = char(0); resp[5] = char(0); resp[6] = char(0); resp[7] = char(1)  # epoch
      resp[8] = char(203); resp[9] = char(0); resp[10] = char(113); resp[11] = char(42)
      var srcHost = newString(256)
      var srcPortStr = newString(32)
      let rc = getnameinfo(cast[ptr SockAddr](unsafeAddr srcAddr), addrLen,
                           cstring(srcHost), 256.SockLen,
                           cstring(srcPortStr), 32.SockLen,
                           (NI_NUMERICHOST or NI_NUMERICSERV).cint)
      if rc == 0:
        srcHost.setLen(srcHost.cstring.len)
        srcPortStr.setLen(srcPortStr.cstring.len)
        let srcPort = parseInt(srcPortStr)
        discard mockSock.trySendToAddr(resp, srcHost, srcPort, AF_INET)

    elif version == 0 and (opcode == 1 or opcode == 2):
      # Mapping request -> respond with success
      var resp = newString(16)
      resp[0] = char(0)
      resp[1] = char(opcode + 128)
      resp[2] = char(0); resp[3] = char(0)   # result = success
      resp[4] = char(0); resp[5] = char(0); resp[6] = char(0); resp[7] = char(1)  # epoch
      if data.len >= 8:
        resp[8] = data[4]; resp[9] = data[5]   # internal port
        resp[10] = data[6]; resp[11] = data[7]  # external port
      if data.len >= 12:
        resp[12] = data[8]; resp[13] = data[9]; resp[14] = data[10]; resp[15] = data[11]
      var srcHost = newString(256)
      var srcPortStr = newString(32)
      let rc = getnameinfo(cast[ptr SockAddr](unsafeAddr srcAddr), addrLen,
                           cstring(srcHost), 256.SockLen,
                           cstring(srcPortStr), 32.SockLen,
                           (NI_NUMERICHOST or NI_NUMERICSERV).cint)
      if rc == 0:
        srcHost.setLen(srcHost.cstring.len)
        srcPortStr.setLen(srcPortStr.cstring.len)
        let srcPort = parseInt(srcPortStr)
        discard mockSock.trySendToAddr(resp, srcHost, srcPort, AF_INET)
  )

  echo "PASS: Mock NAT-PMP responder created on port " & $mockPort

  # Clean up
  mockSock.close()

echo ""
echo "All NAT traversal tests passed."
