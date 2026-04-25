## Tests for optimistic piece verification.

import cps/bittorrent/metainfo
import cps/bittorrent/pieces
import cps/bittorrent/peer_protocol
import cps/bittorrent/sha1
import cps/bittorrent/utils

proc makeTorrentInfo(totalLength: int64, pieceLength: int): TorrentInfo =
  result.pieceLength = pieceLength
  result.totalLength = totalLength
  result.name = "test"
  result.files = @[FileEntry(path: "test", length: totalLength)]
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

proc makeBlockData(pieceIdx: int, offset: int, length: int, pieceLength: int): string =
  ## Generate predictable test data for a specific block.
  result = newString(length)
  let start = pieceIdx * pieceLength + offset
  for j in 0 ..< length:
    result[j] = char((start + j) mod 256)

const BlockSize = 16384

# ============================================================
# Test: consensus initialization on first block receipt
# ============================================================
block testConsensusInit:
  let info = makeTorrentInfo(32768, 32768)  # 1 piece, 32KB
  let pm = newPieceManager(info, trackAgreement = true)

  assert pm.pieces[0].consensus.blockAgreements.len == 0, "consensus not initialized yet"

  let blk = makeBlockData(0, 0, BlockSize, 32768)
  let complete = pm.receiveBlock(0, 0, blk)
  assert not complete
  assert pm.pieces[0].state == psPartial
  assert pm.pieces[0].consensus.blockAgreements.len == 2, "consensus initialized with 2 blocks"

  echo "PASS: consensus initialization on first block receipt"

# ============================================================
# Test: CRC32C recording on block acceptance
# ============================================================
block testCrcRecording:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info, trackAgreement = true)

  let blk0 = makeBlockData(0, 0, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, blk0)

  let expectedCrc = crc32c(blk0.toOpenArrayByte(0, blk0.len - 1))
  assert pm.pieces[0].consensus.blockAgreements[0].crc == expectedCrc
  assert pm.pieces[0].consensus.blockAgreements[0].agreeCount == 0
  assert pm.pieces[0].consensus.blockAgreements[1].crc == 0  # second block not yet received

  echo "PASS: CRC32C recording on block acceptance"

# ============================================================
# Test: agreement check with matching data
# ============================================================
block testAgreementMatch:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info, trackAgreement = true)

  let blk0 = makeBlockData(0, 0, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, blk0)

  # Simulate racing duplicate with identical data
  let agreed = pm.checkBlockAgreement(0, 0, blk0.toOpenArrayByte(0, blk0.len - 1))
  assert agreed, "identical data should agree"
  assert pm.pieces[0].consensus.blockAgreements[0].agreeCount == 1
  assert pm.pieces[0].consensus.agreedBlockCount == 1

  # Second agreement from a third peer
  let agreed2 = pm.checkBlockAgreement(0, 0, blk0.toOpenArrayByte(0, blk0.len - 1))
  assert agreed2
  assert pm.pieces[0].consensus.blockAgreements[0].agreeCount == 2

  echo "PASS: agreement check with matching data"

# ============================================================
# Test: agreement check with mismatching data
# ============================================================
block testAgreementMismatch:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info, trackAgreement = true)

  let blk0 = makeBlockData(0, 0, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, blk0)

  # Simulate racing duplicate with different data
  var badData = newString(BlockSize)
  for i in 0 ..< BlockSize:
    badData[i] = 'X'
  let agreed = pm.checkBlockAgreement(0, 0, badData.toOpenArrayByte(0, badData.len - 1))
  assert not agreed, "different data should not agree"
  assert pm.pieces[0].consensus.blockAgreements[0].agreeCount == 0
  assert pm.pieces[0].consensus.agreedBlockCount == 0

  echo "PASS: agreement check with mismatching data"

# ============================================================
# Test: optimistic threshold — not enough peers
# ============================================================
block testThresholdNotMet:
  let info = makeTorrentInfo(32768, 32768)  # 2 blocks per piece
  let pm = newPieceManager(info, trackAgreement = true)

  # Receive both blocks (piece completes)
  let blk0 = makeBlockData(0, 0, BlockSize, 32768)
  let blk1 = makeBlockData(0, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, blk0)
  let complete = pm.receiveBlock(0, BlockSize, blk1)
  assert complete
  assert pm.pieces[0].state == psComplete

  # No agreement data — threshold not met (need at least 1 agreed block)
  assert not pm.meetsOptimisticThreshold(0, 2, 1)

  echo "PASS: optimistic threshold — not enough peers"

