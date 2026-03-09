## BEP 9: Extension for Peers to Send Metadata Files.
##
## Allows peers to exchange torrent metadata (info dict) over the wire.
## Essential for magnet link support - download metadata from peers
## instead of requiring a .torrent file.

import std/[tables, strutils]
import bencode
import sha1
import utils

const
  UtMetadataName* = "ut_metadata"  ## Extension name for BEP 9
  MetadataBlockSize* = 16384       ## 16 KiB per metadata piece

type
  MetadataMsgType* = enum
    mtRequest = 0
    mtData = 1
    mtReject = 2

  MetadataExchange* = ref object
    infoHash*: array[20, byte]
    totalSize*: int           ## Total metadata size in bytes
    numPieces*: int           ## Number of metadata pieces
    pieces*: seq[string]      ## Downloaded metadata pieces
    received*: seq[bool]      ## Which pieces we have
    complete*: bool           ## All pieces received and verified

proc newMetadataExchange*(infoHash: array[20, byte]): MetadataExchange =
  MetadataExchange(
    infoHash: infoHash,
    totalSize: 0
  )

proc initFromSize*(me: MetadataExchange, size: int) =
  ## Initialize piece tracking once we know the metadata size.
  if me.totalSize > 0:
    return  # Already initialized
  me.totalSize = size
  me.numPieces = (size + MetadataBlockSize - 1) div MetadataBlockSize
  me.pieces = newSeq[string](me.numPieces)
  me.received = newSeq[bool](me.numPieces)

proc encodeMetadataRequest*(piece: int): string =
  ## Encode a metadata request message.
  var d = initTable[string, BencodeValue]()
  d["msg_type"] = bInt(mtRequest.int64)
  d["piece"] = bInt(piece.int64)
  return encode(bDict(d))

proc encodeMetadataData*(piece: int, totalSize: int, data: string): string =
  ## Encode a metadata data message (dict + raw data appended).
  var d = initTable[string, BencodeValue]()
  d["msg_type"] = bInt(mtData.int64)
  d["piece"] = bInt(piece.int64)
  d["total_size"] = bInt(totalSize.int64)
  return encode(bDict(d)) & data

proc encodeMetadataReject*(piece: int): string =
  ## Encode a metadata reject message.
  var d = initTable[string, BencodeValue]()
  d["msg_type"] = bInt(mtReject.int64)
  d["piece"] = bInt(piece.int64)
  return encode(bDict(d))

proc decodeMetadataMsg*(payload: string): tuple[msgType: MetadataMsgType,
                                                 piece: int,
                                                 totalSize: int,
                                                 data: string] =
  ## Decode a metadata exchange message.
  ## For mtData, the raw metadata piece follows the bencoded dict.
  let parsed = decodePartial(payload, 0)
  let root = parsed.value
  if root.kind != bkDict:
    raise newException(ValueError, "metadata message not a dict")

  let msgTypeNode = root.getOrDefault("msg_type")
  if msgTypeNode == nil or msgTypeNode.kind != bkInt:
    raise newException(ValueError, "missing msg_type")
  let rawMsgType = msgTypeNode.intVal
  if rawMsgType < ord(MetadataMsgType.low).int64 or rawMsgType > ord(MetadataMsgType.high).int64:
    raise newException(ValueError, "invalid msg_type: " & $rawMsgType)
  result.msgType = MetadataMsgType(rawMsgType)

  let pieceNode = root.getOrDefault("piece")
  if pieceNode == nil or pieceNode.kind != bkInt:
    raise newException(ValueError, "missing piece")
  result.piece = pieceNode.intVal.int

  if result.msgType == mtData:
    let tsNode = root.getOrDefault("total_size")
    if tsNode != nil and tsNode.kind == bkInt:
      result.totalSize = tsNode.intVal.int
    # Raw data follows the bencoded dict
    result.data = payload[parsed.endPos .. ^1]

proc receivePiece*(me: MetadataExchange, piece: int, data: string): bool =
  ## Store a received metadata piece. Returns true if all pieces received.
  if piece < 0 or piece >= me.numPieces:
    return false
  if me.received[piece]:
    return false

  me.pieces[piece] = data
  me.received[piece] = true

  # Check if all pieces received
  for r in me.received:
    if not r:
      return false
  return true

