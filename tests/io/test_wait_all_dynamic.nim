## Tests for dynamic waitAll(openArray ...) helpers.

import cps/runtime
import cps/eventloop
import cps/transform

block test_waitall_openarray_empty:
  let voidFuts: seq[CpsVoidFuture] = @[]
  let typedFuts: seq[CpsFuture[int]] = @[]
  let v = waitAll(voidFuts)
  let t = waitAll(typedFuts)
  assert v.finished, "empty void openArray should complete immediately"
  assert t.finished, "empty typed openArray should complete immediately"
  assert not v.hasError
  assert not t.hasError
  echo "PASS: waitAll openArray empty"

proc test_waitall_openarray_nil_entries(): CpsVoidFuture {.cps.} =
  let v1 = newCpsVoidFuture()
  v1.pinFutureRuntime()
  let allVoid = waitAll(@[CpsVoidFuture(nil), v1, CpsVoidFuture(nil)])
  assert not allVoid.finished
  v1.complete()
  await allVoid
  assert allVoid.finished

  let t1 = newCpsFuture[int]()
  t1.pinFutureRuntime()
  let allTyped = waitAll(@[CpsFuture[int](nil), t1, CpsFuture[int](nil)])
  assert not allTyped.finished
  t1.complete(1)
  await allTyped
  assert allTyped.finished

proc test_waitall_or_signal_timeout_and_stop(): CpsVoidFuture {.cps.} =
  let fTimeout = newCpsVoidFuture()
  fTimeout.pinFutureRuntime()
  let timeoutGate = waitAllOrTimeout(@[fTimeout], 1)
  await timeoutGate
  assert timeoutGate.finished
  assert not fTimeout.finished

  let fStop = newCpsVoidFuture()
  let stopSignal = newCpsVoidFuture()
  fStop.pinFutureRuntime()
  stopSignal.pinFutureRuntime()
  let stopGate = waitAllOrSignal(@[fStop], 5000, stopSignal)
  stopSignal.complete()
  await stopGate
  assert stopGate.finished
  assert not fStop.finished

  let preDoneStop = newCpsVoidFuture()
  preDoneStop.pinFutureRuntime()
  preDoneStop.complete()
  let immediateGate = waitAllOrSignal(@[fStop], 5000, preDoneStop)
  assert immediateGate.finished

proc test_sleep_or_signal_behavior(): CpsVoidFuture {.cps.} =
  let timeoutOnly = sleepOrSignal(1, nil)
  await timeoutOnly
  assert timeoutOnly.finished

  let stopSignal = newCpsVoidFuture()
  stopSignal.pinFutureRuntime()
  let interrupted = sleepOrSignal(5000, stopSignal)
  stopSignal.complete()
  await interrupted
  assert interrupted.finished

  let preDone = newCpsVoidFuture()
  preDone.pinFutureRuntime()
  preDone.complete()
  let immediate = sleepOrSignal(5000, preDone)
  assert immediate.finished

proc test_waitall_openarray_prefinished(): CpsVoidFuture {.cps.} =
  ## Regression: callbacks may fire inline during registration when inputs are already finished.
  let v1 = newCpsVoidFuture()
  let v2 = newCpsVoidFuture()
  let v3 = newCpsVoidFuture()
  v1.pinFutureRuntime()
  v2.pinFutureRuntime()
  v3.pinFutureRuntime()
  v1.complete()
  v2.cancel()
  v3.fail(newException(ValueError, "prefinished"))
  let allVoid = waitAll(@[v1, v2, v3])
  await allVoid
  assert allVoid.finished

  let t1 = newCpsFuture[int]()
  let t2 = newCpsFuture[int]()
  let t3 = newCpsFuture[int]()
  t1.pinFutureRuntime()
  t2.pinFutureRuntime()
  t3.pinFutureRuntime()
  t1.complete(7)
  t2.cancel()
  t3.fail(newException(ValueError, "prefinished-typed"))
  let allTyped = waitAll(@[t1, t2, t3])
  await allTyped
  assert allTyped.finished

proc test_waitall_openarray_void_mixed(): CpsVoidFuture {.cps.} =
  let f1 = newCpsVoidFuture()
  let f2 = newCpsVoidFuture()
  let f3 = newCpsVoidFuture()
  f1.pinFutureRuntime()
  f2.pinFutureRuntime()
  f3.pinFutureRuntime()

  let all = waitAll(@[f1, f2, f3])
  var completionCount = 0
  all.addCallback(proc() =
    completionCount += 1
  )

  f1.complete()
  f2.cancel()
  f3.fail(newException(ValueError, "boom"))

  await all
  assert completionCount == 1, "waitAll callback should fire exactly once"

  # Terminal-state repeats must stay no-op and never double-complete aggregate.
  f1.complete()
  f2.cancel()
  f3.cancel()
  await cpsYield()
  assert completionCount == 1

proc test_waitall_openarray_typed_mixed(): CpsVoidFuture {.cps.} =
  let f1 = newCpsFuture[int]()
  let f2 = newCpsFuture[int]()
  let f3 = newCpsFuture[int]()
  f1.pinFutureRuntime()
  f2.pinFutureRuntime()
  f3.pinFutureRuntime()

  var typedBatch: seq[CpsFuture[int]] = @[]
  typedBatch.add(f1)
  typedBatch.add(f2)
  typedBatch.add(f3)

  let all = waitAll(typedBatch)
  var completionCount = 0
  all.addCallback(proc() =
    completionCount += 1
  )

  f1.complete(1)
  f2.fail(newException(ValueError, "typed-fail"))
  f3.cancel()

  await all
  assert completionCount == 1, "typed waitAll callback should fire exactly once"

block test_waitall_openarray_void_mixed:
  runCps(test_waitall_openarray_void_mixed())
  echo "PASS: waitAll openArray void mixed terminal states"

block test_waitall_openarray_typed_mixed:
  runCps(test_waitall_openarray_typed_mixed())
  echo "PASS: waitAll openArray typed mixed terminal states"

block test_waitall_openarray_nil_entries:
  runCps(test_waitall_openarray_nil_entries())
  echo "PASS: waitAll openArray nil entries"

block test_waitall_or_signal_timeout_and_stop:
  runCps(test_waitall_or_signal_timeout_and_stop())
  echo "PASS: waitAllOrSignal timeout/stop behavior"

block test_sleep_or_signal_behavior:
  runCps(test_sleep_or_signal_behavior())
  echo "PASS: sleepOrSignal timeout/stop behavior"

block test_waitall_openarray_prefinished:
  runCps(test_waitall_openarray_prefinished())
  echo "PASS: waitAll openArray prefinished registration race"

echo "All dynamic waitAll tests passed!"
