## Shared utilities for the BitTorrent client library.
##
## Contains: PRNG, CRC32C, IP parsing, compact peer format,
## hex encoding/decoding helpers.

import std/strutils

# ============================================================
# XorShift32 PRNG (avoids std/random which clobbers OpenSSL on macOS)
# ============================================================

type
  XorShift32* = object
    state: uint32

proc initXorShift32*(seed: uint32): XorShift32 =
  result.state = if seed == 0: 2654435761'u32 else: seed

proc next*(rng: var XorShift32): uint32 =
  rng.state = rng.state xor (rng.state shl 13)
  rng.state = rng.state xor (rng.state shr 17)
  rng.state = rng.state xor (rng.state shl 5)
  result = rng.state

proc rand*(rng: var XorShift32, bound: int): int =
  ## Return a pseudo-random int in [0, bound).
  if bound <= 1: return 0
  int(rng.next() mod bound.uint32)

# Module-level default PRNG instance for convenience.
import std/times
var defaultRng* = initXorShift32(uint32(epochTime() * 1000) or 1)

proc btRand*(bound: int): int =
  ## Module-level random in [0, bound) using the default PRNG.
  defaultRng.rand(bound)

proc btRandU32*(): uint32 =
  ## Module-level random uint32 using the default PRNG.
  defaultRng.next()

# ============================================================
# CRC32C (Castagnoli polynomial 0x1EDC6F41)
# ============================================================

const Crc32cTable*: array[256, uint32] = block:
  var t: array[256, uint32]
  for i in 0 .. 255:
    var crc = uint32(i)
    for _ in 0 .. 7:
      if (crc and 1) != 0:
        crc = (crc shr 1) xor 0x82F63B78'u32
      else:
        crc = crc shr 1
    t[i] = crc
  t

proc crc32c*(data: openArray[byte]): uint32 =
  result = 0xFFFFFFFF'u32
  for b in data:
    result = (result shr 8) xor Crc32cTable[(result xor uint32(b)) and 0xFF]
  result = result xor 0xFFFFFFFF'u32

# ============================================================
# IPv4 parsing
# ============================================================

proc parseIpv4*(ip: string): array[4, byte] =
  ## Parse a dotted-quad IPv4 string into 4 bytes.
  ## Returns [0,0,0,0] for non-IPv4 input (IPv6, hostnames, etc.).
  var idx = 0
  var octet = 0
  for c in ip:
    if c == '.':
      if idx >= 3:
        return  # Too many dots — not valid IPv4
      result[idx] = byte(octet and 0xFF)
      idx += 1
      octet = 0
    elif c >= '0' and c <= '9':
      octet = octet * 10 + (c.ord - '0'.ord)
      if octet > 255:
        return  # Octet overflow — not valid IPv4
    else:
      return  # Non-digit, non-dot character (IPv6 colon, hex letter, etc.)
  if idx == 3:
    result[idx] = byte(octet and 0xFF)

proc ipv4ToString*(b: array[4, byte]): string =
  $b[0] & "." & $b[1] & "." & $b[2] & "." & $b[3]

# ============================================================
# IPv6 canonicalization (RFC 5952)
# ============================================================

proc canonicalizeIpv6*(ip: string): string =
  ## Canonicalize an IPv6 address to RFC 5952 compressed form.
  ## Handles expanded, partially compressed, and already compressed forms.
  ## Returns the input unchanged if it does not look like IPv6.
  if ':' notin ip:
    return ip
  # Strip brackets if present
  var raw = ip
  if raw.len > 0 and raw[0] == '[':
    raw = raw[1 .. ^1]
  if raw.len > 0 and raw[^1] == ']':
    raw = raw[0 .. ^2]

  # Parse 8 groups from the address
  var groups: array[8, uint16]
  let parts = raw.split(':')
  var pi = 0
  var gi = 0
  while pi < parts.len and gi < 8:
    if parts[pi].len == 0:
      # Found "::" — determine how many zero groups to fill
      pi += 1
      if pi < parts.len and parts[pi].len == 0:
        pi += 1  # skip second empty from "::"
      var tailCount = 0
      for ti in pi ..< parts.len:
        if parts[ti].len > 0:
          tailCount += 1
      let zeroFill = 8 - gi - tailCount
      gi += zeroFill  # groups default to 0
    else:
      groups[gi] = uint16(parseHexInt(parts[pi]))
      gi += 1
      pi += 1

  # Find longest run of consecutive zero groups (RFC 5952 section 4.2.3)
  var bestStart = -1
  var bestLen = 0
  var curStart = -1
  var curLen = 0
  for i in 0 ..< 8:
    if groups[i] == 0:
      if curStart < 0:
        curStart = i
        curLen = 1
      else:
        curLen += 1
    else:
      if curLen > bestLen and curLen >= 2:
        bestStart = curStart
        bestLen = curLen
      curStart = -1
      curLen = 0
  if curLen > bestLen and curLen >= 2:
    bestStart = curStart
    bestLen = curLen

  # Build compressed output
  result = ""
  var i = 0
  var needSep = false
  while i < 8:
    if i == bestStart:
      result.add("::")
      i += bestLen
      needSep = false
    else:
      if needSep:
        result.add(':')
      let hexStr = groups[i].toHex.strip(leading = true, trailing = false, chars = {'0'})
      if hexStr.len == 0:
        result.add('0')
      else:
        result.add(hexStr)
      needSep = true
      i += 1
  # Lowercase for consistency
  result = result.toLowerAscii()

