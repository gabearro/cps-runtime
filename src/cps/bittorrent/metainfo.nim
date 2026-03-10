## Torrent metainfo (.torrent file) parser.
##
## Parses BEP 3 torrent files and computes info hashes.

import bencode
import sha1

const
  HexLower = "0123456789abcdef"
  HexUpper = "0123456789ABCDEF"

type
  FileEntry* = object
    path*: string        ## Relative path (joined with /)
    length*: int64       ## File size in bytes

  TorrentInfo* = object
    infoHash*: array[20, byte]   ## SHA1 of raw bencoded info dict
    name*: string                ## Suggested name for file/directory
    pieceLength*: int            ## Bytes per piece
    pieces*: string              ## Concatenated SHA1 hashes (20 bytes each)
    totalLength*: int64          ## Total size of all files
    files*: seq[FileEntry]       ## File list (single file = 1 entry)
    isPrivate*: bool             ## Private tracker flag

  TorrentMetainfo* = object
    info*: TorrentInfo
    announce*: string            ## Primary tracker URL
    announceList*: seq[seq[string]]  ## BEP 12 multi-tracker tiers
    comment*: string
    createdBy*: string
    creationDate*: int64
    rawInfoDict*: string         ## Raw bencoded info dict (for BEP 9 metadata serving)
    urlList*: seq[string]        ## BEP 19: Web seed URLs
    httpSeeds*: seq[string]      ## BEP 17: HTTP seed URLs

  MetainfoError* = object of CatchableError

proc pieceCount*(info: TorrentInfo): int =
  ## Number of pieces in the torrent.
  info.pieces.len div 20

proc pieceHash*(info: TorrentInfo, index: int): array[20, byte] =
  ## Get the expected SHA1 hash for a piece.
  let offset = index * 20
  if offset + 20 > info.pieces.len:
    raise newException(MetainfoError, "piece index out of range: " & $index)
  copyMem(addr result[0], unsafeAddr info.pieces[offset], 20)

proc lastPieceLength*(info: TorrentInfo): int =
  ## Size of the last piece (may be smaller than pieceLength).
  let rem = info.totalLength mod info.pieceLength.int64
  if rem == 0: info.pieceLength
  else: rem.int

proc pieceSize*(info: TorrentInfo, index: int): int =
  ## Size of a specific piece.
  if index == info.pieceCount - 1:
    info.lastPieceLength
  else:
    info.pieceLength

proc infoHashHex*(info: TorrentInfo): string =
  ## Info hash as lowercase hex string.
  result = newStringOfCap(40)
  for b in info.infoHash:
    result.add(HexLower[b.int shr 4])
    result.add(HexLower[b.int and 0x0F])

proc infoHashUrlEncoded*(info: TorrentInfo): string =
  ## Info hash as URL-encoded string for tracker requests.
  result = newStringOfCap(60)
  for b in info.infoHash:
    result.add('%')
    result.add(HexUpper[b.int shr 4])
    result.add(HexUpper[b.int and 0x0F])

proc parseFileEntry(fileNode: BencodeValue): FileEntry =
  ## Parse a single file entry from a multi-file info dict.
  if fileNode.kind != bkDict:
    raise newException(MetainfoError, "invalid file entry")
  let length = fileNode.requireInt("length", "file entry")
  let pathNode = fileNode.getOrDefault("path")
  if pathNode == nil or pathNode.kind != bkList:
    raise newException(MetainfoError, "missing 'path' in file entry")
  # Build path directly without intermediate seq
  var path: string
  for part in pathNode.listVal:
    if part.kind == bkStr:
      if path.len > 0: path.add('/')
      path.add(part.strVal)
  FileEntry(path: path, length: length)

proc parseInfoFields(infoNode: BencodeValue, info: var TorrentInfo) =
  ## Parse common info dict fields into TorrentInfo.
  info.name = infoNode.requireStr("name", "info dict")
  info.pieceLength = infoNode.requireInt("piece length", "info dict").int

  let piecesRaw = infoNode.requireStr("pieces", "info dict")
  if piecesRaw.len mod 20 != 0:
    raise newException(MetainfoError, "pieces length not multiple of 20")
  info.pieces = piecesRaw

  info.isPrivate = infoNode.optInt("private") == 1

  let filesNode = infoNode.getOrDefault("files")
  if filesNode != nil and filesNode.kind == bkList:
    var totalLen: int64 = 0
    for fileNode in filesNode.listVal:
      let fe = parseFileEntry(fileNode)
      info.files.add(fe)
      totalLen += fe.length
    info.totalLength = totalLen
  else:
    let length = infoNode.requireInt("length", "single-file info")
    info.totalLength = length
    info.files = @[FileEntry(path: info.name, length: length)]

proc parseAnnounceTiers(root: BencodeValue): seq[seq[string]] =
  ## Parse BEP 12 announce-list tiers.
  let node = root.getOrDefault("announce-list")
  if node == nil or node.kind != bkList: return
  for tier in node.listVal:
    if tier.kind == bkList:
      var urls: seq[string]
      for url in tier.listVal:
        if url.kind == bkStr and url.strVal.len > 0:
          urls.add(url.strVal)
      if urls.len > 0:
        result.add(urls)

proc parseTorrent*(data: string): TorrentMetainfo =
  ## Parse a .torrent file from raw bytes.
  try:
    let root = decode(data)
    if root.kind != bkDict:
      raise newException(MetainfoError, "torrent root is not a dictionary")

    result.announce = root.optStr("announce")
    result.announceList = parseAnnounceTiers(root)
    result.comment = root.optStr("comment")
    result.createdBy = root.optStr("created by")
    result.creationDate = root.optInt("creation date")

    let infoNode = root.requireDict("info", "torrent")

    # Extract raw info dict once — used for info hash and BEP 9 metadata serving
    let rawInfo = extractRawValue(data, "info")
    result.info.infoHash = sha1(rawInfo)
    result.rawInfoDict = rawInfo

    parseInfoFields(infoNode, result.info)

    result.urlList = root.optStrList("url-list")
    result.httpSeeds = root.optStrList("httpseeds")
  except BencodeError as e:
    raise newException(MetainfoError, e.msg)

proc parseRawInfoDict*(rawInfoDict: string, infoHash: array[20, byte]): TorrentInfo =
  ## Parse a raw bencoded info dict into TorrentInfo.
  ## Used for BEP 9 metadata exchange (magnet links).
  try:
    let infoNode = decode(rawInfoDict)
    if infoNode.kind != bkDict:
      raise newException(MetainfoError, "info dict is not a dictionary")
    result.infoHash = infoHash
    parseInfoFields(infoNode, result)
  except BencodeError as e:
    raise newException(MetainfoError, e.msg)

proc parseTorrentFile*(path: string): TorrentMetainfo =
  ## Parse a .torrent file from disk (blocking I/O).
  parseTorrent(readFile(path))
