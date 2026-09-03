## CPS Runtime Core
##
## Provides the fundamental types and execution machinery for
## continuation-passing style async programming in Nim.
##
## The core idea: every suspendable procedure is transformed into a
## chain of continuation objects. Each continuation captures:
## - The next function to call (the "bounce")
## - The local state needed by that function (stored in a typed Env)
## - Error state for exception propagation
##
## Execution uses a trampoline: instead of recursing through continuations,
## each step returns the next continuation to run, and a loop drives them.

import std/[deques, atomics, locks, sysatomics, os]
import ./private/cross_thread_closure

export prepareCrossThreadClosure, OwnedClosureTask, ClosureReturnRoute,
       currentClosureReturnRoute, takeClosureTask, runClosureTask,
       releaseClosureTask

when compileOption("gc", "orc"):
  {.pragma: cpsMtAcyclic, acyclic.}
else:
  {.pragma: cpsMtAcyclic.}

type
  CancellationError* = object of CatchableError
    ## Raised when a future or task is cancelled.

  CpsContractError* = object of CatchableError
    ## Raised when CPS-generated code violates required control-flow contracts.

  FuturePerfMode* = enum
    fpSharedSafe
    fpLocalFast

  ContinuationState* = enum
    csRunning    ## Currently executing
    csSuspended  ## Waiting for external event (I/O, timer, etc.)
    csFinished   ## Completed successfully
    csError      ## Completed with an error

  Continuation* {.cpsMtAcyclic.} = ref object of RootObj
    ## Base type for all CPS continuations.
    ## Concrete continuations inherit from this and add their local state.
    fn*: proc(c: sink Continuation): Continuation {.nimcall.}
      ## The next step to execute. Returns the next continuation, or nil if done.
    state*: ContinuationState
    runtimeOwner* {.cursor.}: CpsRuntime

  RuntimeFlavor* = enum
    rfCurrentThread
    rfMultiThread

  RuntimeConfig* = object
    flavor*: RuntimeFlavor
    numWorkers*: int
    pinWorkers*: bool
    numBlockingThreads*: int
    maxSchedulerQueue*: int
    maxBlockingQueue*: int

  CpsRuntime* {.cpsMtAcyclic.} = ref object
    ## Owning runtime object (Tokio-like Runtime).
    id*: int64
    flavor*: RuntimeFlavor
    eventLoopPtr*: RootRef
    ioShardSetPtr*: RootRef
    ioShardCount*: int
    schedulerPtr*: RootRef
    blockingPoolPtr*: RootRef
    blockingThreadCount*: int
    maxBlockingQueue*: int
    continuationDispatcher*: proc(c: sink Continuation) {.closure, gcsafe.}
    callbackDispatcher*: proc(cb: sink proc() {.closure.}) {.closure, gcsafe.}
    pinnedCallbackDispatcher*: proc(workerId: int,
      cb: sink proc() {.closure.}): bool {.closure, gcsafe.}
    closureReleaseDispatcher*: proc(workerId: int,
      task: OwnedClosureTask): bool {.closure, gcsafe.}
    ownedClosureDispatcher*: proc(workerId: int,
      task: OwnedClosureTask): bool {.closure, gcsafe.}
    yieldDispatcher*: proc(cb: sink proc() {.closure, gcsafe.}) {.closure, gcsafe.}
    wakeReactor*: proc() {.closure, gcsafe.}
    wakeIoShard*: proc(workerId: int) {.closure, gcsafe.}
    waitWakeSeq: Atomic[uint64]
    waitInitState: Atomic[int]  ## 0=uninit, 1=initializing, 2=ready
    waiters: Atomic[int]
    mtActive*: bool

  RuntimeHandle* = object
    ## Borrowed lightweight runtime reference (Tokio-like Handle).
    ## The runtime remains valid until its explicit shutdown.
    runtime* {.cursor.}: CpsRuntime

  RuntimeGuard* = object
    ## Scoped enter guard restoring prior runtime context.
    prev* {.cursor.}: CpsRuntime
    active*: bool

  RuntimeAffinityError* = object of CatchableError
    ## Raised when a future/resource cannot move across runtimes.

  Trampoline* = object
    ## Drives a continuation chain to completion without stack growth.
    current: Continuation

  LocalCallbackThunk = object
    cb: proc() {.closure.}
    targetRuntime {.cursor.}: CpsRuntime
    targetWorker: int16

  SharedCallbackThunk = object
    task: OwnedClosureTask
    targetRuntime: pointer
    targetWorker: int16

  CallbackNode = object
    next: pointer
    thunk: pointer

  CpsFuture*[T] {.cpsMtAcyclic.} = ref object
    ## A future value produced by a CPS computation.
    ## Uses atomic state + lock-free callback stack.
    perfMode: FuturePerfMode
    value: T
    error: ref CatchableError
    atomicState: Atomic[int]      ## 0=pending, 1=done, 2=cancelled, 3=completing, 4=cancelling
    callbackHead: Atomic[pointer]
    inlineCallback: proc() {.closure.}
    inlineTargetRuntime {.cursor.}: CpsRuntime
    inlineTargetWorker: int16
    localState: int
    localOwnerThreadToken: pointer
    localOwnerSchedulerPtr: pointer
    localOwnerWorkerId: int
    localCallbacks: seq[LocalCallbackThunk]
    ownerRuntime* {.cursor.}: CpsRuntime
    runtimePinned: Atomic[bool]
    rootContinuationPtr: pointer

  CpsVoidFuture* {.cpsMtAcyclic.} = ref object
    ## A future for void-returning CPS computations.
    ## Uses atomic state + lock-free callback stack.
    perfMode: FuturePerfMode
    error: ref CatchableError
    atomicState: Atomic[int]      ## 0=pending, 1=done, 2=cancelled, 3=completing, 4=cancelling
    callbackHead: Atomic[pointer]
    inlineCallback: proc() {.closure.}
    inlineTargetRuntime {.cursor.}: CpsRuntime
    inlineTargetWorker: int16
    localState: int
    localOwnerThreadToken: pointer
    localOwnerSchedulerPtr: pointer
    localOwnerWorkerId: int
    localCallbacks: seq[LocalCallbackThunk]
    ownerRuntime* {.cursor.}: CpsRuntime
    runtimePinned: Atomic[bool]
    rootContinuationPtr: pointer

const
  FutureStatePending = 0
  FutureStateDone = 1
  FutureStateCancelled = 2
  FutureStateCompleting = 3
  FutureStateCancelling = 4
  CallbackClosed = cast[pointer](1)
  CallbackInline = cast[pointer](2)
  CallbackInlineInit = cast[pointer](3)
  ## Callback affinity sentinel for work that must resume on the main reactor.
  MainReactorCallbackWorker* = -2
  DefaultSchedulerQueueCap = 65536
  DefaultBlockingQueueCap = 65536

type
  RuntimeStats* = object
    completions*: int
    failures*: int
    cancellations*: int
    callbacksRegistered*: int
    callbacksFired*: int
    callbackErrors*: int
    callbackNodesAllocated*: int
    callbackNodesFreed*: int
    runCpsWaits*: int
    runCpsWakeSignals*: int

proc isTerminalFutureState(state: int): bool {.inline.} =
  state == FutureStateDone or state == FutureStateCancelled

proc ensureLocalAffinity[T](fut: CpsFuture[T], opName: string) {.inline.}
proc ensureLocalAffinity(fut: CpsVoidFuture, opName: string) {.inline.}
## Promote the future to shared-safe state before it crosses a thread boundary.
proc ensureShared*[T](fut: CpsFuture[T])
## Promote the future to shared-safe state before it crosses a thread boundary.
proc ensureShared*(fut: CpsVoidFuture)
## Complete the future and notify its waiters.
proc complete*[T](fut: CpsFuture[T], val: T)
## Complete the future and notify its waiters.
proc complete*(fut: CpsVoidFuture)
## Move a worker-owned value into a shared future without foreign RC traffic.
proc completeTransferred*[T](fut: CpsFuture[T], valArg: sink T)
## Fail the future and notify its waiters.
proc fail*[T](fut: CpsFuture[T], err: ref CatchableError)
## Fail the future and notify its waiters.
proc fail*(fut: CpsVoidFuture, err: ref CatchableError)
## Move a worker-owned error into a shared future without foreign RC traffic.
proc failTransferred*[T](fut: CpsFuture[T], errArg: sink ref CatchableError)
## Move a worker-owned error into a shared void future without foreign RC traffic.
proc failTransferred*(fut: CpsVoidFuture, errArg: sink ref CatchableError)

var rtCompletions: Atomic[int]
var rtFailures: Atomic[int]
var rtCancellations: Atomic[int]
var rtCallbacksRegistered: Atomic[int]
var rtCallbacksFired: Atomic[int]
var rtCallbackErrors: Atomic[int]
var rtCallbackNodesAllocated: Atomic[int]
var rtCallbackNodesFreed: Atomic[int]
var rtRunCpsWaits: Atomic[int]
var rtRunCpsWakeSignals: Atomic[int]

const RuntimeStatsEnabled = defined(cpsRuntimeStats)

template statInc(counter: untyped) =
  when RuntimeStatsEnabled:
    discard counter.fetchAdd(1, moRelaxed)

proc getRuntimeStats*(): RuntimeStats =
  ## Return a snapshot of runtime counters and queue depth.
  RuntimeStats(
    completions: rtCompletions.load(moRelaxed),
    failures: rtFailures.load(moRelaxed),
    cancellations: rtCancellations.load(moRelaxed),
    callbacksRegistered: rtCallbacksRegistered.load(moRelaxed),
    callbacksFired: rtCallbacksFired.load(moRelaxed),
    callbackErrors: rtCallbackErrors.load(moRelaxed),
    callbackNodesAllocated: rtCallbackNodesAllocated.load(moRelaxed),
    callbackNodesFreed: rtCallbackNodesFreed.load(moRelaxed),
    runCpsWaits: rtRunCpsWaits.load(moRelaxed),
    runCpsWakeSignals: rtRunCpsWakeSignals.load(moRelaxed)
  )

proc resetRuntimeStats*() =
  ## Reset runtime stats to its initial state.
  rtCompletions.store(0, moRelaxed)
  rtFailures.store(0, moRelaxed)
  rtCancellations.store(0, moRelaxed)
  rtCallbacksRegistered.store(0, moRelaxed)
  rtCallbacksFired.store(0, moRelaxed)
  rtCallbackErrors.store(0, moRelaxed)
  rtCallbackNodesAllocated.store(0, moRelaxed)
  rtCallbackNodesFreed.store(0, moRelaxed)
  rtRunCpsWaits.store(0, moRelaxed)
  rtRunCpsWakeSignals.store(0, moRelaxed)

# ============================================================
# Runtime context + compatibility globals
# ============================================================

type
  MtRuntimeFactoryProc = proc(config: RuntimeConfig): CpsRuntime {.nimcall.}

var gRuntimeLock: Lock
var gRuntimeLockInit: Atomic[int]  ## 0=uninit, 1=initializing, 2=ready
var gMainRuntimeRoot: pointer
var gMainRuntimeFast: Atomic[pointer]
var gMainRuntimeCallbacksInlineFast: Atomic[int]
var gNextRuntimeId: Atomic[int64]
var gMtRuntimeFactory: MtRuntimeFactoryProc = nil

