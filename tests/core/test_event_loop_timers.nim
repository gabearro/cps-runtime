## Event loop timer/ready-queue hardening tests.

import cps/eventloop

block testScheduleCallbackReadyQueue:
  let loop = getEventLoop()
  var ran = false

  loop.scheduleCallback(proc() =
    ran = true
  )

  loop.tick()
  assert ran, "scheduleCallback should enqueue and execute through ready queue"
  echo "PASS: scheduleCallback executes via ready queue"

block testReadyCallbackExceptionDoesNotStopLoop:
  let loop = getEventLoop()
  loop.resetStats()
  var afterThrow = false

  loop.scheduleCallback(proc() =
    raise newException(ValueError, "ready callback failure")
  )
  loop.scheduleCallback(proc() =
    afterThrow = true
  )

  loop.tick()

  let stats = loop.getStats()
  assert afterThrow, "Ready callback after a throwing callback should still run"
  assert stats.callbackErrors >= 1, "Expected ready callback error to be counted"
  echo "PASS: Ready callback exception is isolated"

block testTimerCallbackExceptionDoesNotStopLoop:
  let loop = getEventLoop()
  loop.resetStats()
  var afterThrow = false

  discard loop.registerTimer(0, proc() =
    raise newException(ValueError, "timer callback failure")
  )
  discard loop.registerTimer(0, proc() =
    afterThrow = true
  )

  loop.tick()

  let stats = loop.getStats()
  assert afterThrow, "Timer callback after a throwing callback should still run"
  assert stats.callbackErrors >= 1, "Expected timer callback error to be counted"
  echo "PASS: Timer callback exception is isolated"

block testFutureCallbackExceptionDoesNotEscapeCompletion:
  let fut = newCpsVoidFuture()
  var afterThrow = false
  var completeReturned = false

  fut.addCallback(proc() =
    raise newException(ValueError, "future callback failure")
  )
  fut.addCallback(proc() =
    afterThrow = true
  )

  try:
    fut.complete()
    completeReturned = true
  except CatchableError:
    completeReturned = false

  assert completeReturned, "Future completion should not rethrow callback errors"
  assert afterThrow, "Future callback after a throwing callback should still run"
  echo "PASS: Future callback exception is isolated"

block testFailedFutureStillRaisesOnRead:
  let fut = newCpsVoidFuture()
  var raised = false

  fut.fail(newException(ValueError, "future failure"))

  runCps(fut)
  try:
    fut.read()
  except ValueError:
    raised = true

  assert raised, "Failed futures should still raise when read"
  echo "PASS: Failed future semantics preserved"

block testManyTimersFireAndDrain:
  let loop = getEventLoop()
  var fired = 0
  const N = 512

  for _ in 0 ..< N:
    discard loop.registerTimer(0, proc() =
      inc fired
    )

  var spins = 0
  while fired < N and spins < 32:
    loop.tick()
    inc spins

  assert fired == N, "Expected all timers to fire (" & $N & "), got " & $fired
  assert not loop.hasWork(), "Timer queue should be drained after all timers fire"
  echo "PASS: Many timers fire and drain without retained metadata"

block testCancelledTimerDoesNotRetainWork:
  let loop = getEventLoop()
  var fired = false

  let h = loop.registerTimer(60000, proc() =
    fired = true
  )
  cancel(h)

  loop.tick()

  assert not fired, "Cancelled timer callback must not run"
  assert not loop.hasWork(), "Cancelled timer must not keep event loop work alive"
  echo "PASS: Cancelled timer does not retain active work"

block testCancelledTimersBehindLiveRootStayBounded:
  let loop = getEventLoop()
  let live = loop.registerTimer(60000, proc() = discard)

  # A live, earlier deadline prevents root-only pruning from reaching these
  # cancelled entries. The heap must compact them before their deadlines.
  for _ in 0 ..< 4096:
    let cancelled = loop.registerTimer(120000, proc() = discard)
    cancelled.cancel()

  assert loop.pendingTimerCount() < 512,
    "Cancelled timer entries behind a live root must remain bounded"
  live.cancel()
  discard loop.poll()
  assert loop.pendingTimerCount() == 0,
    "Cancelling the remaining live root should drain the timer heap"
  echo "PASS: Cancelled timers behind a live root stay bounded"


echo "All event loop timer tests passed!"