# ============================================================
# Compact peer format (6 bytes per IPv4 peer: 4 IP + 2 port BE)
# ============================================================

type CompactPeer* = tuple[ip: string, port: uint16]

proc decodeCompactPeers*(data: string): seq[CompactPeer] =
  ## Decode compact peer format (6 bytes per peer: 4 IP + 2 port).
  if data.len mod 6 != 0:
    return @[]
  let count = data.len div 6
  result = newSeqOfCap[CompactPeer](count)
  for i in 0 ..< count:
    let offset = i * 6
    let ip = $data[offset].byte & "." & $data[offset+1].byte & "." &
             $data[offset+2].byte & "." & $data[offset+3].byte
    let port = (uint16(data[offset+4].byte) shl 8) or uint16(data[offset+5].byte)
    result.add((ip, port))

proc encodeCompactPeers*(peers: seq[CompactPeer]): string =
  ## Encode peers in compact format (6 bytes per IPv4 peer).
  result = newStringOfCap(peers.len * 6)
  for peer in peers:
    let parts = peer.ip.split('.')
    if parts.len != 4:
      continue
    for p in parts:
      result.add(char(parseInt(p).byte))
    result.add(char((peer.port shr 8).byte))
    result.add(char((peer.port and 0xFF).byte))

proc parseIpv6Words*(ip: string): array[8, uint16] =
  ## Parse an IPv6 address string into 8 uint16 groups.
  var raw = ip
  if raw.len > 0 and raw[0] == '[':
    raw = raw[1 .. ^1]
  if raw.len > 0 and raw[^1] == ']':
    raw = raw[0 .. ^2]
  let parts = raw.split(':')
  var pi = 0
  var gi = 0
  while pi < parts.len and gi < 8:
    if parts[pi].len == 0:
      pi += 1
      if pi < parts.len and parts[pi].len == 0:
        pi += 1
      var tailCount = 0
      for ti in pi ..< parts.len:
        if parts[ti].len > 0:
          tailCount += 1
      let zeroFill = 8 - gi - tailCount
      gi += zeroFill
    else:
      result[gi] = uint16(parseHexInt(parts[pi]))
      gi += 1
      pi += 1

proc decodeCompactPeers6*(data: string): seq[CompactPeer] =
  ## Decode compact IPv6 peer format (18 bytes per peer: 16 IP + 2 port).
  if data.len mod 18 != 0:
    return @[]
  let count = data.len div 18
  result = newSeqOfCap[CompactPeer](count)
  for i in 0 ..< count:
    let offset = i * 18
    var words: array[8, uint16]
    for w in 0 ..< 8:
      words[w] = (uint16(data[offset + w*2].byte) shl 8) or uint16(data[offset + w*2 + 1].byte)
    # Build expanded IPv6 string then canonicalize
    var parts: seq[string]
    for w in words:
      parts.add(w.int.toHex(4).toLowerAscii())
    let ip = canonicalizeIpv6(parts.join(":"))
    let port = (uint16(data[offset+16].byte) shl 8) or uint16(data[offset+17].byte)
    result.add((ip, port))