var currentRuntimeCtx {.threadvar.}: pointer
var localFutureDefault {.threadvar.}: bool
var currentSchedulerPtr* {.threadvar.}: pointer
var currentEventLoopPtr* {.threadvar.}: pointer
var currentEventLoopRuntimePtr* {.threadvar.}: pointer
var currentIoShardId* {.threadvar.}: int

var mtModeEnabled* {.threadvar.}: bool
var mtDispatcher* {.threadvar.}: proc(c: sink Continuation) {.nimcall, gcsafe.}
var mtCallbackDispatcher* {.threadvar.}: proc(cb: sink proc() {.closure.}) {.closure, gcsafe.}
var mtYieldDispatcher* {.threadvar.}: proc(cb: sink proc() {.closure, gcsafe.}) {.closure, gcsafe.}
var mtWakeReactor* {.threadvar.}: proc() {.closure, gcsafe.}
var isSchedulerWorker* {.threadvar.}: bool
var currentWorkerId* {.threadvar.}: int
var isReactorThread* {.threadvar.}: bool

proc currentThreadIdentity*(): pointer {.inline.} =
  ## Return a stable identity for the calling thread.
  cast[pointer](addr currentRuntimeCtx)

proc bindCurrentEventLoop*(rt: CpsRuntime, loopPtr: pointer,
                           shardId: int) {.inline.} =
  ## Bind a worker-owned event loop to the calling thread.
  currentEventLoopRuntimePtr = cast[pointer](rt)
  currentEventLoopPtr = loopPtr
  currentIoShardId = shardId

proc clearCurrentEventLoop*() {.inline.} =
  ## Clear the worker-owned event-loop binding on the calling thread.
  currentEventLoopRuntimePtr = nil
  currentEventLoopPtr = nil
  currentIoShardId = -1

proc ensureRuntimeLockReady() {.inline.} =
  if gRuntimeLockInit.load(moAcquire) == 2:
    return
  var expected = 0
  if gRuntimeLockInit.compareExchange(expected, 1, moAcquireRelease, moAcquire):
    initLock(gRuntimeLock)
    gRuntimeLockInit.store(2, moRelease)
  else:
    while gRuntimeLockInit.load(moAcquire) != 2:
      cpuRelax()

proc loadMainRuntimeFast(): pointer {.inline.} =
  gMainRuntimeFast.load(moAcquire)

proc storeMainRuntimeFast(rt: CpsRuntime) {.inline.} =
  gMainRuntimeFast.store(cast[pointer](rt), moRelease)
  if rt == nil or (rt.flavor == rfCurrentThread and rt.callbackDispatcher == nil):
    gMainRuntimeCallbacksInlineFast.store(1, moRelease)
  else:
    gMainRuntimeCallbacksInlineFast.store(0, moRelease)

