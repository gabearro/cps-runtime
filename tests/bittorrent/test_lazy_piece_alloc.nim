## Tests for lazy piece buffer allocation.
## Verifies that piece buffers are not allocated upfront and are
## deallocated after verification or failure.

import cps/bittorrent/pieces
import cps/bittorrent/metainfo
import cps/bittorrent/sha1

proc makeTestInfo(pieceLength: int, totalLength: int64): TorrentInfo =
  result.pieceLength = pieceLength
  result.totalLength = totalLength
  result.files = @[FileEntry(path: "test.bin", length: totalLength)]
  let numPieces = int((totalLength + int64(pieceLength) - 1) div int64(pieceLength))
  result.pieces = newString(numPieces * 20)

block: # pieces start with empty buffers (lazy allocation)
  let info = makeTestInfo(65536, 65536 * 100)  # 100 pieces of 64KB
  let pm = newPieceManager(info)

  var totalBufferSize = 0
  for i in 0 ..< pm.totalPieces:
    totalBufferSize += pm.pieces[i].data.len

  assert totalBufferSize == 0, "no buffers should be allocated upfront, got " & $totalBufferSize & " bytes"
  echo "PASS: pieces start with empty buffers"

block: # buffer allocated on first block receipt
  let info = makeTestInfo(32768, 32768)  # 1 piece of 32KB = 2 blocks
  let pm = newPieceManager(info)

  assert pm.pieces[0].data.len == 0, "buffer should be empty initially"

  let data = newString(BlockSize)
  discard pm.receiveBlock(0, 0, data)

  assert pm.pieces[0].data.len == 32768, "buffer should be allocated on first block, got " & $pm.pieces[0].data.len
  echo "PASS: buffer allocated on first block receipt"

block: # buffer released after getPieceData
  let pieceLen = 32768
  # Build a piece whose SHA1 we know
  var pieceData = newString(pieceLen)
  for i in 0 ..< pieceLen:
    pieceData[i] = char(i mod 256)
  let hash = sha1(pieceData)

  # Build info with correct hash
  var info: TorrentInfo
  info.pieceLength = pieceLen
  info.totalLength = int64(pieceLen)
  info.files = @[FileEntry(path: "test.bin", length: int64(pieceLen))]
  info.pieces = newString(20)
  copyMem(addr info.pieces[0], unsafeAddr hash[0], 20)

  let pm = newPieceManager(info)

  # Feed all blocks
  var offset = 0
  while offset < pieceLen:
    let blockLen = min(BlockSize, pieceLen - offset)
    discard pm.receiveBlock(0, offset, pieceData[offset ..< offset + blockLen])
    offset += blockLen

  assert pm.pieces[0].state == psComplete
  assert pm.pieces[0].data.len == pieceLen

  let valid = pm.verifyPiece(0)
  assert valid, "piece should verify correctly"

  # getPieceData should return the data and release the buffer
  let retrieved = pm.getPieceData(0)
  assert retrieved.len == pieceLen, "retrieved data should have correct length"
  assert pm.pieces[0].data.len == 0, "buffer should be released after getPieceData"
  echo "PASS: buffer released after getPieceData"

block: # buffer released on verification failure
  let pieceLen = 32768
  var info: TorrentInfo
  info.pieceLength = pieceLen
  info.totalLength = int64(pieceLen)
  info.files = @[FileEntry(path: "test.bin", length: int64(pieceLen))]
  # Wrong hash (all zeros)
  info.pieces = newString(20)

  let pm = newPieceManager(info)

  var pieceData = newString(pieceLen)
  for i in 0 ..< pieceLen:
    pieceData[i] = char(i mod 256)

  var offset = 0
  while offset < pieceLen:
    let blockLen = min(BlockSize, pieceLen - offset)
    discard pm.receiveBlock(0, offset, pieceData[offset ..< offset + blockLen])
    offset += blockLen

  assert pm.pieces[0].state == psComplete
  let valid = pm.verifyPiece(0)
  assert not valid, "piece should fail verification (wrong hash)"
  assert pm.pieces[0].data.len == 0, "buffer should be released on verification failure"
  echo "PASS: buffer released on verification failure"

block: # buffer released on resetPiece
  let info = makeTestInfo(32768, 32768)
  let pm = newPieceManager(info)

  let data = newString(BlockSize)
  discard pm.receiveBlock(0, 0, data)
  assert pm.pieces[0].data.len > 0, "buffer should exist after block receipt"

  pm.resetPiece(0)
  assert pm.pieces[0].data.len == 0, "buffer should be released on reset"
  echo "PASS: buffer released on resetPiece"

block: # re-download after failure re-allocates buffer
  let info = makeTestInfo(32768, 32768)
  let pm = newPieceManager(info)

  # First download attempt
  let data = newString(BlockSize)
  discard pm.receiveBlock(0, 0, data)
  assert pm.pieces[0].data.len == 32768

  # Reset (failure)
  pm.resetPiece(0)
  assert pm.pieces[0].data.len == 0

  # Second download attempt — buffer re-allocated
  discard pm.receiveBlock(0, 0, data)
  assert pm.pieces[0].data.len == 32768, "buffer should be re-allocated on retry"
  echo "PASS: re-download after failure re-allocates buffer"

block: # memory savings — only active pieces have buffers
  let pieceLen = 65536  # 64KB
  let numPieces = 1000
  let info = makeTestInfo(pieceLen, int64(pieceLen) * int64(numPieces))
  let pm = newPieceManager(info)

  # Only download 3 pieces
  for p in [0, 500, 999]:
    let data = newString(BlockSize)
    discard pm.receiveBlock(p, 0, data)

  var allocatedCount = 0
  for i in 0 ..< pm.totalPieces:
    if pm.pieces[i].data.len > 0:
      allocatedCount += 1

  assert allocatedCount == 3, "only 3 pieces should have allocated buffers, got " & $allocatedCount
  echo "PASS: memory savings — only active pieces have buffers"

echo "ALL LAZY PIECE ALLOC TESTS PASSED"