proc encodeCompactPeers6*(peers: seq[CompactPeer]): string =
  ## Encode peers in compact IPv6 format (18 bytes per peer).
  result = newStringOfCap(peers.len * 18)
  for peer in peers:
    let words = parseIpv6Words(peer.ip)
    for w in words:
      result.add(char((w shr 8) and 0xFF))
      result.add(char(w and 0xFF))
    result.add(char((peer.port shr 8).byte))
    result.add(char((peer.port and 0xFF).byte))

# ============================================================
# Hex encoding/decoding
# ============================================================

proc hexDigitToInt*(c: char): int {.inline.} =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: 0

proc hexToBytes*(hex: string): seq[byte] =
  ## Decode a hex string to bytes.
  result = newSeq[byte](hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(hexDigitToInt(hex[i * 2]) shl 4 or hexDigitToInt(hex[i * 2 + 1]))

proc bytesToHex*(data: openArray[byte]): string =
  ## Encode bytes as lowercase hex string.
  const hexChars = "0123456789abcdef"
  result = newStringOfCap(data.len * 2)
  for b in data:
    result.add(hexChars[b.int shr 4])
    result.add(hexChars[b.int and 0x0F])

proc percentDecode*(s: string): string =
  ## Simple percent-decoding for URL parameters.
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      result.add(char(hexDigitToInt(s[i+1]) shl 4 or hexDigitToInt(s[i+2])))
      i += 3
    elif s[i] == '+':
      result.add(' ')
      i += 1
    else:
      result.add(s[i])
      i += 1

# ============================================================
# Wire format helpers
# ============================================================

proc writeUint32BE*(s: var string, v: uint32) =
  s.add(char((v shr 24) and 0xFF))
  s.add(char((v shr 16) and 0xFF))
  s.add(char((v shr 8) and 0xFF))
  s.add(char(v and 0xFF))

proc readUint32BE*(data: string, offset: int): uint32 =
  result = (uint32(data[offset].byte) shl 24) or
           (uint32(data[offset+1].byte) shl 16) or
           (uint32(data[offset+2].byte) shl 8) or
           uint32(data[offset+3].byte)

proc readUint16BE*(data: string, offset: int): uint16 =
  (uint16(data[offset].byte) shl 8) or uint16(data[offset+1].byte)

proc writeUint16BE*(s: var string, v: uint16) =
  s.add(char((v shr 8) and 0xFF))
  s.add(char(v and 0xFF))

proc writeUint64BE*(s: var string, v: uint64) =
  s.add(char((v shr 56) and 0xFF))
  s.add(char((v shr 48) and 0xFF))
  s.add(char((v shr 40) and 0xFF))
  s.add(char((v shr 32) and 0xFF))
  s.add(char((v shr 24) and 0xFF))
  s.add(char((v shr 16) and 0xFF))
  s.add(char((v shr 8) and 0xFF))
  s.add(char(v and 0xFF))

proc readUint64BE*(data: string, offset: int): uint64 =
  for i in 0 ..< 8:
    result = (result shl 8) or uint64(data[offset+i].byte)

proc writeInt32BE*(s: var string, v: int32) =
  writeUint32BE(s, cast[uint32](v))

proc readInt32BE*(data: string, offset: int): int32 =
  cast[int32](readUint32BE(data, offset))

# ============================================================
# Bitfield popcount
# ============================================================

proc popcnt8(b: byte): int {.inline.} =
  ## Count set bits in a byte.
  var x = b.uint8
  x = x - ((x shr 1) and 0x55'u8)
  x = (x and 0x33'u8) + ((x shr 2) and 0x33'u8)
  int((x + (x shr 4)) and 0x0F'u8)

proc countBitsSet*(bitfield: openArray[byte], totalBits: int): int =
  ## Count the number of set bits in a bitfield, up to totalBits.
  let fullBytes = totalBits div 8
  for i in 0 ..< fullBytes:
    result += popcnt8(bitfield[i])
  let remainingBits = totalBits mod 8
  if remainingBits > 0 and fullBytes < bitfield.len:
    let mask = byte(0xFF shl (8 - remainingBits))
    result += popcnt8(bitfield[fullBytes] and mask)

# ============================================================
# Safe parseInt wrappers
# ============================================================

proc safeParseInt*(s: string, default: int = 0): int =
  ## Parse an integer string, returning default on failure.
  try:
    result = parseInt(s)
  except ValueError:
    result = default

proc safeParseUint16*(s: string, default: uint16 = 0): uint16 =
  ## Parse a uint16 from string, returning default on failure.
  try:
    result = parseInt(s).uint16
  except ValueError:
    result = default