# ============================================================
# Test: optimistic threshold — met with 2 peers agreeing on >50% blocks
# ============================================================
block testThresholdMet:
  let info = makeTorrentInfo(32768, 32768)  # 2 blocks per piece
  let pm = newPieceManager(info, trackAgreement = true)

  let blk0 = makeBlockData(0, 0, BlockSize, 32768)
  let blk1 = makeBlockData(0, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, blk0)
  let complete = pm.receiveBlock(0, BlockSize, blk1)
  assert complete

  # Simulate agreement on both blocks
  discard pm.checkBlockAgreement(0, 0, blk0.toOpenArrayByte(0, blk0.len - 1))
  discard pm.checkBlockAgreement(0, BlockSize, blk1.toOpenArrayByte(0, blk1.len - 1))

  # minAgreePeers=2 means agreeCount >= 1, and both blocks agree → 2 >= 2
  assert pm.meetsOptimisticThreshold(0, 2, 2)
  # Also works with lower threshold
  assert pm.meetsOptimisticThreshold(0, 2, 1)

  echo "PASS: optimistic threshold — met"

# ============================================================
# Test: optimistic threshold — partial agreement below percent
# ============================================================
block testThresholdPartialAgreement:
  let info = makeTorrentInfo(65536, 65536)  # 4 blocks per piece
  let pm = newPieceManager(info, trackAgreement = true)

  # Receive all 4 blocks
  for i in 0 ..< 4:
    let off = i * BlockSize
    let blk = makeBlockData(0, off, BlockSize, 65536)
    discard pm.receiveBlock(0, off, blk)
  assert pm.pieces[0].state == psComplete

  # Agreement on only 1 of 4 blocks — below threshold of 2
  let blk0 = makeBlockData(0, 0, BlockSize, 65536)
  discard pm.checkBlockAgreement(0, 0, blk0.toOpenArrayByte(0, blk0.len - 1))

  assert not pm.meetsOptimisticThreshold(0, 2, 2), "1 agreed < 2 required"
  # But with threshold of 1, should pass
  assert pm.meetsOptimisticThreshold(0, 2, 1), "1 agreed >= 1 required"

  echo "PASS: optimistic threshold — partial agreement"

# ============================================================
# Test: markOptimistic state transition
# ============================================================
block testMarkOptimistic:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info)

  let blk0 = makeBlockData(0, 0, BlockSize, 32768)
  let blk1 = makeBlockData(0, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, blk0)
  discard pm.receiveBlock(0, BlockSize, blk1)
  assert pm.pieces[0].state == psComplete

  pm.markOptimistic(0)
  assert pm.pieces[0].state == psOptimistic
  assert pm.optimisticCount == 1
  assert pm.isComplete  # single piece torrent, optimistic counts as complete
  assert pm.progress == 1.0

  echo "PASS: markOptimistic state transition"

# ============================================================
# Test: applyOptimisticVerification — success
# ============================================================
block testOptimisticVerifySuccess:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info)

  let blk0 = makeBlockData(0, 0, BlockSize, 32768)
  let blk1 = makeBlockData(0, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, blk0)
  discard pm.receiveBlock(0, BlockSize, blk1)
  pm.markOptimistic(0)

  pm.applyOptimisticVerification(0, true)
  assert pm.pieces[0].state == psVerified
  assert pm.verifiedCount == 1
  assert pm.optimisticCount == 0
  assert pm.isComplete

  echo "PASS: applyOptimisticVerification — success"

# ============================================================
# Test: applyOptimisticVerification — failure (rollback)
# ============================================================
block testOptimisticVerifyFailure:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info)

  let blk0 = makeBlockData(0, 0, BlockSize, 32768)
  let blk1 = makeBlockData(0, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, blk0)
  discard pm.receiveBlock(0, BlockSize, blk1)
  pm.markOptimistic(0)

  pm.applyOptimisticVerification(0, false)
  assert pm.pieces[0].state == psFailed
  assert pm.verifiedCount == 0
  assert pm.optimisticCount == 0
  assert pm.completedCount == 0
  assert pm.downloaded == 0  # bytes subtracted
  assert not pm.isComplete
  # All blocks reset to empty
  for blk in pm.pieces[0].blocks:
    assert blk.state == bsEmpty
  # Consensus cleared
  assert pm.pieces[0].consensus.blockAgreements.len == 0
  # Data buffer cleared
  assert pm.pieces[0].data.len == 0

  echo "PASS: applyOptimisticVerification — failure (rollback)"

