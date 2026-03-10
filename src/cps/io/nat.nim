## CPS I/O NAT Traversal
##
## Automatic port forwarding via NAT-PMP (RFC 6886), PCP (RFC 6887),
## and UPnP IGD (ISO/IEC 29341). Provides a unified NatManager API
## that auto-detects the available protocol and manages port mappings
## with automatic renewal.
##
## Detection order: PCP -> NAT-PMP -> UPnP IGD.
## All protocols are best-effort: failure leaves protocol = npNone.

import std/[nativesockets, net, strutils, times, tables, atomics]
import ../runtime
import ../transform
import ../eventloop
import ../private/platform
import ../private/xorshift
import ./streams
import ./udp
import ./tcp
import ./buffered
import ./timeouts

# ============================================================
# Types
# ============================================================

type
  NatError* = object of streams.AsyncIoError
    ## Error during NAT traversal.

  NatProtocol* = enum
    npNone        ## No NAT protocol available
    npNatPmp      ## NAT-PMP (RFC 6886)
    npPcp         ## PCP (RFC 6887)
    npUpnpIgd     ## UPnP IGD

  MappingProto* = enum
    mpTcp
    mpUdp

  NatMapping* = ref object
    ## Tracks an active port mapping.
    proto*: MappingProto
    internalPort*: uint16
    externalPort*: uint16
    lifetime*: uint32           ## Granted lifetime in seconds
    createdAt*: float           ## epochTime when mapping was created/renewed
    natProto*: NatProtocol      ## Which NAT protocol was used
    # PCP-specific: nonce needed for deletion/renewal
    pcpNonce*: array[12, byte]

  NatManager* = ref object
    ## Orchestrates NAT protocol discovery, port mapping, and renewal.
    protocol*: NatProtocol
    gatewayIp*: string
    localIp*: string
    externalIp*: string
    mappings*: seq[NatMapping]
    sock: UdpSocket              ## Shared UDP socket for NAT-PMP/PCP
    # NAT-PMP/PCP pending requests
    pendingPmp: Table[uint32, CpsFuture[string]]  ## key=(opcode<<16|port) -> response future
    pendingPcp: Table[string, CpsFuture[string]]   ## key=nonce hex -> response future
    # UPnP state
    upnpControlUrl: string
    upnpServiceType: string
    upnpHost: string
    upnpPort: int
    # NAT-PMP epoch tracking (RFC 6886 Section 3.6)
    lastPmpEpoch: uint32         ## Last observed SSSOE from gateway
    epochInitialized: bool       ## True after first response
    mappingsStale*: bool         ## Set true on epoch regression (gateway rebooted)
    # Renewal
    renewalRunning: bool
    shutdownFlag: bool
    # Double-NAT: chained outer manager for the upstream gateway
    outerMgr*: NatManager
    doubleNat*: bool             ## True if double-NAT was detected
    depth: int                   ## Nesting depth (0=inner, 1=outer; max 1)
    # Cached gateway IP as raw bytes for fast packet matching
    gatewayAddr: Sockaddr_in     ## Parsed gateway address for onRecv comparison

var gNatRng: XorShift32
var gNatRngInitialized = false

proc ensureRng() =
  if not gNatRngInitialized:
    let seed = int(int64(epochTime() * 1e6) xor int64(platform.getProcessId()))
    gNatRng = initXorShift32(seed)
    gNatRngInitialized = true

proc jitteredTimeout(baseMs: int): int =
  ## Apply RFC 6887 Section 8.1.1 jitter: RAND in [-0.1, +0.1].
  ## Returns baseMs * (1.0 + RAND).
  ensureRng()
  # Map next() (0..2^32-1) to [-0.1, +0.1]: (val / 2^32) * 0.2 - 0.1
  let r = gNatRng.next()
  let factor = 1.0 + (float(r) / float(uint32.high) * 0.2 - 0.1)
  result = max(1, int(float(baseMs) * factor))

# ============================================================
# Big-endian encoding/decoding helpers
# ============================================================

proc putU16BE(buf: var string, offset: int, val: uint16) =
  buf[offset] = char((val shr 8) and 0xFF)
  buf[offset + 1] = char(val and 0xFF)

proc putU32BE(buf: var string, offset: int, val: uint32) =
  buf[offset] = char((val shr 24) and 0xFF)
  buf[offset + 1] = char((val shr 16) and 0xFF)
  buf[offset + 2] = char((val shr 8) and 0xFF)
  buf[offset + 3] = char(val and 0xFF)

proc getU16BE*(data: string, offset: int): uint16 =
  result = (uint16(data[offset].byte) shl 8) or uint16(data[offset + 1].byte)

proc getU32BE*(data: string, offset: int): uint32 =
  result = (uint32(data[offset].byte) shl 24) or
           (uint32(data[offset + 1].byte) shl 16) or
           (uint32(data[offset + 2].byte) shl 8) or
           uint32(data[offset + 3].byte)

proc checkPmpEpoch*(mgr: NatManager, epoch: uint32) =
  ## RFC 6886 Section 3.6: detect gateway reboot via epoch regression.
  ## If the gateway's Seconds Since Start of Epoch goes backwards,
  ## all existing mappings are presumed lost and flagged stale.
  if not mgr.epochInitialized:
    mgr.lastPmpEpoch = epoch
    mgr.epochInitialized = true
    return
  if epoch < mgr.lastPmpEpoch:
    # Epoch regressed — gateway rebooted, mappings invalidated
    mgr.mappingsStale = true
    for m in mgr.mappings:
      m.createdAt = 0.0  # force immediate renewal
  mgr.lastPmpEpoch = epoch

proc sockaddrToIp(sa: Sockaddr_storage, addrLen: SockLen): string =
  ## Extract the IP string from a Sockaddr_storage. Returns "" on failure.
  var host: array[46, char]
  let rc = getnameinfo(cast[ptr SockAddr](unsafeAddr sa), addrLen,
                        cast[cstring](addr host[0]), 46.SockLen,
                        nil, 0.SockLen, NI_NUMERICHOST.cint)
  if rc == 0:
    result = $cast[cstring](addr host[0])
  else:
    result = ""

proc parseGatewayAddr(ip: string): Sockaddr_in =
  ## Parse an IPv4 address string into a Sockaddr_in for fast comparison.
  zeroMem(addr result, sizeof(result))
  result.sin_family = AF_INET.TSa_Family
  discard inet_pton(AF_INET.cint, ip.cstring, addr result.sin_addr)

proc matchesSrcAddr(sa: Sockaddr_storage, expected: Sockaddr_in): bool {.inline.} =
  ## Fast source-IP check: compare raw sin_addr bytes (no string alloc).
  let src = cast[ptr Sockaddr_in](unsafeAddr sa)
  src.sin_family == expected.sin_family and
    src.sin_addr.s_addr == expected.sin_addr.s_addr

# ============================================================
# Gateway Detection
# ============================================================

