## Stress tests for lock-free data structures
##
## Tests MPSC queue, Chase-Lev deque, and lock-free futures
## under concurrent load. Must be compiled with --mm:atomicArc.

when not defined(gcAtomicArc) and not defined(useMalloc):
  {.error: "test_lockfree.nim requires --mm:atomicArc (recommended) or -d:useMalloc for thread-safe ref counting.".}

import std/[atomics, os]
import cps/private/mpsc_queue
import cps/private/chase_lev
import cps/runtime
import cps/eventloop

# ============================================================
# MPSC Queue: 4 producers × 10000 items, 1 consumer
# ============================================================

const MpscProducerCount = 4
const MpscItemsPerProducer = 10000

var gMpscQ: MpscQueue
var mpscTotalReceived: Atomic[int]

proc mpscProducer(args: (ptr MpscQueue, int)) {.thread.} =
  let q = args[0]
  for i in 0 ..< MpscItemsPerProducer:
    let node = allocNode(proc() {.closure, gcsafe.} = discard)
    enqueue(q[], node)

proc testMpscQueue() =
  echo "Testing MPSC queue..."
  initMpscQueue(gMpscQ)
  mpscTotalReceived.store(0, moRelaxed)

  var threads: array[MpscProducerCount, Thread[(ptr MpscQueue, int)]]
  for i in 0 ..< MpscProducerCount:
    createThread(threads[i], mpscProducer, (addr gMpscQ, i))

  # Consumer: drain until we've received all items
  let expected = MpscProducerCount * MpscItemsPerProducer
  var received = 0
  var spinCount = 0
  while received < expected:
    let node = dequeue(gMpscQ)
    if node != nil:
      freeNode(node)
      inc received
      spinCount = 0
    else:
      inc spinCount
      if spinCount > 1000:
        sleep(0)  # yield to OS
        spinCount = 0

  for i in 0 ..< MpscProducerCount:
    joinThread(threads[i])

  assert received == expected, "MPSC: expected " & $expected & " items, got " & $received
  echo "PASS: MPSC queue - " & $expected & " items from " & $MpscProducerCount & " producers"

# ============================================================
# Chase-Lev Deque: 1 owner + 3 thieves, 50000 items
# ============================================================

const ChaseLevTotalItems = 50000
const ChaseLevThieves = 3

var clDeque: ChaseLevDeque[int]
var clStolen: array[ChaseLevThieves, Atomic[int]]
var clOwnerDone: Atomic[bool]

proc chaseLevThief(args: (ptr ChaseLevDeque[int], int)) {.thread.} =
  let d = args[0]
  let thiefIdx = args[1]
  var count = 0
  while true:
    let item = steal(d[])
    if item != 0:  # 0 = default(int) = empty
      inc count
    elif clOwnerDone.load(moAcquire):
      # Owner is done, try a few more steals
      var extraCount = 0
      for retry in 0 ..< 100:
        let extra = steal(d[])
        if extra != 0:
          inc count
          inc extraCount
      break
    else:
      # Spin
      discard
  clStolen[thiefIdx].store(count, moRelease)

proc testChaseLevDeque() =
  echo "Testing Chase-Lev deque..."
  initChaseLevDeque(clDeque)
  clOwnerDone.store(false, moRelaxed)
  for i in 0 ..< ChaseLevThieves:
    clStolen[i].store(0, moRelaxed)

  var thieves: array[ChaseLevThieves, Thread[(ptr ChaseLevDeque[int], int)]]
  for i in 0 ..< ChaseLevThieves:
    createThread(thieves[i], chaseLevThief, (addr clDeque, i))

  # Owner: push items in batches, popping locally to keep deque within capacity
  var ownerPopped = 0
  const batchSize = 4096
  var pushed = 0
  for i in 1 .. ChaseLevTotalItems:  # Use 1-based to distinguish from default(0)
    push(clDeque, i)
    inc pushed
    # When batch is full, drain the local deque before pushing more
    if pushed mod batchSize == 0:
      while true:
        let v = pop(clDeque)
        if v == 0:
          break
        inc ownerPopped
    # Occasionally pop locally to exercise pop/steal races
    elif i mod 7 == 0:
      let v = pop(clDeque)
      if v != 0:
        inc ownerPopped

  # Pop remaining items from local deque
  while true:
    let v = pop(clDeque)
    if v == 0:
      break
    inc ownerPopped

  clOwnerDone.store(true, moRelease)

  for i in 0 ..< ChaseLevThieves:
    joinThread(thieves[i])

  var totalStolen = 0
  for i in 0 ..< ChaseLevThieves:
    totalStolen += clStolen[i].load(moAcquire)

  let totalConsumed = ownerPopped + totalStolen
  assert totalConsumed == ChaseLevTotalItems,
    "Chase-Lev: expected " & $ChaseLevTotalItems & " items, got " & $totalConsumed &
    " (owner=" & $ownerPopped & ", stolen=" & $totalStolen & ")"

  destroyChaseLevDeque(clDeque)
  echo "PASS: Chase-Lev deque - " & $ChaseLevTotalItems & " items (owner=" &
    $ownerPopped & ", stolen=" & $totalStolen & ")"

