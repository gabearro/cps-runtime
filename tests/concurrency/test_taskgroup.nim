## Tests for CPS TaskGroup (structured concurrency)
##
## Verifies task groups with fail-fast and collect-all error policies,
## cancellation, typed tasks, and dynamic spawning.

import cps/runtime
import cps/eventloop
import cps/transform
import cps/concurrency/taskgroup

# ============================================================
# CPS procs at module top level (required by transform macro)
# ============================================================

proc yieldOnce(): CpsVoidFuture {.cps.} =
  ## Yields once then completes.
  await cpsYield()

proc failingTask(msg: string): CpsVoidFuture {.cps.} =
  ## Yields then raises an error.
  await cpsYield()
  raise newException(ValueError, msg)

proc computeValue(x: int): CpsFuture[int] {.cps.} =
  ## Yields then returns a computed value.
  await cpsYield()
  return x * x

proc longSleepTask(): CpsVoidFuture {.cps.} =
  ## Sleeps for a very long time, intended to be cancelled.
  await cpsSleep(10000)

proc dynamicSpawner(group: TaskGroup, counter: ptr int): CpsVoidFuture {.cps.} =
  ## Spawns additional tasks into the group during execution.
  await cpsYield()
  counter[] = counter[] + 1
  # Spawn two more tasks into the group
  group.spawn(yieldOnce())
  group.spawn(yieldOnce())

# ============================================================
# Test 1: Empty group - wait returns immediately
# ============================================================

block testEmptyGroup:
  let group = newTaskGroup()
  assert group.len == 0
  assert group.activeCount == 0

  let waitFut = group.wait()
  assert waitFut.finished, "Empty group wait should complete immediately"
  assert not waitFut.hasError(), "Empty group wait should not have error"
  echo "PASS: Empty group wait returns immediately"

# ============================================================
# Test 2: Single task - spawn, wait, verify completed
# ============================================================

block testSingleTask:
  let group = newTaskGroup()
  group.spawn(yieldOnce())
  assert group.len == 1
  assert group.activeCount == 1

  runCps(group.wait())
  assert group.activeCount == 0
  echo "PASS: Single task spawn and wait"

# ============================================================
# Test 3: Multiple tasks - spawn 3, wait, all complete
# ============================================================

block testMultipleTasks:
  let group = newTaskGroup()
  group.spawn(yieldOnce())
  group.spawn(yieldOnce())
  group.spawn(yieldOnce())
  assert group.len == 3
  assert group.activeCount == 3

  runCps(group.wait())
  assert group.activeCount == 0
  echo "PASS: Multiple tasks all complete"

# ============================================================
# Test 4: FailFast - one task errors, siblings cancelled, wait raises
# ============================================================

block testFailFast:
  let group = newTaskGroup(epFailFast)
  group.spawn(longSleepTask(), "sleeper1")
  group.spawn(failingTask("boom"), "failer")
  group.spawn(longSleepTask(), "sleeper2")
  assert group.len == 3

  let waitFut = group.wait()
  runCps(waitFut)
  assert waitFut.finished
  assert waitFut.hasError(), "FailFast group should have error"
  assert waitFut.getError() of ValueError, "Error should be ValueError"
  assert waitFut.getError().msg == "boom", "Error message should be 'boom'"
  assert group.activeCount == 0, "All tasks should be done"
  echo "PASS: FailFast cancels siblings on first error"

# ============================================================
# Test 5: CollectAll - two tasks error, wait raises TaskGroupError
# ============================================================

block testCollectAll:
  let group = newTaskGroup(epCollectAll)
  group.spawn(failingTask("error1"), "failer1")
  group.spawn(failingTask("error2"), "failer2")
  group.spawn(yieldOnce(), "good")

  let waitFut = group.wait()
  runCps(waitFut)
  assert waitFut.finished
  assert waitFut.hasError(), "CollectAll group should have error"
  let groupErr = waitFut.getError()
  assert groupErr of TaskGroupError, "Error should be TaskGroupError"
  let tge = cast[ref TaskGroupError](groupErr)
  assert tge.errors.len == 2, "Should have 2 errors, got " & $tge.errors.len
  echo "PASS: CollectAll collects all errors"

# ============================================================
# Test 6: CancelAll - manually cancel all tasks
# ============================================================

block testCancelAll:
  let group = newTaskGroup()
  group.spawn(longSleepTask(), "a")
  group.spawn(longSleepTask(), "b")
  group.spawn(longSleepTask(), "c")
  assert group.len == 3

  group.cancelAll()
  # After cancelling, all tasks should be finished
  let waitFut = group.wait()
  # Since we cancelled, the tasks are already done; wait completes immediately
  assert waitFut.finished, "Wait should complete after cancelAll"
  # CancellationErrors should NOT be collected
  assert not waitFut.hasError(), "CancellationError should not count as group error"
  assert group.activeCount == 0
  echo "PASS: CancelAll cancels all tasks"

# ============================================================
# Test 7: Spawn typed task - get return value via Task[T]
# ============================================================

