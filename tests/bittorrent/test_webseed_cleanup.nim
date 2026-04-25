## Tests for webseed piece completion cleanup.
## Verifies that block states are correctly managed when a webseed
## marks blocks as requested and then succeeds or fails.

import cps/bittorrent/pieces
import cps/bittorrent/metainfo

proc makeTestInfo(pieceLength: int, totalLength: int64): TorrentInfo =
  result.pieceLength = pieceLength
  result.totalLength = totalLength
  result.files = @[FileEntry(path: "test.bin", length: totalLength)]
  # Generate dummy piece hashes
  let numPieces = int((totalLength + int64(pieceLength) - 1) div int64(pieceLength))
  result.pieces = newString(numPieces * 20)

block: # markBlockRequested prevents getNeededBlocks from returning those blocks
  let info = makeTestInfo(65536, 65536)  # 1 piece, 64KB = 4 blocks of 16KB
  let pm = newPieceManager(info)

  assert pm.pieces[0].state == psEmpty
  let blocks = pm.getNeededBlocks(0, 10)
  assert blocks.len == 4, "should have 4 blocks, got " & $blocks.len

  # Mark all blocks as requested (simulating webseed claiming them)
  for blk in blocks:
    pm.markBlockRequested(0, blk.offset)

  # Now getNeededBlocks should return nothing
  let blocksAfter = pm.getNeededBlocks(0, 10)
  assert blocksAfter.len == 0, "all blocks are requested, should return 0, got " & $blocksAfter.len
  echo "PASS: markBlockRequested blocks getNeededBlocks"

block: # cancelBlockRequest releases blocks back to empty
  let info = makeTestInfo(65536, 65536)
  let pm = newPieceManager(info)

  let blocks = pm.getNeededBlocks(0, 10)
  for blk in blocks:
    pm.markBlockRequested(0, blk.offset)

  # Cancel all requests (simulating webseed failure cleanup)
  for blk in blocks:
    pm.cancelBlockRequest(0, blk.offset)

  # Blocks should be available again
  let blocksAfter = pm.getNeededBlocks(0, 10)
  assert blocksAfter.len == 4, "all blocks should be available again, got " & $blocksAfter.len
  echo "PASS: cancelBlockRequest releases blocks"

block: # receiveBlock after markBlockRequested works correctly
  let info = makeTestInfo(65536, 65536)
  let pm = newPieceManager(info)

  let blocks = pm.getNeededBlocks(0, 10)
  for blk in blocks:
    pm.markBlockRequested(0, blk.offset)

  # Simulate receiving all blocks (webseed success path)
  var complete = false
  for blk in blocks:
    let data = newString(blk.length)
    complete = pm.receiveBlock(0, blk.offset, data)

  assert complete, "piece should be complete after all blocks received"
  assert pm.pieces[0].state == psComplete
  echo "PASS: receiveBlock after markBlockRequested completes piece"

block: # partial failure: some blocks received, then cancel remaining
  let info = makeTestInfo(65536, 65536)
  let pm = newPieceManager(info)

  let blocks = pm.getNeededBlocks(0, 10)
  assert blocks.len == 4

  # Mark all as requested
  for blk in blocks:
    pm.markBlockRequested(0, blk.offset)

  # Receive first 2 blocks
  for i in 0 ..< 2:
    let data = newString(blocks[i].length)
    discard pm.receiveBlock(0, blocks[i].offset, data)

  assert pm.pieces[0].state == psPartial

  # Cancel the remaining 2 (webseed failure)
  for i in 2 ..< 4:
    pm.cancelBlockRequest(0, blocks[i].offset)

  # The remaining blocks should now be available for peers
  let remaining = pm.getNeededBlocks(0, 10)
  assert remaining.len == 2, "2 cancelled blocks should be available, got " & $remaining.len
  assert remaining[0].offset == blocks[2].offset
  assert remaining[1].offset == blocks[3].offset
  echo "PASS: partial failure cleanup releases remaining blocks"

block: # selectPiece skips pieces with all blocks requested
  let info = makeTestInfo(32768, 65536)  # 2 pieces of 32KB
  let pm = newPieceManager(info)

  # Create a full bitfield (peer has all pieces)
  var bf = newSeq[byte](1)
  bf[0] = 0xC0  # bits 0 and 1 set

  var avail = @[1, 1]

  # Mark all blocks of piece 0 as requested (webseed has them)
  let blocks0 = pm.getNeededBlocks(0, 10)
  for blk in blocks0:
    pm.markBlockRequested(0, blk.offset)

  # selectPiece should pick piece 1, not 0 (piece 0 has no empty blocks)
  let selected = pm.selectPiece(bf, avail)
  assert selected == 1, "should select piece 1 (piece 0 all requested), got " & $selected
  echo "PASS: selectPiece skips fully-requested pieces"

echo "ALL WEBSEED CLEANUP TESTS PASSED"
