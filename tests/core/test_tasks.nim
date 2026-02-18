## Tests for CPS Task support
##
## Verifies spawn, await on tasks, allTasks, and fire-and-forget behavior.

import cps/runtime
import cps/eventloop
import cps/transform

# ============================================================
# Test 1: Spawn and await a single task
# ============================================================

block testSpawnAwait:
  proc makeValue(x: int): CpsFuture[int] {.cps.} =
    await cpsYield()
    return x * 10

  proc main(): CpsFuture[int] {.cps.} =
    let t = spawn makeValue(5)
    let res = await t
    return res

  let val = runCps(main())
  assert val == 50, "Expected 50, got " & $val
  echo "PASS: Spawn and await single task"

# ============================================================
# Test 2: Spawn multiple tasks concurrently
# ============================================================

block testConcurrentTasks:
  var order: seq[string]

  proc worker(name: string, delayMs: int): CpsVoidFuture {.cps.} =
    order.add name & ":start"
    await cpsSleep(delayMs)
    order.add name & ":end"

  proc main(): CpsVoidFuture {.cps.} =
    let t1 = spawn worker("A", 50)
    let t2 = spawn worker("B", 20)
    # Both tasks are running concurrently.
    # B has shorter delay so should finish first.
    await t1
    await t2

  order = @[]
  runCps(main())
  assert "A:start" in order
  assert "B:start" in order
  assert "A:end" in order
  assert "B:end" in order
  # Both started before either ended
  let aStartIdx = order.find("A:start")
  let bStartIdx = order.find("B:start")
  let aEndIdx = order.find("A:end")
  let bEndIdx = order.find("B:end")
  assert aStartIdx < aEndIdx
  assert bStartIdx < bEndIdx
  # B should finish before A since it has shorter delay
  assert bEndIdx < aEndIdx, "Expected B to finish before A, got: " & $order
  echo "PASS: Concurrent task execution"

# ============================================================
# Test 3: allTasks gathers results
# ============================================================

block testAllTasks:
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
  echo "PASS: allTasks gathers results"

# ============================================================
# Test 4: allTasks with void tasks
# ============================================================

block testAllVoidTasks:
  var completed: seq[string]

  proc job(name: string): CpsVoidFuture {.cps.} =
    await cpsYield()
    completed.add name

  proc main(): CpsVoidFuture {.cps.} =
    var tasks: seq[VoidTask]
    tasks.add spawn job("x")
    tasks.add spawn job("y")
    tasks.add spawn job("z")
    await allTasks(tasks)

  completed = @[]
  runCps(main())
  assert completed.len == 3
  assert "x" in completed
  assert "y" in completed
  assert "z" in completed
  echo "PASS: allTasks with void tasks"

# ============================================================
# Test 5: Fire-and-forget task runs on scheduler
# ============================================================

block testFireAndForget:
  var done = false

  proc background(): CpsVoidFuture {.cps.} =
    await cpsSleep(10)
    done = true

  proc main(): CpsVoidFuture {.cps.} =
    discard spawn background()
    # Don't await - the background task should still run
    await cpsSleep(50)  # Give it time to complete

  done = false
  runCps(main())
  assert done, "Fire-and-forget task should have completed"
  echo "PASS: Fire-and-forget task runs on scheduler"

# ============================================================
# Test 6: runCps works directly on Task
# ============================================================

block testRunCpsTask:
  proc compute(x: int): CpsFuture[int] {.cps.} =
    await cpsYield()
    return x + 100

  let t = spawn compute(42)
  let val = runCps(t)
  assert val == 142, "Expected 142, got " & $val
  echo "PASS: runCps works on Task"

echo ""
echo "All task tests passed!"
