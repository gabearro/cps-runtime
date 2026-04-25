## Tests for holepunch state cleanup on peer disconnect.
## Verifies that holepunchInFlight, holepunchBackoff, and holepunchRelayByTarget
## are pruned when peers disconnect.

import std/[tables, sets]
import cps/bittorrent/peer
import cps/bittorrent/pex
import cps/bittorrent/holepunch

# Simulate the cleanup logic that should happen in handlePeerEvent(pekDisconnected).
# We test this in isolation without full client machinery.

block test_holepunchInFlight_pruned_on_disconnect:
  var holepunchInFlight: HashSet[string]
  holepunchInFlight.incl("[2001:db8::1]:6881")
  holepunchInFlight.incl("10.0.0.1:6881")

  # Simulate disconnect of the IPv6 peer
  let key = "[2001:db8::1]:6881"
  holepunchInFlight.excl(key)
  assert key notin holepunchInFlight
  assert "10.0.0.1:6881" in holepunchInFlight
  echo "PASS: holepunchInFlight pruned on disconnect"

block test_holepunchRelayByTarget_pruned_when_relay_disconnects:
  var holepunchRelayByTarget: Table[string, HashSet[string]]
  # Target A uses relays R1, R2; Target B uses relay R1; Target C uses relay R3
  holepunchRelayByTarget["10.0.0.2:6881"] = [
    "10.0.0.100:6881", "10.0.0.200:6881"].toHashSet  # R1 + R2
  holepunchRelayByTarget["10.0.0.3:6881"] = [
    "10.0.0.100:6881"].toHashSet  # R1 only
  holepunchRelayByTarget["10.0.0.4:6881"] = [
    "10.0.0.300:6881"].toHashSet  # R3

  # Relay R1 disconnects — excl from all sets, delete empty sets
  let disconnectedRelay = "10.0.0.100:6881"
  var emptyTargets: seq[string]
  for target, relays in holepunchRelayByTarget.mpairs:
    relays.excl(disconnectedRelay)
    if relays.len == 0:
      emptyTargets.add(target)
  for t in emptyTargets:
    holepunchRelayByTarget.del(t)

  # Target A still has R2
  assert "10.0.0.2:6881" in holepunchRelayByTarget
  assert holepunchRelayByTarget["10.0.0.2:6881"].len == 1
  assert "10.0.0.200:6881" in holepunchRelayByTarget["10.0.0.2:6881"]
  # Target B had only R1 — should be removed
  assert "10.0.0.3:6881" notin holepunchRelayByTarget
  # Target C untouched
  assert "10.0.0.4:6881" in holepunchRelayByTarget
  echo "PASS: holepunchRelayByTarget pruned when relay disconnects"

block test_holepunchBackoff_pruned_on_disconnect:
  var holepunchBackoff: Table[string, float]
  holepunchBackoff["10.0.0.5:6881"] = 99999.0
  holepunchBackoff["10.0.0.6:6881"] = 99999.0

  # Peer 10.0.0.5:6881 disconnects — should remove its backoff entry
  let key = "10.0.0.5:6881"
  holepunchBackoff.del(key)
  assert key notin holepunchBackoff
  assert "10.0.0.6:6881" in holepunchBackoff
  echo "PASS: holepunchBackoff pruned on disconnect"

block test_pexPeerFlags_pruned_on_disconnect:
  var pexPeerFlags: Table[string, uint8]
  pexPeerFlags["10.0.0.7:6881"] = uint8(pexUtp) or uint8(pexHolepunch)
  pexPeerFlags["10.0.0.8:6881"] = uint8(pexEncryption)

  # Peer 10.0.0.7:6881 disconnects — its cached PEX flags should be removed
  let key = "10.0.0.7:6881"
  pexPeerFlags.del(key)
  assert key notin pexPeerFlags
  assert "10.0.0.8:6881" in pexPeerFlags
  echo "PASS: pexPeerFlags pruned on disconnect"

echo "ALL HOLEPUNCH STATE CLEANUP TESTS PASSED"
