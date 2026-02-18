## Tests for race/select combinators
##
## Verifies race, select, and raceCancel on CpsFuture and CpsVoidFuture.

import cps/runtime
import cps/eventloop
import cps/transform

# ============================================================
# Test 1: Race two futures — first to complete wins
# ============================================================

proc raceSlowWorker(ms: int, value: int): CpsFuture[int] {.cps.} =
  await cpsSleep(ms)
  return value

block testRaceTwoFutures:
  proc main(): CpsFuture[int] {.cps.} =
    let f1 = raceSlowWorker(100, 10)
    let f2 = raceSlowWorker(20, 20)
    let winner = await race(f1, f2)
    return winner

  let val = runCps(main())
  assert val == 20, "Expected 20 (shorter sleep wins), got " & $val
  echo "PASS: Race two futures - first to complete wins"

# ============================================================
# Test 2: Race with one already-completed future — returns immediately
# ============================================================

block testRaceAlreadyCompleted:
  let f1 = newCpsFuture[int]()
  f1.complete(42)
  let f2 = newCpsFuture[int]()  # Never completes

  let result = race(f1, f2)
  assert result.finished, "Result should already be finished"
  assert result.read() == 42, "Expected 42, got " & $result.read()
  echo "PASS: Race with already-completed future returns immediately"

# ============================================================
# Test 3: Race where loser completes later — result already set
# ============================================================

block testRaceLoserCompletesLater:
  let f1 = newCpsFuture[string]()
  let f2 = newCpsFuture[string]()

  let result = race(f1, f2)
  assert not result.finished, "Result should not be finished yet"

  # First completion wins
  f1.complete("first")
  assert result.finished, "Result should be finished after f1 completes"
  assert result.read() == "first", "Expected 'first'"

  # Second completion should not affect the result (callback is a no-op)
  f2.complete("second")
  assert result.read() == "first", "Result should still be 'first'"
  echo "PASS: Race where loser completes later - result already set"

# ============================================================
# Test 4: Race with error — error in winner propagates
# ============================================================

block testRaceWithError:
  let f1 = newCpsFuture[int]()
  let f2 = newCpsFuture[int]()

  let result = race(f1, f2)

  # First future fails
  f1.fail(newException(IOError, "network error"))
  assert result.finished, "Result should be finished"
  assert result.hasError(), "Result should have error"
  var caught = false
  try:
    discard result.read()
  except IOError:
    caught = true
  assert caught, "Should catch IOError from winner"
  echo "PASS: Race with error - error in winner propagates"

# ============================================================
# Test 5: Race single future — returns its value
# ============================================================

block testRaceSingle:
  let f1 = newCpsFuture[int]()
  let result = race(f1)
  f1.complete(99)
  assert result.finished
  assert result.read() == 99, "Expected 99, got " & $result.read()
  echo "PASS: Race single future returns its value"

# ============================================================
# Test 6: Race void futures
# ============================================================

block testRaceVoidFutures:
  let f0 = newCpsVoidFuture()
  let f1 = newCpsVoidFuture()

  let result = race(f0, f1)
  assert not result.finished

  # f1 completes first
  f1.complete()
  assert result.finished, "Result should be finished"
  assert not result.hasError(), "No error expected"

  # f0 completing later is a no-op on result
  f0.complete()
  assert result.finished
  assert not result.hasError()
  echo "PASS: Race void futures"

# ============================================================
# Test 7: Select — returns correct index and value
# ============================================================

block testSelect:
  let f0 = newCpsFuture[int]()
  let f1 = newCpsFuture[int]()
  let f2 = newCpsFuture[int]()

  let result = select(f0, f1, f2)
  assert not result.finished

  # Complete the middle one first
  f1.complete(77)
  assert result.finished, "Result should be finished"
  let sel = result.read()
  assert sel.index == 1, "Expected index 1, got " & $sel.index
  assert sel.value == 77, "Expected value 77, got " & $sel.value
  echo "PASS: Select returns correct index and value"

# ============================================================
# Test 8: RaceCancel — losers get cancelled
# ============================================================

