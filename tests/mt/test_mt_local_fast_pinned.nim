## Tests for MT local-fast worker pinning behavior.
##
## Validates that local-fast callbacks fire on the owner worker even when
## completion is initiated from a foreign blocking thread.

when not defined(gcAtomicArc) and not defined(useMalloc):
  {.error: "test_mt_local_fast_pinned.nim requires --mm:atomicArc (recommended) or -d:useMalloc.".}

import cps/mt
import std/[atomics, monotimes, times, os]

let loop = initMtRuntime(numWorkers = 2)
let rt = currentRuntime().runtime

proc waitFlag(flag: var Atomic[int], timeoutMs: int): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if flag.load(moAcquire) != 0:
      return true
    sleep(1)
  result = flag.load(moAcquire) != 0

type
  ShutdownRuntimeArg = object
    rt: CpsRuntime
    started: ptr Atomic[int]
    done: ptr Atomic[int]

proc shutdownRuntimeThread(arg: ShutdownRuntimeArg) {.thread.} =
  arg.started[].store(1, moRelease)
  {.cast(gcsafe).}:
    shutdownMtRuntime(arg.rt)
  arg.done[].store(1, moRelease)

block testPinnedCompletionResumesOnOwnerWorker:
  var done: Atomic[int]
  var ownerId: Atomic[int]
  var resumedId: Atomic[int]
  done.store(0, moRelaxed)
  ownerId.store(-1, moRelaxed)
  resumedId.store(-1, moRelaxed)

  rt.callbackDispatcher(proc() =
    let owner = currentWorkerId
    ownerId.store(owner, moRelease)
    let localF = newLocalCpsVoidFuture()
    localF.addCallback(proc() =
      resumedId.store(currentWorkerId, moRelease)
      done.store(1, moRelease)
    )
    let other = if owner == 0: 1 else: 0
    doAssert rt.pinnedCallbackDispatcher != nil
    doAssert rt.pinnedCallbackDispatcher(other, proc() =
      complete(localF)
    )
  )

  assert waitFlag(done, 3000), "timed out waiting for pinned local callback"
  let owner = ownerId.load(moAcquire)
  let resumed = resumedId.load(moAcquire)
  assert owner >= 0, "owner worker id was not captured"
  assert resumed >= 0, "resume worker id was not captured"
  assert owner == resumed,
    "expected callback on owner worker, owner=" & $owner & " resumed=" & $resumed
  echo "PASS: local-fast callback resumes on owner worker"

block testPinnedAffinityStableAcrossIterations:
  const Rounds = 64
  for _ in 0 ..< Rounds:
    var done: Atomic[int]
    var ok: Atomic[int]
    var ownerStage: Atomic[int]
    var otherStage: Atomic[int]
    done.store(0, moRelaxed)
    ok.store(0, moRelaxed)
    ownerStage.store(0, moRelaxed)
    otherStage.store(0, moRelaxed)

    rt.callbackDispatcher(proc() =
      ownerStage.store(1, moRelease)
      let owner = currentWorkerId
      let localF = newLocalCpsVoidFuture()
      localF.addCallback(proc() =
        if currentWorkerId == owner:
          ok.store(1, moRelease)
        done.store(1, moRelease)
      )
      let other = if owner == 0: 1 else: 0
      doAssert rt.pinnedCallbackDispatcher != nil
      doAssert rt.pinnedCallbackDispatcher(other, proc() =
        otherStage.store(1, moRelease)
        complete(localF)
      )
    )

    if not waitFlag(done, 3000):
      raise newException(AssertionDefect,
        "timed out waiting for pinned local callback round" &
        " ownerStage=" & $ownerStage.load(moAcquire) &
        " otherStage=" & $otherStage.load(moAcquire) &
        " ok=" & $ok.load(moAcquire))
    assert ok.load(moAcquire) == 1, "callback ran on non-owner worker"
  echo "PASS: local-fast worker affinity stable under repeated pinned completions"

block testWorkerRunCpsPromotesLocalFastToShared:
  var done: Atomic[int]
  var promoted: Atomic[int]
  done.store(0, moRelaxed)
  promoted.store(0, moRelaxed)

  rt.callbackDispatcher(proc() =
    let owner = currentWorkerId
    let other = if owner == 0: 1 else: 0
    let localF = newLocalCpsVoidFuture()
    doAssert rt.pinnedCallbackDispatcher != nil
    doAssert rt.pinnedCallbackDispatcher(other, proc() =
      sleep(5)
      complete(localF)
    )
    runCps(localF)
    if localF.isSharedSafe():
      promoted.store(1, moRelease)
    done.store(1, moRelease)
  )

  assert waitFlag(done, 3000), "timed out waiting for worker runCps local-fast completion"
  assert promoted.load(moAcquire) == 1,
    "worker runCps did not promote local-fast future to shared-safe"
  echo "PASS: worker runCps promotes local-fast future to shared-safe"

