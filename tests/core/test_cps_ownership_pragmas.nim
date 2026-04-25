## Regression tests for CPS pragma propagation and ARC ownership hardening.
##
## Validates that `.nosinks` / `.gcsafe` on CPS procs are preserved through
## macro-generated wrappers and step procs, and remains stable under
## cross-await seq reassignment patterns.

import cps/runtime
import cps/transform
import cps/eventloop

type
  StressNode = object
    key: string
    payload: string
    score: int

proc readyVoid(): CpsVoidFuture =
  completedVoidFuture()

proc ownershipStress(rounds: int, width: int): CpsFuture[int] {.cps, nosinks.} =
  var queriedKeys: seq[string]
  var discovered: seq[StressNode]
  var total = 0
  var round = 0

  while round < rounds:
    inc round

    # Mirror DHT-style "closest + discovered merge" with refcounted fields.
    var candidates: seq[StressNode] = discovered
    var di = 0
    while di < discovered.len:
      let dn = discovered[di]
      inc di
      var found = false
      var ci = 0
      while ci < candidates.len:
        if candidates[ci].key == dn.key:
          found = true
          ci = candidates.len
        inc ci
      if not found:
        candidates.add(dn)

    let key = "node-" & $round
    queriedKeys.add(key)

    # Alternate await sites to force segmented CPS environments.
    if (round and 1) == 0:
      await cpsYield()
    else:
      await readyVoid()

    var i = 0
    let n = min(width, candidates.len)
    while i < n:
      total += candidates[i].score + candidates[i].payload.len
      inc i

    # Reassign to empty/new seq in the same shape that previously crashed.
    candidates = @[]
    discovered.add StressNode(
      key: key,
      payload: "payload-" & $round,
      score: round
    )

    if round mod 3 == 0:
      await cpsYield()

  return total + queriedKeys.len + discovered.len

proc branchyOwnershipStress(iters: int): CpsFuture[int] {.cps, nosinks.} =
  var pool: seq[StressNode]
  var total = 0
  var i = 0
  while i < iters:
    if (i and 1) == 0:
      await cpsYield()
    else:
      await readyVoid()

    var merged: seq[StressNode] = pool
    if merged.len > 0 and i mod 5 == 0:
      merged.delete(0)
    merged.add StressNode(key: "k-" & $i, payload: "p-" & $i, score: i)
    pool = merged

    if i mod 4 == 0:
      await cpsYield()

    total += pool.len
    inc i
  return total

block testNosinksOwnershipStress:
  proc driver(): CpsFuture[int] {.cps.} =
    var acc = 0
    var i = 0
    while i < 120:
      acc += await ownershipStress(24, 24)
      inc i
    return acc

  let value = runCps(driver())
  assert value > 0
  echo "PASS: CPS nosinks ownership stress"

block testBranchyNosinksGcsafe:
  let value = runCps(branchyOwnershipStress(600))
  assert value > 0
  echo "PASS: CPS branchy nosinks stress"

block testGcsafeFastPathPragmaPreserved:
  proc addFast(a, b: int): CpsFuture[int] {.cps, gcsafe.} =
    return a + b

  let value = runCps(addFast(40, 2))
  assert value == 42
  echo "PASS: CPS gcsafe fast-path pragma preservation"

echo "All CPS ownership pragma tests passed!"