proc getLocalIp*(): string =
  ## Get the local IP address by connecting a UDP socket to 8.8.8.8:53.
  ## This doesn't send any data — it just lets the OS pick the route.
  let fd = createNativeSocket(Domain.AF_INET, SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP)
  if fd == osInvalidSocket:
    return ""
  defer: fd.close()

  var sa: Sockaddr_in
  zeroMem(addr sa, sizeof(sa))
  sa.sin_family = AF_INET.TSa_Family
  sa.sin_port = nativesockets.htons(53)
  if inet_pton(AF_INET.cint, "8.8.8.8".cstring, addr sa.sin_addr) != 1:
    return ""

  if connect(fd, cast[ptr SockAddr](addr sa), sizeof(sa).SockLen) != 0:
    return ""

  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  if getsockname(fd, cast[ptr SockAddr](addr localAddr), addr addrLen) != 0:
    return ""

  var buf: array[46, char]
  let p = inet_ntop(AF_INET.cint, addr localAddr.sin_addr, cast[cstring](addr buf[0]), 46.int32)
  if p == nil:
    return ""
  result = $cast[cstring](addr buf[0])

proc getDefaultGateway*(): string =
  ## Get the default gateway IP.
  ## Linux: parses /proc/net/route. macOS: uses .1 heuristic on local IP.
  when defined(linux):
    try:
      let content = readFile("/proc/net/route")
      for line in content.splitLines():
        let parts = line.splitWhitespace()
        if parts.len >= 3 and parts[1] == "00000000":
          # Default route: gateway is in hex, little-endian 32-bit
          let gwHex = parts[2]
          if gwHex.len == 8:
            let gw = parseHexInt(gwHex).uint32
            let a = gw and 0xFF
            let b = (gw shr 8) and 0xFF
            let c = (gw shr 16) and 0xFF
            let d = (gw shr 24) and 0xFF
            return $a & "." & $b & "." & $c & "." & $d
    except CatchableError:
      discard
  # macOS / fallback: use .1 heuristic
  let localIp = getLocalIp()
  if localIp.len > 0:
    let parts = localIp.split('.')
    if parts.len == 4:
      return parts[0] & "." & parts[1] & "." & parts[2] & ".1"
  return ""

# ============================================================
# Private / CGNAT IP detection (double-NAT)
# ============================================================

proc parseIpOctets(ip: string): tuple[a, b, c, d: int] =
  ## Parse dotted-decimal IPv4 into four octets. Returns (0,0,0,0) on failure.
  let parts = ip.split('.')
  if parts.len != 4:
    return (0, 0, 0, 0)
  try:
    result = (parseInt(parts[0]), parseInt(parts[1]),
              parseInt(parts[2]), parseInt(parts[3]))
  except ValueError:
    result = (0, 0, 0, 0)

proc isPrivateIp*(ip: string): bool =
  ## True if the IPv4 address falls in a non-routable range:
  ##   10.0.0.0/8        (RFC 1918)
  ##   172.16.0.0/12     (RFC 1918)
  ##   192.168.0.0/16    (RFC 1918)
  ##   100.64.0.0/10     (CGNAT, RFC 6598)
  ##   169.254.0.0/16    (link-local)
  let (a, b, _, _) = parseIpOctets(ip)
  if a == 10: return true
  if a == 172 and b >= 16 and b <= 31: return true
  if a == 192 and b == 168: return true
  if a == 100 and b >= 64 and b <= 127: return true
  if a == 169 and b == 254: return true
  return false

proc outerGatewayCandidates(innerExternalIp: string): seq[string] =
  ## Given the external IP reported by the inner router (which is still
  ## private), guess plausible gateway addresses for the outer router.
  ## Returns candidates in priority order.
  let (a, b, c, _) = parseIpOctets(innerExternalIp)
  result = @[]
  # .1 on the same subnet is by far the most common
  result.add($a & "." & $b & "." & $c & ".1")
  # Some routers use .254
  result.add($a & "." & $b & "." & $c & ".254")

proc canReachGateway(ip: string): bool =
  ## Quick connectivity check: try to connect a UDP socket to port 5351
  ## (NAT-PMP/PCP) on the candidate. This doesn't send traffic — it just
  ## verifies the OS can route to that address (connect() on UDP only sets
  ## the default destination, but will fail with ENETUNREACH/EHOSTUNREACH
  ## if no route exists).
  let fd = createNativeSocket(Domain.AF_INET, SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP)
  if fd == osInvalidSocket:
    return false
  defer: fd.close()
  var sa: Sockaddr_in
  zeroMem(addr sa, sizeof(sa))
  sa.sin_family = AF_INET.TSa_Family
  sa.sin_port = nativesockets.htons(5351)
  if inet_pton(AF_INET.cint, ip.cstring, addr sa.sin_addr) != 1:
    return false
  return connect(fd, cast[ptr SockAddr](addr sa), sizeof(sa).SockLen) == 0

# ============================================================
# NAT-PMP Wire Format (RFC 6886)
# ============================================================
#
# External address request: [version=0, opcode=0] (2 bytes)
# Mapping request: [version=0, opcode, reserved=0x0000, internalPort, externalPort, lifetime] (12 bytes)
# Response: [version=0, opcode+128, resultCode, epoch, ...] (variable)

const
  NatPmpVersion: byte = 0
  NatPmpPort = 5351
  NatPmpOpExternalAddr: byte = 0
  NatPmpOpMapUdp: byte = 1
  NatPmpOpMapTcp: byte = 2
  NatPmpBaseTimeoutMs = 250  # 250ms initial, doubling to 64s

proc natPmpBuildExternalAddrRequest*(): string =
  ## Build a 2-byte NAT-PMP external address request.
  result = newString(2)
  result[0] = char(NatPmpVersion)
  result[1] = char(NatPmpOpExternalAddr)

proc natPmpBuildMappingRequest*(proto: MappingProto, internalPort: uint16,
                                 externalPort: uint16, lifetime: uint32): string =
  ## Build a 12-byte NAT-PMP mapping request.
  result = newString(12)
  result[0] = char(NatPmpVersion)
  result[1] = char(if proto == mpUdp: NatPmpOpMapUdp else: NatPmpOpMapTcp)
  # bytes 2-3: reserved (zero)
  putU16BE(result, 4, internalPort)
  putU16BE(result, 6, externalPort)
  putU32BE(result, 8, lifetime)

