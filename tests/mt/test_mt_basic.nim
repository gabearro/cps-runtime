## Tests for MT runtime basic functionality
##
## Verifies that the MT event loop starts/stops correctly,
## timers and yield work, and CPS procs run properly.
##
## NOTE: MT tests must be compiled with --mm:arc (not ORC)
## because ORC's cycle collector is not thread-safe.

import cps/mt
import cps/transform
import std/[monotimes, times]

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
  var counter = 0

  proc yieldTest(): CpsVoidFuture {.cps.} =
    counter = 1
    await cpsYield()
    counter = 2

  let fut = yieldTest()
  assert counter == 1, "Should have executed first part"
  runCps(fut)
  assert counter == 2, "Should have executed second part after yield"
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
  var log: seq[string]

  proc task1(): CpsVoidFuture {.cps.} =
    log.add "t1-start"
    await cpsSleep(30)
    log.add "t1-end"

  proc task2(): CpsVoidFuture {.cps.} =
    log.add "t2-start"
    await cpsSleep(10)
    log.add "t2-end"

  let f1 = task1()
  let f2 = task2()
  let combined = waitAll(f1, f2)
  runCps(combined)
  assert "t1-start" in log
  assert "t2-start" in log
  assert "t1-end" in log
  assert "t2-end" in log
  let t2EndIdx = log.find("t2-end")
  let t1EndIdx = log.find("t1-end")
  assert t2EndIdx < t1EndIdx, "t2 should finish before t1"
  echo "PASS: Concurrent CPS procs on MT event loop"

loop.shutdownMtRuntime()

echo ""
echo "All MT basic tests passed!"
