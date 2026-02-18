## Tests for MT concurrent workloads
##
## Verifies mixed CPS + blocking tasks, tasks and allTasks on MT,
## and correct sequencing of async+blocking operations.
##
## NOTE: Must be compiled with --mm:arc (ORC is not thread-safe).

import cps/mt
import cps/transform
import std/[atomics, os]

let loop = initMtRuntime(numWorkers = 2)

# Test 1: Tasks (spawn/await) work on MT runtime
block testMtTasks:
  proc compute(x: int): CpsFuture[int] {.cps.} =
    await cpsYield()
    return x * x

  proc main(): CpsFuture[seq[int]] {.cps.} =
    var tasks: seq[Task[int]]
    tasks.add spawn compute(2)
    tasks.add spawn compute(3)
    tasks.add spawn compute(4)
    let results = await allTasks(tasks)
    return results

  let results = runCps(main())
  assert results.len == 3
  assert results[0] == 4, "Expected 4, got " & $results[0]
  assert results[1] == 9, "Expected 9, got " & $results[1]
  assert results[2] == 16, "Expected 16, got " & $results[2]
  echo "PASS: Tasks work on MT runtime"

# Test 2: Mixed async I/O + blocking operations
block testMtMixed:
  var log: seq[string]

  proc asyncWork(name: string, ms: int): CpsVoidFuture {.cps.} =
    log.add name & ":async-start"
    await cpsSleep(ms)
    log.add name & ":async-end"

  proc blockWork(name: string): CpsVoidFuture {.cps.} =
    log.add name & ":block-start"
    await spawnBlocking(proc() {.gcsafe.} =
      sleep(30)
    )
    log.add name & ":block-end"

  proc main(): CpsVoidFuture {.cps.} =
    let t1 = spawn asyncWork("A", 20)
    let t2 = spawn blockWork("B")
    await t1
    await t2

  log = @[]
  runCps(main())

  assert "A:async-start" in log
  assert "A:async-end" in log
  assert "B:block-start" in log
  assert "B:block-end" in log
  echo "PASS: Mixed async + blocking work"

# Test 3: Sequential blocking calls in a CPS proc
block testMtSequentialBlocking:
  proc sequentialWork(): CpsFuture[int] {.cps.} =
    let a = await spawnBlocking(proc(): int {.gcsafe.} =
      sleep(10)
      return 10
    )
    let b = await spawnBlocking(proc(): int {.gcsafe.} =
      sleep(10)
      return 20
    )
    let c = await spawnBlocking(proc(): int {.gcsafe.} =
      sleep(10)
      return 30
    )
    return a + b + c

  let val = runCps(sequentialWork())
  assert val == 60, "Expected 60, got " & $val
  echo "PASS: Sequential blocking calls"

# Test 4: allTasks with void tasks on MT
block testMtAllVoidTasks:
  var completedMask: Atomic[int]

  proc job(name: string): CpsVoidFuture {.cps.} =
    await cpsYield()
    let bit =
      case name
      of "x": 1
      of "y": 2
      of "z": 4
      else: 0
    if bit != 0:
      discard completedMask.fetchOr(bit, moAcquireRelease)

  proc main(): CpsVoidFuture {.cps.} =
    var tasks: seq[VoidTask]
    tasks.add spawn job("x")
    tasks.add spawn job("y")
    tasks.add spawn job("z")
    await allTasks(tasks)

  completedMask.store(0, moRelaxed)
  runCps(main())
  let mask = completedMask.load(moAcquire)
  assert mask == 0b111, "Expected x,y,z completion mask=7, got " & $mask
  echo "PASS: allTasks with void tasks on MT"

# Test 5: spawnBlocking + timer interleave
block testMtInterleave:
  var events: seq[string]

  proc blockAndLog(): CpsVoidFuture {.cps.} =
    events.add "block-start"
    await spawnBlocking(proc() {.gcsafe.} =
      sleep(50)
    )
    events.add "block-done"

  proc timerAndLog(): CpsVoidFuture {.cps.} =
    events.add "timer-start"
    await cpsSleep(10)
    events.add "timer-fired"

  proc main(): CpsVoidFuture {.cps.} =
    let t1 = spawn blockAndLog()
    let t2 = spawn timerAndLog()
    await t1
    await t2

  events = @[]
  runCps(main())

  assert "timer-start" in events
  assert "timer-fired" in events
  assert "block-start" in events
  assert "block-done" in events
  let timerFiredIdx = events.find("timer-fired")
  let blockDoneIdx = events.find("block-done")
  assert timerFiredIdx < blockDoneIdx, "Timer should fire before blocking completes: " & $events
  echo "PASS: spawnBlocking + timer interleave"

loop.shutdownMtRuntime()

echo ""
echo "All MT concurrent tests passed!"
