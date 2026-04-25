## Tests for file-priority change request pipeline cleanup.
## Validates that activeRequests, pendingRequests, and block states
## are properly cleaned up when file priorities change.

import cps/bittorrent/metainfo
import cps/bittorrent/pieces
import cps/bittorrent/peer_protocol

proc makeMultiFileInfo(): TorrentInfo =
  ## 4 pieces, 2 files: file 0 = pieces 0-1, file 1 = pieces 2-3
  result.pieceLength = 16384
  result.totalLength = 65536
  result.name = "priority-test"
  result.files = @[
    FileEntry(path: "a.bin", length: 32768),
    FileEntry(path: "b.bin", length: 32768)
  ]
  result.pieces = newString(4 * 20)  # dummy hashes

block testPendingRequestsDecrementOnPriorityChange:
  ## Simulates the scenario where a peer has in-flight requests for pieces
  ## belonging to a file that gets deprioritized. The pendingRequests counter
  ## must be decremented for each removed request.
  let info = makeMultiFileInfo()
  let pm = newPieceManager(info)

  # Simulate requesting blocks for pieces 2 and 3 (file 1)
  var activeRequests: seq[tuple[pieceIdx: int, offset: int]]
  var pendingRequests = 0

  # Request blocks from piece 2 (file 1)
  let blocks2 = pm.getNeededBlocks(2, 5)
  for blk in blocks2:
    pm.markBlockRequested(2, blk.offset)
    activeRequests.add((pieceIdx: 2, offset: blk.offset))
    pendingRequests += 1

  # Request blocks from piece 3 (file 1)
  let blocks3 = pm.getNeededBlocks(3, 5)
  for blk in blocks3:
    pm.markBlockRequested(3, blk.offset)
    activeRequests.add((pieceIdx: 3, offset: blk.offset))
    pendingRequests += 1

  # Request blocks from piece 0 (file 0, will remain selected)
  let blocks0 = pm.getNeededBlocks(0, 5)
  for blk in blocks0:
    pm.markBlockRequested(0, blk.offset)
    activeRequests.add((pieceIdx: 0, offset: blk.offset))
    pendingRequests += 1

  let file1Requests = blocks2.len + blocks3.len
  assert pendingRequests == file1Requests + blocks0.len,
    "should have all requests tracked"

  # Simulate file 1 getting skipped: pieces 2,3 become unselected
  var selectedPiecesMask = @[true, true, false, false]

  # Clean up requests for deselected pieces (what setFilePriority should do)
  var ri = 0
  while ri < activeRequests.len:
    let req = activeRequests[ri]
    if not selectedPiecesMask[req.pieceIdx]:
      pm.cancelBlockRequest(req.pieceIdx, req.offset)
      activeRequests.del(ri)
      pendingRequests = max(0, pendingRequests - 1)
    else:
      inc ri

  # Verify cleanup
  assert pendingRequests == blocks0.len,
    "should have only file-0 requests remaining, got " & $pendingRequests
  assert activeRequests.len == blocks0.len,
    "active requests should only contain file-0 blocks, got " & $activeRequests.len
  for req in activeRequests:
    assert req.pieceIdx == 0, "remaining request should be for piece 0"

  # Verify blocks were released back to empty
  let blocksAfter = pm.getNeededBlocks(2, 10)
  assert blocksAfter.len > 0, "piece 2 blocks should be released (bsEmpty)"

  echo "PASS: pendingRequests decremented on priority change"

block testCancelBlockRequestReleasesBlock:
  ## Verify that cancelBlockRequest properly resets block state
  let info = makeMultiFileInfo()
  let pm = newPieceManager(info)

  let blocks = pm.getNeededBlocks(2, 10)
  assert blocks.len > 0

  for blk in blocks:
    pm.markBlockRequested(2, blk.offset)

  # All blocks should be requested now
  let needed = pm.getNeededBlocks(2, 10)
  assert needed.len == 0, "all blocks should be requested"

  # Cancel all
  for blk in blocks:
    pm.cancelBlockRequest(2, blk.offset)

  let neededAfter = pm.getNeededBlocks(2, 10)
  assert neededAfter.len == blocks.len, "all blocks should be available again"
  echo "PASS: cancelBlockRequest releases blocks correctly"

block testPieceSelectionRespectsSkippedFiles:
  ## After skipping a file, selectPiece should not return pieces from that file.
  let info = makeMultiFileInfo()
  let pm = newPieceManager(info)

  var peerBf = newBitfield(4)
  for i in 0 ..< 4:
    setPiece(peerBf, i)

  var availability = @[1, 1, 1, 1]

  # Without filtering, any piece could be selected
  let sel1 = pm.selectPiece(peerBf, availability)
  assert sel1 >= 0, "should select a piece"

  # Now filter: clear pieces 2,3 from the bitfield (simulating filtered view)
  var filteredBf = peerBf
  clearPiece(filteredBf, 2)
  clearPiece(filteredBf, 3)

  # selectPiece should only pick 0 or 1
  for trial in 0 ..< 10:
    let sel = pm.selectPiece(filteredBf, availability)
    assert sel in [0, 1], "should only select pieces 0 or 1, got " & $sel

  echo "PASS: selectPiece respects file priority filtering"

echo "All file-priority cleanup tests passed"