proc natPmpParseResponse*(data: string): tuple[
    version: byte, opcode: byte, resultCode: uint16, epoch: uint32,
    externalIp: string, internalPort: uint16, externalPort: uint16, lifetime: uint32] =
  ## Parse a NAT-PMP response. Raises NatError on invalid data.
  if data.len < 8:
    raise newException(NatError, "NAT-PMP response too short: " & $data.len)

  result.version = data[0].byte
  result.opcode = data[1].byte
  result.resultCode = getU16BE(data, 2)
  result.epoch = getU32BE(data, 4)

  if result.opcode == NatPmpOpExternalAddr + 128:
    # External address response: 12 bytes total
    if data.len < 12:
      raise newException(NatError, "NAT-PMP external addr response too short")
    result.externalIp = $data[8].byte & "." & $data[9].byte & "." &
                        $data[10].byte & "." & $data[11].byte
  elif result.opcode == NatPmpOpMapUdp + 128 or result.opcode == NatPmpOpMapTcp + 128:
    # Mapping response: 16 bytes total
    if data.len < 16:
      raise newException(NatError, "NAT-PMP mapping response too short")
    result.internalPort = getU16BE(data, 8)
    result.externalPort = getU16BE(data, 10)
    result.lifetime = getU32BE(data, 12)

# ============================================================
# PCP Wire Format (RFC 6887)
# ============================================================
#
# Request header (24 bytes): [version=2, opcode, reserved, lifetime, clientIp(16 bytes)]
# MAP opcode (36 bytes): [nonce(12), protocol, reserved(3), internalPort, suggestedExternalPort, suggestedExternalIp(16)]
# Total MAP request: 60 bytes
#
# Response header (24 bytes): [version=2, R=1|opcode, reserved, resultCode, lifetime, epoch, reserved(12)]
# MAP opcode body same as request.

const
  PcpVersion: byte = 2
  PcpOpMap: byte = 1
  PcpBaseTimeoutMs = 3000  # 3s initial per RFC 6887

proc ipv4MappedIpv6(ip: string): array[16, byte] =
  ## Convert an IPv4 address string to an IPv4-mapped IPv6 address (16 bytes).
  ## ::ffff:a.b.c.d
  result[10] = 0xFF
  result[11] = 0xFF
  let parts = ip.split('.')
  if parts.len == 4:
    result[12] = byte(parseInt(parts[0]) and 0xFF)
    result[13] = byte(parseInt(parts[1]) and 0xFF)
    result[14] = byte(parseInt(parts[2]) and 0xFF)
    result[15] = byte(parseInt(parts[3]) and 0xFF)

proc generateNonce(): array[12, byte] =
  ensureRng()
  var i = 0
  while i < 12:
    let r = gNatRng.next()
    result[i] = byte(r and 0xFF)
    if i + 1 < 12: result[i + 1] = byte((r shr 8) and 0xFF)
    if i + 2 < 12: result[i + 2] = byte((r shr 16) and 0xFF)
    if i + 3 < 12: result[i + 3] = byte((r shr 24) and 0xFF)
    i += 4

proc nonceToHex(nonce: array[12, byte]): string =
  result = newStringOfCap(24)
  for b in nonce:
    result.add(b.int.toHex(2))

proc pcpBuildMapRequest*(localIp: string, proto: MappingProto,
                          internalPort: uint16, externalPort: uint16,
                          lifetime: uint32, nonce: array[12, byte]): string =
  ## Build a 60-byte PCP MAP request.
  result = newString(60)

  # Header (24 bytes)
  result[0] = char(PcpVersion)
  result[1] = char(PcpOpMap)  # R=0, opcode=1
  # bytes 2-3: reserved
  putU32BE(result, 4, lifetime)
  # Client IP (16 bytes, IPv4-mapped)
  let clientIp = ipv4MappedIpv6(localIp)
  copyMem(addr result[8], unsafeAddr clientIp[0], 16)

  # MAP opcode (36 bytes at offset 24)
  copyMem(addr result[24], unsafeAddr nonce[0], 12)
  # Protocol: 6=TCP, 17=UDP
  result[36] = char(if proto == mpTcp: 6 else: 17)
  # bytes 37-39: reserved
  putU16BE(result, 40, internalPort)
  putU16BE(result, 42, externalPort)
  # Suggested external IP (16 bytes, zeros = wildcard)
  # bytes 44-59 already zero

proc pcpParseResponse*(data: string): tuple[
    version: byte, opcode: byte, resultCode: byte, lifetime: uint32,
    epoch: uint32, nonce: array[12, byte], protocol: byte,
    internalPort: uint16, externalPort: uint16,
    externalIp: string] =
  ## Parse a PCP response. Raises NatError on invalid data.
  if data.len < 60:
    raise newException(NatError, "PCP response too short: " & $data.len)

  result.version = data[0].byte
  result.opcode = data[1].byte and 0x7F  # mask out R bit
  result.resultCode = data[3].byte
  result.lifetime = getU32BE(data, 4)
  result.epoch = getU32BE(data, 8)

  # MAP opcode body at offset 24
  copyMem(addr result.nonce[0], unsafeAddr data[24], 12)
  result.protocol = data[36].byte
  result.internalPort = getU16BE(data, 40)
  result.externalPort = getU16BE(data, 42)

  # External IP at offset 44 (16 bytes, check for IPv4-mapped)
  if data[44].byte == 0 and data[45].byte == 0 and data[46].byte == 0 and data[47].byte == 0 and
     data[48].byte == 0 and data[49].byte == 0 and data[50].byte == 0 and data[51].byte == 0 and
     data[52].byte == 0 and data[53].byte == 0 and data[54].byte == 0xFF and data[55].byte == 0xFF:
    # IPv4-mapped IPv6
    result.externalIp = $data[56].byte & "." & $data[57].byte & "." &
                        $data[58].byte & "." & $data[59].byte
  else:
    # Full IPv6 (simplified)
    var parts: seq[string]
    var i = 44
    while i < 60:
      let word = (uint16(data[i].byte) shl 8) or uint16(data[i + 1].byte)
      parts.add(word.toHex(4).toLowerAscii())
      i += 2
    result.externalIp = parts.join(":")

# ============================================================
# UPnP IGD Parsing
# ============================================================

proc parseSsdpResponse*(data: string): tuple[location: string, server: string, st: string] =
  ## Parse an SSDP M-SEARCH response, extracting LOCATION, SERVER, and ST headers.
  for line in data.splitLines():
    let stripped = line.strip()
    if stripped.toLowerAscii().startsWith("location:"):
      result.location = stripped[9..^1].strip()
    elif stripped.toLowerAscii().startsWith("server:"):
      result.server = stripped[7..^1].strip()
    elif stripped.toLowerAscii().startsWith("st:"):
      result.st = stripped[3..^1].strip()