# ============================================================
# Lock-free futures: racing addCallback vs complete
# ============================================================

const FutureTestCount = 100
const FutureCallbackThreads = 4

var futCallbacksFired: Atomic[int]

type
  FutureTestArg = object
    futures: ptr UncheckedArray[CpsVoidFuture]
    count: int

proc futureCallbackAdder(arg: FutureTestArg) {.thread.} =
  ## Add callbacks to all futures. Some may already be completed.
  {.cast(gcsafe).}:
    for i in 0 ..< arg.count:
      let fut = arg.futures[i]
      fut.addCallback(proc() =
        discard futCallbacksFired.fetchAdd(1, moRelaxed)
      )

proc futureCompleter(arg: FutureTestArg) {.thread.} =
  ## Complete all even-indexed futures from this thread.
  {.cast(gcsafe).}:
    for i in countup(0, arg.count - 1, 2):
      let fut = arg.futures[i]
      complete(fut)

proc futureCompleter2(arg: FutureTestArg) {.thread.} =
  ## Complete all odd-indexed futures from this thread.
  {.cast(gcsafe).}:
    for i in countup(1, arg.count - 1, 2):
      let fut = arg.futures[i]
      complete(fut)

proc testLockFreeFutures() =
  echo "Testing lock-free futures..."
  futCallbacksFired.store(0, moRelaxed)

  # Create futures
  var futures = newSeq[CpsVoidFuture](FutureTestCount)
  for i in 0 ..< FutureTestCount:
    futures[i] = newCpsVoidFuture()

  let buf = cast[ptr UncheckedArray[CpsVoidFuture]](addr futures[0])
  let arg = FutureTestArg(futures: buf, count: FutureTestCount)

  # Launch callback adder threads
  var adders: array[FutureCallbackThreads, Thread[FutureTestArg]]
  for i in 0 ..< FutureCallbackThreads:
    createThread(adders[i], futureCallbackAdder, arg)

  # Launch completers (split evens/odds across two threads)
  var comp1: Thread[FutureTestArg]
  var comp2: Thread[FutureTestArg]
  createThread(comp1, futureCompleter, arg)
  createThread(comp2, futureCompleter2, arg)

  # Wait for all threads
  for i in 0 ..< FutureCallbackThreads:
    joinThread(adders[i])
  joinThread(comp1)
  joinThread(comp2)

  # Verify: each future should have exactly FutureCallbackThreads callbacks fired
  let expectedCallbacks = FutureTestCount * FutureCallbackThreads
  let actualCallbacks = futCallbacksFired.load(moAcquire)
  assert actualCallbacks == expectedCallbacks,
    "Futures: expected " & $expectedCallbacks & " callbacks, got " & $actualCallbacks
  echo "PASS: Lock-free futures - " & $FutureTestCount & " futures × " &
    $FutureCallbackThreads & " callback threads = " & $actualCallbacks & " callbacks"

# ============================================================
# Lock-free futures: typed CpsFuture[int]
# ============================================================

