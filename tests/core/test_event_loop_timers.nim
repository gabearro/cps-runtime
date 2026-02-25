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


echo "All event loop timer tests passed!"