proc nextRuntimeId(): int64 {.inline.} =
  gNextRuntimeId.fetchAdd(1'i64, moAcquireRelease) + 1'i64

proc applyCompatMtHooks(rt: CpsRuntime) {.inline.} =
  # Runtime dispatch now reads the active runtime directly. Keeping duplicate
  # managed closures in threadvars created cross-thread aliases under ARC/ORC
  # and paid three ref-count operations on every runtime switch.
  mtModeEnabled = rt != nil and rt.flavor == rfMultiThread
  mtCallbackDispatcher = nil
  mtYieldDispatcher = nil
  mtWakeReactor = nil

proc defaultRuntimeConfig*(): RuntimeConfig =
  ## Return the default runtime config.
  RuntimeConfig(
    flavor: rfCurrentThread,
    numWorkers: 0,
    pinWorkers: true,
    numBlockingThreads: 0,
    maxSchedulerQueue: DefaultSchedulerQueueCap,
    maxBlockingQueue: DefaultBlockingQueueCap
  )

proc toHandle*(rt: CpsRuntime): RuntimeHandle {.inline.} =
  ## Return a runtime handle for the supplied runtime.
  RuntimeHandle(runtime: rt)

proc isNil*(h: RuntimeHandle): bool {.inline.} =
  ## Return whether the runtime handle has no runtime attached.
  h.runtime.isNil

proc runtimeId*(h: RuntimeHandle): int64 {.inline.} =
  ## Return the stable identifier of the referenced runtime.
  if h.runtime.isNil: 0 else: h.runtime.id

proc runtimeFlavor*(h: RuntimeHandle): RuntimeFlavor {.inline.} =
  ## Return the execution model used by the referenced runtime.
  if h.runtime.isNil: rfCurrentThread else: h.runtime.flavor

proc setCurrentRuntime*(rt: CpsRuntime) =
  ## Bind the supplied runtime to the current thread.
  currentRuntimeCtx = cast[pointer](rt)
  if isSchedulerWorker:
    # Workers use the runtime's direct dispatch fields. Copying those closure
    # values into threadvars adds ref-count traffic and gives ORC closure roots
    # another cross-thread lifetime to track.
    mtModeEnabled = rt != nil and rt.flavor == rfMultiThread
    mtCallbackDispatcher = nil
    mtYieldDispatcher = nil
    mtWakeReactor = nil
  else:
    currentWorkerId = -1
    applyCompatMtHooks(rt)

proc setCurrentRuntimeBorrowed*(rt: CpsRuntime) {.inline.} =
  ## Bind a runtime pointer on an auxiliary worker without copying its managed
  ## compatibility dispatch closures into that worker's ARC/ORC heap.
  currentRuntimeCtx = cast[pointer](rt)
  mtModeEnabled = rt != nil and rt.flavor == rfMultiThread
  currentWorkerId = -1

proc tryCurrentRuntime*(): RuntimeHandle =
  ## Return the runtime bound to this thread without creating one.
  toHandle(cast[CpsRuntime](currentRuntimeCtx))

proc newCurrentThreadRuntime*(): CpsRuntime =
  ## Create a new current thread runtime.
  result = CpsRuntime()
  result.id = nextRuntimeId()
  result.flavor = rfCurrentThread
  result.eventLoopPtr = nil
  result.ioShardSetPtr = nil
  result.ioShardCount = 0
  result.schedulerPtr = nil
  result.blockingPoolPtr = nil
  result.blockingThreadCount = 0
  result.maxBlockingQueue = DefaultBlockingQueueCap
  result.continuationDispatcher = nil
  result.callbackDispatcher = nil
  result.pinnedCallbackDispatcher = nil
  result.closureReleaseDispatcher = nil
  result.ownedClosureDispatcher = nil
  result.yieldDispatcher = nil
  result.wakeReactor = nil
  result.wakeIoShard = nil
  result.waitInitState.store(0, moRelaxed)
  result.waiters.store(0, moRelaxed)
  result.waitWakeSeq.store(0'u64, moRelaxed)
  result.mtActive = false

proc registerMtRuntimeFactory*(factory: MtRuntimeFactoryProc) =
  ## Register the factory used to construct multithreaded runtimes.
  gMtRuntimeFactory = factory

proc newMultiThreadRuntime*(numWorkers: int = 0,
                            numBlockingThreads: int = 0,
                            maxSchedulerQueue: int = DefaultSchedulerQueueCap,
                            maxBlockingQueue: int = DefaultBlockingQueueCap,
                            pinWorkers: bool = true): CpsRuntime =
  ## Create a new multi thread runtime.
  if gMtRuntimeFactory == nil:
    raise newException(ValueError, "MT runtime factory not registered; import cps/mt first")
  let cfg = RuntimeConfig(
    flavor: rfMultiThread,
    numWorkers: numWorkers,
    pinWorkers: pinWorkers,
    numBlockingThreads: numBlockingThreads,
    maxSchedulerQueue: maxSchedulerQueue,
    maxBlockingQueue: maxBlockingQueue
  )
  result = gMtRuntimeFactory(cfg)

proc newRuntime*(config: RuntimeConfig): CpsRuntime =
  ## Create a new runtime.
  case config.flavor
  of rfCurrentThread:
    result = newCurrentThreadRuntime()
  of rfMultiThread:
    result = newMultiThreadRuntime(
      numWorkers = config.numWorkers,
      pinWorkers = config.pinWorkers,
      numBlockingThreads = config.numBlockingThreads,
      maxSchedulerQueue = config.maxSchedulerQueue,
      maxBlockingQueue = config.maxBlockingQueue
    )

proc ensureMainRuntime(): CpsRuntime =
  let fast = loadMainRuntimeFast()
  if fast != nil:
    return cast[CpsRuntime](fast)
  ensureRuntimeLockReady()
  acquire(gRuntimeLock)
  if gMainRuntimeRoot == nil:
    let created = newCurrentThreadRuntime()
    # The final process-wide runtime deliberately keeps one manual root. Nim
    # must not also keep a managed global reference: replacing that reference
    # and releasing the manual root performs two decrements around a runtime
    # graph whose cross-thread cursors deliberately contribute no count.
    GC_ref(created)
    gMainRuntimeRoot = cast[pointer](created)
    storeMainRuntimeFast(created)
  result = cast[CpsRuntime](gMainRuntimeRoot)
  release(gRuntimeLock)

proc setMainRuntime*(rt: CpsRuntime) =
  ## Replace the process-wide main runtime binding.
  var oldRoot: pointer
  ensureRuntimeLockReady()
  acquire(gRuntimeLock)
  if cast[pointer](rt) != gMainRuntimeRoot:
    if rt != nil:
      GC_ref(rt)
    oldRoot = gMainRuntimeRoot
    gMainRuntimeRoot = cast[pointer](rt)
  storeMainRuntimeFast(rt)
  release(gRuntimeLock)
  if oldRoot != nil:
    GC_unref(cast[CpsRuntime](oldRoot))

proc mainRuntime*(): RuntimeHandle =
  ## Return the process-wide main runtime handle.
  toHandle(ensureMainRuntime())

proc currentRuntime*(): RuntimeHandle =
  ## Return the runtime bound to this thread, creating the main runtime when needed.
  if currentRuntimeCtx != nil:
    toHandle(cast[CpsRuntime](currentRuntimeCtx))
  else:
    let fast = loadMainRuntimeFast()
    if fast != nil:
      toHandle(cast[CpsRuntime](fast))
    else:
      mainRuntime()

proc currentRuntimePointer*(): pointer {.inline.} =
  ## Borrow the current runtime without reference-count traffic. Internal
  ## reactor code uses this while the active runtime is retained by its owner.
  if currentRuntimeCtx != nil:
    return currentRuntimeCtx
  let fast = gMainRuntimeFast.load(moAcquire)
  if fast != nil:
    return fast
  cast[pointer](ensureMainRuntime())

proc deferCurrentWorker*(cbArg: sink proc() {.closure.}): bool {.inline.} =
  ## Defer `cbArg` onto the current multithreaded-runtime worker.
  ##
  ## This is the allocation-light primitive for batching owner-local work: the
  ## callback stays on the worker that owns its ARC/ORC graph and enters that
  ## worker's bounded pinned inbox. Callers can provide their event-loop
  ## fallback when no multithreaded worker is active.
  let rt {.cursor.} = cast[CpsRuntime](currentRuntimeCtx)
  if rt == nil or rt.flavor != rfMultiThread or not isSchedulerWorker or
      rt.pinnedCallbackDispatcher == nil:
    return false
  {.cast(gcsafe).}:
    result = rt.pinnedCallbackDispatcher(currentWorkerId, move(cbArg))

proc setLocalFutureDefault*(enabled: bool) {.inline.} =
  ## Select local-fast futures for constructors called on this thread.
  ## Isolated reactor threads use this because their continuations and I/O
  ## callbacks never cross a thread boundary. Shared and work-stealing
  ## runtimes leave it disabled.
  localFutureDefault = enabled

proc localFutureDefaultEnabled*(): bool {.inline.} =
  ## Return whether new futures use reactor-local storage by default.
  localFutureDefault

proc enter*(handle: RuntimeHandle): RuntimeGuard =
  ## Enter the referenced runtime and retain the previous thread-local binding.
  if handle.runtime == nil:
    raise newException(ValueError, "Cannot enter a nil runtime handle")
  result.prev = cast[CpsRuntime](currentRuntimeCtx)
  result.active = true
  setCurrentRuntime(handle.runtime)

proc leave*(guard: var RuntimeGuard) =
  ## Restore the runtime binding retained by the guard.
  if not guard.active:
    return
  guard.active = false
  setCurrentRuntime(guard.prev)

template withRuntime*(handle: RuntimeHandle, body: untyped): untyped =
  ## Run a block with a temporary thread-local runtime binding.
  block:
    var guard = enter(handle)
    try:
      body
    finally:
      leave(guard)

proc ensureRuntimeWaitReady(rt: CpsRuntime) {.inline.} =
  if rt == nil:
    return
  if rt.waitInitState.load(moAcquire) == 2:
    return
  var expected = 0
  if rt.waitInitState.compareExchange(expected, 1, moAcquireRelease, moAcquire):
    rt.waitWakeSeq.store(0'u64, moRelaxed)
    rt.waitInitState.store(2, moRelease)
  else:
    while rt.waitInitState.load(moAcquire) != 2:
      cpuRelax()

proc runCpsWaitEnter*(rt: CpsRuntime) {.inline.} =
  ## Register a synchronous waiter with the runtime.
  ensureRuntimeWaitReady(rt)
  if rt != nil:
    discard rt.waiters.fetchAdd(1, moAcquireRelease)

proc runCpsWaitLeave*(rt: CpsRuntime) {.inline.} =
  ## Remove a synchronous waiter from the runtime.
  if rt != nil:
    discard rt.waiters.fetchSub(1, moAcquireRelease)

proc runCpsWaitEnter*() {.inline.} =
  ## Register a synchronous waiter with the runtime.
  let rt {.cursor.} = cast[CpsRuntime](currentRuntimePointer())
  runCpsWaitEnter(rt)

proc runCpsWaitLeave*() {.inline.} =
  ## Remove a synchronous waiter from the runtime.
  let rt {.cursor.} = cast[CpsRuntime](currentRuntimePointer())
  runCpsWaitLeave(rt)

proc waitRunCpsSignal*[T](rt: CpsRuntime, fut: CpsFuture[T]) =
  ## Wait until the future completes, fails, or is cancelled.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("waitRunCpsSignal")
    return
  if rt == nil:
    return
  var seenSeq = rt.waitWakeSeq.load(moAcquire)
  if isTerminalFutureState(fut.atomicState.load(moAcquire)):
    return
  statInc(rtRunCpsWaits)
  var spins = 128
  while not isTerminalFutureState(fut.atomicState.load(moAcquire)):
    if rt.waitWakeSeq.load(moAcquire) != seenSeq:
      return
    if spins > 0:
      cpuRelax()
      dec spins
    else:
      sleep(0)
      spins = 32

proc waitRunCpsSignal*(rt: CpsRuntime, fut: CpsVoidFuture) =
  ## Wait until the future completes, fails, or is cancelled.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("waitRunCpsSignal")
    return
  if rt == nil:
    return
  var seenSeq = rt.waitWakeSeq.load(moAcquire)
  if isTerminalFutureState(fut.atomicState.load(moAcquire)):
    return
  statInc(rtRunCpsWaits)
  var spins = 128
  while not isTerminalFutureState(fut.atomicState.load(moAcquire)):
    if rt.waitWakeSeq.load(moAcquire) != seenSeq:
      return
    if spins > 0:
      cpuRelax()
      dec spins
    else:
      sleep(0)
      spins = 32

proc waitRunCpsSignal*[T](fut: CpsFuture[T]) =
  ## Wait until the future completes, fails, or is cancelled.
  let rt {.cursor.} = if fut.ownerRuntime != nil: fut.ownerRuntime
    else: cast[CpsRuntime](currentRuntimePointer())
  waitRunCpsSignal(rt, fut)

proc waitRunCpsSignal*(fut: CpsVoidFuture) =
  ## Wait until the future completes, fails, or is cancelled.
  let rt {.cursor.} = if fut.ownerRuntime != nil: fut.ownerRuntime
    else: cast[CpsRuntime](currentRuntimePointer())
  waitRunCpsSignal(rt, fut)

# ============================================================
# Continuation lifecycle
# ============================================================

proc newContinuation*(T: typedesc[Continuation],
                      fn: proc(c: sink Continuation): Continuation {.nimcall.}): T =
  ## Create a new continuation.
  result = T()
  result.fn = fn
  result.state = csRunning
  result.runtimeOwner = cast[CpsRuntime](currentRuntimePointer())

proc pass*(c: sink Continuation): Continuation {.inline.} =
  ## Return the continuation as-is for the trampoline to execute next.
  result = c

proc halt*(c: sink Continuation): Continuation {.inline.} =
  ## Mark the continuation as finished and stop the chain.
  c.state = csFinished
  c.fn = nil
  result = c

proc suspend*(c: sink Continuation): Continuation {.inline.} =
  ## Suspend the continuation. It will be resumed by an external event.
  c.fn = nil
  c.state = csSuspended
  result = c

proc fail*(c: sink Continuation, err: ref CatchableError): Continuation {.inline.} =
  ## Set the continuation into an error state.
  c.state = csError
  c.fn = nil
  result = c

proc isRunning*(c: Continuation): bool {.inline.} =
  ## Return whether the future is currently running.
  c.fn != nil

proc isFinished*(c: Continuation): bool {.inline.} =
  ## Return whether the future has reached a terminal state.
  c.state in {csFinished, csError}

proc isSuspended*(c: Continuation): bool {.inline.} =
  ## Return whether the future is suspended.
  c.state == csSuspended

# ============================================================
# Trampoline - stack-safe execution
# ============================================================

proc initTrampoline*(c: sink Continuation): Trampoline {.inline.} =
  ## Initialize trampoline.
  Trampoline(current: c)

proc bounce*(t: var Trampoline): bool {.inline.} =
  ## Execute one step. Returns true if there are more steps.
  if t.current.isNil:
    return false
  let fn = t.current.fn
  if fn.isNil:
    return false
  t.current = fn(t.current)
  if t.current.isNil:
    return false
  result = not t.current.fn.isNil

proc run*(c: sink Continuation): Continuation {.discardable.} =
  ## Run a continuation chain to completion or suspension via trampoline.
  ## Uses a direct while loop — no Trampoline struct overhead.
  ## The fn pointer is loaded exactly once per iteration to prevent
  ## TOCTOU races when another thread modifies the continuation.
  let targetRt {.cursor.} = if c != nil: c.runtimeOwner else: nil
  if targetRt != nil and targetRt.continuationDispatcher != nil and
     (not isSchedulerWorker or currentRuntimeCtx != cast[pointer](targetRt)):
    targetRt.continuationDispatcher(c)
    return nil
  # Compatibility hook for embedders using the original MT dispatcher API.
  if mtDispatcher != nil:
    mtDispatcher(c)
    return nil
  let prevRt {.cursor.} = cast[CpsRuntime](currentRuntimeCtx)
  if targetRt != nil and targetRt != prevRt:
    setCurrentRuntime(targetRt)
  try:
    result = c
    while not result.isNil:
      let fn = result.fn
      if fn.isNil:
        break
      result = fn(result)
  finally:
    if targetRt != nil and targetRt != prevRt:
      setCurrentRuntime(prevRt)

proc runUntilSuspend*(c: sink Continuation): Continuation =
  ## Run until the continuation suspends or finishes.
  ## Single-load fn to match run() TOCTOU fix.
  let targetRt {.cursor.} = if c != nil: c.runtimeOwner else: nil
  let prevRt {.cursor.} = cast[CpsRuntime](currentRuntimeCtx)
  if targetRt != nil and targetRt != prevRt:
    setCurrentRuntime(targetRt)
  try:
    result = c
    while not result.isNil:
      let fn = result.fn
      if fn.isNil:
        break
      result = fn(result)
  finally:
    if targetRt != nil and targetRt != prevRt:
      setCurrentRuntime(prevRt)

# ============================================================
# CpsFuture[T] operations
# ============================================================

const SharedFuturesOnly = defined(cpsSharedFuturesOnly)

proc currentThreadToken(): pointer {.inline.} =
  cast[pointer](addr currentRuntimeCtx)

proc captureLocalOwner[T](fut: CpsFuture[T]) {.inline.} =
  fut.localOwnerThreadToken = currentThreadToken()
  fut.localOwnerSchedulerPtr = currentSchedulerPtr
  fut.localOwnerWorkerId = if isSchedulerWorker: currentWorkerId else: -1

proc captureLocalOwner(fut: CpsVoidFuture) {.inline.} =
  fut.localOwnerThreadToken = currentThreadToken()
  fut.localOwnerSchedulerPtr = currentSchedulerPtr
  fut.localOwnerWorkerId = if isSchedulerWorker: currentWorkerId else: -1

proc localAffinityOk[T](fut: CpsFuture[T]): bool {.inline.} =
  if fut.localOwnerThreadToken != currentThreadToken():
    return false
  if fut.localOwnerSchedulerPtr != nil:
    if not isSchedulerWorker:
      return false
    if currentSchedulerPtr != fut.localOwnerSchedulerPtr:
      return false
    if currentWorkerId != fut.localOwnerWorkerId:
      return false
  result = true

proc localAffinityOk(fut: CpsVoidFuture): bool {.inline.} =
  if fut.localOwnerThreadToken != currentThreadToken():
    return false
  if fut.localOwnerSchedulerPtr != nil:
    if not isSchedulerWorker:
      return false
    if currentSchedulerPtr != fut.localOwnerSchedulerPtr:
      return false
    if currentWorkerId != fut.localOwnerWorkerId:
      return false
  result = true

proc tryHopLocalOpToOwner[T](fut: CpsFuture[T], op: proc() {.closure.}): bool {.inline.} =
  let rt {.cursor.} = fut.ownerRuntime
  if rt == nil or rt.pinnedCallbackDispatcher == nil or fut.localOwnerWorkerId < 0:
    return false
  GC_ref(fut)
  let accepted = rt.pinnedCallbackDispatcher(fut.localOwnerWorkerId, proc() {.closure.} =
    try:
      op()
    finally:
      GC_unref(fut)
  )
  if not accepted:
    GC_unref(fut)
  result = accepted

proc tryHopLocalOpToOwner(fut: CpsVoidFuture, op: proc() {.closure.}): bool {.inline.} =
  let rt {.cursor.} = fut.ownerRuntime
  if rt == nil or rt.pinnedCallbackDispatcher == nil or fut.localOwnerWorkerId < 0:
    return false
  GC_ref(fut)
  let accepted = rt.pinnedCallbackDispatcher(fut.localOwnerWorkerId, proc() {.closure.} =
    try:
      op()
    finally:
      GC_unref(fut)
  )
  if not accepted:
    GC_unref(fut)
  result = accepted

proc raiseLocalAffinityViolation(opName: string) {.noinline.} =
  let msg = "local-fast future " & opName &
    " on a foreign thread/worker; call ensureShared() before crossing runtime/thread boundaries"
  when defined(release):
    raise newException(RuntimeAffinityError, msg)
  else:
    raise newException(Defect, msg)

proc ensureLocalAffinity[T](fut: CpsFuture[T], opName: string) {.inline.} =
  if not fut.localAffinityOk():
    raiseLocalAffinityViolation(opName)

proc ensureLocalAffinity(fut: CpsVoidFuture, opName: string) {.inline.} =
  if not fut.localAffinityOk():
    raiseLocalAffinityViolation(opName)

proc localTerminalState(state: int): bool {.inline.} =
  state == FutureStateDone or state == FutureStateCancelled

proc isLocalFast*[T](fut: CpsFuture[T]): bool {.inline.} =
  ## Return whether the future uses reactor-local fast state.
  fut.perfMode == fpLocalFast

proc isLocalFast*(fut: CpsVoidFuture): bool {.inline.} =
  ## Return whether the future uses reactor-local fast state.
  fut.perfMode == fpLocalFast

proc isSharedSafe*[T](fut: CpsFuture[T]): bool {.inline.} =
  ## Return whether the future can cross thread boundaries.
  fut.perfMode == fpSharedSafe

proc isSharedSafe*(fut: CpsVoidFuture): bool {.inline.} =
  ## Return whether the future can cross thread boundaries.
  fut.perfMode == fpSharedSafe

proc newCpsFuture*[T](): CpsFuture[T] =
  ## Create a new CPS future.
  when not SharedFuturesOnly:
    if localFutureDefault:
      result = CpsFuture[T]()
      result.perfMode = fpLocalFast
      result.localState = FutureStatePending
      result.captureLocalOwner()
      result.ownerRuntime = cast[CpsRuntime](currentRuntimeCtx)
      return
  result = CpsFuture[T]()
  # Atomic[int] zero-initializes to 0 (pending). No lock needed.
  result.perfMode = fpSharedSafe
  result.localState = FutureStatePending
  result.localOwnerWorkerId = -1
  result.ownerRuntime = nil

proc newCpsVoidFuture*(): CpsVoidFuture =
  ## Create a new CPS void future.
  when not SharedFuturesOnly:
    if localFutureDefault:
      result = CpsVoidFuture()
      result.perfMode = fpLocalFast
      result.localState = FutureStatePending
      result.captureLocalOwner()
      result.ownerRuntime = cast[CpsRuntime](currentRuntimeCtx)
      return
  result = CpsVoidFuture()
  # Atomic[int] zero-initializes to 0 (pending). No lock needed.
  result.perfMode = fpSharedSafe
  result.localState = FutureStatePending
  result.localOwnerWorkerId = -1
  result.ownerRuntime = nil

proc newLocalCpsFuture*[T](): CpsFuture[T] =
  ## Create a new local CPS future.
  when SharedFuturesOnly:
    result = newCpsFuture[T]()
  else:
    let fastRt = cast[CpsRuntime](currentRuntimeCtx)
    let rt =
      if fastRt != nil:
        fastRt
      else:
        let mainRt = loadMainRuntimeFast()
        if mainRt != nil: cast[CpsRuntime](mainRt) else: ensureMainRuntime()
    if rt != nil and rt.flavor == rfMultiThread and
       (not isSchedulerWorker or currentSchedulerPtr == nil):
      return newCpsFuture[T]()
    result = CpsFuture[T]()
    result.perfMode = fpLocalFast
    result.localState = FutureStatePending
    result.captureLocalOwner()
    result.ownerRuntime = rt

proc newLocalCpsVoidFuture*(): CpsVoidFuture =
  ## Create a new local CPS void future.
  when SharedFuturesOnly:
    result = newCpsVoidFuture()
  else:
    let fastRt = cast[CpsRuntime](currentRuntimeCtx)
    let rt =
      if fastRt != nil:
        fastRt
      else:
        let mainRt = loadMainRuntimeFast()
        if mainRt != nil: cast[CpsRuntime](mainRt) else: ensureMainRuntime()
    if rt != nil and rt.flavor == rfMultiThread and
       (not isSchedulerWorker or currentSchedulerPtr == nil):
      return newCpsVoidFuture()
    result = CpsVoidFuture()
    result.perfMode = fpLocalFast
    result.localState = FutureStatePending
    result.captureLocalOwner()
    result.ownerRuntime = rt

proc completedLocalFuture*[T](val: T): CpsFuture[T] =
  ## Create an already-completed reactor-local future.
  result = newLocalCpsFuture[T]()
  complete(result, val)

proc completedLocalVoidFuture*(): CpsVoidFuture =
  ## Create an already-completed reactor-local void future.
  result = newLocalCpsVoidFuture()
  complete(result)

proc failedLocalFuture*[T](err: ref CatchableError): CpsFuture[T] =
  ## Create an already-failed reactor-local future.
  result = newLocalCpsFuture[T]()
  fail(result, err)

proc failedLocalVoidFuture*(err: ref CatchableError): CpsVoidFuture =
  ## Create an already-failed reactor-local void future.
  result = newLocalCpsVoidFuture()
  fail(result, err)

proc completedFuture*[T](val: T): CpsFuture[T] {.inline.} =
  ## Create a future that is already completed with a value.
  ## Uses relaxed store (no CAS needed since the future hasn't been shared yet).
  when not SharedFuturesOnly:
    if localFutureDefault:
      result = newCpsFuture[T]()
      result.value = val
      result.localState = FutureStateDone
      return
  result = CpsFuture[T](value: val, ownerRuntime: nil, perfMode: fpSharedSafe,
                        localState: FutureStateDone, localOwnerWorkerId: -1)
  result.atomicState.store(FutureStateDone, moRelaxed)
  result.callbackHead.store(CallbackClosed, moRelaxed)

proc completedVoidFuture*(): CpsVoidFuture {.inline.} =
  ## Create a void future that is already completed.
  when not SharedFuturesOnly:
    if localFutureDefault:
      result = newCpsVoidFuture()
      result.localState = FutureStateDone
      return
  result = CpsVoidFuture(ownerRuntime: nil, perfMode: fpSharedSafe,
                         localState: FutureStateDone, localOwnerWorkerId: -1)
  result.atomicState.store(FutureStateDone, moRelaxed)
  result.callbackHead.store(CallbackClosed, moRelaxed)

var threadCompletedVoidFuture {.threadvar.}: CpsVoidFuture

proc cachedCompletedVoidFuture*(): CpsVoidFuture {.inline.} =
  ## Return a reusable completed future owned by the current thread.
  ## Completed futures are immutable and callbacks run inline, so synchronous
  ## I/O paths can avoid allocating one completion object per operation.
  if threadCompletedVoidFuture.isNil:
    threadCompletedVoidFuture = completedVoidFuture()
  threadCompletedVoidFuture

proc failedFuture*[T](err: ref CatchableError): CpsFuture[T] {.inline.} =
  ## Create a future that is already failed with an error.
  when not SharedFuturesOnly:
    if localFutureDefault:
      result = newCpsFuture[T]()
      result.error = err
      result.localState = FutureStateDone
      return
  result = CpsFuture[T](error: err, ownerRuntime: nil, perfMode: fpSharedSafe,
                        localState: FutureStateDone, localOwnerWorkerId: -1)
  result.atomicState.store(FutureStateDone, moRelaxed)
  result.callbackHead.store(CallbackClosed, moRelaxed)

proc failedVoidFuture*(err: ref CatchableError): CpsVoidFuture {.inline.} =
  ## Create a void future that is already failed with an error.
  when not SharedFuturesOnly:
    if localFutureDefault:
      result = newCpsVoidFuture()
      result.error = err
      result.localState = FutureStateDone
      return
  result = CpsVoidFuture(error: err, ownerRuntime: nil, perfMode: fpSharedSafe,
                         localState: FutureStateDone, localOwnerWorkerId: -1)
  result.atomicState.store(FutureStateDone, moRelaxed)
  result.callbackHead.store(CallbackClosed, moRelaxed)

proc finished*[T](fut: CpsFuture[T]): bool {.inline.} =
  ## Check if the future has completed (successfully or with error).
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("finished")
    return localTerminalState(fut.localState)
  isTerminalFutureState(fut.atomicState.load(moAcquire))

proc finished*(fut: CpsVoidFuture): bool {.inline.} =
  ## Check if the void future has completed (successfully or with error).
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("finished")
    return localTerminalState(fut.localState)
  isTerminalFutureState(fut.atomicState.load(moAcquire))

template ownerRuntimeRef(fut: typed): CpsRuntime =
  ## Borrow the future's cursor field directly at the call site. Returning it
  ## from a proc creates an owned temporary and races the shared runtime's
  ## non-atomic ARC/ORC count on every completion.
  fut.ownerRuntime

proc futureRuntime*[T](fut: CpsFuture[T]): RuntimeHandle {.inline.} =
  ## Return the runtime currently associated with the future.
  toHandle(ownerRuntimeRef(fut))

proc futureRuntime*(fut: CpsVoidFuture): RuntimeHandle {.inline.} =
  ## Return the runtime currently associated with the future.
  toHandle(ownerRuntimeRef(fut))

proc bindFutureRuntime*[T](fut: CpsFuture[T], handle: RuntimeHandle) {.inline.} =
  ## Associate the future with the supplied runtime.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("bindFutureRuntime")
    if handle.runtime != fut.ownerRuntime:
      fut.ensureShared()
  fut.ownerRuntime = handle.runtime

proc bindFutureRuntime*(fut: CpsVoidFuture, handle: RuntimeHandle) {.inline.} =
  ## Associate the future with the supplied runtime.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("bindFutureRuntime")
    if handle.runtime != fut.ownerRuntime:
      fut.ensureShared()
  fut.ownerRuntime = handle.runtime

proc setFutureRootContinuation*[T](fut: CpsFuture[T], c: Continuation) {.inline.} =
  ## Set the future's root continuation for cancellation and migration.
  fut.rootContinuationPtr = cast[pointer](c)
  if c != nil and c.runtimeOwner != nil:
    fut.ownerRuntime = c.runtimeOwner

proc setFutureRootContinuation*(fut: CpsVoidFuture, c: Continuation) {.inline.} =
  ## Set the future's root continuation for cancellation and migration.
  fut.rootContinuationPtr = cast[pointer](c)
  if c != nil and c.runtimeOwner != nil:
    fut.ownerRuntime = c.runtimeOwner

proc pinFutureRuntime*[T](fut: CpsFuture[T]) {.inline.} =
  ## Pin the future and its root continuation to the supplied runtime.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("pinFutureRuntime")
  if fut.ownerRuntime == nil:
    let rt = cast[CpsRuntime](currentRuntimeCtx)
    if rt != nil:
      fut.ownerRuntime = rt
    else:
      let fast = loadMainRuntimeFast()
      if fast != nil:
        fut.ownerRuntime = cast[CpsRuntime](fast)
      else:
        fut.ownerRuntime = ensureMainRuntime()
  fut.runtimePinned.store(true, moRelease)
  if isSchedulerWorker and fut.localOwnerWorkerId < 0:
    fut.localOwnerWorkerId = currentWorkerId

proc pinFutureRuntime*(fut: CpsVoidFuture) {.inline.} =
  ## Pin the future and its root continuation to the supplied runtime.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("pinFutureRuntime")
  if fut.ownerRuntime == nil:
    let rt = cast[CpsRuntime](currentRuntimeCtx)
    if rt != nil:
      fut.ownerRuntime = rt
    else:
      let fast = loadMainRuntimeFast()
      if fast != nil:
        fut.ownerRuntime = cast[CpsRuntime](fast)
      else:
        fut.ownerRuntime = ensureMainRuntime()
  fut.runtimePinned.store(true, moRelease)
  if isSchedulerWorker and fut.localOwnerWorkerId < 0:
    fut.localOwnerWorkerId = currentWorkerId

proc isRuntimePinned*[T](fut: CpsFuture[T]): bool {.inline.} =
  ## Return whether the future is pinned to a runtime.
  fut.runtimePinned.load(moAcquire)

proc isRuntimePinned*(fut: CpsVoidFuture): bool {.inline.} =
  ## Return whether the future is pinned to a runtime.
  fut.runtimePinned.load(moAcquire)

proc pinFutureWaitWorker*[T](fut: CpsFuture[T]) {.inline.} =
  ## Record the scheduler worker whose nested ``runCps`` loop must be woken.
  if isSchedulerWorker and fut.localOwnerWorkerId < 0:
    fut.localOwnerWorkerId = currentWorkerId

proc pinFutureWaitWorker*(fut: CpsVoidFuture) {.inline.} =
  ## Record the scheduler worker whose nested ``runCps`` loop must be woken.
  if isSchedulerWorker and fut.localOwnerWorkerId < 0:
    fut.localOwnerWorkerId = currentWorkerId

proc tryMigrateTo*[T](fut: CpsFuture[T], handle: RuntimeHandle): bool =
  ## Attempt to move the future to another runtime without blocking.
  if fut.perfMode == fpLocalFast:
    fut.ensureShared()
  if handle.runtime == nil:
    return false
  if fut.isRuntimePinned():
    return false
  fut.ownerRuntime = handle.runtime
  let root = cast[Continuation](fut.rootContinuationPtr)
  if root != nil:
    root.runtimeOwner = handle.runtime
  result = true

proc tryMigrateTo*(fut: CpsVoidFuture, handle: RuntimeHandle): bool =
  ## Attempt to move the future to another runtime without blocking.
  if fut.perfMode == fpLocalFast:
    fut.ensureShared()
  if handle.runtime == nil:
    return false
  if fut.isRuntimePinned():
    return false
  fut.ownerRuntime = handle.runtime
  let root = cast[Continuation](fut.rootContinuationPtr)
  if root != nil:
    root.runtimeOwner = handle.runtime
  result = true

proc migrateTo*[T](fut: CpsFuture[T], handle: RuntimeHandle) =
  ## Move the future to another runtime.
  if not tryMigrateTo(fut, handle):
    raise newException(RuntimeAffinityError,
      "cannot migrate future to runtime " & $handle.runtimeId() &
      ": future is runtime-pinned")

proc migrateTo*(fut: CpsVoidFuture, handle: RuntimeHandle) =
  ## Move the future to another runtime.
  if not tryMigrateTo(fut, handle):
    raise newException(RuntimeAffinityError,
      "cannot migrate future to runtime " & $handle.runtimeId() &
      ": future is runtime-pinned")

proc dispatchCallback(rt: CpsRuntime, targetWorker: int,
                      cb: sink proc() {.closure.}) {.inline.} =
  ## Fire a single callback on the target runtime, dispatching to workers
  ## when the runtime has a scheduler dispatcher configured.
  statInc(rtCallbacksFired)
  if rt != nil and targetWorker != -1 and
     rt.pinnedCallbackDispatcher != nil:
    {.cast(gcsafe).}:
      discard rt.pinnedCallbackDispatcher(targetWorker, move(cb))
  elif rt != nil and rt.callbackDispatcher != nil:
    {.cast(gcsafe).}:
      rt.callbackDispatcher(move(cb))
  else:
    let prevRt {.cursor.} = cast[CpsRuntime](currentRuntimeCtx)
    var mustEnter = rt != nil and rt != prevRt
    # ST fast path: if this callback targets the default current-thread
    # runtime and no explicit runtime is entered, avoid enter/leave churn.
    if mustEnter and prevRt == nil and rt.flavor == rfCurrentThread and
       cast[pointer](rt) == loadMainRuntimeFast():
      mustEnter = false
    if mustEnter:
      setCurrentRuntime(rt)
    try:
      try:
        cb()
      except CatchableError:
        statInc(rtCallbackErrors)
    finally:
      if mustEnter:
        setCurrentRuntime(prevRt)

proc allocCallbackThunk(cb: sink proc() {.closure.}, targetRt: CpsRuntime,
                        targetWorker: int): ptr SharedCallbackThunk {.inline.} =
  result = cast[ptr SharedCallbackThunk](
    allocShared0(sizeof(SharedCallbackThunk)))
  var owned = move(cb)
  result.task = takeClosureTask(owned)
  result.targetRuntime = cast[pointer](targetRt)
  result.targetWorker = int16(targetWorker)

proc allocCallbackNode(thunk: ptr SharedCallbackThunk): ptr CallbackNode {.inline.} =
  result = cast[ptr CallbackNode](allocShared0(sizeof(CallbackNode)))
  result.next = nil
  result.thunk = cast[pointer](thunk)
  statInc(rtCallbackNodesAllocated)

proc takeCallbackProc(thunk: ptr SharedCallbackThunk): proc() {.closure.} {.inline.} =
  copyMem(addr result, addr thunk.task, sizeof(result))
  thunk.task = default(OwnedClosureTask)

proc fireCallbackThunk(thunk: ptr SharedCallbackThunk) {.inline.} =
  if thunk == nil:
    return
  var task = thunk.task
  thunk.task = default(OwnedClosureTask)
  let targetRt {.cursor.} = cast[CpsRuntime](thunk.targetRuntime)
  let targetWorker = int(thunk.targetWorker)
  deallocShared(thunk)
  if targetRt != nil and targetWorker != -1 and
     targetRt.ownedClosureDispatcher != nil:
    {.cast(gcsafe).}:
      if targetRt.ownedClosureDispatcher(targetWorker, task):
        return
    when compileOption("gc", "atomicArc"):
      releaseClosureTask(task, proc() {.closure.})
    return
  var cb: proc() {.closure.}
  copyMem(addr cb, addr task, sizeof(cb))
  task = default(OwnedClosureTask)
  if targetRt == nil:
    cb()
  else:
    dispatchCallback(targetRt, targetWorker, move(cb))

proc freeCallbackNode(node: ptr CallbackNode) {.inline.} =
  statInc(rtCallbackNodesFreed)
  deallocShared(node)

proc closeAndTakeCallbackStack[T](fut: CpsFuture[T]): pointer {.inline.} =
  while true:
    let head = fut.callbackHead.load(moAcquire)
    if head == CallbackInlineInit:
      cpuRelax()
      continue
    var expected = head
    if fut.callbackHead.compareExchange(expected, CallbackClosed, moAcquireRelease, moAcquire):
      return head

proc closeAndTakeCallbackStack(fut: CpsVoidFuture): pointer {.inline.} =
  while true:
    let head = fut.callbackHead.load(moAcquire)
    if head == CallbackInlineInit:
      cpuRelax()
      continue
    var expected = head
    if fut.callbackHead.compareExchange(expected, CallbackClosed, moAcquireRelease, moAcquire):
      return head

proc fireCallbacks[T](fut: CpsFuture[T], head: pointer) {.inline.} =
  if head == CallbackInline:
    var cb = move(fut.inlineCallback)
    let rt {.cursor.} = fut.inlineTargetRuntime
    let worker = int(fut.inlineTargetWorker)
    fut.inlineTargetRuntime = nil
    if cb != nil:
      try:
        if rt == nil:
          cb()
        else:
          dispatchCallback(rt, worker, move(cb))
      except CatchableError:
        statInc(rtCallbackErrors)
    return
  var p = head
  while p != nil and p != CallbackClosed:
    let node = cast[ptr CallbackNode](p)
    p = node.next
    let thunk = cast[ptr SharedCallbackThunk](node.thunk)
    try:
      fireCallbackThunk(thunk)
    except CatchableError:
      statInc(rtCallbackErrors)
    finally:
      freeCallbackNode(node)

proc fireCallbacks(fut: CpsVoidFuture, head: pointer) {.inline.} =
  if head == CallbackInline:
    var cb = move(fut.inlineCallback)
    let rt {.cursor.} = fut.inlineTargetRuntime
    let worker = int(fut.inlineTargetWorker)
    fut.inlineTargetRuntime = nil
    if cb != nil:
      try:
        if rt == nil:
          cb()
        else:
          dispatchCallback(rt, worker, move(cb))
      except CatchableError:
        statInc(rtCallbackErrors)
    return
  var p = head
  while p != nil and p != CallbackClosed:
    let node = cast[ptr CallbackNode](p)
    p = node.next
    let thunk = cast[ptr SharedCallbackThunk](node.thunk)
    try:
      fireCallbackThunk(thunk)
    except CatchableError:
      statInc(rtCallbackErrors)
    finally:
      freeCallbackNode(node)

proc fireLocalCallback[T](fut: CpsFuture[T], targetRt: CpsRuntime,
                          cbArg: sink proc() {.closure.}) {.inline.} =
  var cb = move(cbArg)
  if cb == nil:
    return
  if targetRt == nil:
    try:
      cb()
    except CatchableError:
      statInc(rtCallbackErrors)
    return
  dispatchCallback(targetRt, fut.localOwnerWorkerId, move(cb))

proc fireLocalCallback(fut: CpsVoidFuture, targetRt: CpsRuntime,
                       cbArg: sink proc() {.closure.}) {.inline.} =
  var cb = move(cbArg)
  if cb == nil:
    return
  if targetRt == nil:
    try:
      cb()
    except CatchableError:
      statInc(rtCallbackErrors)
    return
  dispatchCallback(targetRt, fut.localOwnerWorkerId, move(cb))

proc fireLocalCallbacks[T](fut: CpsFuture[T]) =
  if fut.localCallbacks.len == 0:
    var inlineCb = move(fut.inlineCallback)
    if inlineCb == nil:
      return
    let inlineRt {.cursor.} = fut.inlineTargetRuntime
    fut.inlineTargetRuntime = nil
    fut.fireLocalCallback(inlineRt, move(inlineCb))
    return

  if fut.localCallbacks.len > 0:
    var i = fut.localCallbacks.len - 1
    while true:
      var thunk = move(fut.localCallbacks[i])
      fut.fireLocalCallback(thunk.targetRuntime, move(thunk.cb))
      if i == 0:
        break
      dec i
    fut.localCallbacks.setLen(0)
  var inlineCb = move(fut.inlineCallback)
  let inlineRt {.cursor.} = fut.inlineTargetRuntime
  fut.inlineCallback = nil
  fut.inlineTargetRuntime = nil
  fut.fireLocalCallback(inlineRt, move(inlineCb))

proc fireLocalCallbacks(fut: CpsVoidFuture) =
  if fut.localCallbacks.len == 0:
    var inlineCb = move(fut.inlineCallback)
    if inlineCb == nil:
      return
    let inlineRt {.cursor.} = fut.inlineTargetRuntime
    fut.inlineTargetRuntime = nil
    fut.fireLocalCallback(inlineRt, move(inlineCb))
    return

  if fut.localCallbacks.len > 0:
    var i = fut.localCallbacks.len - 1
    while true:
      var thunk = move(fut.localCallbacks[i])
      fut.fireLocalCallback(thunk.targetRuntime, move(thunk.cb))
      if i == 0:
        break
      dec i
    fut.localCallbacks.setLen(0)
  var inlineCb = move(fut.inlineCallback)
  let inlineRt {.cursor.} = fut.inlineTargetRuntime
  fut.inlineCallback = nil
  fut.inlineTargetRuntime = nil
  fut.fireLocalCallback(inlineRt, move(inlineCb))

proc wakeReactorIfNeeded(rt: CpsRuntime, workerId: int) {.inline.} =
  ## Wake only synchronous runtime waiters. Normal async completion already
  ## dispatches its callbacks directly or through the scheduler queue.
  if rt == nil or rt.waiters.load(moAcquire) <= 0:
    return
  if workerId >= 0 and rt.wakeIoShard != nil:
    rt.wakeIoShard(workerId)
  elif rt.wakeReactor != nil:
    rt.wakeReactor()

proc wakeRunCpsWaitersIfNeeded(rt: CpsRuntime) {.inline.} =
  if rt == nil:
    return
  if rt.waiters.load(moAcquire) > 0:
    statInc(rtRunCpsWakeSignals)
    discard rt.waitWakeSeq.fetchAdd(1'u64, moAcquireRelease)

proc completeLocal[T](fut: CpsFuture[T], val: T) {.noinline.} =
  ## Kept out of the shared completion path so its fallback closure is never
  ## allocated, retained, or retired on a foreign blocking worker.
  if not fut.localAffinityOk():
    let localVal = val
    if fut.tryHopLocalOpToOwner(proc() {.closure.} =
      complete(fut, localVal)
    ):
      return
    raiseLocalAffinityViolation("complete")
  if fut.localState != FutureStatePending:
    return
  fut.value = val
  fut.localState = FutureStateDone
  fut.rootContinuationPtr = nil
  statInc(rtCompletions)
  fut.fireLocalCallbacks()
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc completeLocal(fut: CpsVoidFuture) {.noinline.} =
  if not fut.localAffinityOk():
    if fut.tryHopLocalOpToOwner(proc() {.closure.} =
      complete(fut)
    ):
      return
    raiseLocalAffinityViolation("complete")
  if fut.localState != FutureStatePending:
    return
  fut.localState = FutureStateDone
  fut.rootContinuationPtr = nil
  statInc(rtCompletions)
  fut.fireLocalCallbacks()
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc complete*[T](fut: CpsFuture[T], val: T) =
  ## Complete the future and notify its waiters.
  if fut.perfMode == fpLocalFast:
    completeLocal(fut, val)
    return
  ## Complete a typed future with a value. Lock-free.
  ## 1. CAS state pending→completing (exclusive ownership)
  ## 2. Write payload
  ## 3. Store state done (release)
  ## 4. Drain callbacks
  var expected = FutureStatePending
  if not fut.atomicState.compareExchange(expected, FutureStateCompleting, moAcquireRelease, moAcquire):
    return
  fut.value = val
  fut.atomicState.store(FutureStateDone, moRelease)
  fut.rootContinuationPtr = nil
  statInc(rtCompletions)
  fireCallbacks(fut, closeAndTakeCallbackStack(fut))
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc complete*(fut: CpsVoidFuture) =
  ## Complete the future and notify its waiters.
  if fut.perfMode == fpLocalFast:
    completeLocal(fut)
    return
  ## Complete a void future. Lock-free.
  var expected = FutureStatePending
  if not fut.atomicState.compareExchange(expected, FutureStateCompleting, moAcquireRelease, moAcquire):
    return
  fut.atomicState.store(FutureStateDone, moRelease)
  fut.rootContinuationPtr = nil
  statInc(rtCompletions)
  fireCallbacks(fut, closeAndTakeCallbackStack(fut))
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc completeTransferred*[T](fut: CpsFuture[T], valArg: sink T) =
  ## Move a worker-owned value into a shared future without retaining and
  ## releasing that value on two ARC/ORC heaps.
  if fut.perfMode != fpSharedSafe:
    raise newException(RuntimeAffinityError,
      "completeTransferred requires a shared-safe future")
  var expected = FutureStatePending
  if not fut.atomicState.compareExchange(expected, FutureStateCompleting,
                                          moAcquireRelease, moAcquire):
    return
  var val = move(valArg)
  fut.value = move(val)
  fut.atomicState.store(FutureStateDone, moRelease)
  fut.rootContinuationPtr = nil
  statInc(rtCompletions)
  fireCallbacks(fut, closeAndTakeCallbackStack(fut))
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc failLocal[T](fut: CpsFuture[T], err: ref CatchableError) {.noinline.} =
  ## Isolate the local-future hop closure from the shared failure hot path.
  if not fut.localAffinityOk():
    let localErr = err
    if fut.tryHopLocalOpToOwner(proc() {.closure.} =
      fail(fut, localErr)
    ):
      return
    raiseLocalAffinityViolation("fail")
  if fut.localState != FutureStatePending:
    return
  fut.error = err
  fut.localState = FutureStateDone
  fut.rootContinuationPtr = nil
  statInc(rtFailures)
  fut.fireLocalCallbacks()
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc failLocal(fut: CpsVoidFuture,
               err: ref CatchableError) {.noinline.} =
  if not fut.localAffinityOk():
    let localErr = err
    if fut.tryHopLocalOpToOwner(proc() {.closure.} =
      fail(fut, localErr)
    ):
      return
    raiseLocalAffinityViolation("fail")
  if fut.localState != FutureStatePending:
    return
  fut.error = err
  fut.localState = FutureStateDone
  fut.rootContinuationPtr = nil
  statInc(rtFailures)
  fut.fireLocalCallbacks()
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc fail*[T](fut: CpsFuture[T], err: ref CatchableError) =
  ## Fail the future and notify its waiters.
  if fut.perfMode == fpLocalFast:
    failLocal(fut, err)
    return
  ## Fail a typed future with an error. Lock-free.
  var expected = FutureStatePending
  if not fut.atomicState.compareExchange(expected, FutureStateCompleting, moAcquireRelease, moAcquire):
    return
  fut.error = err
  fut.atomicState.store(FutureStateDone, moRelease)
  fut.rootContinuationPtr = nil
  statInc(rtFailures)
  fireCallbacks(fut, closeAndTakeCallbackStack(fut))
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc fail*(fut: CpsVoidFuture, err: ref CatchableError) =
  ## Fail the future and notify its waiters.
  if fut.perfMode == fpLocalFast:
    failLocal(fut, err)
    return
  ## Fail a void future with an error. Lock-free.
  var expected = FutureStatePending
  if not fut.atomicState.compareExchange(expected, FutureStateCompleting, moAcquireRelease, moAcquire):
    return
  fut.error = err
  fut.atomicState.store(FutureStateDone, moRelease)
  fut.rootContinuationPtr = nil
  statInc(rtFailures)
  fireCallbacks(fut, closeAndTakeCallbackStack(fut))
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc failTransferred*[T](fut: CpsFuture[T],
                         errArg: sink ref CatchableError) =
  ## Move a worker-owned error into a shared future without retaining and
  ## releasing the exception on two ARC/ORC heaps.
  if fut.perfMode != fpSharedSafe:
    raise newException(RuntimeAffinityError,
      "failTransferred requires a shared-safe future")
  var expected = FutureStatePending
  if not fut.atomicState.compareExchange(expected, FutureStateCompleting,
                                          moAcquireRelease, moAcquire):
    return
  var err = move(errArg)
  fut.error = move(err)
  fut.atomicState.store(FutureStateDone, moRelease)
  fut.rootContinuationPtr = nil
  statInc(rtFailures)
  fireCallbacks(fut, closeAndTakeCallbackStack(fut))
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc failTransferred*(fut: CpsVoidFuture,
                      errArg: sink ref CatchableError) =
  ## Move a worker-owned error into a shared void future without retaining and
  ## releasing the exception on two ARC/ORC heaps.
  if fut.perfMode != fpSharedSafe:
    raise newException(RuntimeAffinityError,
      "failTransferred requires a shared-safe future")
  var expected = FutureStatePending
  if not fut.atomicState.compareExchange(expected, FutureStateCompleting,
                                          moAcquireRelease, moAcquire):
    return
  var err = move(errArg)
  fut.error = move(err)
  fut.atomicState.store(FutureStateDone, moRelease)
  fut.rootContinuationPtr = nil
  statInc(rtFailures)
  fireCallbacks(fut, closeAndTakeCallbackStack(fut))
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc hasError*[T](fut: CpsFuture[T]): bool {.inline.} =
  ## Return whether the operation completed with an error.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("hasError")
  fut.error != nil

proc hasError*(fut: CpsVoidFuture): bool {.inline.} =
  ## Return whether the operation completed with an error.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("hasError")
  fut.error != nil

proc getError*[T](fut: CpsFuture[T]): ref CatchableError {.inline.} =
  ## Return the error that failed the future.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("getError")
  fut.error

proc getError*(fut: CpsVoidFuture): ref CatchableError {.inline.} =
  ## Return the error that failed the future.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("getError")
  fut.error

proc read*[T](fut: CpsFuture[T]): T =
  ## Return the completed future's value or raise its terminal error.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("read")
  assert fut.finished, "Future not yet completed"
  if fut.error != nil:
    raise fut.error
  result = fut.value

proc read*(fut: CpsVoidFuture) =
  ## Return the completed future's value or raise its terminal error.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("read")
  assert fut.finished, "Future not yet completed"
  if fut.error != nil:
    raise fut.error

proc fireCallbackInline(targetRt: CpsRuntime, targetWorker: int,
                        cb: proc() {.closure.}) {.inline.} =
  if targetRt == nil:
    try:
      cb()
    except CatchableError:
      statInc(rtCallbackErrors)
  else:
    dispatchCallback(targetRt, targetWorker, cb)

proc defaultCallbackRuntimePtr(): pointer {.inline.} =
  if currentRuntimeCtx != nil:
    return currentRuntimeCtx
  if gMainRuntimeCallbacksInlineFast.load(moAcquire) != 0:
    return nil
  gMainRuntimeFast.load(moAcquire)

proc callbackAffinity(targetRt: CpsRuntime,
                      cb: proc() {.closure.}): int {.inline.} =
  ## Keep every alias of one closure environment on one worker. ORC cycle
  ## roots are thread-local, so allowing aliases to retire on different
  ## workers is unsafe even when the queue transfer itself is move-only.
  if targetRt == nil or targetRt.flavor != rfMultiThread or
     targetRt.ioShardCount <= 0:
    return -1
  if isReactorThread and not isSchedulerWorker and
     currentRuntimeCtx == cast[pointer](targetRt):
    return MainReactorCallbackWorker
  var transferable = cb
  prepareCrossThreadClosure(transferable)
  if isSchedulerWorker and currentRuntimeCtx == cast[pointer](targetRt):
    return currentWorkerId
  var words: array[2, pointer]
  static: assert sizeof(cb) == sizeof(words)
  copyMem(addr words, unsafeAddr cb, sizeof(words))
  if words[1] == nil:
    return 0
  int((cast[uint](words[1]) shr 4) mod uint(targetRt.ioShardCount))

proc addCallbackOnRuntime[T](fut: CpsFuture[T], targetRt: CpsRuntime,
                             cbArg: sink proc() {.closure.}) {.inline.} =
  var cb = move(cbArg)
  if cb == nil:
    return
  let targetWorker = callbackAffinity(targetRt, cb)
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("addCallback")
    statInc(rtCallbacksRegistered)
    if fut.localState != FutureStatePending:
      fut.fireLocalCallback(targetRt, cb)
      return
    if fut.inlineCallback == nil and fut.localCallbacks.len == 0:
      fut.inlineCallback = move(cb)
      fut.inlineTargetRuntime = targetRt
      fut.inlineTargetWorker = int16(targetWorker)
      return
    fut.localCallbacks.add LocalCallbackThunk(cb: move(cb), targetRuntime: targetRt,
      targetWorker: int16(targetWorker))
    return
  statInc(rtCallbacksRegistered)
  while true:
    let head = fut.callbackHead.load(moAcquire)
    if head == CallbackClosed:
      fireCallbackInline(targetRt, targetWorker, cb)
      return

    if head == nil:
      var expectedNil = cast[pointer](nil)
      if fut.callbackHead.compareExchange(
        expectedNil,
        CallbackInlineInit,
        moAcquireRelease,
        moAcquire
      ):
        fut.inlineCallback = move(cb)
        fut.inlineTargetRuntime = targetRt
        fut.inlineTargetWorker = int16(targetWorker)
        fut.callbackHead.store(CallbackInline, moRelease)
        return
      continue

    if head == CallbackInlineInit:
      cpuRelax()
      continue

    if head == CallbackInline:
      var expectedInline = CallbackInline
      if not fut.callbackHead.compareExchange(
        expectedInline,
        CallbackInlineInit,
        moAcquireRelease,
        moAcquire
      ):
        if expectedInline == CallbackClosed:
          fireCallbackInline(targetRt, targetWorker, cb)
          return
        if expectedInline == CallbackInlineInit:
          cpuRelax()
        continue

      var oldCb = move(fut.inlineCallback)
      let oldRt {.cursor.} = fut.inlineTargetRuntime
      let oldWorker = int(fut.inlineTargetWorker)
      if oldCb == nil:
        fut.inlineCallback = move(cb)
        fut.inlineTargetRuntime = targetRt
        fut.inlineTargetWorker = int16(targetWorker)
        fut.callbackHead.store(CallbackInline, moRelease)
        return

      let oldThunk = allocCallbackThunk(move(oldCb), oldRt, oldWorker)
      let oldNode = allocCallbackNode(oldThunk)
      let newThunk = allocCallbackThunk(move(cb), targetRt, targetWorker)
      let newNode = allocCallbackNode(newThunk)
      newNode.next = cast[pointer](oldNode)
      fut.inlineCallback = nil
      fut.inlineTargetRuntime = nil
      fut.callbackHead.store(cast[pointer](newNode), moRelease)
      return

    let thunk = allocCallbackThunk(move(cb), targetRt, targetWorker)
    let node = allocCallbackNode(thunk)
    node.next = head
    var expected = head
    if fut.callbackHead.compareExchange(
      expected,
      cast[pointer](node),
      moAcquireRelease,
      moAcquire
    ):
      return
    freeCallbackNode(node)
    cb = takeCallbackProc(thunk)
    deallocShared(thunk)
    if expected == CallbackClosed:
      fireCallbackInline(targetRt, targetWorker, cb)
      return
    if expected == CallbackInlineInit:
      cpuRelax()

proc addCallbackOnRuntime(fut: CpsVoidFuture, targetRt: CpsRuntime,
                          cbArg: sink proc() {.closure.}) {.inline.} =
  var cb = move(cbArg)
  if cb == nil:
    return
  let targetWorker = callbackAffinity(targetRt, cb)
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("addCallback")
    statInc(rtCallbacksRegistered)
    if fut.localState != FutureStatePending:
      fut.fireLocalCallback(targetRt, cb)
      return
    if fut.inlineCallback == nil and fut.localCallbacks.len == 0:
      fut.inlineCallback = move(cb)
      fut.inlineTargetRuntime = targetRt
      fut.inlineTargetWorker = int16(targetWorker)
      return
    fut.localCallbacks.add LocalCallbackThunk(cb: move(cb), targetRuntime: targetRt,
      targetWorker: int16(targetWorker))
    return
  statInc(rtCallbacksRegistered)
  while true:
    let head = fut.callbackHead.load(moAcquire)
    if head == CallbackClosed:
      fireCallbackInline(targetRt, targetWorker, cb)
      return

    if head == nil:
      var expectedNil = cast[pointer](nil)
      if fut.callbackHead.compareExchange(
        expectedNil,
        CallbackInlineInit,
        moAcquireRelease,
        moAcquire
      ):
        fut.inlineCallback = move(cb)
        fut.inlineTargetRuntime = targetRt
        fut.inlineTargetWorker = int16(targetWorker)
        fut.callbackHead.store(CallbackInline, moRelease)
        return
      continue

    if head == CallbackInlineInit:
      cpuRelax()
      continue

    if head == CallbackInline:
      var expectedInline = CallbackInline
      if not fut.callbackHead.compareExchange(
        expectedInline,
        CallbackInlineInit,
        moAcquireRelease,
        moAcquire
      ):
        if expectedInline == CallbackClosed:
          fireCallbackInline(targetRt, targetWorker, cb)
          return
        if expectedInline == CallbackInlineInit:
          cpuRelax()
        continue

      var oldCb = move(fut.inlineCallback)
      let oldRt {.cursor.} = fut.inlineTargetRuntime
      let oldWorker = int(fut.inlineTargetWorker)
      if oldCb == nil:
        fut.inlineCallback = move(cb)
        fut.inlineTargetRuntime = targetRt
        fut.inlineTargetWorker = int16(targetWorker)
        fut.callbackHead.store(CallbackInline, moRelease)
        return

      let oldThunk = allocCallbackThunk(move(oldCb), oldRt, oldWorker)
      let oldNode = allocCallbackNode(oldThunk)
      let newThunk = allocCallbackThunk(move(cb), targetRt, targetWorker)
      let newNode = allocCallbackNode(newThunk)
      newNode.next = cast[pointer](oldNode)
      fut.inlineCallback = nil
      fut.inlineTargetRuntime = nil
      fut.callbackHead.store(cast[pointer](newNode), moRelease)
      return

    let thunk = allocCallbackThunk(move(cb), targetRt, targetWorker)
    let node = allocCallbackNode(thunk)
    node.next = head
    var expected = head
    if fut.callbackHead.compareExchange(
      expected,
      cast[pointer](node),
      moAcquireRelease,
      moAcquire
    ):
      return
    freeCallbackNode(node)
    cb = takeCallbackProc(thunk)
    deallocShared(thunk)
    if expected == CallbackClosed:
      fireCallbackInline(targetRt, targetWorker, cb)
      return
    if expected == CallbackInlineInit:
      cpuRelax()

proc addCallbackOn*[T](fut: CpsFuture[T], rt: RuntimeHandle,
                       cb: sink proc() {.closure.}) {.inline.} =
  ## Register a callback on the future's owning runtime.
  addCallbackOnRuntime(fut, rt.runtime, move(cb))

proc addCallbackOn*(fut: CpsVoidFuture, rt: RuntimeHandle,
                    cb: sink proc() {.closure.}) {.inline.} =
  ## Register a callback on the future's owning runtime.
  addCallbackOnRuntime(fut, rt.runtime, move(cb))

proc addCallback*[T](fut: CpsFuture[T],
                     cb: sink proc() {.closure.}) {.inline.} =
  ## Register a callback to run when the future completes.
  addCallbackOnRuntime(fut,
    cast[CpsRuntime](defaultCallbackRuntimePtr()), move(cb))

proc addCallback*(fut: CpsVoidFuture,
                  cb: sink proc() {.closure.}) {.inline.} =
  ## Register a callback to run when the future completes.
  addCallbackOnRuntime(fut,
    cast[CpsRuntime](defaultCallbackRuntimePtr()), move(cb))

proc ensureShared*[T](fut: CpsFuture[T]) =
  ## Promote the future to shared-safe state before it crosses a thread boundary.
  if fut.perfMode == fpSharedSafe:
    return
  fut.ensureLocalAffinity("ensureShared")
  let localState = fut.localState
  var inlineCb = move(fut.inlineCallback)
  let inlineRt {.cursor.} = fut.inlineTargetRuntime
  var localCbs = move(fut.localCallbacks)

  fut.perfMode = fpSharedSafe
  fut.localOwnerThreadToken = nil
  fut.localOwnerSchedulerPtr = nil
  fut.localCallbacks.setLen(0)
  fut.inlineCallback = nil
  fut.inlineTargetRuntime = nil

  case localState
  of FutureStatePending:
    fut.atomicState.store(FutureStatePending, moRelaxed)
    fut.callbackHead.store(nil, moRelaxed)
    if inlineCb != nil:
      addCallbackOnRuntime(fut, inlineRt, move(inlineCb))
    if localCbs.len > 0:
      for thunk in mitems(localCbs):
        if thunk.cb != nil:
          addCallbackOnRuntime(fut, thunk.targetRuntime, move(thunk.cb))
  of FutureStateCancelled:
    fut.atomicState.store(FutureStateCancelled, moRelaxed)
    fut.callbackHead.store(CallbackClosed, moRelaxed)
  else:
    fut.atomicState.store(FutureStateDone, moRelaxed)
    fut.callbackHead.store(CallbackClosed, moRelaxed)

proc ensureShared*(fut: CpsVoidFuture) =
  ## Promote the future to shared-safe state before it crosses a thread boundary.
  if fut.perfMode == fpSharedSafe:
    return
  fut.ensureLocalAffinity("ensureShared")
  let localState = fut.localState
  var inlineCb = move(fut.inlineCallback)
  let inlineRt {.cursor.} = fut.inlineTargetRuntime
  var localCbs = move(fut.localCallbacks)

  fut.perfMode = fpSharedSafe
  fut.localOwnerThreadToken = nil
  fut.localOwnerSchedulerPtr = nil
  fut.localCallbacks.setLen(0)
  fut.inlineCallback = nil
  fut.inlineTargetRuntime = nil

  case localState
  of FutureStatePending:
    fut.atomicState.store(FutureStatePending, moRelaxed)
    fut.callbackHead.store(nil, moRelaxed)
    if inlineCb != nil:
      addCallbackOnRuntime(fut, inlineRt, move(inlineCb))
    if localCbs.len > 0:
      for thunk in mitems(localCbs):
        if thunk.cb != nil:
          addCallbackOnRuntime(fut, thunk.targetRuntime, move(thunk.cb))
  of FutureStateCancelled:
    fut.atomicState.store(FutureStateCancelled, moRelaxed)
    fut.callbackHead.store(CallbackClosed, moRelaxed)
  else:
    fut.atomicState.store(FutureStateDone, moRelaxed)
    fut.callbackHead.store(CallbackClosed, moRelaxed)

# ============================================================
# Cancellation
# ============================================================

proc isCancelled*[T](fut: CpsFuture[T]): bool {.inline.} =
  ## Check if a future has been cancelled.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("isCancelled")
    return fut.localState == FutureStateCancelled
  fut.atomicState.load(moAcquire) == FutureStateCancelled

proc isCancelled*(fut: CpsVoidFuture): bool {.inline.} =
  ## Check if a void future has been cancelled.
  if fut.perfMode == fpLocalFast:
    fut.ensureLocalAffinity("isCancelled")
    return fut.localState == FutureStateCancelled
  fut.atomicState.load(moAcquire) == FutureStateCancelled

proc cancel*[T](fut: CpsFuture[T]) =
  ## Cancel runtime and notify its waiters.
  if fut.perfMode == fpLocalFast:
    if not fut.localAffinityOk():
      if fut.tryHopLocalOpToOwner(proc() {.closure.} =
        cancel(fut)
      ):
        return
      raiseLocalAffinityViolation("cancel")
    if fut.localState != FutureStatePending:
      return
    fut.error = newException(CancellationError, "cancelled")
    fut.localState = FutureStateCancelled
    fut.rootContinuationPtr = nil
    statInc(rtCancellations)
    fut.fireLocalCallbacks()
    wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
    wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)
    return
  ## Cancel a future. If the future is already completed, this is a no-op.
  ## Uses CAS to atomically transition from pending to cancelling, then
  ## publishes cancelled terminal state after setting the error payload.
  var expected = FutureStatePending
  if not fut.atomicState.compareExchange(expected, FutureStateCancelling, moAcquireRelease, moAcquire):
    return  # already completed or cancelled — no state mutation
  fut.error = newException(CancellationError, "cancelled")
  fut.atomicState.store(FutureStateCancelled, moRelease)
  fut.rootContinuationPtr = nil
  statInc(rtCancellations)
  fireCallbacks(fut, closeAndTakeCallbackStack(fut))
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

proc cancel*(fut: CpsVoidFuture) =
  ## Cancel runtime and notify its waiters.
  if fut.perfMode == fpLocalFast:
    if not fut.localAffinityOk():
      if fut.tryHopLocalOpToOwner(proc() {.closure.} =
        cancel(fut)
      ):
        return
      raiseLocalAffinityViolation("cancel")
    if fut.localState != FutureStatePending:
      return
    fut.error = newException(CancellationError, "cancelled")
    fut.localState = FutureStateCancelled
    fut.rootContinuationPtr = nil
    statInc(rtCancellations)
    fut.fireLocalCallbacks()
    wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
    wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)
    return
  ## Cancel a void future. If the future is already completed, this is a no-op.
  ## Uses CAS to atomically transition from pending to cancelling, then
  ## publishes cancelled terminal state after setting error payload.
  var expected = FutureStatePending
  if not fut.atomicState.compareExchange(expected, FutureStateCancelling, moAcquireRelease, moAcquire):
    return  # already completed or cancelled — no state mutation
  fut.error = newException(CancellationError, "cancelled")
  fut.atomicState.store(FutureStateCancelled, moRelease)
  fut.rootContinuationPtr = nil
  statInc(rtCancellations)
  fireCallbacks(fut, closeAndTakeCallbackStack(fut))
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut), fut.localOwnerWorkerId)

