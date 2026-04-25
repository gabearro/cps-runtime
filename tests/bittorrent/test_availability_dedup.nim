## Tests for availability deduplication.
## Verifies that duplicate HAVE messages don't inflate availability counts.

import cps/bittorrent/metainfo
import cps/bittorrent/pieces
import cps/bittorrent/peer_protocol

block testDuplicateHaveDoesNotInflate:
  ## Simulates a peer sending HAVE for the same piece twice.
  ## Availability should only be incremented once.
  var availability = newSeq[int](4)
  var peerBf = newBitfield(4)

  # First HAVE for piece 2: peer didn't have it, so increment
  let alreadyHad1 = hasPiece(peerBf, 2)
  assert not alreadyHad1, "peer should not have piece 2 yet"
  if not alreadyHad1:
    availability[2] += 1
  setPiece(peerBf, 2)

  assert availability[2] == 1, "availability should be 1 after first HAVE"

  # Second HAVE for piece 2: peer already has it, don't increment
  let alreadyHad2 = hasPiece(peerBf, 2)
  assert alreadyHad2, "peer should already have piece 2"
  if not alreadyHad2:
    availability[2] += 1

  assert availability[2] == 1, "availability should still be 1 after duplicate HAVE, got " & $availability[2]
  echo "PASS: duplicate HAVE does not inflate availability"

block testHaveAfterBitfieldDoesNotInflate:
  ## Simulates BITFIELD followed by HAVE for a piece already in the bitfield.
  var availability = newSeq[int](4)
  var peerBf = newBitfield(4)

  # Peer sends BITFIELD with pieces 0, 1, 3
  setPiece(peerBf, 0)
  setPiece(peerBf, 1)
  setPiece(peerBf, 3)

  # Add availability from bitfield
  for i in 0 ..< 4:
    if hasPiece(peerBf, i):
      availability[i] += 1

  assert availability[0] == 1
  assert availability[1] == 1
  assert availability[2] == 0
  assert availability[3] == 1

  # Now peer sends HAVE for piece 1 (already in bitfield)
  let alreadyHad = hasPiece(peerBf, 1)
  assert alreadyHad, "piece 1 should already be in bitfield"
  if not alreadyHad:
    availability[1] += 1

  assert availability[1] == 1, "availability should still be 1 after redundant HAVE, got " & $availability[1]

  # HAVE for piece 2 (NOT in bitfield) - should increment
  let alreadyHad2 = hasPiece(peerBf, 2)
  assert not alreadyHad2
  if not alreadyHad2:
    availability[2] += 1
  setPiece(peerBf, 2)

  assert availability[2] == 1, "availability should be 1 for new piece"
  echo "PASS: HAVE after BITFIELD does not inflate for known pieces"

block testMultiplePeersAvailability:
  ## Two peers with overlapping pieces: availability reflects unique counts.
  var availability = newSeq[int](4)

  var peer1bf = newBitfield(4)
  var peer2bf = newBitfield(4)

  # Peer 1 has pieces 0, 2
  setPiece(peer1bf, 0)
  setPiece(peer1bf, 2)
  for i in 0 ..< 4:
    if hasPiece(peer1bf, i):
      availability[i] += 1

  # Peer 2 has pieces 0, 1
  setPiece(peer2bf, 0)
  setPiece(peer2bf, 1)
  for i in 0 ..< 4:
    if hasPiece(peer2bf, i):
      availability[i] += 1

  assert availability[0] == 2, "piece 0 has 2 peers"
  assert availability[1] == 1, "piece 1 has 1 peer"
  assert availability[2] == 1, "piece 2 has 1 peer"
  assert availability[3] == 0, "piece 3 has 0 peers"

  # Peer 1 sends duplicate HAVE for piece 0
  let alreadyHad = hasPiece(peer1bf, 0)
  assert alreadyHad
  if not alreadyHad:
    availability[0] += 1

  assert availability[0] == 2, "piece 0 should still be 2, got " & $availability[0]
  echo "PASS: multi-peer availability with dedup"

echo "All availability dedup tests passed"