proc parseUpnpControlUrl*(xml: string): tuple[controlUrl: string, serviceType: string] =
  ## Extract the controlURL and serviceType from a UPnP device description XML.
  ## Uses simple string scanning (no XML library dependency).
  ## Searches within each <service>...</service> block for the matching
  ## serviceType and its controlURL, regardless of element ordering.
  const serviceTypes = [
    "urn:schemas-upnp-org:service:WANIPConnection:1",
    "urn:schemas-upnp-org:service:WANIPConnection:2",
    "urn:schemas-upnp-org:service:WANPPPConnection:1"
  ]

  # Iterate over all <service> blocks
  var searchPos = 0
  while searchPos < xml.len:
    let blockStart = xml.find("<service>", searchPos)
    if blockStart < 0:
      # Also try case-insensitive / self-closing variants won't apply here
      break
    let blockEnd = xml.find("</service>", blockStart)
    if blockEnd < 0:
      break
    let blockSlice = xml[blockStart .. blockEnd + "</service>".len - 1]

    # Check if this block contains a matching serviceType
    for st in serviceTypes:
      if blockSlice.find(st) < 0:
        continue

      # Extract controlURL from within this same block
      let ctrlStart = blockSlice.find("<controlURL>")
      if ctrlStart < 0:
        continue
      let urlStart = ctrlStart + "<controlURL>".len
      let ctrlEnd = blockSlice.find("</controlURL>", urlStart)
      if ctrlEnd < 0:
        continue
      return (controlUrl: blockSlice[urlStart ..< ctrlEnd].strip(), serviceType: st)

    searchPos = blockEnd + "</service>".len

  return (controlUrl: "", serviceType: "")

proc parseSoapResponse*(xml: string, tagName: string): string =
  ## Extract a value from a SOAP response XML by tag name.
  let openTag = "<" & tagName & ">"
  let closeTag = "</" & tagName & ">"
  let startIdx = xml.find(openTag)
  if startIdx < 0:
    return ""
  let valStart = startIdx + openTag.len
  let endIdx = xml.find(closeTag, valStart)
  if endIdx < 0:
    return ""
  return xml[valStart ..< endIdx].strip()

proc parseUrlComponents*(url: string): tuple[host: string, port: int, path: string, isHttps: bool] =
  ## Parse a URL into host, port, path components.
  var s = url
  result.isHttps = false
  if s.startsWith("https://"):
    s = s[8..^1]
    result.isHttps = true
    result.port = 443
  elif s.startsWith("http://"):
    s = s[7..^1]
    result.port = 80
  else:
    result.port = 80

  let pathIdx = s.find('/')
  var hostPart: string
  if pathIdx >= 0:
    hostPart = s[0 ..< pathIdx]
    result.path = s[pathIdx..^1]
  else:
    hostPart = s
    result.path = "/"

  let colonIdx = hostPart.find(':')
  if colonIdx >= 0:
    result.host = hostPart[0 ..< colonIdx]
    try:
      result.port = parseInt(hostPart[colonIdx + 1..^1])
    except ValueError:
      discard
  else:
    result.host = hostPart

# ============================================================
# UPnP SOAP Templates
# ============================================================

proc soapAddPortMapping*(serviceType: string, externalPort: uint16,
                          proto: MappingProto, internalPort: uint16,
                          internalIp: string, description: string,
                          lifetime: uint32): string =
  ## Build a SOAP AddPortMapping XML envelope.
  let protoStr = if proto == mpTcp: "TCP" else: "UDP"
  let lifetimeStr = $lifetime
  result = "<?xml version=\"1.0\"?>\r\n" &
    "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " &
    "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\r\n" &
    "<s:Body>\r\n" &
    "<u:AddPortMapping xmlns:u=\"" & serviceType & "\">\r\n" &
    "<NewRemoteHost></NewRemoteHost>\r\n" &
    "<NewExternalPort>" & $externalPort & "</NewExternalPort>\r\n" &
    "<NewProtocol>" & protoStr & "</NewProtocol>\r\n" &
    "<NewInternalPort>" & $internalPort & "</NewInternalPort>\r\n" &
    "<NewInternalClient>" & internalIp & "</NewInternalClient>\r\n" &
    "<NewEnabled>1</NewEnabled>\r\n" &
    "<NewPortMappingDescription>" & description & "</NewPortMappingDescription>\r\n" &
    "<NewLeaseDuration>" & lifetimeStr & "</NewLeaseDuration>\r\n" &
    "</u:AddPortMapping>\r\n" &
    "</s:Body>\r\n" &
    "</s:Envelope>"

proc soapDeletePortMapping*(serviceType: string, externalPort: uint16,
                             proto: MappingProto): string =
  let protoStr = if proto == mpTcp: "TCP" else: "UDP"
  result = "<?xml version=\"1.0\"?>\r\n" &
    "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " &
    "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\r\n" &
    "<s:Body>\r\n" &
    "<u:DeletePortMapping xmlns:u=\"" & serviceType & "\">\r\n" &
    "<NewRemoteHost></NewRemoteHost>\r\n" &
    "<NewExternalPort>" & $externalPort & "</NewExternalPort>\r\n" &
    "<NewProtocol>" & protoStr & "</NewProtocol>\r\n" &
    "</u:DeletePortMapping>\r\n" &
    "</s:Body>\r\n" &
    "</s:Envelope>"

proc soapGetExternalIPAddress*(serviceType: string): string =
  result = "<?xml version=\"1.0\"?>\r\n" &
    "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " &
    "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\r\n" &
    "<s:Body>\r\n" &
    "<u:GetExternalIPAddress xmlns:u=\"" & serviceType & "\"/>\r\n" &
    "</s:Body>\r\n" &
    "</s:Envelope>"

# ============================================================
# withTimeoutBool helper
# ============================================================
# Returns true if timed out, false if completed.

proc withTimeoutBool*[T](fut: CpsFuture[T], timeoutMs: int): CpsFuture[bool] =
  let resultFut = newCpsFuture[bool]()
  resultFut.pinFutureRuntime()

  var resolved: Atomic[bool]
  resolved.store(false, moRelaxed)

  let loop = getEventLoop()

  proc makeTimerCb(rf: CpsFuture[bool]): proc() {.closure.} =
    result = proc() =
      var expected = false
      if resolved.compareExchange(expected, true):
        rf.complete(true)  # timed out

  proc makeCompleteCb(rf: CpsFuture[bool], timer: TimerHandle): proc() {.closure.} =
    result = proc() =
      var expected = false
      if resolved.compareExchange(expected, true):
        timer.cancel()
        rf.complete(false)  # completed

  let timerHandle = loop.registerTimer(timeoutMs, makeTimerCb(resultFut))
  fut.addCallback(makeCompleteCb(resultFut, timerHandle))

  result = resultFut

proc withTimeoutBool*(fut: CpsVoidFuture, timeoutMs: int): CpsFuture[bool] =
  let resultFut = newCpsFuture[bool]()
  resultFut.pinFutureRuntime()

  var resolved: Atomic[bool]
  resolved.store(false, moRelaxed)

  let loop = getEventLoop()

  proc makeTimerCb(rf: CpsFuture[bool]): proc() {.closure.} =
    result = proc() =
      var expected = false
      if resolved.compareExchange(expected, true):
        rf.complete(true)

  proc makeCompleteCb(rf: CpsFuture[bool], timer: TimerHandle): proc() {.closure.} =
    result = proc() =
      var expected = false
      if resolved.compareExchange(expected, true):
        timer.cancel()
        rf.complete(false)

  let timerHandle = loop.registerTimer(timeoutMs, makeTimerCb(resultFut))
  fut.addCallback(makeCompleteCb(resultFut, timerHandle))

  result = resultFut