# ============================================================
# Atomic counter for thread-safe waitAll / allTasks
# ============================================================

type
  AtomicCounter* = object
    value*: Atomic[int]
    failed*: Atomic[bool]

proc newAtomicCounter*(initial: int): ptr AtomicCounter =
  ## Create a new atomic counter.
  result = cast[ptr AtomicCounter](allocShared0(sizeof(AtomicCounter)))
  result.value.store(initial, moRelaxed)
  result.failed.store(false, moRelaxed)

proc freeAtomicCounter*(c: ptr AtomicCounter) =
  ## Release resources owned by atomic counter.
  deallocShared(c)

# ============================================================
# Typed environment helpers
# ============================================================

template setContinuation*(env: Continuation, nextFn: untyped) =
  ## Set the next step function on a continuation.
  env.fn = nextFn

# ============================================================
# Race / Select combinators
# ============================================================

type
  RaceFlag = ref object
    ## Atomic once-flag for race/raceCancel/select combinators.
    ## Uses Atomic[bool] with compareExchange for MT safety.
    value: Atomic[bool]

proc newRaceFlag(): RaceFlag =
  result = RaceFlag()
  result.value.store(false)

proc race*[T](futures: varargs[CpsFuture[T]]): CpsFuture[T] =
  ## Returns a future that completes with the value of the first
  ## input future to complete. If that future has an error, the
  ## error propagates. Non-winning futures are left running.
  let count = futures.len
  if count == 0:
    return failedFuture[T](newException(ValueError, "race called with no futures"))
  let resultFut = newCpsFuture[T]()
  # Shared atomic once-flag so only the first completion wins.
  let triggered = newRaceFlag()
  # Check for already-completed futures first
  for i in 0 ..< count:
    let fut = futures[i]
    if fut.finished:
      var expected = false
      if triggered.value.compareExchange(expected, true):
        if fut.hasError:
          fail(resultFut, fut.getError)
        else:
          complete(resultFut, fut.read)
      return resultFut
  # Register callbacks via closure factory to avoid loop capture gotcha
  proc makeRaceCallback(fut: CpsFuture[T], resFut: CpsFuture[T],
                         flag: RaceFlag): proc() {.closure.} =
    result = proc() =
      var expected = false
      if flag.value.compareExchange(expected, true):
        if fut.hasError:
          fail(resFut, fut.getError)
        else:
          complete(resFut, fut.read)
  for i in 0 ..< count:
    let fut = futures[i]
    fut.addCallback(makeRaceCallback(fut, resultFut, triggered))
  result = resultFut

