## QUIC packet header codec and packet helpers.

import ./types
import ./varint
import ./packet_protection
import ./secure_random

const
  QuicVersion1* = 0x00000001'u32
  QuicVersion2* = 0x6B3343CF'u32

  RetryIntegrityTagLen* = 16
  StatelessResetTokenLen* = 16
  StatelessResetMinLen* = 21

  RetryIntegrityKeyV1* = [
    0xBE'u8, 0x0C, 0x69, 0x0B, 0x9F, 0x66, 0x57, 0x5A,
    0x1D, 0x76, 0x6B, 0x54, 0xE3, 0x68, 0xC8, 0x4E
  ]
  RetryIntegrityNonceV1* = [
    0x46'u8, 0x15, 0x99, 0xD3, 0x5D, 0x63, 0x2B, 0xF2,
    0x23, 0x98, 0x25, 0xBB
  ]
  RetryIntegrityKeyV2* = [
    0x8F'u8, 0xB4, 0xB0, 0x1B, 0x56, 0xAC, 0x48, 0xE2,
    0x60, 0xFB, 0xCB, 0xCE, 0xAD, 0x7C, 0xCC, 0x92
  ]
  RetryIntegrityNonceV2* = [
    0xD8'u8, 0x69, 0x69, 0xBC, 0x2D, 0x7C, 0x6D, 0x99,
    0x90, 0xEF, 0xB0, 0x4A
  ]

type
  QuicRetryPacket* = object
    firstByte*: byte
    version*: uint32
    dstConnId*: seq[byte]
    srcConnId*: seq[byte]
    token*: seq[byte]
    integrityTag*: array[RetryIntegrityTagLen, byte]

proc sliceToSeq(data: openArray[byte], startIdx, endIdxExclusive: int): seq[byte] =
  let n = endIdxExclusive - startIdx
  if n <= 0:
    return @[]
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = data[startIdx + i]

proc appendPacketNumber*(dst: var seq[byte], packetNumber: uint64, packetNumberLen: int) =
  ## Append truncated packet number (1..4 bytes).
  if packetNumberLen < 1 or packetNumberLen > 4:
    raise newException(ValueError, "packet number length must be 1..4")
  for i in countdown(packetNumberLen - 1, 0):
    dst.add byte((packetNumber shr (i * 8)) and 0xFF)