proc assembleAndVerify*(me: MetadataExchange): string =
  ## Assemble metadata from pieces and verify against info hash.
  ## Returns the raw info dict on success, empty string on failure.
  var assembled = ""
  for p in me.pieces:
    assembled.add(p)

  # Verify SHA1 hash matches info hash
  let hash = sha1(assembled)
  if hash != me.infoHash:
    # Reset state so pieces can be re-requested (prevents deadlock)
    for i in 0 ..< me.numPieces:
      me.received[i] = false
      me.pieces[i] = ""
    return ""

  me.complete = true
  return assembled

proc getNeededPieces*(me: MetadataExchange): seq[int] =
  ## Get list of pieces we still need.
  for i in 0 ..< me.numPieces:
    if not me.received[i]:
      result.add(i)

proc getMetadataPiece*(infoDict: string, piece: int): string =
  ## Extract a metadata piece from the complete info dict (for serving to peers).
  let offset = piece * MetadataBlockSize
  if offset >= infoDict.len:
    return ""
  let length = min(MetadataBlockSize, infoDict.len - offset)
  return infoDict[offset ..< offset + length]

# Magnet link helpers

proc decodePercent(s: string): string =
  percentDecode(s)

proc decodeBase32Hash(s: string): array[20, byte] =
  ## Decode a base32 (RFC 4648) encoded info hash.
  const base32Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
  var bits = 0
  var value = 0
  var idx = 0
  for c in s:
    let upper = if c >= 'a' and c <= 'z': char(ord(c) - 32) else: c
    let charIdx = base32Chars.find(upper)
    if charIdx < 0:
      continue
    value = (value shl 5) or charIdx
    bits += 5
    if bits >= 8:
      bits -= 8
      if idx < 20:
        result[idx] = byte((value shr bits) and 0xFF)
        idx += 1

proc parseMagnetLink*(uri: string): tuple[infoHash: array[20, byte],
                                           displayName: string,
                                           trackers: seq[string],
                                           selectedFiles: seq[int]] =
  ## Parse a magnet link URI.
  ## Format: magnet:?xt=urn:btih:<hash>&dn=<name>&tr=<tracker>&so=<file-indices>
  ## BEP 53: `so` parameter specifies file indices to download (comma-separated,
  ## supports ranges like "0-4,6,8").
  if not uri.startsWith("magnet:?"):
    raise newException(ValueError, "not a magnet link")

  let params = uri[8..^1]

  for param in params.split('&'):
    let eqIdx = param.find('=')
    if eqIdx < 0:
      continue
    let key = param[0 ..< eqIdx]
    let value = param[eqIdx+1 .. ^1]

    case key
    of "xt":
      # urn:btih:<hex_hash> or urn:btih:<base32_hash>
      if value.startsWith("urn:btih:"):
        let hashStr = value[9..^1]
        if hashStr.len == 40:
          # Hex-encoded hash
          for i in 0 ..< 20:
            result.infoHash[i] = byte(hexDigitToInt(hashStr[i*2]) shl 4 or hexDigitToInt(hashStr[i*2+1]))
        elif hashStr.len == 32:
          # Base32-encoded hash
          result.infoHash = decodeBase32Hash(hashStr)
    of "dn":
      result.displayName = decodePercent(value)
    of "tr":
      result.trackers.add(decodePercent(value))
    of "so":
      # BEP 53: file selection — "0-4,6,8" means files 0,1,2,3,4,6,8
      let decoded = decodePercent(value)
      for part in decoded.split(','):
        let dashIdx = part.find('-')
        if dashIdx >= 0:
          let startIdx = safeParseInt(part[0 ..< dashIdx], -1)
          let endIdx = safeParseInt(part[dashIdx + 1 .. ^1], -1)
          if startIdx >= 0 and endIdx >= 0:
            for fi in startIdx .. endIdx:
              result.selectedFiles.add(fi)
        else:
          let fi = safeParseInt(part, -1)
          if fi >= 0:
            result.selectedFiles.add(fi)

  # Validate that we got a non-zero info hash
  var allZero = true
  for b in result.infoHash:
    if b != 0:
      allZero = false
      break
  if allZero:
    raise newException(ValueError, "magnet link missing valid xt (info hash)")
