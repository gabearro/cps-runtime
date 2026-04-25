## Tests for multi-relay holepunch support.
## Verifies that multiple relays can announce the same target and
## that losing one relay doesn't blackhole the target.

import std/[tables, sets]

# Simulate the multi-relay data structure
type RelaySet = HashSet[string]

block test_multiple_relays_per_target:
  var holepunchRelayByTarget: Table[string, RelaySet]

  let target = "[2001:db8::1]:6881"
  let relay1 = "10.0.0.100:6881"
  let relay2 = "10.0.0.200:6881"

  # First relay announces the target
  if target notin holepunchRelayByTarget:
    holepunchRelayByTarget[target] = initHashSet[string]()
  holepunchRelayByTarget[target].incl(relay1)

  # Second relay also announces the target
  holepunchRelayByTarget[target].incl(relay2)

  assert holepunchRelayByTarget[target].len == 2
  assert relay1 in holepunchRelayByTarget[target]
  assert relay2 in holepunchRelayByTarget[target]
  echo "PASS: multiple relays stored per target"

block test_relay_disconnect_doesnt_blackhole:
  var holepunchRelayByTarget: Table[string, RelaySet]

  let target = "10.0.0.50:6881"
  let relay1 = "10.0.0.100:6881"
  let relay2 = "10.0.0.200:6881"

  holepunchRelayByTarget[target] = [relay1, relay2].toHashSet

  # Relay1 disconnects — remove from all sets
  var emptyTargets: seq[string]
  for tgt, relays in holepunchRelayByTarget.mpairs:
    relays.excl(relay1)
    if relays.len == 0:
      emptyTargets.add(tgt)
  for t in emptyTargets:
    holepunchRelayByTarget.del(t)

  assert target in holepunchRelayByTarget
  assert holepunchRelayByTarget[target].len == 1
  assert relay2 in holepunchRelayByTarget[target]
  echo "PASS: relay disconnect preserves other relays for target"

block test_all_relays_disconnect_removes_target:
  var holepunchRelayByTarget: Table[string, RelaySet]

  let target = "10.0.0.50:6881"
  let relay1 = "10.0.0.100:6881"

  holepunchRelayByTarget[target] = [relay1].toHashSet

  # Relay1 disconnects — target entry should be removed
  var emptyTargets: seq[string]
  for tgt, relays in holepunchRelayByTarget.mpairs:
    relays.excl(relay1)
    if relays.len == 0:
      emptyTargets.add(tgt)
  for t in emptyTargets:
    holepunchRelayByTarget.del(t)

  assert target notin holepunchRelayByTarget
  echo "PASS: all relays gone removes target entry"

block test_relay_lookup_tries_stored_first:
  var holepunchRelayByTarget: Table[string, RelaySet]
  var peers: Table[string, string]  # key -> state (simplified)

  let target = "10.0.0.50:6881"
  let relay1 = "10.0.0.100:6881"  # disconnected
  let relay2 = "10.0.0.200:6881"  # still connected

  holepunchRelayByTarget[target] = [relay1, relay2].toHashSet
  peers[relay2] = "active"  # relay1 is not in peers (disconnected)

  # Find a usable relay from the set
  var candidateRelay = ""
  if target in holepunchRelayByTarget:
    for rKey in holepunchRelayByTarget[target]:
      if rKey in peers:
        candidateRelay = rKey
        break

  assert candidateRelay == relay2
  echo "PASS: relay lookup finds usable relay from set"

echo "ALL MULTI-RELAY HOLEPUNCH TESTS PASSED"
