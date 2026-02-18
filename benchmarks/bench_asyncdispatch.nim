## std/asyncdispatch Benchmarks using Criterion
##
## Compare with bench_cps.nim for CPS runtime comparison.
##
## Run:
##   nim c -r -d:danger benchmarks/bench_asyncdispatch.nim
##   nim c -r -d:danger benchmarks/bench_cps.nim
##
## Both files benchmark equivalent operations so results are directly comparable.

import criterion
import std/asyncdispatch

var cfg = newDefaultConfig()

# ============================================================
# Async Procs
# ============================================================

proc noopAsync(): Future[void] {.async.} =
  discard

proc returnIntAsync(x: int): Future[int] {.async.} =
  return x

proc multiStepAsync(): Future[int] {.async.} =
  var a = 1
  var b = 2
  var c = a + b
  return c

proc awaitOneAsync(): Future[int] {.async.} =
  let val = await returnIntAsync(42)
  return val

proc awaitChain5Async(): Future[int] {.async.} =
  let a = await returnIntAsync(1)
  let b = await returnIntAsync(2)
  let c = await returnIntAsync(3)
  let d = await returnIntAsync(4)
  let e = await returnIntAsync(5)
  return a + b + c + d + e

proc awaitChain10Async(): Future[int] {.async.} =
  let a = await returnIntAsync(1)
  let b = await returnIntAsync(2)
  let c = await returnIntAsync(3)
  let d = await returnIntAsync(4)
  let e = await returnIntAsync(5)
  let f = await returnIntAsync(6)
  let g = await returnIntAsync(7)
  let h = await returnIntAsync(8)
  let i = await returnIntAsync(9)
  let j = await returnIntAsync(10)
  return a + b + c + d + e + f + g + h + i + j

# ============================================================
# Benchmarks
# ============================================================

benchmark cfg:
  proc benchNoopTask() {.measure.} =
    ## Void async task: create Future + complete
    waitFor noopAsync()

  proc benchReturnInt() {.measure.} =
    ## Typed async task: create Future + complete with value
    blackBox waitFor(returnIntAsync(42))

  proc benchMultiStep() {.measure.} =
    ## Async task with 3 local vars
    blackBox waitFor(multiStepAsync())

  proc benchFutureCreateComplete() {.measure.} =
    ## Raw Future: alloc + complete + read (no async proc)
    let fut = newFuture[int]("bench")
    fut.complete(42)
    blackBox fut.read()

  proc benchVoidFutureCreateComplete() {.measure.} =
    ## Raw Future[void]: alloc + complete (no async proc)
    let fut = newFuture[void]("bench")
    fut.complete()
    blackBox fut.finished

  proc benchFutureWithCallback() {.measure.} =
    ## Future + callback: alloc + register callback + complete (fires callback)
    let fut = newFuture[int]("bench")
    var called = false
    {.cast(gcsafe).}:
      fut.addCallback(proc() = called = true)
    fut.complete(42)
    blackBox called

  proc benchAwaitOne() {.measure.} =
    ## Async task awaiting 1 pre-completed future
    blackBox waitFor(awaitOneAsync())

  proc benchAwaitChain5() {.measure.} =
    ## Async task with 5 sequential awaits of pre-completed futures
    blackBox waitFor(awaitChain5Async())

  proc benchAwaitChain10() {.measure.} =
    ## Async task with 10 sequential awaits of pre-completed futures
    blackBox waitFor(awaitChain10Async())

  iterator taskCounts(): int =
    for n in [10, 100, 1000]:
      yield n

  proc benchNNoopTasks(n: int) {.measure: taskCounts.} =
    ## Sequential N noop tasks
    for i in 0 ..< n:
      waitFor noopAsync()
