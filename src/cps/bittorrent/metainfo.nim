## Torrent metainfo (.torrent file) parser.
##
## Parses BEP 3 torrent files and computes info hashes.

import std/strutils
import bencode
import sha1

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
    rawData*: string             ## Original file data (for info hash)
    urlList*: seq[string]        ## BEP 19: Web seed URLs
    httpSeeds*: seq[string]      ## BEP 17: HTTP seed URLs

  MetainfoError* = object of CatchableError

proc pieceCount*(info: TorrentInfo): int =
  ## Number of pieces in the torrent.
  info.pieces.len div 20

proc pieceHash*(info: TorrentInfo, index: int): array[20, byte] =
  ## Get the expected SHA1 hash for a piece.
  let offset = index * 20
  assert offset + 20 <= info.pieces.len
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
    result.add(b.int.toHex(2).toLowerAscii())

proc infoHashUrlEncoded*(info: TorrentInfo): string =
  ## Info hash as URL-encoded string for tracker requests.
  result = newStringOfCap(60)
  for b in info.infoHash:
    result.add('%')
    result.add(b.int.toHex(2).toUpperAscii())

proc parseInfoFields(infoNode: BencodeValue, info: var TorrentInfo) =
  ## Parse common info dict fields into TorrentInfo.
  let nameNode = infoNode.getOrDefault("name")
  if nameNode == nil or nameNode.kind != bkStr:
    raise newException(MetainfoError, "missing 'name' in info dict")
  info.name = nameNode.strVal

  let pieceLenNode = infoNode.getOrDefault("piece length")
  if pieceLenNode == nil or pieceLenNode.kind != bkInt:
    raise newException(MetainfoError, "missing 'piece length' in info dict")
  info.pieceLength = pieceLenNode.intVal.int

  let piecesNode = infoNode.getOrDefault("pieces")
  if piecesNode == nil or piecesNode.kind != bkStr:
    raise newException(MetainfoError, "missing 'pieces' in info dict")
  if piecesNode.strVal.len mod 20 != 0:
    raise newException(MetainfoError, "pieces length not multiple of 20")
  info.pieces = piecesNode.strVal

  let privateNode = infoNode.getOrDefault("private")
  if privateNode != nil and privateNode.kind == bkInt:
    info.isPrivate = privateNode.intVal == 1

  let filesNode = infoNode.getOrDefault("files")
  if filesNode != nil and filesNode.kind == bkList:
    var totalLen: int64 = 0
    for fileNode in filesNode.listVal:
      if fileNode.kind != bkDict:
        raise newException(MetainfoError, "invalid file entry")
      let lenNode = fileNode.getOrDefault("length")
      if lenNode == nil or lenNode.kind != bkInt:
        raise newException(MetainfoError, "missing file length")
      let pathNode = fileNode.getOrDefault("path")
      if pathNode == nil or pathNode.kind != bkList:
        raise newException(MetainfoError, "missing file path")
      var pathParts: seq[string]
      for part in pathNode.listVal:
        if part.kind == bkStr:
          pathParts.add(part.strVal)
      let fe = FileEntry(
        path: pathParts.join("/"),
        length: lenNode.intVal
      )
      info.files.add(fe)
      totalLen += fe.length
    info.totalLength = totalLen
  else:
    let lenNode = infoNode.getOrDefault("length")
    if lenNode == nil or lenNode.kind != bkInt:
      raise newException(MetainfoError, "missing 'length' in single-file info")
    info.totalLength = lenNode.intVal
    info.files = @[FileEntry(
      path: info.name,
      length: lenNode.intVal
    )]

proc parseTorrent*(data: string): TorrentMetainfo =
  ## Parse a .torrent file from raw bytes.
  let root = decode(data)
  if root.kind != bkDict:
    raise newException(MetainfoError, "torrent root is not a dictionary")

  result.rawData = data

  # Announce
  let announceNode = root.getOrDefault("announce")
  if announceNode != nil and announceNode.kind == bkStr:
    result.announce = announceNode.strVal

  # Announce list (BEP 12)
  let announceListNode = root.getOrDefault("announce-list")
  if announceListNode != nil and announceListNode.kind == bkList:
    for tier in announceListNode.listVal:
      if tier.kind == bkList:
        var urls: seq[string]
        for url in tier.listVal:
          if url.kind == bkStr and url.strVal.len > 0:
            urls.add(url.strVal)
        if urls.len > 0:
          result.announceList.add(urls)

  # Comment
  let commentNode = root.getOrDefault("comment")
  if commentNode != nil and commentNode.kind == bkStr:
    result.comment = commentNode.strVal

  # Created by
  let createdByNode = root.getOrDefault("created by")
  if createdByNode != nil and createdByNode.kind == bkStr:
    result.createdBy = createdByNode.strVal

  # Creation date
  let dateNode = root.getOrDefault("creation date")
  if dateNode != nil and dateNode.kind == bkInt:
    result.creationDate = dateNode.intVal

  # Info dict
  let infoNode = root.getOrDefault("info")
  if infoNode == nil or infoNode.kind != bkDict:
    raise newException(MetainfoError, "missing or invalid 'info' dictionary")

  # Compute info hash from raw bencoded info dict
  let rawInfo = extractRawValue(data, "info")
  result.info.infoHash = sha1(rawInfo)

  parseInfoFields(infoNode, result.info)

  # BEP 19: url-list (web seeds)
  let urlListNode = root.getOrDefault("url-list")
  if urlListNode != nil:
    if urlListNode.kind == bkStr:
      result.urlList = @[urlListNode.strVal]
    elif urlListNode.kind == bkList:
      for item in urlListNode.listVal:
        if item.kind == bkStr:
          result.urlList.add(item.strVal)

  # BEP 17: httpseeds
  let httpSeedsNode = root.getOrDefault("httpseeds")
  if httpSeedsNode != nil and httpSeedsNode.kind == bkList:
    for item in httpSeedsNode.listVal:
      if item.kind == bkStr:
        result.httpSeeds.add(item.strVal)

proc parseRawInfoDict*(rawInfoDict: string, infoHash: array[20, byte]): TorrentInfo =
  ## Parse a raw bencoded info dict into TorrentInfo.
  ## Used for BEP 9 metadata exchange (magnet links).
  let infoNode = decode(rawInfoDict)
  if infoNode.kind != bkDict:
    raise newException(MetainfoError, "info dict is not a dictionary")

  result.infoHash = infoHash
  parseInfoFields(infoNode, result)

proc parseTorrentFile*(path: string): TorrentMetainfo =
  ## Parse a .torrent file from disk.
  let data = readFile(path)
  parseTorrent(data)