proc decodePacketNumber*(largestPn: uint64, truncatedPn: uint64, packetNumberLen: int): uint64 =
  ## Reconstruct full packet number from truncated value (RFC 9000 Appendix A.3).
  let pnNbits = packetNumberLen * 8
  let pnWin = 1'u64 shl pnNbits
  let pnHalfWin = pnWin div 2
  let pnMask = pnWin - 1
  let expectedPn = largestPn + 1
  var candidate = (expectedPn and (not pnMask)) or truncatedPn

  if candidate + pnHalfWin <= expectedPn and candidate < (1'u64 shl 62) - pnWin:
    candidate += pnWin
  elif candidate > expectedPn + pnHalfWin and candidate >= pnWin:
    candidate -= pnWin

  result = candidate

proc packetTypeFromFirstByte(first: byte): QuicPacketType =
  if (first and 0x80'u8) == 0:
    return qptShort

  let t = (first shr 4) and 0x03
  case t
  of 0: qptInitial
  of 1: qpt0Rtt
  of 2: qptHandshake
  of 3: qptRetry
  else: raise newException(AssertionDefect, "unreachable")

proc packetTypeToBits(packetType: QuicPacketType): byte =
  case packetType
  of qptVersionNegotiation:
    raise newException(ValueError, "Version Negotiation does not use long-header type bits")
  of qptInitial: 0'u8
  of qpt0Rtt: 1'u8
  of qptHandshake: 2'u8
  of qptRetry: 3'u8
  of qptShort: 0'u8

proc parsePacketHeader*(data: openArray[byte], offset: var int): QuicPacketHeader =
  if offset >= data.len:
    raise newException(ValueError, "packet header decode: empty input")

  let first = data[offset]
  inc offset

  result.packetType = packetTypeFromFirstByte(first)
  result.packetNumberLen = int(first and 0x03'u8) + 1
  result.payloadLen = -1

  if result.packetType == qptShort:
    if (first and 0x40'u8) == 0:
      raise newException(ValueError, "packet header decode: short header fixed bit is zero")
    result.keyPhase = (first and 0x04'u8) != 0
    return

  if offset + 4 > data.len:
    raise newException(ValueError, "packet header decode: truncated version")
  result.version =
    (uint32(data[offset]) shl 24) or
    (uint32(data[offset + 1]) shl 16) or
    (uint32(data[offset + 2]) shl 8) or
    uint32(data[offset + 3])
  offset += 4

  if result.version != 0'u32 and (first and 0x40'u8) == 0:
    raise newException(ValueError, "packet header decode: fixed bit is zero")

  if offset >= data.len:
    raise newException(ValueError, "packet header decode: missing dcid length")
  let dcidLen = int(data[offset])
  inc offset
  if dcidLen > 20:
    raise newException(ValueError, "packet header decode: invalid dcid length")
  if offset + dcidLen > data.len:
    raise newException(ValueError, "packet header decode: truncated dcid")
  result.dstConnId = sliceToSeq(data, offset, offset + dcidLen)
  offset += dcidLen

  if offset >= data.len:
    raise newException(ValueError, "packet header decode: missing scid length")
  let scidLen = int(data[offset])
  inc offset
  if scidLen > 20:
    raise newException(ValueError, "packet header decode: invalid scid length")
  if offset + scidLen > data.len:
    raise newException(ValueError, "packet header decode: truncated scid")
  result.srcConnId = sliceToSeq(data, offset, offset + scidLen)
  offset += scidLen

  if result.version == 0'u32:
    result.packetType = qptVersionNegotiation
    result.packetNumberLen = 0
    return

  if result.packetType == qptInitial:
    let tokenLen = decodeQuicVarInt(data, offset)
    if offset + int(tokenLen) > data.len:
      raise newException(ValueError, "packet header decode: truncated token")
    if tokenLen > 0:
      result.token = sliceToSeq(data, offset, offset + int(tokenLen))
      offset += int(tokenLen)
    else:
      result.token = @[]

  if result.packetType != qptRetry:
    let fullLen = decodeQuicVarInt(data, offset)
    result.payloadLen = int(fullLen)

proc encodePacketHeader*(header: QuicPacketHeader,
                         payloadLen: int,
                         packetNumberLen: int): seq[byte] =
  ## Encode packet header up to (but excluding) packet number.
  if packetNumberLen < 1 or packetNumberLen > 4:
    raise newException(ValueError, "packet number length must be 1..4")

  result = @[]

  if header.packetType == qptShort:
    var first = 0x40'u8 or byte(packetNumberLen - 1)
    if header.keyPhase:
      first = first or 0x04'u8
    result.add first
    if header.dstConnId.len > 0:
      if header.dstConnId.len > 20:
        raise newException(ValueError, "QUIC connection IDs must be <= 20 bytes")
      result.add header.dstConnId
    return

  if header.packetType == qptVersionNegotiation:
    raise newException(ValueError, "use encodeVersionNegotiationPacket for VN packets")

  var first = 0xC0'u8
  first = first or (packetTypeToBits(header.packetType) shl 4)
  first = first or byte(packetNumberLen - 1)
  result.add first

  result.add byte((header.version shr 24) and 0xFF)
  result.add byte((header.version shr 16) and 0xFF)
  result.add byte((header.version shr 8) and 0xFF)
  result.add byte(header.version and 0xFF)

  if header.dstConnId.len > 20 or header.srcConnId.len > 20:
    raise newException(ValueError, "QUIC connection IDs must be <= 20 bytes")

  result.add byte(header.dstConnId.len and 0xFF)
  result.add header.dstConnId
  result.add byte(header.srcConnId.len and 0xFF)
  result.add header.srcConnId

  if header.packetType == qptInitial:
    result.appendQuicVarInt(uint64(header.token.len))
    if header.token.len > 0:
      result.add header.token

  if header.packetType != qptRetry:
    let fullLen = payloadLen + packetNumberLen
    result.appendQuicVarInt(uint64(fullLen))

proc packetTypeToSpace*(packetType: QuicPacketType): QuicPacketNumberSpace =
  case packetType
  of qptInitial: qpnsInitial
  of qptHandshake: qpnsHandshake
  of qpt0Rtt, qptShort: qpnsApplication
  of qptRetry, qptVersionNegotiation:
    raise newException(ValueError, "Retry and Version Negotiation packets do not have a packet number space")

proc spaceToEncryptionLevel*(space: QuicPacketNumberSpace): QuicEncryptionLevel =
  case space
  of qpnsInitial: qelInitial
  of qpnsHandshake: qelHandshake
  of qpnsApplication: qelApplication

proc describePacketType*(packetType: QuicPacketType): string =
  case packetType
  of qptVersionNegotiation: "Version Negotiation"
  of qptInitial: "Initial"
  of qpt0Rtt: "0-RTT"
  of qptHandshake: "Handshake"
  of qptRetry: "Retry"
  of qptShort: "1-RTT"

proc parseVersionNegotiationPacket*(data: openArray[byte]): tuple[
    firstByte: byte,
    destinationConnId: seq[byte],
    sourceConnId: seq[byte],
    supportedVersions: seq[uint32]
  ] =
  ## Parse a QUIC Version Negotiation packet.
  if data.len < 7:
    raise newException(ValueError, "VN packet too short")

  let first = data[0]
  if (first and 0x80'u8) == 0:
    raise newException(ValueError, "VN packet must be a long header")

  let version =
    (uint32(data[1]) shl 24) or
    (uint32(data[2]) shl 16) or
    (uint32(data[3]) shl 8) or
    uint32(data[4])
  if version != 0'u32:
    raise newException(ValueError, "not a Version Negotiation packet")

  var off = 5
  let dcidLen = int(data[off])
  inc off
  if off + dcidLen > data.len:
    raise newException(ValueError, "VN packet truncated destination CID")
  let dcid = sliceToSeq(data, off, off + dcidLen)
  off += dcidLen

  if off >= data.len:
    raise newException(ValueError, "VN packet missing source CID length")
  let scidLen = int(data[off])
  inc off
  if off + scidLen > data.len:
    raise newException(ValueError, "VN packet truncated source CID")
  let scid = sliceToSeq(data, off, off + scidLen)
  off += scidLen

  let remaining = data.len - off
  if (remaining mod 4) != 0:
    raise newException(ValueError, "VN packet supported versions must be 32-bit aligned")

  var versions: seq[uint32]
  while off < data.len:
    let v =
      (uint32(data[off]) shl 24) or
      (uint32(data[off + 1]) shl 16) or
      (uint32(data[off + 2]) shl 8) or
      uint32(data[off + 3])
    versions.add v
    off += 4

  (
    firstByte: first,
    destinationConnId: dcid,
    sourceConnId: scid,
    supportedVersions: versions
  )

proc encodeVersionNegotiationPacket*(sourceConnId: openArray[byte],
                                     destinationConnId: openArray[byte],
                                     supportedVersions: openArray[uint32],
                                     firstByte: byte = 0xC0'u8): seq[byte] =
  ## Encode a QUIC Version Negotiation packet.
  if sourceConnId.len > 20 or destinationConnId.len > 20:
    raise newException(ValueError, "QUIC connection ID length must be <= 20")

  result = @[]
  result.add (firstByte or 0x80'u8)

  result.add 0'u8
  result.add 0'u8
  result.add 0'u8
  result.add 0'u8

  result.add byte(destinationConnId.len)
  if destinationConnId.len > 0:
    result.add destinationConnId

  result.add byte(sourceConnId.len)
  if sourceConnId.len > 0:
    result.add sourceConnId

  for version in supportedVersions:
    result.add byte((version shr 24) and 0xFF)
    result.add byte((version shr 16) and 0xFF)
    result.add byte((version shr 8) and 0xFF)
    result.add byte(version and 0xFF)

proc encodeCoalescedPackets*(packets: openArray[seq[byte]]): seq[byte] =
  ## Concatenate multiple QUIC packets into one datagram payload.
  result = @[]
  for p in packets:
    if p.len > 0:
      result.add p

proc splitCoalescedPackets*(datagram: openArray[byte], shortHeaderDcidLen: int = 0): seq[seq[byte]] =
  ## Split a UDP datagram containing coalesced QUIC packets.
  var off = 0
  while off < datagram.len:
    let start = off
    let first = datagram[off]
    if (first and 0x80'u8) == 0:
      # Short header packets are expected to be last in a datagram.
      result.add sliceToSeq(datagram, start, datagram.len)
      break

    var hdrOff = off
    let hdr = parsePacketHeader(datagram, hdrOff)
    var packetLen = datagram.len - start
    if hdr.packetType != qptRetry and hdr.packetType != qptVersionNegotiation:
      if hdr.payloadLen < 0:
        raise newException(ValueError, "coalesced split failed: missing long-header payload length")
      packetLen = (hdrOff - start) + hdr.payloadLen

    if packetLen <= 0 or start + packetLen > datagram.len:
      raise newException(ValueError, "coalesced split failed: invalid packet length")

    result.add sliceToSeq(datagram, start, start + packetLen)
    off = start + packetLen

proc retryIntegrityTag(version: uint32, pseudoPacket: openArray[byte]): array[RetryIntegrityTagLen, byte] =
  let (key, nonce) =
    if version == QuicVersion2:
      (RetryIntegrityKeyV2, RetryIntegrityNonceV2)
    elif version == QuicVersion1:
      (RetryIntegrityKeyV1, RetryIntegrityNonceV1)
    else:
      raise newException(ValueError, "retry integrity supports QUIC v1/v2 only")
  let enc = encryptAes128Gcm(key, nonce, pseudoPacket, @[])
  result = enc.tag

proc constantTimeEq(a, b: openArray[byte]): bool =
  if a.len != b.len:
    return false
  var diff: byte = 0
  for i in 0 ..< a.len:
    diff = diff or (a[i] xor b[i])
  diff == 0

proc encodeRetryPacket*(version: uint32,
                        destinationConnId: openArray[byte],
                        sourceConnId: openArray[byte],
                        token: openArray[byte],
                        originalDestinationConnId: openArray[byte],
                        firstByte: byte = 0xF0'u8): seq[byte] =
  ## Encode a QUIC Retry packet with integrity tag.
  if destinationConnId.len > 20 or sourceConnId.len > 20:
    raise newException(ValueError, "QUIC connection ID length must be <= 20")
  if originalDestinationConnId.len > 20:
    raise newException(ValueError, "original destination connection ID length must be <= 20")

  result = @[]
  var fb = firstByte
  fb = fb or 0x80'u8
  fb = fb or 0x40'u8
  fb = (fb and 0xCF'u8) or 0x30'u8 # force Retry long-header type bits
  result.add fb

  result.add byte((version shr 24) and 0xFF)
  result.add byte((version shr 16) and 0xFF)
  result.add byte((version shr 8) and 0xFF)
  result.add byte(version and 0xFF)

  result.add byte(destinationConnId.len)
  if destinationConnId.len > 0:
    result.add destinationConnId
  result.add byte(sourceConnId.len)
  if sourceConnId.len > 0:
    result.add sourceConnId
  if token.len > 0:
    result.add token

  var pseudo: seq[byte] = @[]
  pseudo.add byte(originalDestinationConnId.len)
  if originalDestinationConnId.len > 0:
    pseudo.add originalDestinationConnId
  pseudo.add result

  let tag = retryIntegrityTag(version, pseudo)
  for i in 0 ..< RetryIntegrityTagLen:
    result.add tag[i]

proc parseRetryPacket*(data: openArray[byte]): QuicRetryPacket =
  if data.len < 1 + 4 + 1 + 1 + RetryIntegrityTagLen:
    raise newException(ValueError, "Retry packet too short")

  var off = 0
  result.firstByte = data[off]
  inc off
  if (result.firstByte and 0x80'u8) == 0:
    raise newException(ValueError, "Retry packet must be long header")
  if ((result.firstByte shr 4) and 0x03'u8) != 0x03'u8:
    raise newException(ValueError, "packet is not Retry type")

  result.version =
    (uint32(data[off]) shl 24) or
    (uint32(data[off + 1]) shl 16) or
    (uint32(data[off + 2]) shl 8) or
    uint32(data[off + 3])
  off += 4

  let dcidLen = int(data[off])
  inc off
  if dcidLen > 20 or off + dcidLen > data.len:
    raise newException(ValueError, "Retry packet has invalid destination CID")
  result.dstConnId = sliceToSeq(data, off, off + dcidLen)
  off += dcidLen

  let scidLen = int(data[off])
  inc off
  if scidLen > 20 or off + scidLen > data.len:
    raise newException(ValueError, "Retry packet has invalid source CID")
  result.srcConnId = sliceToSeq(data, off, off + scidLen)
  off += scidLen

  if off + RetryIntegrityTagLen > data.len:
    raise newException(ValueError, "Retry packet missing integrity tag")

  let tokenLen = data.len - off - RetryIntegrityTagLen
  result.token = sliceToSeq(data, off, off + tokenLen)
  off += tokenLen

  for i in 0 ..< RetryIntegrityTagLen:
    result.integrityTag[i] = data[off + i]

proc validateRetryPacketIntegrity*(rawPacket: openArray[byte],
                                   originalDestinationConnId: openArray[byte]): bool =
  ## Validate Retry packet integrity tag.
  if rawPacket.len < RetryIntegrityTagLen:
    return false
  var parsed: QuicRetryPacket
  try:
    parsed = parseRetryPacket(rawPacket)
  except ValueError:
    return false

  let noTagLen = rawPacket.len - RetryIntegrityTagLen
  var pseudo: seq[byte] = @[]
  pseudo.add byte(originalDestinationConnId.len)
  if originalDestinationConnId.len > 0:
    pseudo.add originalDestinationConnId
  pseudo.add sliceToSeq(rawPacket, 0, noTagLen)

  try:
    let expectedTag = retryIntegrityTag(parsed.version, pseudo)
    var provided = newSeq[byte](RetryIntegrityTagLen)
    for i in 0 ..< RetryIntegrityTagLen:
      provided[i] = parsed.integrityTag[i]
    return constantTimeEq(expectedTag, provided)
  except ValueError:
    return false

proc generateStatelessReset*(resetToken: openArray[byte], totalLen: int = 43): seq[byte] =
  ## Build a stateless reset payload with random-looking prefix and trailing token.
  if resetToken.len != StatelessResetTokenLen:
    raise newException(ValueError, "stateless reset token must be 16 bytes")
  if totalLen < StatelessResetMinLen:
    raise newException(ValueError, "stateless reset length must be at least 21 bytes")
  result = newSeq[byte](totalLen)
  var prefix = secureRandomBytes(totalLen - StatelessResetTokenLen)
  for i in 0 ..< prefix.len:
    result[i] = prefix[i]
  # Ensure it looks like a short-header packet candidate:
  # long-header bit clear, fixed bit set.
  result[0] = (result[0] and 0x7F'u8) or 0x40'u8
  for i in 0 ..< StatelessResetTokenLen:
    result[totalLen - StatelessResetTokenLen + i] = resetToken[i]

proc isStatelessResetCandidate*(datagram: openArray[byte], resetToken: openArray[byte]): bool =
  if datagram.len < StatelessResetMinLen:
    return false
  if resetToken.len != StatelessResetTokenLen:
    return false
  # Stateless reset payload must look like a short-header packet.
  if (datagram[0] and 0x80'u8) != 0'u8:
    return false
  if (datagram[0] and 0x40'u8) == 0'u8:
    return false
  let start = datagram.len - StatelessResetTokenLen
  for i in 0 ..< StatelessResetTokenLen:
    if datagram[start + i] != resetToken[i]:
      return false
  return true
