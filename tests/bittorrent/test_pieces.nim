## Tests for the piece manager.

import cps/bittorrent/metainfo
import cps/bittorrent/pieces
import cps/bittorrent/peer_protocol
import cps/bittorrent/sha1

proc makeTorrentInfo(totalLength: int64, pieceLength: int): TorrentInfo =
  ## Create a TorrentInfo with computed piece hashes for test data.
  result.pieceLength = pieceLength
  result.totalLength = totalLength
  result.name = "test"
  result.files = @[FileEntry(path: "test", length: totalLength)]

  let numPieces = (totalLength.int + pieceLength - 1) div pieceLength
  var piecesStr = ""
  for i in 0 ..< numPieces:
    let start = i * pieceLength
    let size = min(pieceLength, totalLength.int - start)
    # Create predictable data for each piece
    var pieceData = newString(size)
    for j in 0 ..< size:
      pieceData[j] = char((start + j) mod 256)
    let hash = sha1(pieceData)
    for b in hash:
      piecesStr.add(char(b))
  result.pieces = piecesStr

# Basic piece manager creation
block testPieceManagerCreation:
  let info = makeTorrentInfo(1048576, 262144)  # 1MB, 256KB pieces
  let pm = newPieceManager(info)

  assert pm.totalPieces == 4
  assert not pm.isComplete
  assert pm.progress == 0.0
  assert pm.bytesRemaining == 1048576

  for i in 0 ..< 4:
    assert pm.pieces[i].state == psEmpty
    assert pm.pieces[i].totalLength == 262144

  echo "PASS: piece manager creation"

# Block calculation
block testBlockCalculation:
  let info = makeTorrentInfo(65536, 32768)  # 64KB, 32KB pieces
  let pm = newPieceManager(info)

  assert pm.totalPieces == 2
  # 32KB piece = 2 blocks of 16KB each
  assert pm.pieces[0].blocks.len == 2
  assert pm.pieces[0].blocks[0].offset == 0
  assert pm.pieces[0].blocks[0].length == 16384
  assert pm.pieces[0].blocks[1].offset == 16384
  assert pm.pieces[0].blocks[1].length == 16384

  echo "PASS: block calculation"

# Last piece with non-standard size
block testLastPieceSize:
  let info = makeTorrentInfo(300000, 262144)  # 300KB total, 256KB piece
  let pm = newPieceManager(info)

  assert pm.totalPieces == 2
  assert pm.pieces[0].totalLength == 262144
  assert pm.pieces[1].totalLength == 300000 - 262144  # 37856 bytes

  # Last piece should have smaller blocks
  let lastPiece = pm.pieces[1]
  var totalBlockSize = 0
  for blk in lastPiece.blocks:
    totalBlockSize += blk.length
  assert totalBlockSize == lastPiece.totalLength

  echo "PASS: last piece size"

# Receive blocks and verify
block testReceiveAndVerify:
  let pieceLength = 32768
  let info = makeTorrentInfo(32768, pieceLength)  # Single piece
  let pm = newPieceManager(info)

  # Create the expected data
  var expectedData = newString(pieceLength)
  for j in 0 ..< pieceLength:
    expectedData[j] = char(j mod 256)

  # Receive first block
  let complete1 = pm.receiveBlock(0, 0, expectedData[0 ..< 16384])
  assert not complete1
  assert pm.pieces[0].state == psPartial

  # Receive second block
  let complete2 = pm.receiveBlock(0, 16384, expectedData[16384 ..< 32768])
  assert complete2
  assert pm.pieces[0].state == psComplete

  # Verify
  let valid = pm.verifyPiece(0)
  assert valid
  assert pm.pieces[0].state == psVerified
  assert pm.isComplete

  echo "PASS: receive blocks and verify"

# Duplicate block handling
block testDuplicateBlock:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info)

  var data = newString(16384)
  for i in 0 ..< 16384:
    data[i] = char(i mod 256)

  let ok1 = pm.receiveBlock(0, 0, data)
  assert not ok1

  # Duplicate should return false
  let ok2 = pm.receiveBlock(0, 0, data)
  assert not ok2

  echo "PASS: duplicate block handling"

# Verification failure
block testVerificationFailure:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info)

  # Send wrong data
  var wrongData = newString(16384)
  discard pm.receiveBlock(0, 0, wrongData)

  wrongData = newString(16384)
  let complete = pm.receiveBlock(0, 16384, wrongData)
  assert complete

  let valid = pm.verifyPiece(0)
  assert not valid
  assert pm.pieces[0].state == psFailed

  echo "PASS: verification failure"