proc testTypedFutures() =
  echo "Testing typed lock-free futures..."
  var count = 0
  for i in 0 ..< 1000:
    let fut = newCpsFuture[int]()
    fut.addCallback(proc() =
      inc count
    )
    complete(fut, i * 2)
    assert fut.finished
    assert fut.read() == i * 2

  assert count == 1000, "Typed futures: expected 1000 callbacks, got " & $count
  echo "PASS: Typed lock-free futures - 1000 complete/read cycles"

# ============================================================
# Lock-free futures: cancel races with complete
# ============================================================

proc testCancelRace() =
  echo "Testing cancel/complete race..."
  var completedCount = 0
  var cancelledCount = 0

  for i in 0 ..< 1000:
    let fut = newCpsVoidFuture()
    fut.addCallback(proc() =
      if fut.hasError():
        inc cancelledCount
      else:
        inc completedCount
    )
    if i mod 2 == 0:
      complete(fut)
    else:
      cancel(fut)

  assert completedCount + cancelledCount == 1000,
    "Cancel race: expected 1000 total, got " & $(completedCount + cancelledCount)
  assert completedCount == 500
  assert cancelledCount == 500
  echo "PASS: Cancel/complete race - completed=" & $completedCount & ", cancelled=" & $cancelledCount

# ============================================================
# Lock-free futures: addCallback vs complete/fail/cancel mix
# ============================================================

proc futureCompleterThird(arg: FutureTestArg) {.thread.} =
  {.cast(gcsafe).}:
    for i in countup(0, arg.count - 1, 3):
      let fut = arg.futures[i]
      complete(fut)

proc futureFailerThird(arg: FutureTestArg) {.thread.} =
  {.cast(gcsafe).}:
    for i in countup(1, arg.count - 1, 3):
      let fut = arg.futures[i]
      fail(fut, newException(CatchableError, "boom"))

proc futureCancellerThird(arg: FutureTestArg) {.thread.} =
  {.cast(gcsafe).}:
    for i in countup(2, arg.count - 1, 3):
      let fut = arg.futures[i]
      cancel(fut)

proc testTerminalMixRace() =
  echo "Testing addCallback vs complete/fail/cancel race..."
  futCallbacksFired.store(0, moRelaxed)

  var futures = newSeq[CpsVoidFuture](FutureTestCount)
  for i in 0 ..< FutureTestCount:
    futures[i] = newCpsVoidFuture()

  let buf = cast[ptr UncheckedArray[CpsVoidFuture]](addr futures[0])
  let arg = FutureTestArg(futures: buf, count: FutureTestCount)

  var adders: array[FutureCallbackThreads, Thread[FutureTestArg]]
  for i in 0 ..< FutureCallbackThreads:
    createThread(adders[i], futureCallbackAdder, arg)

  var comp: Thread[FutureTestArg]
  var failer: Thread[FutureTestArg]
  var canceller: Thread[FutureTestArg]
  createThread(comp, futureCompleterThird, arg)
  createThread(failer, futureFailerThird, arg)
  createThread(canceller, futureCancellerThird, arg)

  for i in 0 ..< FutureCallbackThreads:
    joinThread(adders[i])
  joinThread(comp)
  joinThread(failer)
  joinThread(canceller)

  let expectedCallbacks = FutureTestCount * FutureCallbackThreads
  let actualCallbacks = futCallbacksFired.load(moAcquire)
  assert actualCallbacks == expectedCallbacks,
    "Terminal mix: expected " & $expectedCallbacks & " callbacks, got " & $actualCallbacks

  for i in 0 ..< FutureTestCount:
    let fut = futures[i]
    assert fut.finished
    case i mod 3
    of 0:
      assert not fut.hasError()
    of 1:
      assert fut.hasError()
      assert not fut.isCancelled()
    else:
      assert fut.isCancelled()
  echo "PASS: addCallback vs complete/fail/cancel race"

# ============================================================
# runCps wait/wake race: single + concurrent waiters
# ============================================================

type
  CompleteAfterArg = object
    fut: CpsVoidFuture
    delayMs: int

  WaiterArg = object
    runtime: CpsRuntime
    fut: CpsVoidFuture