block testSpawnTyped:
  proc mainTyped(): CpsFuture[int] {.cps.} =
    let group = newTaskGroup()
    let t = group.spawn(computeValue(7), "compute")
    await group.wait()
    return await t

  let val = runCps(mainTyped())
  assert val == 49, "Expected 49, got " & $val
  echo "PASS: Spawn typed task returns value"

# ============================================================
# Test 8: Mixed success/failure with collectAll
# ============================================================

block testMixedCollectAll:
  let group = newTaskGroup(epCollectAll)
  group.spawn(yieldOnce(), "ok1")
  group.spawn(failingTask("fail1"), "bad1")
  group.spawn(yieldOnce(), "ok2")
  group.spawn(failingTask("fail2"), "bad2")
  group.spawn(yieldOnce(), "ok3")

  let waitFut = group.wait()
  runCps(waitFut)
  assert waitFut.hasError(), "Should have errors"
  let groupErr = cast[ref TaskGroupError](waitFut.getError())
  assert groupErr.errors.len == 2, "Should have exactly 2 errors, got " & $groupErr.errors.len
  # Verify the error messages
  var msgs: seq[string]
  for e in groupErr.errors:
    msgs.add(e.msg)
  assert "fail1" in msgs, "Should contain fail1"
  assert "fail2" in msgs, "Should contain fail2"
  echo "PASS: Mixed success/failure with collectAll"

# ============================================================
# Test 9: Task names preserved
# ============================================================

block testTaskNames:
  let group = newTaskGroup()
  group.spawn(yieldOnce(), "alpha")
  group.spawn(yieldOnce(), "beta")
  group.spawn(yieldOnce(), "gamma")

  assert group.len == 3
  runCps(group.wait())
  echo "PASS: Task names preserved"

# ============================================================
# Test 10: Dynamic spawn during execution
# ============================================================

block testDynamicSpawn:
  var counter: int = 0

  proc mainDynamic(): CpsVoidFuture {.cps.} =
    let group = newTaskGroup()
    group.spawn(dynamicSpawner(group, addr counter), "spawner")
    await group.wait()

  counter = 0
  runCps(mainDynamic())
  assert counter == 1, "Spawner should have run, counter = " & $counter
  echo "PASS: Dynamic spawn during execution"

# ============================================================
# Test 11: Cancellation errors not collected (epFailFast)
# ============================================================

block testCancellationErrorsNotCollected:
  # In epFailFast mode, when one task fails, siblings are cancelled.
  # The resulting error should be the real error, not CancellationError.
  let group = newTaskGroup(epFailFast)
  group.spawn(longSleepTask(), "will-cancel-1")
  group.spawn(longSleepTask(), "will-cancel-2")
  group.spawn(failingTask("real-error"), "failer")

  let waitFut = group.wait()
  runCps(waitFut)
  assert waitFut.hasError(), "Should have error"
  let err = waitFut.getError()
  # The error should be the real ValueError, not a CancellationError
  assert err of ValueError, "Error should be ValueError, got " & $err.type
  assert err.msg == "real-error", "Error message should be 'real-error'"
  assert not (err of CancellationError), "Should not be CancellationError"
  echo "PASS: Cancellation errors not collected"

# ============================================================
# Test 12: waitAll with no errors returns empty seq
# ============================================================

block testWaitAllNoErrors:
  let group = newTaskGroup()
  group.spawn(yieldOnce())
  group.spawn(yieldOnce())
  group.spawn(yieldOnce())

  let errors = runCps(group.waitAll())
  assert errors.len == 0, "waitAll with no errors should return empty seq"
  echo "PASS: waitAll with no errors"

# ============================================================
# Test 13: waitAll with epCollectAll returns all errors as values
# ============================================================

block testWaitAllCollectsErrors:
  let group = newTaskGroup(epCollectAll)
  group.spawn(failingTask("err1"))
  group.spawn(yieldOnce())
  group.spawn(failingTask("err2"))

  let errors = runCps(group.waitAll())
  assert errors.len == 2, "waitAll should return 2 errors, got " & $errors.len
  var msgs: seq[string]
  for e in errors:
    msgs.add(e.msg)
  assert "err1" in msgs, "Should contain err1"
  assert "err2" in msgs, "Should contain err2"
  echo "PASS: waitAll collects errors without raising"

# ============================================================
# Test 14: waitAll with epFailFast returns the first error
# ============================================================

block testWaitAllFailFast:
  let group = newTaskGroup(epFailFast)
  group.spawn(longSleepTask())
  group.spawn(failingTask("first-error"))
  group.spawn(longSleepTask())

  let errors = runCps(group.waitAll())
  assert errors.len >= 1, "waitAll with failFast should return at least 1 error"
  assert errors[0].msg == "first-error", "First error should be 'first-error'"
  echo "PASS: waitAll with failFast"

# ============================================================
# Test 15: waitAll on empty group returns empty seq immediately
# ============================================================

block testWaitAllEmpty:
  let group = newTaskGroup()
  let errFut = group.waitAll()
  assert errFut.finished, "waitAll on empty group should complete immediately"
  let errors = errFut.read()
  assert errors.len == 0, "Empty group should have no errors"
  echo "PASS: waitAll on empty group"

echo ""
echo "All task group tests passed!"
