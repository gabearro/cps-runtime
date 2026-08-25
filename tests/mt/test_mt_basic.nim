## Tests for MT runtime basic functionality
##
## Verifies that the MT event loop starts/stops correctly,
## timers and yield work, and CPS procs run properly.
##
## NOTE: MT tests must be compiled with --mm:arc (not ORC)
## because ORC's cycle collector is not thread-safe.

import cps/mt
import cps/transform
import std/[atomics, monotimes, times]

let loop = initMtRuntime(numWorkers = 2)

# Test 1: Basic MT state
block testMtState:
  assert loop.mtActive, "MT loop should be active"
  assert mtModeEnabled, "mtModeEnabled should be set"
  echo "PASS: MT event loop state"

# Test 2: cpsSleep works on MT event loop
block testMtSleep:
  proc sleepTest(): CpsVoidFuture {.cps.} =
    await cpsSleep(50)

  let start = getMonoTime()
  let fut = sleepTest()
  runCps(fut)
  let elapsed = (getMonoTime() - start).inMilliseconds
  assert elapsed >= 40, "Sleep should take at least 40ms, took " & $elapsed & "ms"
  echo "PASS: cpsSleep on MT event loop"

# Test 3: cpsYield works on MT event loop
block testMtYield:
  var counter: Atomic[int]
  counter.store(0, moRelaxed)

  proc yieldTest(): CpsVoidFuture {.cps.} =
    counter.store(1, moRelease)
    await cpsYield()
    counter.store(2, moRelease)

  let fut = yieldTest()
  runCps(fut)
  assert counter.load(moAcquire) == 2,
    "Should have executed both parts around yield on a worker"
  echo "PASS: cpsYield on MT event loop"

# Test 4: CPS proc with return value on MT event loop
block testMtReturnValue:
  proc addOne(x: int): CpsFuture[int] =
    let f = newCpsFuture[int]()
    let loop = getEventLoop()
    loop.registerTimer(5, proc() =
      f.complete(x + 1)
    )
    return f

  proc chainTest(): CpsFuture[int] {.cps.} =
    let a = await addOne(0)
    let b = await addOne(a)
    let c = await addOne(b)
    return c

  let result = runCps(chainTest())
  assert result == 3, "Expected 3, got " & $result
  echo "PASS: CPS return value on MT event loop"

# Test 5: Concurrent CPS procs on MT event loop
block testMtConcurrent:
  var seen: Atomic[int]
  var completionSeq: Atomic[int]
  var t1EndOrder: Atomic[int]
  var t2EndOrder: Atomic[int]

  proc task1(): CpsVoidFuture {.cps.} =
    discard seen.fetchOr(0b0001, moAcquireRelease)
    await cpsSleep(30)
    t1EndOrder.store(completionSeq.fetchAdd(1, moAcquireRelease), moRelease)
    discard seen.fetchOr(0b0100, moAcquireRelease)

  proc task2(): CpsVoidFuture {.cps.} =
    discard seen.fetchOr(0b0010, moAcquireRelease)
    await cpsSleep(10)
    t2EndOrder.store(completionSeq.fetchAdd(1, moAcquireRelease), moRelease)
    discard seen.fetchOr(0b1000, moAcquireRelease)

  let f1 = task1()
  let f2 = task2()
  let combined = waitAll(f1, f2)
  runCps(combined)
  assert seen.load(moAcquire) == 0b1111
  assert t2EndOrder.load(moAcquire) < t1EndOrder.load(moAcquire),
    "t2 should finish before t1"
  echo "PASS: Concurrent CPS procs on MT event loop"

loop.shutdownMtRuntime()

echo ""
echo "All MT basic tests passed!"