block testRaceCancel:
  let f0 = newCpsFuture[int]()
  let f1 = newCpsFuture[int]()
  let f2 = newCpsFuture[int]()

  let result = raceCancel(f0, f1, f2)
  assert not result.finished

  # f1 wins
  f1.complete(55)
  assert result.finished, "Result should be finished"
  assert result.read() == 55, "Expected 55"

  # Losers should be cancelled
  assert f0.finished, "f0 should be finished (cancelled)"
  assert f0.isCancelled(), "f0 should be cancelled"
  assert f0.hasError(), "f0 should have error"
  assert f0.getError() of CancellationError, "f0 error should be CancellationError"

  assert f2.finished, "f2 should be finished (cancelled)"
  assert f2.isCancelled(), "f2 should be cancelled"
  assert f2.hasError(), "f2 should have error"
  assert f2.getError() of CancellationError, "f2 error should be CancellationError"
  echo "PASS: RaceCancel - losers get cancelled"

# ============================================================
# Test 9: Race with cpsSleep — shorter sleep wins
# ============================================================

proc raceTimedWorker(ms: int, value: int): CpsFuture[int] {.cps.} =
  await cpsSleep(ms)
  return value

block testRaceWithCpsSleep:
  proc main(): CpsFuture[int] {.cps.} =
    let f1 = raceTimedWorker(200, 1)
    let f2 = raceTimedWorker(30, 2)
    let f3 = raceTimedWorker(150, 3)
    let winner = await race(f1, f2, f3)
    return winner

  let val = runCps(main())
  assert val == 2, "Expected 2 (30ms wins), got " & $val
  echo "PASS: Race with cpsSleep - shorter sleep wins"

# ============================================================
# Test 10: Empty race — handles gracefully with error
# ============================================================

block testEmptyRace:
  var futs: seq[CpsFuture[int]]
  let result = race(futs)
  assert result.finished, "Empty race should be finished immediately"
  assert result.hasError(), "Empty race should have error"
  var caught = false
  try:
    discard result.read()
  except ValueError:
    caught = true
  assert caught, "Empty race should raise ValueError"
  echo "PASS: Empty race handles gracefully"

# ============================================================
# Test 11: RaceCancel void futures — losers get cancelled
# ============================================================

block testRaceCancelVoid:
  let f0 = newCpsVoidFuture()
  let f1 = newCpsVoidFuture()

  let result = raceCancel(f0, f1)
  assert not result.finished

  # f0 wins
  f0.complete()
  assert result.finished, "Result should be finished"
  assert not result.hasError(), "No error expected"

  # Loser should be cancelled
  assert f1.finished, "f1 should be finished (cancelled)"
  assert f1.isCancelled(), "f1 should be cancelled"
  echo "PASS: RaceCancel void futures - losers cancelled"

# ============================================================
# Test 12: Select with already-completed future
# ============================================================

block testSelectAlreadyCompleted:
  let f0 = newCpsFuture[int]()
  let f1 = newCpsFuture[int]()
  f1.complete(33)
  let f2 = newCpsFuture[int]()

  let result = select(f0, f1, f2)
  assert result.finished, "Should be finished immediately"
  let sel = result.read()
  assert sel.index == 1, "Expected index 1, got " & $sel.index
  assert sel.value == 33, "Expected value 33, got " & $sel.value
  echo "PASS: Select with already-completed future"

# ============================================================
# Test 13: RaceCancel with already-completed future cancels others
# ============================================================

block testRaceCancelAlreadyCompleted:
  let f0 = newCpsFuture[int]()
  let f1 = newCpsFuture[int]()
  f1.complete(88)
  let f2 = newCpsFuture[int]()

  let result = raceCancel(f0, f1, f2)
  assert result.finished
  assert result.read() == 88

  # f0 and f2 should be cancelled
  assert f0.isCancelled(), "f0 should be cancelled"
  assert f2.isCancelled(), "f2 should be cancelled"
  echo "PASS: RaceCancel with already-completed future cancels others"

echo ""
echo "All race/select tests passed!"
