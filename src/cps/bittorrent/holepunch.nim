## BEP 55: Holepunch Extension.
##
## Enables NAT traversal via a relay peer. The initiating peer sends a
## rendezvous message to a relay, which forwards connect messages to both
## sides, prompting simultaneous uTP connection attempts.

import std/strutils

const
  UtHolepunchName* = "ut_holepunch"

  # Message types
  HpRendezvous* = 0x00'u8
  HpConnect* = 0x01'u8
  HpError* = 0x02'u8

  # Address types
  AddrIPv4* = 0x00'u8
  AddrIPv6* = 0x01'u8

  # Error codes
  HpErrNoSuchPeer* = 0x01'u32
  HpErrNotConnected* = 0x02'u32
  HpErrNoSupport* = 0x03'u32
  HpErrNoSelf* = 0x04'u32

type
  HolepunchMsg* = object
    msgType*: uint8
    addrType*: uint8
    ip*: string            ## Dotted-quad IPv4 or colon-hex IPv6
    port*: uint16
    errCode*: uint32

proc encodeHolepunchMsg*(msg: HolepunchMsg): string =
  ## Encode a holepunch message to binary format.
  ## Format: [msg_type(1), addr_type(1), addr(4 or 16), port(2), err_code(4)]
  result = newStringOfCap(12)
  result.add(char(msg.msgType))
  result.add(char(msg.addrType))

  if msg.addrType != AddrIPv4 and msg.addrType != AddrIPv6:
    raise newException(ValueError, "unknown holepunch addr_type: " & $msg.addrType)

  if msg.addrType == AddrIPv4:
    # Parse dotted-quad IPv4 and encode as 4 bytes big-endian
    let parts = msg.ip.split('.')
    if parts.len != 4:
      raise newException(ValueError, "invalid IPv4 address: " & msg.ip)
    for part in parts:
      let v = parseInt(part)
      result.add(char(v and 0xFF))
  else:
    # IPv6: parse colon-hex groups and encode as 16 bytes big-endian
    var words: array[8, uint16]
    let groups = msg.ip.split(':')
    var gi = 0
    var wi = 0
    while gi < groups.len and wi < 8:
      if groups[gi].len == 0:
        # Found :: — count non-empty groups to determine zero fill
        gi += 1
        if gi < groups.len and groups[gi].len == 0:
          gi += 1  # skip second empty from "::"
        var tailCount = 0
        for ti in gi ..< groups.len:
          if groups[ti].len > 0:
            tailCount += 1
        let zeroFill = 8 - wi - tailCount
        wi += zeroFill  # words default to 0
      else:
        words[wi] = uint16(parseHexInt(groups[gi]))
        wi += 1
        gi += 1
    for w in words:
      result.add(char((w shr 8) and 0xFF))
      result.add(char(w and 0xFF))

  # Port (2 bytes big-endian)
  result.add(char((msg.port shr 8) and 0xFF))
  result.add(char(msg.port and 0xFF))

  # Error code (4 bytes big-endian)
  result.add(char((msg.errCode shr 24) and 0xFF))
  result.add(char((msg.errCode shr 16) and 0xFF))
  result.add(char((msg.errCode shr 8) and 0xFF))
  result.add(char(msg.errCode and 0xFF))

proc decodeHolepunchMsg*(data: string): HolepunchMsg =
  ## Decode a holepunch message from binary format.
  if data.len < 2:
    raise newException(ValueError, "holepunch message too short")

  result.msgType = data[0].byte
  result.addrType = data[1].byte

  if result.addrType != AddrIPv4 and result.addrType != AddrIPv6:
    raise newException(ValueError, "unknown holepunch addr_type: " & $result.addrType)

  var offset = 2
  if result.addrType == AddrIPv4:
    if data.len < offset + 4 + 2 + 4:
      raise newException(ValueError, "holepunch IPv4 message too short")
    result.ip = $data[offset].byte & "." &
                $data[offset+1].byte & "." &
                $data[offset+2].byte & "." &
                $data[offset+3].byte
    offset += 4
  else:
    if data.len < offset + 16 + 2 + 4:
      raise newException(ValueError, "holepunch IPv6 message too short")
    var parts: seq[string]
    for i in 0 ..< 8:
      let hi = data[offset + i*2].byte
      let lo = data[offset + i*2 + 1].byte
      let val = (uint16(hi) shl 8) or uint16(lo)
      parts.add(val.int.toHex(4).toLowerAscii())
    result.ip = parts.join(":")
    offset += 16

  # Port
  result.port = (uint16(data[offset].byte) shl 8) or uint16(data[offset+1].byte)
  offset += 2

  # Error code
  result.errCode = (uint32(data[offset].byte) shl 24) or
                   (uint32(data[offset+1].byte) shl 16) or
                   (uint32(data[offset+2].byte) shl 8) or
                   uint32(data[offset+3].byte)

proc rendezvousMsg*(ip: string, port: uint16): HolepunchMsg =
  ## Create a rendezvous message to request holepunching via relay.
  HolepunchMsg(
    msgType: HpRendezvous,
    addrType: if ip.contains(':'): AddrIPv6 else: AddrIPv4,
    ip: ip,
    port: port,
    errCode: 0
  )

proc connectMsg*(ip: string, port: uint16): HolepunchMsg =
  ## Create a connect message to initiate uTP connection.
  HolepunchMsg(
    msgType: HpConnect,
    addrType: if ip.contains(':'): AddrIPv6 else: AddrIPv4,
    ip: ip,
    port: port,
    errCode: 0
  )

proc errorMsg*(ip: string, port: uint16, errCode: uint32): HolepunchMsg =
  ## Create an error message for failed rendezvous.
  HolepunchMsg(
    msgType: HpError,
    addrType: if ip.contains(':'): AddrIPv6 else: AddrIPv4,
    ip: ip,
    port: port,
    errCode: errCode
  )

proc errorName*(code: uint32): string =
  ## Human-readable name for an error code.
  case code
  of HpErrNoSuchPeer: "NoSuchPeer"
  of HpErrNotConnected: "NotConnected"
  of HpErrNoSupport: "NoSupport"
  of HpErrNoSelf: "NoSelf"
  else: "Unknown(" & $code & ")"