proc completeAfterDelay(arg: CompleteAfterArg) {.thread.} =
  sleep(arg.delayMs)
  {.cast(gcsafe).}:
    complete(arg.fut)

proc waiterThread(arg: WaiterArg) {.thread.} =
  {.cast(gcsafe).}:
    setCurrentRuntime(arg.runtime)
    runCps(arg.fut)

proc testRunCpsWakeRace() =
  echo "Testing runCps wait/wake race..."
  # Single waiter stress
  for _ in 0 ..< 200:
    let fut = newCpsVoidFuture()
    var c: Thread[CompleteAfterArg]
    createThread(c, completeAfterDelay, CompleteAfterArg(fut: fut, delayMs: 1))
    runCps(fut)
    joinThread(c)
    assert fut.finished

  # Concurrent waiters on independent runtimes
  const WaiterCount = 16
  var waiters: array[WaiterCount, Thread[WaiterArg]]
  var completers: array[WaiterCount, Thread[CompleteAfterArg]]
  var runtimes = newSeq[CpsRuntime](WaiterCount)
  var futures = newSeq[CpsVoidFuture](WaiterCount)

  for i in 0 ..< WaiterCount:
    let rt = newCurrentThreadRuntime()
    runtimes[i] = rt
    let fut = newCpsVoidFuture()
    fut.bindFutureRuntime(toHandle(rt))
    futures[i] = fut
    createThread(waiters[i], waiterThread, WaiterArg(runtime: rt, fut: fut))
    createThread(completers[i], completeAfterDelay, CompleteAfterArg(fut: fut, delayMs: 1))

  for i in 0 ..< WaiterCount:
    joinThread(completers[i])
  for i in 0 ..< WaiterCount:
    joinThread(waiters[i])
    assert futures[i].finished

  echo "PASS: runCps wait/wake race"

# ============================================================
# Callback node lifecycle: allocation/free balance
# ============================================================

proc testCallbackNodeLifecycleNoLeak() =
  echo "Testing callback node lifecycle (no leak)..."
  resetRuntimeStats()

  const FutureCount = 2000
  const CallbacksPerFuture = 6
  var callbacksRan = 0

  for i in 0 ..< FutureCount:
    let fut = newCpsVoidFuture()
    for _ in 0 ..< CallbacksPerFuture:
      fut.addCallback(proc() =
        inc callbacksRan
      )
    case i mod 3
    of 0:
      complete(fut)
    of 1:
      fail(fut, newException(CatchableError, "boom"))
    else:
      cancel(fut)
    assert fut.finished

  # Already-terminal fast-path should not allocate callback nodes.
  let doneFut = newCpsVoidFuture()
  complete(doneFut)
  for _ in 0 ..< 100:
    doneFut.addCallback(proc() =
      inc callbacksRan
    )

  let stats = getRuntimeStats()
  assert stats.callbackNodesAllocated >= FutureCount * (CallbacksPerFuture - 1),
    "Unexpectedly low callback node allocations: " & $stats.callbackNodesAllocated
  assert stats.callbackNodesAllocated <= FutureCount * CallbacksPerFuture,
    "Unexpectedly high callback node allocations: " & $stats.callbackNodesAllocated
  assert stats.callbackNodesFreed == stats.callbackNodesAllocated,
    "Callback node leak detected: allocated=" &
    $stats.callbackNodesAllocated & ", freed=" & $stats.callbackNodesFreed
  assert callbacksRan == FutureCount * CallbacksPerFuture + 100,
    "Expected callback invocations did not run: " & $callbacksRan
  echo "PASS: callback node lifecycle balanced (allocated=" &
    $stats.callbackNodesAllocated & ", freed=" & $stats.callbackNodesFreed & ")"

# ============================================================
# Run all tests
# ============================================================

testMpscQueue()
testChaseLevDeque()
testLockFreeFutures()
testTypedFutures()
testCancelRace()
testTerminalMixRace()
testRunCpsWakeRace()
when defined(cpsRuntimeStats):
  testCallbackNodeLifecycleNoLeak()
else:
  echo "SKIP: callback node lifecycle stats test (compile with -d:cpsRuntimeStats)"
echo ""
echo "All lock-free stress tests passed!"
