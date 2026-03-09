## Tests for CPS I/O timeouts

import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/timeouts
import cps/io/udp

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

# Test 7: Stress cancelled timeout timers wrapping UDP recv futures.
# Regression for a crash in timer-root pruning during cancellation cleanup.
block testTimeoutUdpRecvCancellationStress:
  let receiver = newUdpSocket()
  receiver.bindAddr("127.0.0.1", 0)
  let loop = getEventLoop()

  const N = 300
  for i in 0 ..< N:
    let timed = withTimeout(receiver.recvFrom(1024), 1)
    var spins = 0
    while not timed.finished and spins < 256:
      loop.tick()
      inc spins

    assert timed.finished, "Timed recv future should finish in iteration " & $i
    assert timed.hasError(), "Timed recv future should error in iteration " & $i
    assert timed.getError() of TimeoutError,
      "Timed recv future should fail with TimeoutError in iteration " & $i

    # Give cancellation cleanup/pruning a chance to run before next iteration.
    loop.tick()

  receiver.close()
  echo "PASS: withTimeout + UDP recv cancellation stress"

# Test 8: Stress fast UDP receives where withTimeout cancels the timer path.
# This exercises cancelled timer pruning for callbacks that capture UDP recv state.
block testTimeoutUdpRecvFastCompletionStress:
  let receiver = newUdpSocket()
  receiver.bindAddr("127.0.0.1", 0)
  let sender = newUdpSocket()
  let loop = getEventLoop()
  let port = receiver.localPort()

  const N = 300
  for i in 0 ..< N:
    let expectedMsg = "pkt-" & $i
    let timedRecv = withTimeout(receiver.recvFrom(1024), 250)

    if not sender.trySendToAddr(expectedMsg, "127.0.0.1", port):
      let sendFut = sender.sendToAddr(expectedMsg, "127.0.0.1", port)
      var sendSpins = 0
      while not sendFut.finished and sendSpins < 256:
        loop.tick()
        inc sendSpins
      assert sendFut.finished, "Fallback send should finish in iteration " & $i
      assert not sendFut.hasError(), "Fallback send should succeed in iteration " & $i

    var recvSpins = 0
    while not timedRecv.finished and recvSpins < 512:
      loop.tick()
      inc recvSpins

    assert timedRecv.finished, "Timed recv should finish in iteration " & $i
    assert not timedRecv.hasError(), "Timed recv should succeed in iteration " & $i
    let dg = timedRecv.read()
    assert dg.data == expectedMsg,
      "Expected '" & expectedMsg & "', got '" & dg.data & "'"

    # Give cancelled-timer pruning a chance to run before next iteration.
    loop.tick()

  receiver.close()
  sender.close()
  echo "PASS: withTimeout + UDP recv fast completion stress"

echo "All timeout tests passed!"
