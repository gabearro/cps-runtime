## Tests for CPS event loop

import cps/runtime
import cps/transform
import cps/eventloop
import std/[monotimes, times]

# Test 1: cpsSleep
block testCpsSleep:
  proc sleepTest(): CpsVoidFuture {.cps.} =
    await cpsSleep(50)

  let start = getMonoTime()
  let fut = sleepTest()
  runCps(fut)
  let elapsed = (getMonoTime() - start).inMilliseconds
  assert elapsed >= 40, "Sleep should take at least 40ms, took " & $elapsed & "ms"
  echo "PASS: cpsSleep"

# Test 2: cpsYield
block testCpsYield:
  var counter = 0

  proc yieldTest(): CpsVoidFuture {.cps.} =
    counter = 1
    await cpsYield()
    counter = 2

  let fut = yieldTest()
  assert counter == 1, "Should have executed first part"
  runCps(fut)
  assert counter == 2, "Should have executed second part after yield"
  echo "PASS: cpsYield"

# Test 3: Multiple concurrent CPS procs
block testConcurrent:
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
  # t2 should finish before t1 since it has shorter sleep
  let t2EndIdx = log.find("t2-end")
  let t1EndIdx = log.find("t1-end")
  assert t2EndIdx < t1EndIdx, "t2 should finish before t1"
  echo "PASS: Concurrent CPS procs"

# Test 4: Chained awaits with values
block testChainedAwaits:
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
  echo "PASS: Chained awaits with values"

echo "All event loop tests passed!"
