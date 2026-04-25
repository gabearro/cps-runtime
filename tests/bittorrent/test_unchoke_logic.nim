## Tests for unchoke algorithm logic.
## Verifies that uninterested peers don't waste unchoke slots.

block testUnchokeSetOnlyContainsInterestedPeers:
  ## The unchoke set should only include peers that are interested.
  ## Uninterested peers should never be in the unchoke set.
  type
    MockPeer = object
      key: string
      peerInterested: bool
      amChoking: bool
      rate: float

  var peers = @[
    MockPeer(key: "peer1", peerInterested: true, amChoking: true, rate: 100.0),
    MockPeer(key: "peer2", peerInterested: false, amChoking: false, rate: 200.0),  # NOT interested but unchoked
    MockPeer(key: "peer3", peerInterested: true, amChoking: true, rate: 50.0),
    MockPeer(key: "peer4", peerInterested: false, amChoking: false, rate: 300.0),  # NOT interested but unchoked
  ]

  # Step 1: collect interested peers (what unchokeLoop does)
  var interestedPeers: seq[tuple[key: string, rate: float]]
  for p in peers:
    if p.peerInterested:
      interestedPeers.add((p.key, p.rate))

  assert interestedPeers.len == 2, "should only have 2 interested peers"

  # Step 2: build unchoke set from interested peers
  let maxUnchoked = 4
  var unchokeSet: seq[string]
  for ip in interestedPeers:
    if unchokeSet.len < maxUnchoked - 1:
      unchokeSet.add(ip.key)

  assert "peer2" notin unchokeSet, "uninterested peer2 should not be in unchoke set"
  assert "peer4" notin unchokeSet, "uninterested peer4 should not be in unchoke set"

  # Step 3: apply decisions (the fix)
  var chokeActions: seq[string]
  var unchokeActions: seq[string]

  for p in peers:
    var shouldUnchoke = p.key in unchokeSet

    if shouldUnchoke and p.amChoking:
      unchokeActions.add(p.key)
    elif not shouldUnchoke and not p.amChoking:
      # FIX: choke all unchoked peers not in unchoke set, including uninterested
      chokeActions.add(p.key)

  assert "peer1" in unchokeActions, "interested peer1 should be unchoked"
  assert "peer3" in unchokeActions, "interested peer3 should be unchoked"
  assert "peer2" in chokeActions, "uninterested peer2 should be choked (slot reclaimed)"
  assert "peer4" in chokeActions, "uninterested peer4 should be choked (slot reclaimed)"
  echo "PASS: uninterested peers get choked to reclaim slots"

block testOldBugWouldLeakSlots:
  ## Before the fix: `and p.peerInterested` condition prevented choking
  ## uninterested peers, leaving them unchoked indefinitely.
  type
    MockPeer = object
      key: string
      peerInterested: bool
      amChoking: bool

  # Peer was unchoked while interested, then sent NotInterested
  let peer = MockPeer(key: "leaky", peerInterested: false, amChoking: false)
  let shouldUnchoke = false  # not in unchoke set (not interested)

  # OLD behavior: would NOT choke because of `and p.peerInterested`
  let oldWouldChoke = not shouldUnchoke and not peer.amChoking and peer.peerInterested
  assert not oldWouldChoke, "old code would NOT choke uninterested peer (bug)"

  # NEW behavior: chokes regardless of interest
  let newWouldChoke = not shouldUnchoke and not peer.amChoking
  assert newWouldChoke, "new code DOES choke uninterested peer (fix)"

  echo "PASS: old bug confirmed and fix verified"

echo "All unchoke logic tests passed"