# ============================================================
# NAT-PMP/PCP Async Operations (UDP + onRecv)
# ============================================================

proc pmpPcpKey(opcode: byte, port: uint16): uint32 =
  (uint32(opcode) shl 16) or uint32(port)

proc ensureNatSocket(mgr: NatManager) =
  ## Create the shared UDP socket for NAT-PMP/PCP and register the receive handler.
  if mgr.sock != nil:
    return

  mgr.sock = newUdpSocket(AF_INET)
  mgr.pendingPmp = initTable[uint32, CpsFuture[string]]()
  mgr.pendingPcp = initTable[string, CpsFuture[string]]()

  mgr.sock.onRecv(256, proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
    if data.len < 2:
      return

    # Validate source: compare raw IP bytes (no string alloc per packet).
    if not matchesSrcAddr(srcAddr, mgr.gatewayAddr):
      return

    let version = data[0].byte
    if version == 0:
      # NAT-PMP response: opcode high bit must be set (>= 128)
      let opcode = data[1].byte
      if opcode >= 128 and data.len >= 8:
        var port: uint16 = 0
        if opcode == NatPmpOpExternalAddr + 128:
          port = 0
        elif data.len >= 12:
          port = getU16BE(data, 8)
        let key = pmpPcpKey(opcode - 128, port)
        if key in mgr.pendingPmp:
          let fut = mgr.pendingPmp[key]
          mgr.pendingPmp.del(key)
          fut.complete(data)
    elif version == 2:
      # PCP response: R-bit (bit 7 of byte 1) must be set (RFC 6887 Section 7.2)
      if (data[1].byte and 0x80) != 0 and data.len >= 60:
        var nonce: array[12, byte]
        copyMem(addr nonce[0], unsafeAddr data[24], 12)
        let key = nonceToHex(nonce)
        if key in mgr.pendingPcp:
          let fut = mgr.pendingPcp[key]
          mgr.pendingPcp.del(key)
          fut.complete(data)
  )

proc natPmpRequest(mgr: NatManager, request: string, opcode: byte,
                    port: uint16, maxRetries: int = 9): CpsFuture[string] {.cps.} =
  ## Send a NAT-PMP request with exponential retry (250ms -> 64s).
  ensureNatSocket(mgr)

  let key: uint32 = pmpPcpKey(opcode, port)
  let responseFut = newCpsFuture[string]()
  responseFut.pinFutureRuntime()
  mgr.pendingPmp[key] = responseFut

  var attempt: int = 0
  while attempt < maxRetries:
    discard mgr.sock.trySendToAddr(request, mgr.gatewayIp, NatPmpPort, AF_INET)
    let timeoutMs: int = NatPmpBaseTimeoutMs * (1 shl attempt)
    let timedOut: bool = await withTimeoutBool(responseFut, timeoutMs)
    if not timedOut:
      # Response received
      let data: string = responseFut.read()
      return data
    attempt += 1

  # Clean up pending entry
  if key in mgr.pendingPmp:
    mgr.pendingPmp.del(key)
  raise newException(NatError, "NAT-PMP request timed out after " & $maxRetries & " retries")

proc pcpRequest(mgr: NatManager, request: string,
                 nonce: array[12, byte], maxRetries: int = 6): CpsFuture[string] {.cps.} =
  ## Send a PCP request with exponential retry (3s initial, MRT 1024s).
  ## Jittered per RFC 6887 Section 8.1.1: RT = 2*RT_prev + RAND*RT_prev.
  ensureNatSocket(mgr)

  let key: string = nonceToHex(nonce)
  let responseFut = newCpsFuture[string]()
  responseFut.pinFutureRuntime()
  mgr.pendingPcp[key] = responseFut

  var attempt: int = 0
  while attempt < maxRetries:
    discard mgr.sock.trySendToAddr(request, mgr.gatewayIp, NatPmpPort, AF_INET)
    let baseMs: int = min(PcpBaseTimeoutMs * (1 shl attempt), 1024_000)
    let timeoutMs: int = jitteredTimeout(baseMs)
    let timedOut: bool = await withTimeoutBool(responseFut, timeoutMs)
    if not timedOut:
      let data: string = responseFut.read()
      return data
    attempt += 1

  if key in mgr.pendingPcp:
    mgr.pendingPcp.del(key)
  raise newException(NatError, "PCP request timed out after " & $maxRetries & " retries")

# ============================================================
# UPnP IGD Operations (SSDP + HTTP + SOAP)
# ============================================================

proc readHttpBody(reader: BufferedReader, maxSize: int = 65536): CpsFuture[string] {.cps.} =
  ## Read an HTTP response's status line, headers, and body via a BufferedReader.
  ## Raises NatError on invalid responses or oversized bodies.
  let statusLine: string = await reader.readLine("\r\n")
  if not statusLine.startsWith("HTTP/"):
    raise newException(NatError, "Invalid HTTP response: " & statusLine)

  var contentLength: int = -1
  while true:
    let line: string = await reader.readLine("\r\n")
    if line.len == 0: break
    let colonIdx: int = line.find(':')
    if colonIdx > 0:
      let name: string = line[0 ..< colonIdx].strip().toLowerAscii()
      let value: string = line[colonIdx + 1..^1].strip()
      if name == "content-length":
        try: contentLength = parseInt(value)
        except ValueError: discard

  if contentLength > maxSize:
    raise newException(NatError, "HTTP response body too large: " & $contentLength)
  if contentLength > 0:
    return await reader.readExact(contentLength)

  var body: string = ""
  while body.len < maxSize:
    let chunk: string = await reader.read(8192)
    if chunk.len == 0: break
    body.add(chunk)
  return body

proc httpGet(host: string, port: int, path: string): CpsFuture[string] {.cps.} =
  ## Minimal HTTP GET, returns response body. Connection: close.
  let stream: TcpStream = await withTimeout(tcpConnect(host, port), 5000)
  defer: stream.close()
  let req: string = "GET " & path & " HTTP/1.1\r\n" &
    "Host: " & host & ":" & $port & "\r\n" &
    "Connection: close\r\n\r\n"
  await stream.write(req)
  let reader: BufferedReader = newBufferedReader(stream.AsyncStream, 16384)
  return await readHttpBody(reader)

proc httpPost(host: string, port: int, path: string,
              contentType: string, body: string,
              extraHeaders: string = ""): CpsFuture[string] {.cps.} =
  ## Minimal HTTP POST, returns response body. Connection: close.
  let stream: TcpStream = await withTimeout(tcpConnect(host, port), 5000)
  defer: stream.close()
  let req: string = "POST " & path & " HTTP/1.1\r\n" &
    "Host: " & host & ":" & $port & "\r\n" &
    "Content-Type: " & contentType & "\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    extraHeaders &
    "Connection: close\r\n\r\n" &
    body
  await stream.write(req)
  let reader: BufferedReader = newBufferedReader(stream.AsyncStream, 16384)
  return await readHttpBody(reader)