# Get needed blocks
block testGetNeededBlocks:
  let info = makeTorrentInfo(65536, 32768)
  let pm = newPieceManager(info)

  let blocks = pm.getNeededBlocks(0)
  assert blocks.len == 2
  assert blocks[0].offset == 0
  assert blocks[0].length == 16384
  assert blocks[1].offset == 16384
  assert blocks[1].length == 16384

  # Mark one as requested
  pm.markBlockRequested(0, 0)
  let blocks2 = pm.getNeededBlocks(0)
  assert blocks2.len == 1
  assert blocks2[0].offset == 16384

  echo "PASS: get needed blocks"

# Cancel block request
block testCancelBlockRequest:
  let info = makeTorrentInfo(65536, 32768)
  let pm = newPieceManager(info)

  pm.markBlockRequested(0, 0)
  let blocks1 = pm.getNeededBlocks(0)
  assert blocks1.len == 1

  pm.cancelBlockRequest(0, 0)
  let blocks2 = pm.getNeededBlocks(0)
  assert blocks2.len == 2

  echo "PASS: cancel block request"

# Piece selection (simple)
block testPieceSelectionSimple:
  let info = makeTorrentInfo(65536, 32768)
  let pm = newPieceManager(info)

  # Peer has both pieces
  var peerBf = newBitfield(2)
  setPiece(peerBf, 0)
  setPiece(peerBf, 1)

  let sel = pm.selectPieceSimple(peerBf)
  assert sel == 0  # Sequential: first piece

  # Mark first piece as complete
  pm.pieces[0].state = psComplete
  let sel2 = pm.selectPieceSimple(peerBf)
  assert sel2 == 1

  # Mark both complete
  pm.pieces[1].state = psComplete
  let sel3 = pm.selectPieceSimple(peerBf)
  assert sel3 == -1  # Nothing needed

  echo "PASS: simple piece selection"

# Piece selection - prefers partial pieces
block testPieceSelectionPartial:
  let info = makeTorrentInfo(3 * 32768, 32768)
  let pm = newPieceManager(info)

  var peerBf = newBitfield(3)
  setPiece(peerBf, 0)
  setPiece(peerBf, 1)
  setPiece(peerBf, 2)

  # Mark piece 1 as partial
  pm.pieces[1].state = psPartial

  let sel = pm.selectPieceSimple(peerBf)
  assert sel == 1  # Should prefer partial piece

  echo "PASS: piece selection prefers partial"

# Generate bitfield
block testGenerateBitfield:
  let info = makeTorrentInfo(3 * 32768, 32768)
  let pm = newPieceManager(info)

  pm.pieces[0].state = psVerified
  pm.pieces[2].state = psVerified

  let bf = pm.generateBitfield()
  assert hasPiece(bf, 0)
  assert not hasPiece(bf, 1)
  assert hasPiece(bf, 2)

  echo "PASS: generate bitfield"

# Reset piece
block testResetPiece:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info)

  pm.pieces[0].state = psPartial
  pm.pieces[0].blocks[0].state = bsReceived

  pm.resetPiece(0)
  assert pm.pieces[0].state == psEmpty
  assert pm.pieces[0].blocks[0].state == bsEmpty
  assert pm.pieces[0].receivedBytes == 0

  echo "PASS: reset piece"

# Download accounting after hash-fail reset
block testDownloadAccountingDrift:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info)

  # Send wrong data (will fail verification)
  var wrongData1 = newString(16384)
  var wrongData2 = newString(16384)
  discard pm.receiveBlock(0, 0, wrongData1)
  let complete = pm.receiveBlock(0, 16384, wrongData2)
  assert complete
  assert pm.downloaded == 32768, "downloaded should be 32768 but got " & $pm.downloaded

  let valid = pm.verifyPiece(0)
  assert not valid
  assert pm.pieces[0].state == psFailed

  # After failed verification + reset, downloaded should be decremented
  pm.resetPiece(0)
  assert pm.downloaded == 0, "downloaded should be 0 after reset but got " & $pm.downloaded
  assert pm.bytesRemaining == 32768, "bytesRemaining should be 32768 but got " & $pm.bytesRemaining

  echo "PASS: download accounting after hash-fail reset"

# Rarest-first piece selection
block testRarestFirst:
  let info = makeTorrentInfo(4 * 32768, 32768)
  let pm = newPieceManager(info)

  var peerBf = newBitfield(4)
  setPiece(peerBf, 0)
  setPiece(peerBf, 1)
  setPiece(peerBf, 2)
  setPiece(peerBf, 3)

  # Simulate availability: piece 2 is rarest (1 peer has it)
  var avail = @[5, 3, 1, 4]

  let sel = pm.selectPiece(peerBf, avail)
  assert sel == 2  # Rarest piece

  echo "PASS: rarest-first piece selection"

echo "ALL PIECE MANAGER TESTS PASSED"