proc race*(futures: varargs[CpsVoidFuture]): CpsVoidFuture =
  ## Returns a void future that completes when the first input future
  ## completes. If that future has an error, the error propagates.
  let count = futures.len
  if count == 0:
    return failedVoidFuture(newException(ValueError, "race called with no futures"))
  let resultFut = newCpsVoidFuture()
  let triggered = newRaceFlag()
  for i in 0 ..< count:
    let fut = futures[i]
    if fut.finished:
      var expected = false
      if triggered.value.compareExchange(expected, true):
        if fut.hasError:
          fail(resultFut, fut.getError)
        else:
          complete(resultFut)
      return resultFut
  proc makeRaceCallback(fut: CpsVoidFuture, resFut: CpsVoidFuture,
                         flag: RaceFlag): proc() {.closure.} =
    result = proc() =
      var expected = false
      if flag.value.compareExchange(expected, true):
        if fut.hasError:
          fail(resFut, fut.getError)
        else:
          complete(resFut)
  for i in 0 ..< count:
    let fut = futures[i]
    fut.addCallback(makeRaceCallback(fut, resultFut, triggered))
  result = resultFut

proc select*[T](futures: varargs[CpsFuture[T]]): CpsFuture[tuple[index: int, value: T]] =
  ## Returns a future that completes with (index, value) of the first
  ## input future to complete. The index indicates which future won.
  let count = futures.len
  if count == 0:
    return failedFuture[tuple[index: int, value: T]](newException(ValueError, "select called with no futures"))
  let resultFut = newCpsFuture[tuple[index: int, value: T]]()
  let triggered = newRaceFlag()
  for i in 0 ..< count:
    let fut = futures[i]
    if fut.finished:
      var expected = false
      if triggered.value.compareExchange(expected, true):
        if fut.hasError:
          fail(resultFut, fut.getError)
        else:
          complete(resultFut, (index: i, value: fut.read))
      return resultFut
  proc makeSelectCallback(fut: CpsFuture[T],
                           resFut: CpsFuture[tuple[index: int, value: T]],
                           flag: RaceFlag, idx: int): proc() {.closure.} =
    result = proc() =
      var expected = false
      if flag.value.compareExchange(expected, true):
        if fut.hasError:
          fail(resFut, fut.getError)
        else:
          complete(resFut, (index: idx, value: fut.read))
  for i in 0 ..< count:
    let fut = futures[i]
    fut.addCallback(makeSelectCallback(fut, resultFut, triggered, i))
  result = resultFut