proc ssdpDiscover(mgr: NatManager, timeoutMs: int = 3000): CpsVoidFuture {.cps.} =
  ## Discover UPnP IGD devices via SSDP M-SEARCH multicast.
  let searchTarget = "urn:schemas-upnp-org:device:InternetGatewayDevice:1"
  let msearch: string = "M-SEARCH * HTTP/1.1\r\n" &
    "HOST: 239.255.255.250:1900\r\n" &
    "MAN: \"ssdp:discover\"\r\n" &
    "MX: 3\r\n" &
    "ST: " & searchTarget & "\r\n\r\n"

  let discoverSock = newUdpSocket(AF_INET)
  defer: discoverSock.close()

  discard discoverSock.trySendToAddr(msearch, "239.255.255.250", 1900, AF_INET)

  let recvFut: CpsFuture[Datagram] = discoverSock.recvFrom(2048)
  let timedOut: bool = await withTimeoutBool(recvFut, timeoutMs)
  if timedOut:
    raise newException(NatError, "SSDP discovery timed out")

  let dg: Datagram = recvFut.read()
  let parsed = parseSsdpResponse(dg.data)
  if parsed.location.len == 0:
    raise newException(NatError, "SSDP response missing LOCATION header")

  # Fetch device description
  let urlParts = parseUrlComponents(parsed.location)
  mgr.upnpHost = urlParts.host
  mgr.upnpPort = urlParts.port

  let body: string = await httpGet(urlParts.host, urlParts.port, urlParts.path)

  let upnpResult = parseUpnpControlUrl(body)
  if upnpResult.controlUrl.len == 0:
    raise newException(NatError, "No WANIPConnection service found in UPnP description")

  mgr.upnpServiceType = upnpResult.serviceType
  let controlUrl: string = upnpResult.controlUrl

  if controlUrl.startsWith("http://") or controlUrl.startsWith("https://"):
    let cu = parseUrlComponents(controlUrl)
    mgr.upnpHost = cu.host
    mgr.upnpPort = cu.port
    mgr.upnpControlUrl = cu.path
  else:
    mgr.upnpControlUrl = controlUrl

proc upnpSoapRequest(mgr: NatManager, soapAction: string,
                      soapBody: string): CpsFuture[string] {.cps.} =
  ## Send a SOAP request to the UPnP IGD device and return the response body.
  let extraHdr: string = "SOAPAction: \"" & mgr.upnpServiceType & "#" & soapAction & "\"\r\n"
  return await httpPost(mgr.upnpHost, mgr.upnpPort, mgr.upnpControlUrl,
                        "text/xml; charset=\"utf-8\"", soapBody, extraHdr)

# ============================================================
# NatManager - Unified API
# ============================================================

proc newNatManager*(gatewayIp: string = "", maxDepth: int = 0): NatManager =
  ## Create a new NAT manager.
  ## If gatewayIp is empty, auto-detects the default gateway.
  ## maxDepth controls double-NAT: 0 = inner (will spawn outer if needed),
  ## 1 = outer (no further recursion).
  result = NatManager(
    protocol: npNone,
    gatewayIp: gatewayIp,
    localIp: getLocalIp(),
    shutdownFlag: false,
    depth: maxDepth,
  )
  if result.gatewayIp.len == 0:
    result.gatewayIp = getDefaultGateway()
  if result.gatewayIp.len > 0:
    result.gatewayAddr = parseGatewayAddr(result.gatewayIp)

proc discoverInner(mgr: NatManager): CpsVoidFuture {.cps.} =
  ## Try PCP, then NAT-PMP, then UPnP IGD on the configured gateway.
  ## Sets mgr.protocol and mgr.externalIp on success.
  if mgr.gatewayIp.len == 0 or mgr.localIp.len == 0:
    return

  # Try PCP first (version 2)
  var pcpOk: bool = false
  try:
    let nonce = generateNonce()
    let request: string = pcpBuildMapRequest(mgr.localIp, mpTcp, 0, 0, 0, nonce)
    ensureNatSocket(mgr)
    discard mgr.sock.trySendToAddr(request, mgr.gatewayIp, NatPmpPort, AF_INET)

    let key: string = nonceToHex(nonce)
    let responseFut = newCpsFuture[string]()
    responseFut.pinFutureRuntime()
    mgr.pendingPcp[key] = responseFut

    let timedOut: bool = await withTimeoutBool(responseFut, 3000)
    if not timedOut:
      let data: string = responseFut.read()
      let pcpProbe = pcpParseResponse(data)
      if pcpProbe.version == 2:
        mgr.protocol = npPcp
        pcpOk = true
    else:
      if key in mgr.pendingPcp:
        mgr.pendingPcp.del(key)
  except CatchableError:
    discard

  if pcpOk:
    try:
      let nonce = generateNonce()
      let request: string = pcpBuildMapRequest(mgr.localIp, mpTcp, 0, 0, 0, nonce)
      let data: string = await pcpRequest(mgr, request, nonce, 3)
      let pcpExtIp = pcpParseResponse(data)
      if pcpExtIp.externalIp.len > 0:
        mgr.externalIp = pcpExtIp.externalIp
    except CatchableError:
      discard
    return

  # Try NAT-PMP
  var pmpOk: bool = false
  try:
    let request: string = natPmpBuildExternalAddrRequest()
    let data: string = await natPmpRequest(mgr, request, NatPmpOpExternalAddr, 0, 4)
    let pmpResp = natPmpParseResponse(data)
    mgr.checkPmpEpoch(pmpResp.epoch)
    if pmpResp.resultCode == 0:
      mgr.protocol = npNatPmp
      mgr.externalIp = pmpResp.externalIp
      pmpOk = true
  except CatchableError:
    discard

  if pmpOk:
    return

  # Try UPnP IGD
  try:
    await ssdpDiscover(mgr)
    mgr.protocol = npUpnpIgd
    try:
      let soapBody: string = soapGetExternalIPAddress(mgr.upnpServiceType)
      let respBody: string = await upnpSoapRequest(mgr, "GetExternalIPAddress", soapBody)
      let ip = parseSoapResponse(respBody, "NewExternalIPAddress")
      if ip.len > 0:
        mgr.externalIp = ip
    except CatchableError:
      discard
  except CatchableError:
    discard