# ============================================================
# Test: generateBitfield includes optimistic pieces
# ============================================================
block testBitfieldIncludesOptimistic:
  let info = makeTorrentInfo(65536, 32768)  # 2 pieces
  let pm = newPieceManager(info)

  # Complete and verify piece 0 normally
  let p0b0 = makeBlockData(0, 0, BlockSize, 32768)
  let p0b1 = makeBlockData(0, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, p0b0)
  discard pm.receiveBlock(0, BlockSize, p0b1)
  pm.applyVerification(0, true)

  # Complete piece 1 and mark optimistic
  let p1b0 = makeBlockData(1, 0, BlockSize, 32768)
  let p1b1 = makeBlockData(1, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(1, 0, p1b0)
  discard pm.receiveBlock(1, BlockSize, p1b1)
  pm.markOptimistic(1)

  let bf = pm.generateBitfield()
  assert hasPiece(bf, 0), "verified piece in bitfield"
  assert hasPiece(bf, 1), "optimistic piece in bitfield"

  echo "PASS: generateBitfield includes optimistic pieces"

# ============================================================
# Test: getNeededBlocks / selectPiece skip optimistic
# ============================================================
block testSkipOptimistic:
  let info = makeTorrentInfo(65536, 32768)  # 2 pieces
  let pm = newPieceManager(info)

  # Complete and mark piece 0 optimistic
  let p0b0 = makeBlockData(0, 0, BlockSize, 32768)
  let p0b1 = makeBlockData(0, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, p0b0)
  discard pm.receiveBlock(0, BlockSize, p0b1)
  pm.markOptimistic(0)

  # No needed blocks for optimistic piece
  let needed = pm.getNeededBlocks(0)
  assert needed.len == 0, "optimistic piece has no needed blocks"

  # selectPiece should skip optimistic, pick piece 1
  var bf = newBitfield(2)
  setPiece(bf, 0)
  setPiece(bf, 1)
  let avail = @[1, 1]
  let picked = pm.selectPiece(bf, avail)
  assert picked == 1, "should pick non-optimistic piece"

  echo "PASS: getNeededBlocks / selectPiece skip optimistic"

# ============================================================
# Test: inEndgame skips optimistic
# ============================================================
block testEndgameSkipsOptimistic:
  let info = makeTorrentInfo(65536, 32768)  # 2 pieces
  let pm = newPieceManager(info)

  # Complete piece 0 optimistically
  let p0b0 = makeBlockData(0, 0, BlockSize, 32768)
  let p0b1 = makeBlockData(0, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, p0b0)
  discard pm.receiveBlock(0, BlockSize, p0b1)
  pm.markOptimistic(0)

  # Piece 1: all blocks requested (endgame candidate)
  pm.markBlockRequested(1, 0)
  pm.markBlockRequested(1, BlockSize)

  # Should be in endgame: only 1 piece remaining, all blocks requested
  assert pm.piecesRemaining == 1
  assert pm.inEndgame

  echo "PASS: inEndgame skips optimistic"

# ============================================================
# Test: resetPiece handles optimistic state
# ============================================================
block testResetOptimistic:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info)

  let blk0 = makeBlockData(0, 0, BlockSize, 32768)
  let blk1 = makeBlockData(0, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, blk0)
  discard pm.receiveBlock(0, BlockSize, blk1)
  pm.markOptimistic(0)
  assert pm.optimisticCount == 1

  pm.resetPiece(0)
  assert pm.pieces[0].state == psEmpty
  assert pm.optimisticCount == 0
  assert pm.completedCount == 0

  echo "PASS: resetPiece handles optimistic state"

# ============================================================
# Test: no-racing single peer — threshold never met
# ============================================================
block testSinglePeerNoOptimistic:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info, trackAgreement = true)

  let blk0 = makeBlockData(0, 0, BlockSize, 32768)
  let blk1 = makeBlockData(0, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, blk0)
  discard pm.receiveBlock(0, BlockSize, blk1)
  assert pm.pieces[0].state == psComplete

  # No agreement data at all — single peer download
  assert not pm.meetsOptimisticThreshold(0, 2, 1)
  # With 0 blocks required, passes vacuously
  assert pm.meetsOptimisticThreshold(0, 2, 0)
  # Any positive threshold requires actual agreement
  assert not pm.meetsOptimisticThreshold(0, 2, 1)

  echo "PASS: single peer — threshold behavior"

# ============================================================
# Test: getPieceData works for optimistic pieces
# ============================================================
block testGetPieceDataOptimistic:
  let info = makeTorrentInfo(32768, 32768)
  let pm = newPieceManager(info)

  let blk0 = makeBlockData(0, 0, BlockSize, 32768)
  let blk1 = makeBlockData(0, BlockSize, BlockSize, 32768)
  discard pm.receiveBlock(0, 0, blk0)
  discard pm.receiveBlock(0, BlockSize, blk1)
  pm.markOptimistic(0)

  let data = pm.getPieceData(0)
  assert data.len == 32768, "getPieceData returns data for optimistic piece"

  echo "PASS: getPieceData works for optimistic pieces"

echo ""
echo "All optimistic verification tests passed."