proc raceCancel*[T](futures: varargs[CpsFuture[T]]): CpsFuture[T] =
  ## Like race, but cancels all non-winning futures after the winner
  ## is determined. Uses the existing cancel() which is a no-op on
  ## already-completed futures.
  let count = futures.len
  if count == 0:
    return failedFuture[T](newException(ValueError, "raceCancel called with no futures"))
  let resultFut = newCpsFuture[T]()
  # Need to keep a copy of all futures so we can cancel losers
  var allFuts = newSeq[CpsFuture[T]](count)
  for i in 0 ..< count:
    allFuts[i] = futures[i]
  let triggered = newRaceFlag()
  # Check for already-completed futures first
  for i in 0 ..< count:
    let fut = allFuts[i]
    if fut.finished:
      var expected = false
      if triggered.value.compareExchange(expected, true):
        if fut.hasError:
          fail(resultFut, fut.getError)
        else:
          complete(resultFut, fut.read)
        # Cancel all other futures
        for j in 0 ..< count:
          if j != i:
            cancel(allFuts[j])
      return resultFut
  proc makeRaceCancelCallback(fut: CpsFuture[T], resFut: CpsFuture[T],
                               flag: RaceFlag, idx: int,
                               futs: seq[CpsFuture[T]]): proc() {.closure.} =
    result = proc() =
      var expected = false
      if flag.value.compareExchange(expected, true):
        if fut.hasError:
          fail(resFut, fut.getError)
        else:
          complete(resFut, fut.read)
        # Cancel all other futures
        for j in 0 ..< futs.len:
          if j != idx:
            cancel(futs[j])
  for i in 0 ..< count:
    let fut = allFuts[i]
    fut.addCallback(makeRaceCancelCallback(fut, resultFut, triggered, i, allFuts))
  result = resultFut