proc discover*(mgr: NatManager): CpsVoidFuture {.cps.} =
  ## Auto-detect the available NAT protocol.
  ## Tries PCP -> NAT-PMP -> UPnP IGD on the immediate gateway.
  ## If the discovered external IP is still private (double-NAT),
  ## attempts to discover and forward through the outer gateway too.
  ## Sets mgr.protocol to npNone if all fail (best-effort, no error).
  await discoverInner(mgr)

  # Double-NAT detection: if we found a protocol but the external IP
  # is still in a private range, there's another NAT layer above us.
  if mgr.protocol == npNone:
    return
  if mgr.depth > 0:
    return  # already the outer layer, don't recurse further
  if mgr.externalIp.len == 0:
    return  # no external IP to check
  if not isPrivateIp(mgr.externalIp):
    return  # public IP — single NAT, nothing more to do

  # External IP is private -> double-NAT detected
  mgr.doubleNat = true

  # Try candidate gateways on the WAN-side subnet. The inner router's
  # external IP sits on the same LAN as the outer router, so .1 / .254
  # on that subnet are the most likely candidates.
  let candidates: seq[string] = outerGatewayCandidates(mgr.externalIp)

  var outerGw: string = ""
  var ci: int = 0
  while ci < candidates.len:
    let candidate: string = candidates[ci]
    # Skip if same as inner gateway (would just rediscover the same device)
    if candidate != mgr.gatewayIp and canReachGateway(candidate):
      outerGw = candidate
      break
    ci += 1

  if outerGw.len == 0:
    return  # can't reach any outer candidate

  # Create a child NatManager targeting the outer gateway.
  # depth=1 prevents infinite recursion. Set localIp directly to the inner
  # router's external IP (visible on the outer LAN), avoiding a redundant
  # getLocalIp() that would return the wrong address anyway.
  let outer = NatManager(
    protocol: npNone,
    gatewayIp: outerGw,
    localIp: mgr.externalIp,
    depth: 1,
    gatewayAddr: parseGatewayAddr(outerGw),
  )
  await discoverInner(outer)

  if outer.protocol != npNone:
    mgr.outerMgr = outer
    # Propagate the truly-public external IP
    if outer.externalIp.len > 0 and not isPrivateIp(outer.externalIp):
      mgr.externalIp = outer.externalIp

proc addMappingSingle(mgr: NatManager, proto: MappingProto, internalPort: uint16,
                       externalPort: uint16, lifetime: uint32): CpsFuture[NatMapping] {.cps.} =
  ## Add a single-layer port mapping on this manager's gateway.
  let requestedExtPort: uint16 = if externalPort == 0: internalPort else: externalPort

  case mgr.protocol
  of npNatPmp:
    let opcode: byte = if proto == mpUdp: NatPmpOpMapUdp else: NatPmpOpMapTcp
    let request: string = natPmpBuildMappingRequest(proto, internalPort, requestedExtPort, lifetime)
    let data: string = await natPmpRequest(mgr, request, opcode, internalPort)
    let pmpAddResp = natPmpParseResponse(data)
    mgr.checkPmpEpoch(pmpAddResp.epoch)
    if pmpAddResp.resultCode != 0:
      raise newException(NatError, "NAT-PMP mapping failed, result code: " & $pmpAddResp.resultCode)
    let mapping = NatMapping(
      proto: proto,
      internalPort: internalPort,
      externalPort: pmpAddResp.externalPort,
      lifetime: pmpAddResp.lifetime,
      createdAt: epochTime(),
      natProto: npNatPmp,
    )
    mgr.mappings.add(mapping)
    return mapping

  of npPcp:
    let nonce = generateNonce()
    let request: string = pcpBuildMapRequest(mgr.localIp, proto, internalPort,
                                              requestedExtPort, lifetime, nonce)
    let data: string = await pcpRequest(mgr, request, nonce)
    let pcpAddResp = pcpParseResponse(data)
    if pcpAddResp.resultCode != 0:
      raise newException(NatError, "PCP mapping failed, result code: " & $pcpAddResp.resultCode)
    let mapping = NatMapping(
      proto: proto,
      internalPort: internalPort,
      externalPort: pcpAddResp.externalPort,
      lifetime: pcpAddResp.lifetime,
      createdAt: epochTime(),
      natProto: npPcp,
      pcpNonce: nonce,
    )
    mgr.mappings.add(mapping)
    return mapping

  of npUpnpIgd:
    var actualLifetime: uint32 = lifetime
    var actualExtPort: uint16 = requestedExtPort
    var attempt: int = 0
    while attempt < 3:
      let soapBody: string = soapAddPortMapping(mgr.upnpServiceType, actualExtPort,
        proto, internalPort, mgr.localIp, "CPS BitTorrent", actualLifetime)
      let respBody: string = await upnpSoapRequest(mgr, "AddPortMapping", soapBody)
      if respBody.find("<UPnPError>") < 0 and respBody.find("s:Fault") < 0:
        # Success
        let mapping = NatMapping(
          proto: proto,
          internalPort: internalPort,
          externalPort: actualExtPort,
          lifetime: actualLifetime,
          createdAt: epochTime(),
          natProto: npUpnpIgd,
        )
        mgr.mappings.add(mapping)
        return mapping

      let errCode = parseSoapResponse(respBody, "errorCode")
      if errCode == "725":
        # OnlyPermanentLeasesSupported: retry with lifetime=0 (permanent)
        actualLifetime = 0
        attempt += 1
      elif errCode == "718":
        # ConflictInMappingEntry: try a different external port
        ensureRng()
        actualExtPort = uint16(49152 + (gNatRng.next() mod 16384))
        attempt += 1
      else:
        let errDesc = parseSoapResponse(respBody, "errorDescription")
        raise newException(NatError, "UPnP AddPortMapping failed: " & errCode & " " & errDesc)

    raise newException(NatError, "UPnP AddPortMapping failed after " & $attempt & " retries")

  of npNone:
    raise newException(NatError, "No NAT protocol available")

proc addMapping*(mgr: NatManager, proto: MappingProto, internalPort: uint16,
                  externalPort: uint16 = 0, lifetime: uint32 = 7200): CpsFuture[NatMapping] {.cps.} =
  ## Add a port mapping. In double-NAT scenarios, chains through both
  ## the inner and outer gateways automatically.
  ## Returns the innermost mapping (with the port visible to the caller).
  let innerMapping: NatMapping = await addMappingSingle(mgr, proto, internalPort,
                                                         externalPort, lifetime)

  # If double-NAT, also forward on the outer gateway.
  # The inner mapping's external port becomes the outer mapping's internal port.
  if mgr.outerMgr != nil and mgr.outerMgr.protocol != npNone:
    try:
      discard await addMappingSingle(mgr.outerMgr, proto,
                                      innerMapping.externalPort,
                                      innerMapping.externalPort, lifetime)
    except CatchableError:
      # Outer mapping failed — inner mapping still holds, partial forwarding
      discard

  return innerMapping

