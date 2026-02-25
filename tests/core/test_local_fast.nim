## Local-fast future tests
##
## Validates local-fast callback behavior, promotion to shared-safe mode,
## and CPS macro constructor mode selection.

import cps/runtime
import cps/eventloop
import cps/transform
import std/atomics

when defined(gcAtomicArc) or defined(useMalloc):
  type
    ForeignCompleteArg = object
      fut: CpsVoidFuture
      sawException: ptr Atomic[int]

  proc completeFromForeignThread(arg: ForeignCompleteArg) {.thread.} =
    {.cast(gcsafe).}:
      try:
        complete(arg.fut)
      except Exception:
        arg.sawException[].store(1, moRelease)

block testLocalFastBasic:
  var called = false
  let fut = newLocalCpsFuture[int]()
  fut.addCallback(proc() = called = true)
  complete(fut, 42)
  assert called
  when defined(cpsSharedFuturesOnly):
    assert fut.isSharedSafe()
  else:
    assert fut.isLocalFast()
  assert fut.read() == 42
  echo "PASS: local-fast addCallback + complete"

block testCompleteThenAdd:
  let fut = newLocalCpsFuture[int]()
  complete(fut, 1)
  var called = false
  fut.addCallback(proc() = called = true)
  assert called
  assert fut.read() == 1
  echo "PASS: local-fast complete then addCallback"

block testFailAndCancel:
  let failed = newLocalCpsVoidFuture()
  var failCb = false
  failed.addCallback(proc() = failCb = true)
  fail(failed, newException(CatchableError, "boom"))
  assert failCb
  assert failed.hasError()

  let cancelled = newLocalCpsVoidFuture()
  var cancelCb = false
  cancelled.addCallback(proc() = cancelCb = true)
  cancel(cancelled)
  assert cancelCb
  assert cancelled.isCancelled()
  echo "PASS: local-fast fail/cancel callback fire"

block testPromotionToShared:
  let fut = newLocalCpsFuture[int]()
  var callbacks = 0
  fut.addCallback(proc() = inc callbacks)
  ensureShared(fut)
  assert fut.isSharedSafe()
  complete(fut, 7)
  assert callbacks == 1
  assert fut.read() == 7
  echo "PASS: ensureShared preserves pending callback semantics"

block testPromotionFromTerminalState:
  let doneFut = newLocalCpsFuture[int]()
  complete(doneFut, 11)
  ensureShared(doneFut)
  assert doneFut.isSharedSafe()
  var doneCb = false
  doneFut.addCallback(proc() = doneCb = true)
  assert doneCb
  assert doneFut.read() == 11

  let cancelled = newLocalCpsVoidFuture()
  cancel(cancelled)
  ensureShared(cancelled)
  assert cancelled.isSharedSafe()
  var cancelCb = false
  cancelled.addCallback(proc() = cancelCb = true)
  assert cancelCb
  assert cancelled.isCancelled()
  echo "PASS: ensureShared preserves terminal-state behavior"

when defined(gcAtomicArc) or defined(useMalloc):
  block testCrossRuntimeBindPromotesToShared:
    let fut = newLocalCpsVoidFuture()
    let otherRt = newCurrentThreadRuntime()
    fut.bindFutureRuntime(toHandle(otherRt))
    assert fut.isSharedSafe()

    var sawException: Atomic[int]
    sawException.store(0, moRelaxed)
    var worker: Thread[ForeignCompleteArg]
    createThread(worker, completeFromForeignThread,
      ForeignCompleteArg(fut: fut, sawException: addr sawException))
    joinThread(worker)

    assert sawException.load(moAcquire) == 0
    assert fut.finished()
    echo "PASS: cross-runtime bind promotes local-fast future to shared-safe"

  block testCpsDefaultWrapperStaysSharedAcrossForeignCompletion:
    proc awaitExternal(f: CpsVoidFuture): CpsVoidFuture {.cps.} =
      await f

    let sourceFut = newCpsVoidFuture()
    let wrapped = awaitExternal(sourceFut)
    assert wrapped.isSharedSafe()

    var sawException: Atomic[int]
    sawException.store(0, moRelaxed)
    var worker: Thread[ForeignCompleteArg]
    createThread(worker, completeFromForeignThread,
      ForeignCompleteArg(fut: sourceFut, sawException: addr sawException))
    joinThread(worker)

    assert sawException.load(moAcquire) == 0
    assert wrapped.finished()
    runCps(wrapped)
    echo "PASS: default CPS wrapper remains shared-safe under foreign completion"
else:
  echo "SKIP: cross-runtime bind promotion test requires --mm:atomicArc or -d:useMalloc"

when not defined(cpsSharedFuturesOnly):
  type
    LocalAffinityArg = object
      fut: CpsVoidFuture
      sawException: ptr Atomic[int]
      op: int

  proc localAffinityThread(arg: LocalAffinityArg) {.thread.} =
    {.cast(gcsafe).}:
      try:
        if arg.op == 0:
          arg.fut.addCallback(proc() = discard)
        else:
          complete(arg.fut)
      except Exception:
        arg.sawException[].store(1, moRelease)

  block testLocalAffinityEnforcement:
    var sawAdd, sawComplete: Atomic[int]
    sawAdd.store(0, moRelaxed)
    sawComplete.store(0, moRelaxed)

    let futAdd = newLocalCpsVoidFuture()
    let futComplete = newLocalCpsVoidFuture()

    var addThread: Thread[LocalAffinityArg]
    var completeThread: Thread[LocalAffinityArg]
    createThread(addThread, localAffinityThread,
      LocalAffinityArg(fut: futAdd, sawException: addr sawAdd, op: 0))
    createThread(completeThread, localAffinityThread,
      LocalAffinityArg(fut: futComplete, sawException: addr sawComplete, op: 1))

    joinThread(addThread)
    joinThread(completeThread)

    assert sawAdd.load(moAcquire) == 1
    assert sawComplete.load(moAcquire) == 1
    assert not futAdd.finished()
    assert not futComplete.finished()
    echo "PASS: local-fast affinity violation traps on foreign thread"

block testMacroDefaultAndPragma:
  proc leafDefault(): CpsFuture[int] {.cps.} =
    return 3

  proc awaitDefault(): CpsFuture[int] {.cps.} =
    let v = await leafDefault()
    return v + 1

  proc awaitLocal(): CpsFuture[int] {.cps, cpsFutureMode: local.} =
    let v = await leafDefault()
    return v + 2

  proc awaitShared(): CpsFuture[int] {.cps, cpsFutureMode: shared.} =
    let v = await leafDefault()
    return v + 3

  let defaultFut = awaitDefault()
  let localFut = awaitLocal()
  let sharedFut = awaitShared()

  assert defaultFut.isSharedSafe()
  when defined(cpsSharedFuturesOnly):
    assert localFut.isSharedSafe()
  else:
    assert localFut.isLocalFast()
  assert sharedFut.isSharedSafe()
  assert runCps(defaultFut) == 4
  assert runCps(localFut) == 5
  assert runCps(sharedFut) == 6
  echo "PASS: CPS macro shared default + pragma overrides"

echo "All local-fast core tests passed!"
