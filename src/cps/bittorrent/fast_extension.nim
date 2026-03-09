## BEP 6: Fast Extension.
##
## Adds messages for faster piece exchange:
## - Suggest Piece (0x0D): suggest a piece for downloading
## - Have All (0x0E) / Have None (0x0F): shorthand for full/empty bitfields
## - Reject Request (0x10): explicitly reject a request
## - Allowed Fast (0x11): pieces requestable while choked

import std/strutils
import sha1
import utils

const
  FastMsgSuggestPiece* = 0x0D'u8
  FastMsgHaveAll* = 0x0E'u8
  FastMsgHaveNone* = 0x0F'u8
  FastMsgRejectRequest* = 0x10'u8
  FastMsgAllowedFast* = 0x11'u8
  FastExtensionBit* = 0x04'u8  ## Bit in reserved[7]

proc supportsFastExtension*(reserved: array[8, byte]): bool =
  (reserved[7] and FastExtensionBit) != 0

proc setFastExtensionBit*(reserved: var array[8, byte]) =
  reserved[7] = reserved[7] or FastExtensionBit

# Encoding fast extension messages

proc encodeSuggestPiece*(index: uint32): string =
  ## Encode Suggest Piece message.
  var payload = ""
  payload.add(char(FastMsgSuggestPiece))
  payload.writeUint32BE(index)
  result = newStringOfCap(4 + payload.len)
  result.writeUint32BE(uint32(payload.len))
  result.add(payload)

proc encodeHaveAll*(): string =
  ## Encode Have All message (single byte, no payload).
  result = newStringOfCap(5)
  result.writeUint32BE(1)
  result.add(char(FastMsgHaveAll))

proc encodeHaveNone*(): string =
  ## Encode Have None message (single byte, no payload).
  result = newStringOfCap(5)
  result.writeUint32BE(1)
  result.add(char(FastMsgHaveNone))

proc encodeRejectRequest*(index, begin, length: uint32): string =
  ## Encode Reject Request message.
  var payload = ""
  payload.add(char(FastMsgRejectRequest))
  payload.writeUint32BE(index)
  payload.writeUint32BE(begin)
  payload.writeUint32BE(length)
  result = newStringOfCap(4 + payload.len)
  result.writeUint32BE(uint32(payload.len))
  result.add(payload)

proc encodeAllowedFast*(index: uint32): string =
  ## Encode Allowed Fast message.
  var payload = ""
  payload.add(char(FastMsgAllowedFast))
  payload.writeUint32BE(index)
  result = newStringOfCap(4 + payload.len)
  result.writeUint32BE(uint32(payload.len))
  result.add(payload)

# Allowed fast set generation (BEP 6 algorithm)
proc generateAllowedFastSet*(infoHash: array[20, byte],
                              ip: string,
                              numPieces: int,
                              setSize: int = 10): seq[uint32] =
  ## Generate the Allowed Fast set for a peer using the BEP 6 algorithm.
  let parts = ip.split('.')
  if parts.len != 4:
    return @[]

  var ipBytes: array[4, byte]
  for i in 0 ..< 4:
    ipBytes[i] = byte(parseInt(parts[i]))
  ipBytes[3] = 0  # Mask to /24

  # Initial hash: SHA1(ip_masked + info_hash)
  var hashInput = ""
  for b in ipBytes:
    hashInput.add(char(b))
  for b in infoHash:
    hashInput.add(char(b))

  var hash = sha1(hashInput)
  result = @[]

  while result.len < setSize:
    for i in countup(0, 16, 4):
      if result.len >= setSize:
        break
      let idx = (uint32(hash[i]) shl 24 or uint32(hash[i+1]) shl 16 or
                 uint32(hash[i+2]) shl 8 or uint32(hash[i+3])) mod uint32(numPieces)
      var found = false
      for existing in result:
        if existing == idx:
          found = true
          break
      if not found:
        result.add(idx)

    # Generate next hash from current hash
    var nextInput = ""
    for b in hash:
      nextInput.add(char(b))
    hash = sha1(nextInput)