proc deleteMappingSingle(mgr: NatManager, mapping: NatMapping): CpsVoidFuture {.cps.} =
  ## Delete a single-layer port mapping on this manager's gateway.
  case mapping.natProto
  of npNatPmp:
    let opcode: byte = if mapping.proto == mpUdp: NatPmpOpMapUdp else: NatPmpOpMapTcp
    let request: string = natPmpBuildMappingRequest(mapping.proto, mapping.internalPort,
                                                     mapping.externalPort, 0)
    let data: string = await natPmpRequest(mgr, request, opcode, mapping.internalPort, 4)
    let pmpDelResp = natPmpParseResponse(data)
    mgr.checkPmpEpoch(pmpDelResp.epoch)
    if pmpDelResp.resultCode != 0:
      raise newException(NatError, "NAT-PMP delete failed, result code: " & $pmpDelResp.resultCode)

  of npPcp:
    let request: string = pcpBuildMapRequest(mgr.localIp, mapping.proto, mapping.internalPort,
                                              0, 0, mapping.pcpNonce)
    let data: string = await pcpRequest(mgr, request, mapping.pcpNonce, 4)
    let pcpDelResp = pcpParseResponse(data)
    if pcpDelResp.resultCode != 0:
      raise newException(NatError, "PCP delete failed, result code: " & $pcpDelResp.resultCode)

  of npUpnpIgd:
    let soapBody: string = soapDeletePortMapping(mgr.upnpServiceType, mapping.externalPort,
                                                  mapping.proto)
    discard await upnpSoapRequest(mgr, "DeletePortMapping", soapBody)

  of npNone:
    discard

  var i = 0
  while i < mgr.mappings.len:
    if mgr.mappings[i] == mapping:
      mgr.mappings.delete(i)
      break
    i += 1

proc deleteMapping*(mgr: NatManager, mapping: NatMapping): CpsVoidFuture {.cps.} =
  ## Delete a port mapping. In double-NAT, removes the corresponding
  ## outer mapping first (by matching on the external port), then the inner.
  if mgr.outerMgr != nil:
    # Find and delete the matching outer mapping (same proto + port)
    var oi: int = 0
    while oi < mgr.outerMgr.mappings.len:
      let om = mgr.outerMgr.mappings[oi]
      if om.proto == mapping.proto and om.internalPort == mapping.externalPort:
        try:
          await deleteMappingSingle(mgr.outerMgr, om)
        except CatchableError:
          discard
        break
      oi += 1

  await deleteMappingSingle(mgr, mapping)

proc deleteAllMappings*(mgr: NatManager): CpsVoidFuture {.cps.} =
  ## Delete all tracked port mappings.
  while mgr.mappings.len > 0:
    let mapping = mgr.mappings[0]
    try:
      await deleteMapping(mgr, mapping)
    except CatchableError:
      # Best effort — remove from list even if delete fails
      if mgr.mappings.len > 0 and mgr.mappings[0] == mapping:
        mgr.mappings.delete(0)

proc renewMapping(mgr: NatManager, mapping: NatMapping): CpsVoidFuture {.cps.} =
  ## Renew a single mapping by re-issuing the request.
  case mapping.natProto
  of npNatPmp:
    let opcode: byte = if mapping.proto == mpUdp: NatPmpOpMapUdp else: NatPmpOpMapTcp
    let request: string = natPmpBuildMappingRequest(mapping.proto, mapping.internalPort,
                                                     mapping.externalPort, mapping.lifetime)
    let data: string = await natPmpRequest(mgr, request, opcode, mapping.internalPort, 4)
    let pmpRenewResp = natPmpParseResponse(data)
    mgr.checkPmpEpoch(pmpRenewResp.epoch)
    if pmpRenewResp.resultCode == 0:
      mapping.externalPort = pmpRenewResp.externalPort
      mapping.lifetime = pmpRenewResp.lifetime
      mapping.createdAt = epochTime()

  of npPcp:
    # RFC 6887 Section 11.1: mapping nonce MUST be the same for all MAP
    # requests for a given mapping (create, renew, delete).
    let request: string = pcpBuildMapRequest(mgr.localIp, mapping.proto, mapping.internalPort,
                                              mapping.externalPort, mapping.lifetime,
                                              mapping.pcpNonce)
    let data: string = await pcpRequest(mgr, request, mapping.pcpNonce, 4)
    let pcpRenewResp = pcpParseResponse(data)
    if pcpRenewResp.resultCode == 0:
      mapping.externalPort = pcpRenewResp.externalPort
      mapping.lifetime = pcpRenewResp.lifetime
      mapping.createdAt = epochTime()

  of npUpnpIgd:
    let soapBody: string = soapAddPortMapping(mgr.upnpServiceType, mapping.externalPort,
      mapping.proto, mapping.internalPort, mgr.localIp, "CPS BitTorrent", mapping.lifetime)
    discard await upnpSoapRequest(mgr, "AddPortMapping", soapBody)
    mapping.createdAt = epochTime()

  of npNone:
    discard

proc renewAllDue(mgr: NatManager): CpsVoidFuture {.cps.} =
  ## Renew all mappings that have passed half their lifetime.
  ## If mappingsStale is set (epoch regression), renews all immediately.
  let now: float = epochTime()
  let forceAll: bool = mgr.mappingsStale
  var i: int = 0
  while i < mgr.mappings.len:
    let m = mgr.mappings[i]
    let elapsed: float = now - m.createdAt
    if forceAll or elapsed > float(m.lifetime) / 2.0:
      try:
        await renewMapping(mgr, m)
      except CatchableError:
        discard
    i += 1
  if forceAll:
    mgr.mappingsStale = false
  # Also renew outer mappings if double-NAT
  if mgr.outerMgr != nil:
    let forceOuter: bool = mgr.outerMgr.mappingsStale
    var oi: int = 0
    while oi < mgr.outerMgr.mappings.len:
      let om = mgr.outerMgr.mappings[oi]
      let outerElapsed: float = now - om.createdAt
      if forceOuter or outerElapsed > float(om.lifetime) / 2.0:
        try:
          await renewMapping(mgr.outerMgr, om)
        except CatchableError:
          discard
      oi += 1
    if forceOuter:
      mgr.outerMgr.mappingsStale = false

proc startRenewal*(mgr: NatManager): CpsVoidFuture {.cps.} =
  ## Start a background renewal loop that renews mappings at lifetime/2.
  ## Also renews outer-gateway mappings in double-NAT scenarios.
  if mgr.renewalRunning:
    return
  mgr.renewalRunning = true

  while not mgr.shutdownFlag:
    await cpsSleep(30000)
    await renewAllDue(mgr)

  mgr.renewalRunning = false

proc shutdown*(mgr: NatManager): CpsVoidFuture {.cps.} =
  ## Delete all mappings and close sockets.
  ## In double-NAT, shuts down the outer manager first.
  mgr.shutdownFlag = true

  # Shut down outer manager first (delete outer mappings before inner)
  if mgr.outerMgr != nil:
    try:
      await shutdown(mgr.outerMgr)
    except CatchableError:
      discard
    mgr.outerMgr = nil

  try:
    await deleteAllMappings(mgr)
  except CatchableError:
    discard

  if mgr.sock != nil:
    mgr.sock.close()
    mgr.sock = nil

proc getExternalIp*(mgr: NatManager): string =
  ## Get the discovered external IP address.
  mgr.externalIp
