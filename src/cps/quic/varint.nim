## QUIC Variable-Length Integer Encoding (RFC 9000, section 16)

import std/[strformat]

const
  QuicVarIntMax1* = 63'u64
  QuicVarIntMax2* = 16_383'u64
  QuicVarIntMax4* = 1_073_741_823'u64
  QuicVarIntMax8* = 4_611_686_018_427_387_903'u64

proc quicVarIntLen*(v: uint64): int {.inline.} =
  ## Return encoded size in bytes for a QUIC varint.
  if v <= QuicVarIntMax1:
    1
  elif v <= QuicVarIntMax2:
    2
  elif v <= QuicVarIntMax4:
    4
  elif v <= QuicVarIntMax8:
    8
  else:
    raise newException(ValueError, fmt"QUIC varint out of range: {v}")

proc appendQuicVarInt*(dst: var seq[byte], v: uint64) =
  ## Append a QUIC varint to `dst`.
  case quicVarIntLen(v)
  of 1:
    dst.add byte(v and 0x3F)
  of 2:
    dst.add byte(0x40 or ((v shr 8) and 0x3F))
    dst.add byte(v and 0xFF)
  of 4:
    dst.add byte(0x80 or ((v shr 24) and 0x3F))
    dst.add byte((v shr 16) and 0xFF)
    dst.add byte((v shr 8) and 0xFF)
    dst.add byte(v and 0xFF)
  of 8:
    dst.add byte(0xC0 or ((v shr 56) and 0x3F))
    dst.add byte((v shr 48) and 0xFF)
    dst.add byte((v shr 40) and 0xFF)
    dst.add byte((v shr 32) and 0xFF)
    dst.add byte((v shr 24) and 0xFF)
    dst.add byte((v shr 16) and 0xFF)
    dst.add byte((v shr 8) and 0xFF)
    dst.add byte(v and 0xFF)
  else:
    raise newException(AssertionDefect, "unreachable")

proc encodeQuicVarInt*(v: uint64): seq[byte] =
  ## Encode a value as QUIC varint.
  result = @[]
  result.appendQuicVarInt(v)

proc quicVarIntEncodedLen*(firstByte: byte): int {.inline.} =
  ## Return QUIC varint encoded length from first byte.
  1 shl int((firstByte shr 6) and 0x03)

proc decodeQuicVarInt*(data: openArray[byte], offset: var int): uint64 =
  ## Decode QUIC varint from `data[offset..]` and advance offset.
  if offset >= data.len:
    raise newException(ValueError, "QUIC varint decode: empty input")

  let first = data[offset]
  let encLen = quicVarIntEncodedLen(first)
  if offset + encLen > data.len:
    raise newException(ValueError, "QUIC varint decode: truncated input")

  case encLen
  of 1:
    result = uint64(first and 0x3F)
  of 2:
    result = (uint64(first and 0x3F) shl 8) or
             uint64(data[offset + 1])
  of 4:
    result = (uint64(first and 0x3F) shl 24) or
             (uint64(data[offset + 1]) shl 16) or
             (uint64(data[offset + 2]) shl 8) or
             uint64(data[offset + 3])
  of 8:
    result = (uint64(first and 0x3F) shl 56) or
             (uint64(data[offset + 1]) shl 48) or
             (uint64(data[offset + 2]) shl 40) or
             (uint64(data[offset + 3]) shl 32) or
             (uint64(data[offset + 4]) shl 24) or
             (uint64(data[offset + 5]) shl 16) or
             (uint64(data[offset + 6]) shl 8) or
             uint64(data[offset + 7])
  else:
    raise newException(AssertionDefect, "unreachable")

  offset += encLen
