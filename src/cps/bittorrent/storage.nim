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
    filePaths: seq[string]
    fileStarts: seq[int64]  ## Cached cumulative file start offsets

  StorageError* = object of CatchableError

proc newStorageManager*(info: TorrentInfo, baseDir: string): StorageManager =
  result = StorageManager(
    baseDir: baseDir,
    info: info,
    files: newSeq[system.File](info.files.len),
    filePaths: newSeq[string](info.files.len),
    fileStarts: newSeq[int64](info.files.len)
  )
  # Pre-compute cumulative file start offsets
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

proc openFiles*(sm: StorageManager) =
  ## Create directories and open all files for writing.
  for i, fe in sm.info.files:
    validatePath(fe.path)
    let path = sm.baseDir / fe.path
    let dir = parentDir(path)
    if dir.len > 0:
      createDir(dir)
    sm.filePaths[i] = path
    # Open or create file
    if fileExists(path):
      sm.files[i] = open(path, fmReadWriteExisting)
    else:
      sm.files[i] = open(path, fmReadWrite)
      # Pre-allocate file size (skip zero-length files)
      if fe.length > 0:
        sm.files[i].setFilePos(fe.length - 1)
        sm.files[i].write('\0')

proc closeFiles*(sm: StorageManager) =
  for f in sm.files.mitems:
    if f != nil:
      f.close()

proc getFileRegions(sm: StorageManager, pieceIdx: int, offset: int, length: int): seq[FileRegion] =
  ## Map a piece region to file regions. Uses cached file start offsets.
  let pieceStart = int64(pieceIdx) * int64(sm.info.pieceLength) + int64(offset)
  var remaining = length
  var globalOffset = pieceStart

  for i, fe in sm.info.files:
    let fileStart = sm.fileStarts[i]
    let fileEnd = fileStart + fe.length

    if globalOffset >= fileEnd:
      continue
    if globalOffset < fileStart:
      break  # Files are sorted — if we passed our offset, no more matches

    let fileOffset = globalOffset - fileStart
    let availInFile = int(min(int64(remaining), fe.length - fileOffset))
    if availInFile <= 0:
      continue

    result.add(FileRegion(
      fileIndex: i,
      offset: fileOffset,
      length: availInFile
    ))

    remaining -= availInFile
    globalOffset += int64(availInFile)

    if remaining <= 0:
      break

proc writePiece*(sm: StorageManager, pieceIdx: int, data: string) =
  ## Write a complete piece to disk.
  let regions = sm.getFileRegions(pieceIdx, 0, data.len)
  var dataOffset = 0

  var flushed: set[int16] = {}  # Track which files need flushing
  for region in regions:
    let f = sm.files[region.fileIndex]
    f.setFilePos(region.offset)
    let written = f.writeBuffer(unsafeAddr data[dataOffset], region.length)
    if written != region.length:
      raise newException(StorageError, "short write: expected " & $region.length &
                        " wrote " & $written)
    flushed.incl(int16(region.fileIndex))
    dataOffset += region.length
  for idx in flushed:
    sm.files[idx].flushFile()

proc readPiece*(sm: StorageManager, pieceIdx: int, length: int): string =
  ## Read a piece from disk.
  result = newString(length)
  let regions = sm.getFileRegions(pieceIdx, 0, length)
  var dataOffset = 0

  for region in regions:
    let f = sm.files[region.fileIndex]
    f.setFilePos(region.offset)
    let bytesRead = f.readBuffer(addr result[dataOffset], region.length)
    if bytesRead != region.length:
      raise newException(StorageError, "short read: expected " & $region.length &
                        " got " & $bytesRead)
    dataOffset += region.length

proc readBlock*(sm: StorageManager, pieceIdx: int, offset: int, length: int): string =
  ## Read a block from a piece on disk.
  result = newString(length)
  let regions = sm.getFileRegions(pieceIdx, offset, length)
  var dataOffset = 0

  for region in regions:
    let f = sm.files[region.fileIndex]
    f.setFilePos(region.offset)
    let bytesRead = f.readBuffer(addr result[dataOffset], region.length)
    if bytesRead != region.length:
      raise newException(StorageError, "short read in block")
    dataOffset += region.length

proc verifyExistingFiles*(sm: StorageManager, info: TorrentInfo): seq[bool] =
  ## Check which pieces already exist and are valid on disk.
  ## Returns a seq of bools indicating verified pieces.
  ## Uses a single reusable buffer and OpenSSL SHA1 for speed.
  let numPieces = info.pieceCount
  result = newSeq[bool](numPieces)

  # Pre-allocate a single buffer for the largest piece size
  var buf = newString(info.pieceLength)

  for i in 0 ..< numPieces:
    let pieceLen = info.pieceSize(i)
    try:
      # Read into the reusable buffer
      let regions = sm.getFileRegions(i, 0, pieceLen)
      var dataOffset = 0
      var readOk = true
      for region in regions:
        let f = sm.files[region.fileIndex]
        f.setFilePos(region.offset)
        let bytesRead = f.readBuffer(addr buf[dataOffset], region.length)
        if bytesRead != region.length:
          readOk = false
          break
        dataOffset += region.length
      if readOk:
        let hash = sha1(addr buf[0], pieceLen)
        result[i] = (hash == info.pieceHash(i))
      else:
        result[i] = false
    except CatchableError:
      result[i] = false
