## Tests for CPS I/O timeouts

import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/timeouts

# Test 1: withTimeout on fast future (succeeds)
block testTimeoutFastFuture:
  proc fastOp(): CpsFuture[int] =
    let f = newCpsFuture[int]()
    let loop = getEventLoop()
    loop.registerTimer(10, proc() =
      f.complete(42)
    )
    return f

  let fut = withTimeout(fastOp(), 200)
  let val = runCps(fut)
  assert val == 42, "Expected 42, got " & $val
  echo "PASS: withTimeout fast future succeeds"

# Test 2: withTimeout on slow future (times out)
# Uses a future that never completes — no orphaned timer to worry about
block testTimeoutSlowFuture:
  let neverFut = newCpsFuture[string]()  # Will never complete on its own

  let fut = withTimeout(neverFut, 30)
  let loop = getEventLoop()
  while not fut.finished:
    loop.tick()
    if not fut.finished and not loop.hasWork:
      break
  assert fut.finished, "Should be finished"
  assert fut.hasError(), "Should have timed out"
  assert fut.getError() of TimeoutError, "Error should be TimeoutError"
  echo "PASS: withTimeout slow future times out"

# Test 3: withTimeout on void future (succeeds)
block testVoidTimeoutSuccess:
  let voidFut = newCpsVoidFuture()
  let loop = getEventLoop()
  loop.registerTimer(10, proc() =
    voidFut.complete()
  )

  let tFut = withTimeout(voidFut, 200)
  runCps(tFut)
  assert not tFut.hasError(), "Should have succeeded"
  echo "PASS: withTimeout void future succeeds"

# Test 4: withTimeout on void future (times out)
# Uses a future that never completes — no orphaned timer
block testVoidTimeoutFail:
  let neverFut = newCpsVoidFuture()  # Will never complete on its own

  let tFut = withTimeout(neverFut, 30)
  let loop = getEventLoop()
  while not tFut.finished:
    loop.tick()
    if not tFut.finished and not loop.hasWork:
      break
  assert tFut.hasError(), "Should have timed out"
  assert tFut.getError() of TimeoutError, "Error should be TimeoutError"
  echo "PASS: withTimeout void future times out"

# Test 5: withTimeout propagates errors
block testTimeoutPropagatesError:
  let innerFut = newCpsFuture[int]()
  let loop = getEventLoop()
  loop.registerTimer(10, proc() =
    innerFut.fail(newException(streams.AsyncIoError, "inner error"))
  )

  let fut = withTimeout(innerFut, 200)
  let loop2 = getEventLoop()
  while not fut.finished:
    loop2.tick()
    if not fut.finished and not loop2.hasWork:
      break
  assert fut.hasError(), "Should have error"
  assert fut.getError() of streams.AsyncIoError, "Error should be IoError"
  echo "PASS: withTimeout propagates errors"

# Test 6: withTimeout in CPS proc
block testTimeoutInCps:
  proc addDelayed(x: int, delayMs: int): CpsFuture[int] =
    let f = newCpsFuture[int]()
    let loop = getEventLoop()
    loop.registerTimer(delayMs, proc() =
      f.complete(x + 1)
    )
    return f

  proc timeoutTest(): CpsFuture[string] {.cps.} =
    let val = await withTimeout(addDelayed(10, 10), 200)
    return "got " & $val

  let r = runCps(timeoutTest())
  assert r == "got 11", "Expected 'got 11', got '" & r & "'"
  echo "PASS: withTimeout in CPS proc"

echo "All timeout tests passed!"
