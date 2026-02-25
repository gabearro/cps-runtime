## CPS Runtime Benchmarks using Criterion
##
## Compare with bench_asyncdispatch.nim for std/asyncdispatch comparison.
##
## Run:
##   nim c -r -d:danger benchmarks/bench_cps.nim
##   nim c -r -d:danger benchmarks/bench_asyncdispatch.nim
##
## Export JSON for comparison:
##   nim c -r -d:danger benchmarks/bench_cps.nim --json:cps.json
##   nim c -r -d:danger benchmarks/bench_asyncdispatch.nim --json:asyncdispatch.json

import criterion
import cps/runtime
import cps/transform
import cps/eventloop

var cfg = newDefaultConfig()

# ============================================================
# CPS Procs (must be at module top level)
# ============================================================

proc noopCps(): CpsVoidFuture {.cps.} =
  discard

proc returnInt(x: int): CpsFuture[int] {.cps.} =
  return x

proc multiStep(): CpsFuture[int] {.cps.} =
  var a = 1
  var b = 2
  var c = a + b
  return c

proc awaitOne(): CpsFuture[int] {.cps.} =
  let val: int = await returnInt(42)
  return val

proc awaitChain5(): CpsFuture[int] {.cps.} =
  let a: int = await returnInt(1)
  let b: int = await returnInt(2)
  let c: int = await returnInt(3)
  let d: int = await returnInt(4)
  let e: int = await returnInt(5)
  return a + b + c + d + e

proc awaitChain10(): CpsFuture[int] {.cps.} =
  let a: int = await returnInt(1)
  let b: int = await returnInt(2)
  let c: int = await returnInt(3)
  let d: int = await returnInt(4)
  let e: int = await returnInt(5)
  let f: int = await returnInt(6)
  let g: int = await returnInt(7)
  let h: int = await returnInt(8)
  let i: int = await returnInt(9)
  let j: int = await returnInt(10)
  return a + b + c + d + e + f + g + h + i + j

# ============================================================
# Benchmarks
# ============================================================

benchmark cfg:
  proc benchNoopTask() {.measure.} =
    ## Void CPS task: create env + trampoline + complete
    let fut = noopCps()
    blackBox fut.finished()

  proc benchReturnInt() {.measure.} =
    ## Typed CPS task: create env + trampoline + complete with value
    let fut = returnInt(42)
    blackBox fut.read()

  proc benchMultiStep() {.measure.} =
    ## CPS task with 3 local vars (multiple env fields)
    let fut = multiStep()
    blackBox fut.read()

  proc benchFutureCreateComplete() {.measure.} =
    ## Raw CpsFuture: alloc + complete + read (no CPS proc)
    let fut = newCpsFuture[int]()
    complete(fut, 42)
    blackBox read(fut)

  proc benchFutureCreateCompleteLocal() {.measure.} =
    ## Raw local-fast CpsFuture: alloc + complete + read (single-owner path)
    let fut = newLocalCpsFuture[int]()
    complete(fut, 42)
    blackBox read(fut)

  proc benchVoidFutureCreateComplete() {.measure.} =
    ## Raw CpsVoidFuture: alloc + complete (no CPS proc)
    let fut = newCpsVoidFuture()
    complete(fut)
    blackBox fut.finished()

  proc benchVoidFutureCreateCompleteLocal() {.measure.} =
    ## Raw local-fast CpsVoidFuture: alloc + complete (single-owner path)
    let fut = newLocalCpsVoidFuture()
    complete(fut)
    blackBox fut.finished()

  proc benchFutureWithCallback() {.measure.} =
    ## Future + callback (shared-safe default): alloc + callback + complete.
    let fut = newCpsFuture[int]()
    var called = false
    addCallback(fut, proc() = called = true)
    complete(fut, 42)
    blackBox called

  proc benchFutureWithCallbackLocal() {.measure.} =
    ## Future + callback (local-fast): alloc + callback + complete.
    let fut = newLocalCpsFuture[int]()
    var called = false
    addCallback(fut, proc() = called = true)
    complete(fut, 42)
    blackBox called

  iterator callbackFanouts(): int =
    for n in [8, 64, 256]:
      yield n

  proc benchFutureCallbackFanout(n: int) {.measure: callbackFanouts.} =
    ## Shared-safe registration + completion with many callbacks on one future.
    let fut = newCpsVoidFuture()
    var fired = 0
    for _ in 0 ..< n:
      addCallback(fut, proc() = inc fired)
    complete(fut)
    blackBox fired

  proc benchFutureCallbackFanoutLocal(n: int) {.measure: callbackFanouts.} =
    ## Local-fast registration + completion with many callbacks on one future.
    let fut = newLocalCpsVoidFuture()
    var fired = 0
    for _ in 0 ..< n:
      addCallback(fut, proc() = inc fired)
    complete(fut)
    blackBox fired

  proc benchAwaitOne() {.measure.} =
    ## CPS task awaiting 1 pre-completed future
    let fut = awaitOne()
    blackBox fut.read()

  proc benchAwaitChain5() {.measure.} =
    ## CPS task with 5 sequential awaits of pre-completed futures
    let fut = awaitChain5()
    blackBox fut.read()

  proc benchAwaitChain10() {.measure.} =
    ## CPS task with 10 sequential awaits of pre-completed futures
    let fut = awaitChain10()
    blackBox fut.read()

  iterator taskCounts(): int =
    for n in [10, 100, 1000]:
      yield n

  proc benchNNoopTasks(n: int) {.measure: taskCounts.} =
    ## Sequential N noop tasks
    for i in 0 ..< n:
      let fut = noopCps()
      blackBox fut.finished()
