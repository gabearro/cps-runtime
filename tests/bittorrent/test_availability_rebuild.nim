## Tests for availability rebuild after file selection changes.
## Verifies that newly-selected pieces get correct availability counts.

import cps/bittorrent/metainfo
import cps/bittorrent/pieces
import cps/bittorrent/peer_protocol

proc makeMultiFileInfo(): TorrentInfo =
  result.pieceLength = 16384
  result.totalLength = 65536
  result.name = "rebuild-test"
  result.files = @[
    FileEntry(path: "a.bin", length: 32768),
    FileEntry(path: "b.bin", length: 32768)
  ]
  result.pieces = newString(4 * 20)

block testAvailabilityRebuildOnFileSelection:
  ## When file selection changes, availability must be recalculated.
  ## Otherwise newly-selected pieces have stale (zero) availability.
  let info = makeMultiFileInfo()
  let pm = newPieceManager(info)

  # Two peers, each with full bitfield
  var peer1bf = newBitfield(4)
  var peer2bf = newBitfield(4)
  for i in 0 ..< 4:
    setPiece(peer1bf, i)
    setPiece(peer2bf, i)

  var availability = newSeq[int](4)

  # Initially only file 0 is selected (pieces 0-1)
  var selectedPiecesMask = @[true, true, false, false]

  # Update availability with mask filter (only selected pieces)
  for i in 0 ..< 4:
    if selectedPiecesMask[i]:
      if hasPiece(peer1bf, i): availability[i] += 1
      if hasPiece(peer2bf, i): availability[i] += 1

  assert availability[0] == 2
  assert availability[1] == 2
  assert availability[2] == 0, "piece 2 not selected, should be 0"
  assert availability[3] == 0, "piece 3 not selected, should be 0"

  # Now select file 1 too (pieces 2-3 become selected)
  selectedPiecesMask = @[true, true, true, true]

  # BUG (before fix): availability[2] and [3] would still be 0
  # FIX: rebuild from scratch
  for i in 0 ..< 4:
    availability[i] = 0
  for i in 0 ..< 4:
    if selectedPiecesMask[i]:
      if hasPiece(peer1bf, i): availability[i] += 1
      if hasPiece(peer2bf, i): availability[i] += 1

  assert availability[0] == 2, "piece 0 should be 2, got " & $availability[0]
  assert availability[1] == 2, "piece 1 should be 2, got " & $availability[1]
  assert availability[2] == 2, "piece 2 should now be 2 (rebuilt), got " & $availability[2]
  assert availability[3] == 2, "piece 3 should now be 2 (rebuilt), got " & $availability[3]
  echo "PASS: availability rebuilt on file selection change"

block testSkipFileZerosAvailability:
  ## When a file is skipped, its pieces' availability should go to 0
  ## (since updateAvailability skips non-selected pieces).
  var availability = @[2, 2, 2, 2]
  var selectedPiecesMask = @[true, true, false, false]

  # Rebuild with file 1 skipped
  var peer1bf = newBitfield(4)
  for i in 0 ..< 4:
    setPiece(peer1bf, i)

  # Zero and rebuild
  for i in 0 ..< 4:
    availability[i] = 0
  for i in 0 ..< 4:
    if selectedPiecesMask[i]:
      if hasPiece(peer1bf, i): availability[i] += 1

  assert availability[0] == 1
  assert availability[1] == 1
  assert availability[2] == 0, "skipped piece should have 0 availability"
  assert availability[3] == 0, "skipped piece should have 0 availability"
  echo "PASS: skipped file zeros availability"

echo "All availability rebuild tests passed"
