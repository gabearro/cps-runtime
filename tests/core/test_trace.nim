## Tests for CPS task naming and tracing/observability features.
##
## Compile with tracing:    nim c -r -d:cpsTrace tests/test_trace.nim
## Compile without tracing: nim c -r tests/test_trace.nim

import cps/eventloop
import cps/transform

# ============================================================
# Test 1: Task with name
# ============================================================

block testTaskWithName:
  proc doWork(): CpsVoidFuture {.cps.} =
    await cpsYield()

  let t = spawn(doWork(), "myTask")
  assert t.name == "myTask", "Expected name 'myTask', got '" & t.name & "'"
  runCps(t)
  echo "PASS: Task with name"

# ============================================================
# Test 2: Task without name (default empty string)
# ============================================================

block testTaskWithoutName:
  proc doWork(): CpsVoidFuture {.cps.} =
    await cpsYield()

  let t = spawn(doWork())
  assert t.name == "", "Expected empty name, got '" & t.name & "'"
  runCps(t)
  echo "PASS: Task without name defaults to empty string"

# ============================================================
# Test 3: Named Task[T] (typed task with return value)
# ============================================================

block testNamedTypedTask:
  proc compute(x: int): CpsFuture[int] {.cps.} =
    await cpsYield()
    return x * 2

  let t = spawn(compute(21), "doubler")
  assert t.name == "doubler", "Expected name 'doubler', got '" & t.name & "'"
  let val = runCps(t)
  assert val == 42, "Expected 42, got " & $val
  echo "PASS: Named typed task"

# ============================================================
# Test 4: Multiple tasks with different names
# ============================================================

block testMultipleNamedTasks:
  proc worker(id: int): CpsVoidFuture {.cps.} =
    await cpsYield()

  let t1 = spawn(worker(1), "worker-1")
  let t2 = spawn(worker(2), "worker-2")
  let t3 = spawn(worker(3))  # unnamed

  assert t1.name == "worker-1"
  assert t2.name == "worker-2"
  assert t3.name == ""

  runCps(t1)
  runCps(t2)
  runCps(t3)
  echo "PASS: Multiple tasks with different names"

# ============================================================
# Tests 5-7: Event loop stats (only with -d:cpsTrace)
# ============================================================

when defined(cpsTrace):
  import cps/trace

  # Test 5: Event loop stats show nonzero tickCount after work
  block testLoopStatsTickCount:
    let loop = getEventLoop()
    loop.resetStats()

    proc doSomeWork(): CpsVoidFuture {.cps.} =
      await cpsYield()
      await cpsYield()

    runCps(doSomeWork())

    let stats = loop.getStats()
    assert stats.tickCount > 0, "Expected nonzero tickCount, got " & $stats.tickCount
    echo "PASS: Event loop stats - nonzero tickCount: " & $stats.tickCount

  # Test 6: Callbacks are counted
  block testLoopStatsCallbacks:
    let loop = getEventLoop()
    loop.resetStats()

    proc yieldTwice(): CpsVoidFuture {.cps.} =
      await cpsYield()
      await cpsYield()

    runCps(yieldTwice())

    let stats = loop.getStats()
    # cpsYield schedules a callback on the ready queue, so at least 2
    assert stats.totalCallbacksRun >= 2, "Expected >= 2 callbacks, got " & $stats.totalCallbacksRun
    echo "PASS: Event loop stats - callbacks counted: " & $stats.totalCallbacksRun

  # Test 7: Timers are counted
  block testLoopStatsTimers:
    let loop = getEventLoop()
    loop.resetStats()

    proc sleepBriefly(): CpsVoidFuture {.cps.} =
      await cpsSleep(10)

    runCps(sleepBriefly())

    let stats = loop.getStats()
    assert stats.totalTimersFired >= 1, "Expected >= 1 timer fired, got " & $stats.totalTimersFired
    echo "PASS: Event loop stats - timers counted: " & $stats.totalTimersFired

  # Test 8: Stats reset works
  block testLoopStatsReset:
    let loop = getEventLoop()

    # Do some work first to get nonzero stats
    proc doWork(): CpsVoidFuture {.cps.} =
      await cpsYield()

    runCps(doWork())
    let before = loop.getStats()
    assert before.tickCount > 0

    # Reset and verify
    loop.resetStats()
    let after = loop.getStats()
    assert after.tickCount == 0, "Expected 0 tickCount after reset, got " & $after.tickCount
    assert after.totalCallbacksRun == 0, "Expected 0 callbacks after reset"
    assert after.totalTimersFired == 0, "Expected 0 timers after reset"
    assert after.totalIoEvents == 0, "Expected 0 io events after reset"
    assert after.maxTickDurationUs == 0, "Expected 0 maxTickDuration after reset"
    assert after.lastTickDurationUs == 0, "Expected 0 lastTickDuration after reset"
    echo "PASS: Event loop stats reset"

  # Test 9: Trace module activeTaskCount
  block testTraceActiveTaskCount:
    assert activeTaskCount() == 0, "Expected 0 active tasks initially"
    incTaskCount()
    incTaskCount()
    assert activeTaskCount() == 2, "Expected 2 active tasks"
    decTaskCount()
    assert activeTaskCount() == 1, "Expected 1 active task"
    decTaskCount()
    assert activeTaskCount() == 0, "Expected 0 active tasks after decrement"
    echo "PASS: Trace module activeTaskCount"

else:
  echo "PASS: Compiles without -d:cpsTrace (no stats tests, tracing disabled)"

echo ""
echo "All trace tests passed!"
