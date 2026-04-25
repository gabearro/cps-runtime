## Tests for BitTorrent disk storage.

import std/[os, strutils]
import cps/bittorrent/metainfo
import cps/bittorrent/storage
import cps/bittorrent/sha1

proc makeTorrentInfo(totalLength: int64, pieceLength: int,
                     files: seq[FileEntry]): TorrentInfo =
  result.pieceLength = pieceLength
  result.totalLength = totalLength
  result.name = "test_torrent"
  result.files = files
  let numPieces = (totalLength.int + pieceLength - 1) div pieceLength
  var piecesStr = ""
  for i in 0 ..< numPieces:
    let start = i * pieceLength
    let size = min(pieceLength, totalLength.int - start)
    var pieceData = newString(size)
    for j in 0 ..< size:
      pieceData[j] = char((start + j) mod 256)
    let hash = sha1(pieceData)
    for b in hash:
      piecesStr.add(char(b))
  result.pieces = piecesStr

let testDir = getTempDir() / "bt_storage_test_" & $getCurrentProcessId()

# Single file write/read
block testSingleFileWriteRead:
  let dir = testDir / "single"
  let files = @[FileEntry(path: "test.bin", length: 65536)]
  let info = makeTorrentInfo(65536, 32768, files)

  let sm = newStorageManager(info, dir)
  sm.openFiles()

  # Write first piece
  var piece0 = newString(32768)
  for i in 0 ..< 32768:
    piece0[i] = char(i mod 256)
  sm.writePiece(0, piece0)

  # Write second piece
  var piece1 = newString(32768)
  for i in 0 ..< 32768:
    piece1[i] = char((32768 + i) mod 256)
  sm.writePiece(1, piece1)

  # Read back and verify
  let read0 = sm.readPiece(0, 32768)
  assert read0 == piece0
  let read1 = sm.readPiece(1, 32768)
  assert read1 == piece1

  # Read a block
  let block0 = sm.readBlock(0, 16384, 16384)
  assert block0 == piece0[16384 ..< 32768]

  sm.closeFiles()
  echo "PASS: single file write/read"

# Multi-file torrent (piece spans files)
block testMultiFileWriteRead:
  let dir = testDir / "multi"
  let files = @[
    FileEntry(path: "file1.bin", length: 20000),
    FileEntry(path: "subdir/file2.bin", length: 30000)
  ]
  let info = makeTorrentInfo(50000, 32768, files)

  let sm = newStorageManager(info, dir)
  sm.openFiles()

  # First piece: 32768 bytes spanning file1 (20000) + file2 (12768)
  var piece0 = newString(32768)
  for i in 0 ..< 32768:
    piece0[i] = char(i mod 256)
  sm.writePiece(0, piece0)

  # Second piece: remaining 17232 bytes of file2
  var piece1 = newString(50000 - 32768)
  for i in 0 ..< piece1.len:
    piece1[i] = char((32768 + i) mod 256)
  sm.writePiece(1, piece1)

  # Read back first piece
  let read0 = sm.readPiece(0, 32768)
  assert read0 == piece0

  # Read back second piece
  let read1 = sm.readPiece(1, piece1.len)
  assert read1 == piece1

  sm.closeFiles()

  # Verify the actual files on disk
  assert fileExists(dir / "file1.bin")
  assert fileExists(dir / "subdir" / "file2.bin")
  assert getFileSize(dir / "file1.bin") == 20000
  assert getFileSize(dir / "subdir" / "file2.bin") == 30000

  echo "PASS: multi-file write/read"

# Verify existing files
block testVerifyExisting:
  let dir = testDir / "verify"
  let files = @[FileEntry(path: "data.bin", length: 65536)]
  let info = makeTorrentInfo(65536, 32768, files)

  let sm = newStorageManager(info, dir)
  sm.openFiles()

  # Write correct data for piece 0
  var piece0 = newString(32768)
  for i in 0 ..< 32768:
    piece0[i] = char(i mod 256)
  sm.writePiece(0, piece0)

  # Write WRONG data for piece 1
  var piece1 = newString(32768)
  for i in 0 ..< 32768:
    piece1[i] = char(0xFF)  # All 0xFF instead of correct data
  sm.writePiece(1, piece1)

  # Verify
  let verified = sm.verifyExistingFiles(info)
  assert verified.len == 2
  assert verified[0] == true, "piece 0 should verify"
  assert verified[1] == false, "piece 1 should fail verification"

  sm.closeFiles()
  echo "PASS: verify existing files"

# Zero-length file should not crash storage init
block testZeroLengthFile:
  let dir = testDir / "zero"
  let files = @[
    FileEntry(path: "empty.txt", length: 0),
    FileEntry(path: "data.bin", length: 32768)
  ]
  let info = makeTorrentInfo(32768, 32768, files)

  let sm = newStorageManager(info, dir)
  var initOk = true
  try:
    sm.openFiles()
  except CatchableError as e:
    initOk = false
  except Exception as e:
    initOk = false
  assert initOk, "openFiles should not crash on zero-length files"

  # The zero-length file should exist
  assert fileExists(dir / "empty.txt")

  sm.closeFiles()
  echo "PASS: zero-length file init"

# Verify existing files with truncated file (short read)
block testVerifyShortRead:
  let dir = testDir / "shortread"
  let files = @[FileEntry(path: "data.bin", length: 65536)]
  let info = makeTorrentInfo(65536, 32768, files)

  let sm = newStorageManager(info, dir)
  sm.openFiles()

  # Write only partial data — piece 0 correct, piece 1 truncated file
  var piece0 = newString(32768)
  for i in 0 ..< 32768:
    piece0[i] = char(i mod 256)
  sm.writePiece(0, piece0)

  sm.closeFiles()

  # Now truncate the file to only have piece 0 (remove piece 1 data)
  let filePath = dir / "data.bin"
  let f = open(filePath, fmReadWriteExisting)
  # Truncate to just 40000 bytes (piece 1 starts at 32768, needs 32768 but only 7232 available)
  f.setFilePos(39999)
  f.write('\0')
  f.close()
  # Actually set file size by rewriting
  let content = readFile(filePath)
  writeFile(filePath, content[0 ..< 40000])

  let sm2 = newStorageManager(info, dir)
  sm2.openFiles()
  let verified = sm2.verifyExistingFiles(info)
  assert verified[0] == true, "piece 0 should still verify"
  assert verified[1] == false, "piece 1 should fail (short read from truncated file)"
  sm2.closeFiles()
  echo "PASS: verify existing files with short read"

# Path traversal prevention
block testPathTraversal:
  let dir = testDir / "traverse"
  let files = @[
    FileEntry(path: "../../escape.txt", length: 100),
    FileEntry(path: "normal.bin", length: 100)
  ]
  let info = makeTorrentInfo(200, 200, files)
  let sm = newStorageManager(info, dir)

  var caught = false
  try:
    sm.openFiles()
  except StorageError:
    caught = true
  assert caught, "openFiles should reject paths with .."

  # Also test absolute path
  let files2 = @[FileEntry(path: "/etc/evil.txt", length: 100)]
  let info2 = makeTorrentInfo(100, 100, files2)
  let sm2 = newStorageManager(info2, dir)
  var caught2 = false
  try:
    sm2.openFiles()
  except StorageError:
    caught2 = true
  assert caught2, "openFiles should reject absolute paths"
  echo "PASS: path traversal prevention"

# Cleanup
block cleanup:
  removeDir(testDir)
  echo "PASS: cleanup"

echo "ALL STORAGE TESTS PASSED"
