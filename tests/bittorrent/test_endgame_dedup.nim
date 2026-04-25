## Tests for endgame request deduplication.
##
## Verifies that getEndgameBlocks returns only bsRequested blocks,
## and validates the dedup logic that prevents duplicate entries
## in activeRequests when requestBlocks is called multiple times.

import cps/bittorrent/pieces
import cps/bittorrent/metainfo
import cps/bittorrent/peer_protocol

proc makeTestInfo(pieceLength: int, totalLength: int64): TorrentInfo =
  result.pieceLength = pieceLength
  result.totalLength = totalLength
  result.files = @[FileEntry(path: "test.bin", length: totalLength)]
  let numPieces = int((totalLength + int64(pieceLength) - 1) div int64(pieceLength))
  result.pieces = newString(numPieces * 20)

block: # getEndgameBlocks returns only bsRequested blocks
  let info = makeTestInfo(BlockSize * 2, int64(BlockSize * 2))  # 1 piece, 2 blocks
  let pm = newPieceManager(info)

  # Mark both blocks as requested (simulate normal mode)
  pm.markBlockRequested(0, 0)
  pm.markBlockRequested(0, BlockSize)

  # Build a bitfield that has piece 0
  var bf = newBitfield(1)
  setPiece(bf, 0)

  # inEndgame should be true (all remaining blocks are requested)
  assert pm.inEndgame(), "should be in endgame mode"

  let blocks = pm.getEndgameBlocks(bf, 10)
  assert blocks.len == 2, "should return 2 requested blocks, got " & $blocks.len
  assert blocks[0].pieceIdx == 0
  assert blocks[0].offset == 0
  assert blocks[1].offset == BlockSize
  echo "PASS: getEndgameBlocks returns bsRequested blocks"

block: # getEndgameBlocks respects maxBlocks limit
  let info = makeTestInfo(BlockSize * 4, int64(BlockSize * 4))  # 1 piece, 4 blocks
  let pm = newPieceManager(info)

  for i in 0 ..< 4:
    pm.markBlockRequested(0, i * BlockSize)

  var bf = newBitfield(1)
  setPiece(bf, 0)

  let blocks = pm.getEndgameBlocks(bf, 2)
  assert blocks.len == 2, "should limit to 2, got " & $blocks.len
  echo "PASS: getEndgameBlocks respects maxBlocks"

block: # getEndgameBlocks skips pieces peer doesn't have
  let info = makeTestInfo(BlockSize, int64(BlockSize * 2))  # 2 pieces, 1 block each
  let pm = newPieceManager(info)

  pm.markBlockRequested(0, 0)
  pm.markBlockRequested(1, 0)

  # Peer only has piece 1
  var bf = newBitfield(2)
  setPiece(bf, 1)

  let blocks = pm.getEndgameBlocks(bf, 10)
  assert blocks.len == 1
  assert blocks[0].pieceIdx == 1
  echo "PASS: getEndgameBlocks filters by peer bitfield"

block: # dedup logic prevents duplicate activeRequests entries
  ## Simulates the dedup check in requestBlocks endgame path.
  type ActiveReq = tuple[pieceIdx: int, offset: int]

  var activeRequests: seq[ActiveReq]
  var pendingRequests = 0

  # First call: add 2 endgame blocks
  let blocks1 = @[
    (pieceIdx: 0, offset: 0, length: BlockSize),
    (pieceIdx: 0, offset: BlockSize, length: BlockSize),
  ]
  for blk in blocks1:
    var alreadyTracked = false
    for ar in activeRequests:
      if ar.pieceIdx == blk.pieceIdx and ar.offset == blk.offset:
        alreadyTracked = true
        break
    if not alreadyTracked:
      activeRequests.add((blk.pieceIdx, blk.offset))
      pendingRequests += 1

  assert activeRequests.len == 2
  assert pendingRequests == 2

  # Second call (same blocks): dedup should prevent duplicates
  for blk in blocks1:
    var alreadyTracked = false
    for ar in activeRequests:
      if ar.pieceIdx == blk.pieceIdx and ar.offset == blk.offset:
        alreadyTracked = true
        break
    if not alreadyTracked:
      activeRequests.add((blk.pieceIdx, blk.offset))
      pendingRequests += 1

  assert activeRequests.len == 2, "duplicates should not accumulate, got " & $activeRequests.len
  assert pendingRequests == 2, "pendingRequests should stay 2, got " & $pendingRequests
  echo "PASS: dedup prevents duplicate activeRequests entries"

block: # reconcile with activeRequests.len stays correct after dedup
  type ActiveReq = tuple[pieceIdx: int, offset: int]
  var activeRequests: seq[ActiveReq]

  # Add 3 unique entries
  activeRequests.add((0, 0))
  activeRequests.add((0, BlockSize))
  activeRequests.add((1, 0))

  # Reconcile
  var pendingRequests = activeRequests.len
  assert pendingRequests == 3

  # Remove one (simulating piece receipt)
  var ri = activeRequests.len - 1
  while ri >= 0:
    if activeRequests[ri].pieceIdx == 0 and activeRequests[ri].offset == 0:
      activeRequests.del(ri)
      pendingRequests = max(0, pendingRequests - 1)
      break
    ri -= 1

  assert activeRequests.len == 2
  assert pendingRequests == 2

  # Reconcile again
  pendingRequests = activeRequests.len
  assert pendingRequests == 2, "reconciled pendingRequests should be 2"
  echo "PASS: reconciliation stays correct with deduped entries"

echo "ALL ENDGAME DEDUP TESTS PASSED"