proc raceCancel*(futures: varargs[CpsVoidFuture]): CpsVoidFuture =
  ## Like race for void futures, but cancels all non-winning futures
  ## after the winner is determined.
  let count = futures.len
  if count == 0:
    return failedVoidFuture(newException(ValueError, "raceCancel called with no futures"))
  let resultFut = newCpsVoidFuture()
  var allFuts = newSeq[CpsVoidFuture](count)
  for i in 0 ..< count:
    allFuts[i] = futures[i]
  let triggered = newRaceFlag()
  for i in 0 ..< count:
    let fut = allFuts[i]
    if fut.finished:
      var expected = false
      if triggered.value.compareExchange(expected, true):
        if fut.hasError:
          fail(resultFut, fut.getError)
        else:
          complete(resultFut)
        for j in 0 ..< count:
          if j != i:
            cancel(allFuts[j])
      return resultFut
  proc makeRaceCancelCallback(fut: CpsVoidFuture, resFut: CpsVoidFuture,
                               flag: RaceFlag, idx: int,
                               futs: seq[CpsVoidFuture]): proc() {.closure.} =
    result = proc() =
      var expected = false
      if flag.value.compareExchange(expected, true):
        if fut.hasError:
          fail(resFut, fut.getError)
        else:
          complete(resFut)
        for j in 0 ..< futs.len:
          if j != idx:
            cancel(futs[j])
  for i in 0 ..< count:
    let fut = allFuts[i]
    fut.addCallback(makeRaceCancelCallback(fut, resultFut, triggered, i, allFuts))
  result = resultFut