block testPinnedSingleSubmissionWakeStress:
  ## Stress a single pinned submission from a non-worker thread while the owner
  ## worker is likely idle/parked. This catches lost-wake races in park logic.
  const Rounds = 512
  doAssert rt.pinnedCallbackDispatcher != nil
  for round in 0 ..< Rounds:
    var ready: Atomic[int]
    var done: Atomic[int]
    var ownerId: Atomic[int]
    var resumedId: Atomic[int]
    ready.store(0, moRelaxed)
    done.store(0, moRelaxed)
    ownerId.store(-1, moRelaxed)
    resumedId.store(-1, moRelaxed)
    var localF: CpsVoidFuture = nil

    rt.callbackDispatcher(proc() =
      let owner = currentWorkerId
      ownerId.store(owner, moRelease)
      localF = newLocalCpsVoidFuture()
      localF.addCallback(proc() =
        resumedId.store(currentWorkerId, moRelease)
        done.store(1, moRelease)
      )
      ready.store(1, moRelease)
    )

    if not waitFlag(ready, 3000):
      raise newException(AssertionDefect,
        "timed out waiting for setup round=" & $round &
        " owner=" & $ownerId.load(moAcquire))

    let owner = ownerId.load(moAcquire)
    if owner < 0 or localF == nil:
      raise newException(AssertionDefect,
        "invalid setup state round=" & $round &
        " owner=" & $owner &
        " localF.nil=" & $(localF == nil))

    # Let the worker finish setup and likely park before external pinned submit.
    sleep(1)
    let submitted = rt.pinnedCallbackDispatcher(owner, proc() =
      complete(localF)
    )
    if not submitted:
      raise newException(AssertionDefect,
        "failed pinned submit round=" & $round & " owner=" & $owner)

    if not waitFlag(done, 3000):
      raise newException(AssertionDefect,
        "timed out waiting for pinned completion round=" & $round &
        " owner=" & $owner &
        " resumed=" & $resumedId.load(moAcquire))
  echo "PASS: pinned single-submit stress while owner worker is idle"

block testCrossRuntimeBindPromotesAndCompletes:
  let otherRt = newMultiThreadRuntime(numWorkers = 1)
  defer:
    shutdownMtRuntime(otherRt)

  var done: Atomic[int]
  var promoted: Atomic[int]
  var sawException: Atomic[int]
  done.store(0, moRelaxed)
  promoted.store(0, moRelaxed)
  sawException.store(0, moRelaxed)

  rt.callbackDispatcher(proc() =
    let localF = newLocalCpsVoidFuture()
    localF.bindFutureRuntime(toHandle(otherRt))
    if localF.isSharedSafe():
      promoted.store(1, moRelease)
    localF.addCallback(proc() =
      done.store(1, moRelease)
    )
    doAssert otherRt.callbackDispatcher != nil
    otherRt.callbackDispatcher(proc() =
      try:
        complete(localF)
      except Exception:
        sawException.store(1, moRelease)
    )
  )

  assert waitFlag(done, 3000), "timed out waiting for cross-runtime completion"
  assert promoted.load(moAcquire) == 1, "cross-runtime bind did not promote to shared-safe"
  assert sawException.load(moAcquire) == 0, "cross-runtime completion unexpectedly raised"
  echo "PASS: cross-runtime bind promotes local-fast future before completion"

block testPinnedSubmissionRejectedAfterShutdownStarts:
  let tempRt = newMultiThreadRuntime(numWorkers = 1)
  doAssert tempRt.callbackDispatcher != nil
  doAssert tempRt.pinnedCallbackDispatcher != nil

  var workerEntered: Atomic[int]
  var shutdownStarted: Atomic[int]
  var shutdownDone: Atomic[int]
  workerEntered.store(0, moRelaxed)
  shutdownStarted.store(0, moRelaxed)
  shutdownDone.store(0, moRelaxed)

  tempRt.callbackDispatcher(proc() =
    workerEntered.store(1, moRelease)
    sleep(250)
  )
  assert waitFlag(workerEntered, 1000), "worker did not enter blocking callback"

  var shutdownThread: Thread[ShutdownRuntimeArg]
  createThread(shutdownThread, shutdownRuntimeThread,
    ShutdownRuntimeArg(rt: tempRt, started: addr shutdownStarted, done: addr shutdownDone))
  assert waitFlag(shutdownStarted, 1000), "shutdown thread did not start"

  var sawReject = false
  var acceptedAfterReject = 0
  let deadline = getMonoTime() + initDuration(milliseconds = 2000)
  while shutdownDone.load(moAcquire) == 0 and getMonoTime() < deadline:
    let accepted = tempRt.pinnedCallbackDispatcher(0, proc() = discard)
    if not accepted:
      sawReject = true
    elif sawReject:
      inc acceptedAfterReject
    sleep(1)

  joinThread(shutdownThread)
  assert sawReject, "expected pinned submissions to be rejected once shutdown started"
  assert acceptedAfterReject == 0,
    "pinned submissions were accepted after rejection during shutdown"
  echo "PASS: pinned submissions reject after shutdown starts"

loop.shutdownMtRuntime()
echo ""
echo "All MT local-fast pinning tests passed!"
