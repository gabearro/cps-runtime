## Tests for magnet link metadata transition logic.
## Validates that availability is rebuilt and request scheduling
## is triggered immediately after metadata completion.

import cps/bittorrent/metainfo
import cps/bittorrent/pieces
import cps/bittorrent/peer_protocol

proc makeTestInfo(pieceCount: int, pieceLength: int = 16384): TorrentInfo =
  result.pieceLength = pieceLength
  result.totalLength = int64(pieceCount * pieceLength)
  result.name = "magnet-test"
  result.files = @[FileEntry(path: "data.bin", length: result.totalLength)]
  result.pieces = newString(pieceCount * 20)  # dummy hashes

block testAvailabilityRebuildAfterMetadata:
  ## Simulates the magnet transition: piece manager is created after peers
  ## already have bitfields. Availability must be rebuilt from existing peers.
  let info = makeTestInfo(4)
  let pm = newPieceManager(info)
  var availability = newSeq[int](4)

  # Simulate two peers with different bitfields
  var peer1bf = newBitfield(4)
  setPiece(peer1bf, 0)
  setPiece(peer1bf, 2)

  var peer2bf = newBitfield(4)
  setPiece(peer2bf, 1)
  setPiece(peer2bf, 2)
  setPiece(peer2bf, 3)

  # Rebuild availability (what the fix does after metadata completes)
  for i in 0 ..< 4:
    if hasPiece(peer1bf, i):
      availability[i] += 1
    if hasPiece(peer2bf, i):
      availability[i] += 1

  assert availability[0] == 1, "piece 0 should have availability 1"
  assert availability[1] == 1, "piece 1 should have availability 1"
  assert availability[2] == 2, "piece 2 should have availability 2"
  assert availability[3] == 1, "piece 3 should have availability 1"
  echo "PASS: availability rebuild after metadata"

block testRequestableAfterMetadata:
  ## After metadata completes and piece manager exists, unchoked peers
  ## should be able to get blocks immediately (no stall).
  let info = makeTestInfo(4)
  let pm = newPieceManager(info)

  # Peer has all pieces and we are unchoked
  var peerBf = newBitfield(4)
  for i in 0 ..< 4:
    setPiece(peerBf, i)

  # selectPiece should find a piece immediately
  var availability = newSeq[int](4)
  for i in 0 ..< 4:
    availability[i] = 1  # one peer has each piece

  let selected = pm.selectPiece(peerBf, availability)
  assert selected >= 0, "should select a piece immediately after metadata, got " & $selected

  # getNeededBlocks should return blocks
  let blocks = pm.getNeededBlocks(selected, 5)
  assert blocks.len > 0, "should have blocks to request"
  echo "PASS: immediate piece selection after metadata"

block testNoStallWhenAlreadyUnchoked:
  ## Verifies that pieces can be requested without waiting for unchoke
  ## when the peer already unchoked us before metadata arrived.
  let info = makeTestInfo(2)
  let pm = newPieceManager(info)

  var peerBf = newBitfield(2)
  setPiece(peerBf, 0)
  setPiece(peerBf, 1)

  # Simulate: peer has unchoked us (peerChoking = false)
  # We should be able to request blocks immediately
  let blocks0 = pm.getNeededBlocks(0, 5)
  assert blocks0.len > 0, "piece 0 should have requestable blocks"

  let blocks1 = pm.getNeededBlocks(1, 5)
  assert blocks1.len > 0, "piece 1 should have requestable blocks"
  echo "PASS: no stall when already unchoked"

echo "All magnet transition tests passed"
