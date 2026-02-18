## Tests for spawnBlocking
##
## Verifies blocking work is offloaded to worker threads,
## results are returned correctly, and errors propagate.

import cps/mt
import cps/transform
import std/[os, monotimes, times, strutils]

let loop = initMtRuntime(numWorkers = 4)

# Test 1: spawnBlocking with typed result
block testSpawnBlockingTyped:
  proc compute(): CpsFuture[int] {.cps.} =
    let res = await spawnBlocking(proc(): int {.gcsafe.} =
      var sum = 0
      for i in 0 ..< 1000:
        sum += i
      return sum
    )
    return res

  let val = runCps(compute())
  assert val == 499500, "Expected 499500, got " & $val
  echo "PASS: spawnBlocking with typed result"

# Test 2: spawnBlocking with void
block testSpawnBlockingVoid:
  var done = false

  proc doBlocking(): CpsVoidFuture {.cps.} =
    await spawnBlocking(proc() {.gcsafe.} =
      sleep(10)
    )
    done = true

  runCps(doBlocking())
  assert done, "Should have completed"
  echo "PASS: spawnBlocking void"

# Test 3: spawnBlocking error propagation
block testSpawnBlockingError:
  proc failingWork(): CpsFuture[int] {.cps.} =
    let res = await spawnBlocking(proc(): int {.gcsafe.} =
      raise newException(ValueError, "worker error")
    )
    return res

  # Check error on the future directly, driving the event loop manually
  let fut = failingWork()
  while not fut.finished:
    loop.tick()
  assert fut.finished, "Future should be finished"
  assert fut.hasError(), "Future should have error"
  assert fut.getError().msg.find("worker error") >= 0,
    "Expected 'worker error' in message, got: " & fut.getError().msg
  echo "PASS: spawnBlocking error propagation"

# Test 4: spawnBlocking doesn't block the event loop
block testSpawnBlockingNonBlocking:
  var timerFired = false
  var blockingDone = false

  proc timerTask(): CpsVoidFuture {.cps.} =
    await cpsSleep(20)
    timerFired = true

  proc blockingTask(): CpsVoidFuture {.cps.} =
    await spawnBlocking(proc() {.gcsafe.} =
      sleep(100)
    )
    blockingDone = true

  let f1 = blockingTask()
  let f2 = timerTask()
  let combined = waitAll(f1, f2)
  let start = getMonoTime()
  runCps(combined)
  let elapsed = (getMonoTime() - start).inMilliseconds

  assert timerFired, "Timer should have fired while blocking work ran"
  assert blockingDone, "Blocking work should have completed"
  assert elapsed < 150, "Expected under 150ms, got " & $elapsed & "ms"
  echo "PASS: spawnBlocking doesn't block the event loop"

# Test 5: Multiple spawnBlocking run in parallel
block testSpawnBlockingParallel:
  proc blockingOne(): CpsFuture[int] {.cps.} =
    let r = await spawnBlocking(proc(): int {.gcsafe.} =
      sleep(50)
      return 1
    )
    return r

  proc blockingTwo(): CpsFuture[int] {.cps.} =
    let r = await spawnBlocking(proc(): int {.gcsafe.} =
      sleep(50)
      return 2
    )
    return r

  proc blockingThree(): CpsFuture[int] {.cps.} =
    let r = await spawnBlocking(proc(): int {.gcsafe.} =
      sleep(50)
      return 3
    )
    return r

  proc parallelWork(): CpsFuture[int] {.cps.} =
    let t1 = spawn blockingOne()
    let t2 = spawn blockingTwo()
    let t3 = spawn blockingThree()
    let r1 = await t1
    let r2 = await t2
    let r3 = await t3
    return r1 + r2 + r3

  let start = getMonoTime()
  let val = runCps(parallelWork())
  let elapsed = (getMonoTime() - start).inMilliseconds

  assert val == 6, "Expected 6, got " & $val
  assert elapsed < 150, "Expected under 150ms (parallel), got " & $elapsed & "ms"
  echo "PASS: Multiple spawnBlocking run in parallel"

loop.shutdownMtRuntime()

echo ""
echo "All MT blocking tests passed!"
