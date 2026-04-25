## Tests for completedCount consistency across reset paths.
## Verifies that resetPiece properly decrements completedCount
## when called on psComplete or psFailed pieces.

import cps/bittorrent/pieces
import cps/bittorrent/metainfo
import cps/bittorrent/sha1

proc makeTestInfo(pieceLength: int, totalLength: int64): TorrentInfo =
  result.pieceLength = pieceLength
  result.totalLength = totalLength
  result.files = @[FileEntry(path: "test.bin", length: totalLength)]
  let numPieces = int((totalLength + int64(pieceLength) - 1) div int64(pieceLength))
  result.pieces = newString(numPieces * 20)

proc fillPiece(pm: PieceManager, pieceIdx: int) =
  let pieceLen = pm.pieces[pieceIdx].totalLength
  var offset = 0
  while offset < pieceLen:
    let blockLen = min(BlockSize, pieceLen - offset)
    let data = newString(blockLen)
    discard pm.receiveBlock(pieceIdx, offset, data)
    offset += blockLen

block: # completedCount increments when piece is complete
  let info = makeTestInfo(32768, 32768 * 3)  # 3 pieces
  let pm = newPieceManager(info)
  assert pm.completedCount == 0

  fillPiece(pm, 0)
  assert pm.completedCount == 1, "should be 1 after completing piece 0, got " & $pm.completedCount
  assert pm.pieces[0].state == psComplete

  fillPiece(pm, 1)
  assert pm.completedCount == 2, "should be 2 after completing piece 1, got " & $pm.completedCount
  echo "PASS: completedCount increments on piece completion"

block: # resetPiece on psComplete decrements completedCount
  let info = makeTestInfo(32768, 32768 * 2)
  let pm = newPieceManager(info)

  fillPiece(pm, 0)
  assert pm.completedCount == 1
  assert pm.pieces[0].state == psComplete

  # Simulate write failure — resetPiece called on psComplete piece
  pm.resetPiece(0)
  assert pm.completedCount == 0, "completedCount should be 0 after reset, got " & $pm.completedCount
  assert pm.pieces[0].state == psEmpty
  echo "PASS: resetPiece on psComplete decrements completedCount"

block: # resetPiece on psVerified decrements both verifiedCount and completedCount
  # A verified piece was once psComplete (completedCount incremented), then
  # promoted to psVerified (verifiedCount incremented). When resetPiece is
  # called on psVerified, BOTH counters must be decremented.
  let pieceLen = 32768
  var pieceData = newString(pieceLen)
  for i in 0 ..< pieceLen:
    pieceData[i] = char(i mod 256)
  let hash = sha1(pieceData)

  var info: TorrentInfo
  info.pieceLength = pieceLen
  info.totalLength = int64(pieceLen)
  info.files = @[FileEntry(path: "test.bin", length: int64(pieceLen))]
  info.pieces = newString(20)
  copyMem(addr info.pieces[0], unsafeAddr hash[0], 20)

  let pm = newPieceManager(info)

  # Fill the piece with correct data
  var offset = 0
  while offset < pieceLen:
    let blockLen = min(BlockSize, pieceLen - offset)
    discard pm.receiveBlock(0, offset, pieceData[offset ..< offset + blockLen])
    offset += blockLen

  assert pm.completedCount == 1
  let valid = pm.verifyPiece(0)
  assert valid
  assert pm.verifiedCount == 1
  assert pm.completedCount == 1  # verifyPiece doesn't touch completedCount on success

  # resetPiece on psVerified should decrement BOTH counts
  pm.resetPiece(0)
  assert pm.verifiedCount == 0, "verifiedCount should be 0, got " & $pm.verifiedCount
  assert pm.completedCount == 0, "completedCount should be 0 after reset of psVerified, got " & $pm.completedCount
  echo "PASS: resetPiece on psVerified decrements both counts"

block: # verifyPiece failure decrements completedCount
  let info = makeTestInfo(32768, 32768)
  let pm = newPieceManager(info)

  fillPiece(pm, 0)
  assert pm.completedCount == 1

  # verifyPiece with wrong hash should fail and decrement completedCount
  let valid = pm.verifyPiece(0)
  assert not valid
  assert pm.completedCount == 0, "completedCount should be 0 after verify failure, got " & $pm.completedCount
  echo "PASS: verifyPiece failure decrements completedCount"

block: # double reset doesn't go negative
  let info = makeTestInfo(32768, 32768)
  let pm = newPieceManager(info)

  fillPiece(pm, 0)
  assert pm.completedCount == 1

  pm.resetPiece(0)
  assert pm.completedCount == 0

  # Reset again on psEmpty — should not go negative
  pm.resetPiece(0)
  assert pm.completedCount == 0, "completedCount should not go negative, got " & $pm.completedCount
  echo "PASS: double reset doesn't make completedCount negative"

block: # full cycle: complete -> fail verify -> re-download -> complete -> verify
  let pieceLen = 32768
  var correctData = newString(pieceLen)
  for i in 0 ..< pieceLen:
    correctData[i] = char(i mod 256)
  let hash = sha1(correctData)

  var info: TorrentInfo
  info.pieceLength = pieceLen
  info.totalLength = int64(pieceLen)
  info.files = @[FileEntry(path: "test.bin", length: int64(pieceLen))]
  info.pieces = newString(20)
  copyMem(addr info.pieces[0], unsafeAddr hash[0], 20)

  let pm = newPieceManager(info)

  # First attempt: fill with wrong data
  fillPiece(pm, 0)
  assert pm.completedCount == 1
  let valid1 = pm.verifyPiece(0)
  assert not valid1
  assert pm.completedCount == 0, "completedCount after failed verify: " & $pm.completedCount

  # Reset before re-download (receiveBlock rejects psFailed state)
  pm.resetPiece(0)
  assert pm.completedCount == 0, "completedCount after reset of psFailed: " & $pm.completedCount
  assert pm.pieces[0].state == psEmpty

  # Second attempt: fill with correct data
  var offset = 0
  while offset < pieceLen:
    let blockLen = min(BlockSize, pieceLen - offset)
    discard pm.receiveBlock(0, offset, correctData[offset ..< offset + blockLen])
    offset += blockLen

  assert pm.completedCount == 1
  let valid2 = pm.verifyPiece(0)
  assert valid2
  assert pm.verifiedCount == 1
  assert pm.completedCount == 1
  echo "PASS: full cycle maintains consistent counts"

echo "ALL COMPLETED COUNT TESTS PASSED"
