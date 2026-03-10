## Disk storage for BitTorrent downloads.
##
## Maps pieces to file regions and handles reading/writing to disk.
## Supports both single-file and multi-file torrents.

import std/[os, strutils]
import metainfo
import sha1

type
  FileRegion = object
    fileIndex: int
    offset: int64
    length: int

  StorageManager* = ref object
    baseDir*: string
    info*: TorrentInfo
    files: seq[system.File]
    fileStarts: seq[int64]  ## Cached cumulative file start offsets

  StorageError* = object of CatchableError

proc newStorageManager*(info: TorrentInfo, baseDir: string): StorageManager =
  result = StorageManager(
    baseDir: baseDir,
    info: info,
    files: newSeq[system.File](info.files.len),
    fileStarts: newSeq[int64](info.files.len)
  )
  var offset: int64 = 0
  for i, fe in info.files:
    result.fileStarts[i] = offset
    offset += fe.length

proc validatePath(filePath: string) =
  ## Reject file paths that could escape the base directory.
  if filePath.len == 0:
    raise newException(StorageError, "empty file path in torrent")
  if filePath.startsWith("/") or filePath.startsWith("\\"):
    raise newException(StorageError, "absolute path in torrent: " & filePath)
  if filePath.len >= 2 and filePath[1] == ':':
    raise newException(StorageError, "absolute path in torrent: " & filePath)
  for component in filePath.split({'/', '\\'}):
    if component == "..":
      raise newException(StorageError, "path traversal in torrent: " & filePath)

proc closeFiles*(sm: StorageManager) =
  ## Close all file handles. Safe to call multiple times.
  for i in 0 ..< sm.files.len:
    if sm.files[i] != nil:
      try: sm.files[i].close()
      except CatchableError: discard
      sm.files[i] = nil

proc openFiles*(sm: StorageManager) =
  ## Create directories and open all files for read/write.
  ## Cleans up already-opened files on failure.
  try:
    for i, fe in sm.info.files:
      validatePath(fe.path)
      let path = sm.baseDir / fe.path
      let dir = parentDir(path)
      if dir.len > 0:
        createDir(dir)
      try:
        sm.files[i] = open(path, fmReadWriteExisting)
      except IOError:
        sm.files[i] = open(path, fmReadWrite)
        if fe.length > 0:
          sm.files[i].setFilePos(fe.length - 1)
          sm.files[i].write('\0')
  except CatchableError:
    sm.closeFiles()
    raise

proc findStartFile(sm: StorageManager, globalOffset: int64): int =
  ## Binary search for the file containing globalOffset.
  var lo = 0
  var hi = sm.fileStarts.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if sm.fileStarts[mid] <= globalOffset:
      lo = mid
    else:
      hi = mid - 1
  lo

iterator fileRegions(sm: StorageManager, pieceIdx: int, offset: int,
                     length: int): FileRegion =
  ## Yield file regions covering a piece range. Uses binary search to
  ## find the starting file in O(log n) instead of scanning from index 0.
  let pieceStart = int64(pieceIdx) * int64(sm.info.pieceLength) + int64(offset)
  var remaining = length
  var globalOffset = pieceStart
  var i = sm.findStartFile(globalOffset)
  while i < sm.info.files.len and remaining > 0:
    let fe = sm.info.files[i]
    let fileEnd = sm.fileStarts[i] + fe.length
    if globalOffset < fileEnd:
      let fileOffset = globalOffset - sm.fileStarts[i]
      let n = int(min(int64(remaining), fe.length - fileOffset))
      yield FileRegion(fileIndex: i, offset: fileOffset, length: n)
      remaining -= n
      globalOffset += int64(n)
    inc i

proc readRegions(sm: StorageManager, pieceIdx: int, offset: int,
                 buf: var string, length: int): bool =
  ## Read piece data into buf. Returns false on short read.
  var dataOffset = 0
  for region in sm.fileRegions(pieceIdx, offset, length):
    let f = sm.files[region.fileIndex]
    f.setFilePos(region.offset)
    let n = f.readBuffer(addr buf[dataOffset], region.length)
    if n != region.length:
      return false
    dataOffset += region.length
  true

proc writePiece*(sm: StorageManager, pieceIdx: int, data: string,
                 flush = true) =
  ## Write a complete piece to disk.
  var dataOffset = 0
  for region in sm.fileRegions(pieceIdx, 0, data.len):
    let f = sm.files[region.fileIndex]
    f.setFilePos(region.offset)
    let n = f.writeBuffer(unsafeAddr data[dataOffset], region.length)
    if n != region.length:
      raise newException(StorageError, "short write: expected " &
                        $region.length & " wrote " & $n)
    dataOffset += region.length
    if flush:
      f.flushFile()

proc readBlock*(sm: StorageManager, pieceIdx: int, offset: int,
                length: int): string =
  ## Read a block from a piece on disk.
  result = newString(length)
  if not sm.readRegions(pieceIdx, offset, result, length):
    raise newException(StorageError, "short read at piece " & $pieceIdx &
                      " offset " & $offset)

proc readPiece*(sm: StorageManager, pieceIdx: int, length: int): string =
  ## Read a complete piece from disk.
  sm.readBlock(pieceIdx, 0, length)

proc verifyExistingFiles*(sm: StorageManager, info: TorrentInfo): seq[bool] =
  ## Check which pieces already exist and are valid on disk.
  ## Uses a single reusable buffer and OpenSSL SHA1 for speed.
  let numPieces = info.pieceCount
  result = newSeq[bool](numPieces)
  var buf = newString(info.pieceLength)
  for i in 0 ..< numPieces:
    let pieceLen = info.pieceSize(i)
    try:
      if sm.readRegions(i, 0, buf, pieceLen):
        result[i] = sha1(addr buf[0], pieceLen) == info.pieceHash(i)
    except CatchableError:
      discard
