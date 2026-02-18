## Tests for CPS task cancellation
##
## Verifies cancel/isCancelled on futures and tasks, CancellationError
## propagation through await chains, and withTimeout cancellation.

import cps/runtime
import cps/eventloop
import cps/transform
import cps/io/streams
import cps/io/timeouts

# ============================================================
# Test 1: Cancel a pending future — callbacks fire with CancellationError
# ============================================================

block testCancelPendingFuture:
  var callbackFired = false
  var gotCancellationError = false

  let fut = newCpsFuture[int]()
  fut.addCallback(proc() =
    callbackFired = true
    if fut.hasError() and fut.getError() of CancellationError:
      gotCancellationError = true
  )

  fut.cancel()
  assert callbackFired, "Callback should have fired on cancel"
  assert gotCancellationError, "Callback should receive CancellationError"
  assert fut.finished, "Future should be finished after cancel"
  assert fut.hasError(), "Future should have error after cancel"
  assert fut.getError() of CancellationError, "Error should be CancellationError"
  echo "PASS: Cancel pending future fires callbacks with CancellationError"

# ============================================================
# Test 2: Cancel an already-completed future — no-op
# ============================================================

block testCancelCompletedFuture:
  let fut = newCpsFuture[int]()
  fut.complete(42)
  assert fut.finished

  # Cancel after completion should be a no-op
  fut.cancel()
  assert not fut.isCancelled(), "Should not be marked cancelled"
  assert not fut.hasError(), "Should still have no error"
  assert fut.read() == 42, "Value should still be 42"
  echo "PASS: Cancel already-completed future is no-op"

# ============================================================
# Test 3: Cancel a task — underlying future gets CancellationError
# ============================================================

block testCancelTask:
  proc slowWork(): CpsFuture[int] {.cps.} =
    await cpsSleep(5000)  # Very long sleep — will be cancelled
    return 99

  let t = spawn slowWork()
  t.cancel()
  assert t.isCancelled(), "Task should be cancelled"
  assert t.hasError(), "Task should have error"
  assert t.getError() of CancellationError, "Error should be CancellationError"
  echo "PASS: Cancel task cancels underlying future"

# ============================================================
# Test 4: isCancelled returns true after cancel
# ============================================================

block testIsCancelled:
  let fut = newCpsFuture[string]()
  assert not fut.isCancelled(), "Should not be cancelled initially"
  fut.cancel()
  assert fut.isCancelled(), "Should be cancelled after cancel()"

  let vfut = newCpsVoidFuture()
  assert not vfut.isCancelled(), "Void future should not be cancelled initially"
  vfut.cancel()
  assert vfut.isCancelled(), "Void future should be cancelled after cancel()"
  echo "PASS: isCancelled returns true after cancel"

# ============================================================
# Test 5: Await a cancelled future — CancellationError propagates to parent
# ============================================================

block testAwaitCancelledPropagates:
  var caughtCancellation = false

  proc inner(): CpsVoidFuture =
    let f = newCpsVoidFuture()
    # Cancel immediately
    f.cancel()
    return f

  proc outer(): CpsVoidFuture {.cps.} =
    try:
      await inner()
    except CancellationError:
      caughtCancellation = true

  caughtCancellation = false
  runCps(outer())
  assert caughtCancellation, "CancellationError should propagate through await"
  echo "PASS: Await cancelled future propagates CancellationError"

# ============================================================
# Test 6: Cancel during cpsSleep — the sleeping task wakes up with CancellationError
# ============================================================

block testCancelDuringSleep:
  var reachedAfterSleep = false
  var gotError = false

  proc sleeper(): CpsVoidFuture {.cps.} =
    await cpsSleep(10000)  # 10 seconds — will be cancelled before this
    reachedAfterSleep = true

  let sleepFut = sleeper()
  # The sleeper is now suspended waiting on cpsSleep's internal future.
  # Cancel the outer future — this fails it with CancellationError.
  sleepFut.cancel()

  assert sleepFut.finished, "Future should be finished"
  assert sleepFut.isCancelled(), "Future should be cancelled"
  assert sleepFut.hasError(), "Future should have error"
  assert sleepFut.getError() of CancellationError, "Error should be CancellationError"
  assert not reachedAfterSleep, "Should not have reached code after sleep"
  echo "PASS: Cancel during cpsSleep wakes up with CancellationError"

# ============================================================
# Test 7: withTimeout cancels the inner future on timeout
# ============================================================

block testWithTimeoutCancelsInner:
  let innerFut = newCpsVoidFuture()  # Never completes on its own

  let timedFut = withTimeout(innerFut, 30)
  let loop = getEventLoop()
  while not timedFut.finished:
    loop.tick()
    if not timedFut.finished and not loop.hasWork:
      break

  assert timedFut.finished, "Timed future should be finished"
  assert timedFut.hasError(), "Should have timed out"
  assert timedFut.getError() of TimeoutError, "Error should be TimeoutError"
  # The inner future should have been cancelled by withTimeout
  assert innerFut.finished, "Inner future should be finished (cancelled)"
  assert innerFut.isCancelled(), "Inner future should be cancelled"
  assert innerFut.hasError(), "Inner future should have error"
  assert innerFut.getError() of CancellationError, "Inner error should be CancellationError"
  echo "PASS: withTimeout cancels inner future on timeout"

# ============================================================
# Test 8: Multiple cancel calls are idempotent
# ============================================================

block testMultipleCancels:
  var callbackCount = 0

  let fut = newCpsFuture[int]()
  fut.addCallback(proc() =
    inc callbackCount
  )

  fut.cancel()
  assert callbackCount == 1, "Callback should fire once"
  assert fut.isCancelled(), "Should be cancelled"

  # Second cancel — should be no-op since already finished
  fut.cancel()
  assert callbackCount == 1, "Callback should not fire again"
  assert fut.isCancelled(), "Should still be cancelled"

  # Third cancel — still no-op
  fut.cancel()
  assert callbackCount == 1, "Callback should still not fire again"
  echo "PASS: Multiple cancel calls are idempotent"

echo ""
echo "All cancellation tests passed!"
