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

type
  CancellationError* = object of CatchableError
    ## Raised when a future or task is cancelled.

  ContinuationState* = enum
    csRunning    ## Currently executing
    csSuspended  ## Waiting for external event (I/O, timer, etc.)
    csFinished   ## Completed successfully
    csError      ## Completed with an error

  Continuation* = ref object of RootObj
    ## Base type for all CPS continuations.
    ## Concrete continuations inherit from this and add their local state.
    fn*: proc(c: sink Continuation): Continuation {.nimcall.}
      ## The next step to execute. Returns the next continuation, or nil if done.
    state*: ContinuationState
    runtimeOwner*: CpsRuntime

  RuntimeFlavor* = enum
    rfCurrentThread
    rfMultiThread

  RuntimeConfig* = object
    flavor*: RuntimeFlavor
    numWorkers*: int
    numBlockingThreads*: int
    maxSchedulerQueue*: int
    maxBlockingQueue*: int

  CpsRuntime* = ref object
    ## Owning runtime object (Tokio-like Runtime).
    id*: int64
    flavor*: RuntimeFlavor
    eventLoopPtr*: RootRef
    schedulerPtr*: RootRef
    blockingPoolPtr*: RootRef
    callbackDispatcher*: proc(cb: proc() {.closure.}) {.closure, gcsafe.}
    yieldDispatcher*: proc(cb: proc() {.closure, gcsafe.}) {.closure, gcsafe.}
    wakeReactor*: proc() {.closure, gcsafe.}
    waitWakeSeq: Atomic[uint64]
    waitInitState: Atomic[int]  ## 0=uninit, 1=initializing, 2=ready
    waiters: Atomic[int]
    mtActive*: bool

  RuntimeHandle* = object
    ## Cloneable lightweight runtime reference (Tokio-like Handle).
    runtime*: CpsRuntime

  RuntimeGuard* = object
    ## Scoped enter guard restoring prior runtime context.
    prev*: CpsRuntime
    active*: bool

  RuntimeAffinityError* = object of CatchableError
    ## Raised when a future/resource cannot move across runtimes.

  Trampoline* = object
    ## Drives a continuation chain to completion without stack growth.
    current: Continuation

  CallbackThunk = ref object
    cb: proc() {.closure.}
    targetRuntime: CpsRuntime

  CallbackNode = object
    next: pointer
    thunk: pointer

  CpsFuture*[T] = ref object
    ## A future value produced by a CPS computation.
    ## Uses atomic state + lock-free callback stack.
    value: T
    error: ref CatchableError
    atomicState: Atomic[int]      ## 0=pending, 1=done, 2=cancelled, 3=completing, 4=cancelling
    callbackHead: Atomic[pointer]
    inlineCallback: proc() {.closure.}
    inlineTargetRuntime: CpsRuntime
    ownerRuntime*: CpsRuntime
    runtimePinned: Atomic[bool]
    rootContinuationPtr: pointer

  CpsVoidFuture* = ref object
    ## A future for void-returning CPS computations.
    ## Uses atomic state + lock-free callback stack.
    error: ref CatchableError
    atomicState: Atomic[int]      ## 0=pending, 1=done, 2=cancelled, 3=completing, 4=cancelling
    callbackHead: Atomic[pointer]
    inlineCallback: proc() {.closure.}
    inlineTargetRuntime: CpsRuntime
    ownerRuntime*: CpsRuntime
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
  DefaultSchedulerQueueCap = 65536
  DefaultBlockingQueueCap = 65536

type
  RuntimeStats* = object
    completions*: int
    failures*: int
    cancellations*: int
    callbacksRegistered*: int
    callbacksFired*: int
    callbackNodesAllocated*: int
    callbackNodesFreed*: int
    runCpsWaits*: int
    runCpsWakeSignals*: int

proc isTerminalFutureState(state: int): bool {.inline.} =
  state == FutureStateDone or state == FutureStateCancelled

var rtCompletions: Atomic[int]
var rtFailures: Atomic[int]
var rtCancellations: Atomic[int]
var rtCallbacksRegistered: Atomic[int]
var rtCallbacksFired: Atomic[int]
var rtCallbackNodesAllocated: Atomic[int]
var rtCallbackNodesFreed: Atomic[int]
var rtRunCpsWaits: Atomic[int]
var rtRunCpsWakeSignals: Atomic[int]

const RuntimeStatsEnabled = defined(cpsRuntimeStats)

template statInc(counter: untyped) =
  when RuntimeStatsEnabled:
    discard counter.fetchAdd(1, moRelaxed)

proc getRuntimeStats*(): RuntimeStats =
  RuntimeStats(
    completions: rtCompletions.load(moRelaxed),
    failures: rtFailures.load(moRelaxed),
    cancellations: rtCancellations.load(moRelaxed),
    callbacksRegistered: rtCallbacksRegistered.load(moRelaxed),
    callbacksFired: rtCallbacksFired.load(moRelaxed),
    callbackNodesAllocated: rtCallbackNodesAllocated.load(moRelaxed),
    callbackNodesFreed: rtCallbackNodesFreed.load(moRelaxed),
    runCpsWaits: rtRunCpsWaits.load(moRelaxed),
    runCpsWakeSignals: rtRunCpsWakeSignals.load(moRelaxed)
  )

proc resetRuntimeStats*() =
  rtCompletions.store(0, moRelaxed)
  rtFailures.store(0, moRelaxed)
  rtCancellations.store(0, moRelaxed)
  rtCallbacksRegistered.store(0, moRelaxed)
  rtCallbacksFired.store(0, moRelaxed)
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
var gMainRuntime: CpsRuntime = nil
var gMainRuntimeFast: Atomic[pointer]
var gMainRuntimeCallbacksInlineFast: Atomic[int]
var gNextRuntimeId: Atomic[int64]
var gMtRuntimeFactory: MtRuntimeFactoryProc = nil

var currentRuntimeCtx {.threadvar.}: CpsRuntime
var currentSchedulerPtr* {.threadvar.}: pointer

var mtModeEnabled* {.threadvar.}: bool
var mtDispatcher* {.threadvar.}: proc(c: sink Continuation) {.nimcall, gcsafe.}
var mtCallbackDispatcher*: proc(cb: proc() {.closure.}) {.closure, gcsafe.} = nil
var mtYieldDispatcher*: proc(cb: proc() {.closure, gcsafe.}) {.closure, gcsafe.} = nil
var mtWakeReactor*: proc() {.closure, gcsafe.} = nil
var isSchedulerWorker* {.threadvar.}: bool
var isReactorThread* {.threadvar.}: bool

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

proc loadMainRuntimeFast(): CpsRuntime {.inline.} =
  cast[CpsRuntime](gMainRuntimeFast.load(moAcquire))

proc storeMainRuntimeFast(rt: CpsRuntime) {.inline.} =
  gMainRuntimeFast.store(cast[pointer](rt), moRelease)
  if rt == nil or (rt.flavor == rfCurrentThread and rt.callbackDispatcher == nil):
    gMainRuntimeCallbacksInlineFast.store(1, moRelease)
  else:
    gMainRuntimeCallbacksInlineFast.store(0, moRelease)

proc nextRuntimeId(): int64 {.inline.} =
  gNextRuntimeId.fetchAdd(1'i64, moAcquireRelease) + 1'i64

proc applyCompatMtHooks(rt: CpsRuntime) {.inline.} =
  if rt != nil and rt.flavor == rfMultiThread:
    mtModeEnabled = true
    mtCallbackDispatcher = rt.callbackDispatcher
    mtYieldDispatcher = rt.yieldDispatcher
    mtWakeReactor = rt.wakeReactor
  else:
    mtModeEnabled = false
    mtCallbackDispatcher = nil
    mtYieldDispatcher = nil
    mtWakeReactor = nil

proc defaultRuntimeConfig*(): RuntimeConfig =
  RuntimeConfig(
    flavor: rfCurrentThread,
    numWorkers: 0,
    numBlockingThreads: 0,
    maxSchedulerQueue: DefaultSchedulerQueueCap,
    maxBlockingQueue: DefaultBlockingQueueCap
  )

proc toHandle*(rt: CpsRuntime): RuntimeHandle {.inline.} =
  RuntimeHandle(runtime: rt)

proc isNil*(h: RuntimeHandle): bool {.inline.} =
  h.runtime.isNil

proc runtimeId*(h: RuntimeHandle): int64 {.inline.} =
  if h.runtime.isNil: 0 else: h.runtime.id

proc runtimeFlavor*(h: RuntimeHandle): RuntimeFlavor {.inline.} =
  if h.runtime.isNil: rfCurrentThread else: h.runtime.flavor

proc setCurrentRuntime*(rt: CpsRuntime) =
  currentRuntimeCtx = rt
  applyCompatMtHooks(rt)

proc tryCurrentRuntime*(): RuntimeHandle =
  toHandle(currentRuntimeCtx)

proc newCurrentThreadRuntime*(): CpsRuntime =
  result = CpsRuntime()
  result.id = nextRuntimeId()
  result.flavor = rfCurrentThread
  result.eventLoopPtr = nil
  result.schedulerPtr = nil
  result.blockingPoolPtr = nil
  result.callbackDispatcher = nil
  result.yieldDispatcher = nil
  result.wakeReactor = nil
  result.waitInitState.store(0, moRelaxed)
  result.waiters.store(0, moRelaxed)
  result.waitWakeSeq.store(0'u64, moRelaxed)
  result.mtActive = false

proc registerMtRuntimeFactory*(factory: MtRuntimeFactoryProc) =
  gMtRuntimeFactory = factory

proc newMultiThreadRuntime*(numWorkers: int = 0,
                            numBlockingThreads: int = 0,
                            maxSchedulerQueue: int = DefaultSchedulerQueueCap,
                            maxBlockingQueue: int = DefaultBlockingQueueCap): CpsRuntime =
  if gMtRuntimeFactory == nil:
    raise newException(ValueError, "MT runtime factory not registered; import cps/mt first")
  let cfg = RuntimeConfig(
    flavor: rfMultiThread,
    numWorkers: numWorkers,
    numBlockingThreads: numBlockingThreads,
    maxSchedulerQueue: maxSchedulerQueue,
    maxBlockingQueue: maxBlockingQueue
  )
  result = gMtRuntimeFactory(cfg)

proc newRuntime*(config: RuntimeConfig): CpsRuntime =
  case config.flavor
  of rfCurrentThread:
    result = newCurrentThreadRuntime()
  of rfMultiThread:
    result = newMultiThreadRuntime(
      numWorkers = config.numWorkers,
      numBlockingThreads = config.numBlockingThreads,
      maxSchedulerQueue = config.maxSchedulerQueue,
      maxBlockingQueue = config.maxBlockingQueue
    )

proc ensureMainRuntime(): CpsRuntime =
  let fast = loadMainRuntimeFast()
  if fast != nil:
    return fast
  ensureRuntimeLockReady()
  acquire(gRuntimeLock)
  if gMainRuntime == nil:
    gMainRuntime = newCurrentThreadRuntime()
    storeMainRuntimeFast(gMainRuntime)
  result = gMainRuntime
  release(gRuntimeLock)

proc setMainRuntime*(rt: CpsRuntime) =
  ensureRuntimeLockReady()
  acquire(gRuntimeLock)
  gMainRuntime = rt
  storeMainRuntimeFast(rt)
  release(gRuntimeLock)

proc mainRuntime*(): RuntimeHandle =
  toHandle(ensureMainRuntime())

proc currentRuntime*(): RuntimeHandle =
  if currentRuntimeCtx != nil:
    toHandle(currentRuntimeCtx)
  else:
    let fast = loadMainRuntimeFast()
    if fast != nil:
      toHandle(fast)
    else:
      mainRuntime()

proc enter*(handle: RuntimeHandle): RuntimeGuard =
  if handle.runtime == nil:
    raise newException(ValueError, "Cannot enter a nil runtime handle")
  result.prev = currentRuntimeCtx
  result.active = true
  setCurrentRuntime(handle.runtime)

proc leave*(guard: var RuntimeGuard) =
  if not guard.active:
    return
  guard.active = false
  setCurrentRuntime(guard.prev)

template withRuntime*(handle: RuntimeHandle, body: untyped): untyped =
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
  ensureRuntimeWaitReady(rt)
  if rt != nil:
    discard rt.waiters.fetchAdd(1, moAcquireRelease)

proc runCpsWaitLeave*(rt: CpsRuntime) {.inline.} =
  if rt != nil:
    discard rt.waiters.fetchSub(1, moAcquireRelease)

proc runCpsWaitEnter*() {.inline.} =
  runCpsWaitEnter(currentRuntime().runtime)

proc runCpsWaitLeave*() {.inline.} =
  runCpsWaitLeave(currentRuntime().runtime)

proc waitRunCpsSignal*[T](rt: CpsRuntime, fut: CpsFuture[T]) =
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
  let rt = if fut.ownerRuntime != nil: fut.ownerRuntime else: currentRuntime().runtime
  waitRunCpsSignal(rt, fut)

proc waitRunCpsSignal*(fut: CpsVoidFuture) =
  let rt = if fut.ownerRuntime != nil: fut.ownerRuntime else: currentRuntime().runtime
  waitRunCpsSignal(rt, fut)

# ============================================================
# Continuation lifecycle
# ============================================================

proc newContinuation*(T: typedesc[Continuation],
                      fn: proc(c: sink Continuation): Continuation {.nimcall.}): T =
  result = T()
  result.fn = fn
  result.state = csRunning
  result.runtimeOwner = currentRuntime().runtime

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
  c.fn != nil

proc isFinished*(c: Continuation): bool {.inline.} =
  c.state in {csFinished, csError}

proc isSuspended*(c: Continuation): bool {.inline.} =
  c.state == csSuspended

# ============================================================
# Trampoline - stack-safe execution
# ============================================================

proc initTrampoline*(c: sink Continuation): Trampoline {.inline.} =
  Trampoline(current: c)

proc bounce*(t: var Trampoline): bool {.inline.} =
  ## Execute one step. Returns true if there are more steps.
  if t.current.isNil or t.current.fn.isNil:
    return false
  let fn = t.current.fn
  t.current = fn(t.current)
  result = not t.current.isNil and not t.current.fn.isNil

proc run*(c: sink Continuation): Continuation {.discardable.} =
  ## Run a continuation chain to completion or suspension via trampoline.
  ## Uses a direct while loop — no Trampoline struct overhead.
  if mtDispatcher != nil:
    mtDispatcher(c)
    return nil
  let targetRt = if c != nil: c.runtimeOwner else: nil
  let prevRt = currentRuntimeCtx
  if targetRt != nil and targetRt != prevRt:
    setCurrentRuntime(targetRt)
  try:
    result = c
    while not result.isNil and not result.fn.isNil:
      let fn = result.fn
      result = fn(result)
  finally:
    if targetRt != nil and targetRt != prevRt:
      setCurrentRuntime(prevRt)

proc runUntilSuspend*(c: sink Continuation): Continuation =
  ## Run until the continuation suspends or finishes.
  let targetRt = if c != nil: c.runtimeOwner else: nil
  let prevRt = currentRuntimeCtx
  if targetRt != nil and targetRt != prevRt:
    setCurrentRuntime(targetRt)
  try:
    result = c
    while not result.isNil and not result.fn.isNil:
      let fn = result.fn
      result = fn(result)
  finally:
    if targetRt != nil and targetRt != prevRt:
      setCurrentRuntime(prevRt)

# ============================================================
# CpsFuture[T] operations
# ============================================================

proc newCpsFuture*[T](): CpsFuture[T] =
  result = CpsFuture[T]()
  # Atomic[int] zero-initializes to 0 (pending). No lock needed.
  result.ownerRuntime = nil

proc newCpsVoidFuture*(): CpsVoidFuture =
  result = CpsVoidFuture()
  # Atomic[int] zero-initializes to 0 (pending). No lock needed.
  result.ownerRuntime = nil

proc completedFuture*[T](val: T): CpsFuture[T] =
  ## Create a future that is already completed with a value.
  ## Uses relaxed store (no CAS needed since the future hasn't been shared yet).
  result = CpsFuture[T](value: val, ownerRuntime: nil)
  result.atomicState.store(FutureStateDone, moRelaxed)

proc completedVoidFuture*(): CpsVoidFuture =
  ## Create a void future that is already completed.
  result = CpsVoidFuture(ownerRuntime: nil)
  result.atomicState.store(FutureStateDone, moRelaxed)

proc failedFuture*[T](err: ref CatchableError): CpsFuture[T] =
  ## Create a future that is already failed with an error.
  result = CpsFuture[T](error: err, ownerRuntime: nil)
  result.atomicState.store(FutureStateDone, moRelaxed)

proc failedVoidFuture*(err: ref CatchableError): CpsVoidFuture =
  ## Create a void future that is already failed with an error.
  result = CpsVoidFuture(error: err, ownerRuntime: nil)
  result.atomicState.store(FutureStateDone, moRelaxed)

proc finished*[T](fut: CpsFuture[T]): bool {.inline.} =
  ## Check if the future has completed (successfully or with error).
  isTerminalFutureState(fut.atomicState.load(moAcquire))

proc finished*(fut: CpsVoidFuture): bool {.inline.} =
  ## Check if the void future has completed (successfully or with error).
  isTerminalFutureState(fut.atomicState.load(moAcquire))

proc ownerRuntimeRef[T](fut: CpsFuture[T]): CpsRuntime {.inline.} =
  fut.ownerRuntime

proc ownerRuntimeRef(fut: CpsVoidFuture): CpsRuntime {.inline.} =
  fut.ownerRuntime

proc futureRuntime*[T](fut: CpsFuture[T]): RuntimeHandle {.inline.} =
  toHandle(ownerRuntimeRef(fut))

proc futureRuntime*(fut: CpsVoidFuture): RuntimeHandle {.inline.} =
  toHandle(ownerRuntimeRef(fut))

proc bindFutureRuntime*[T](fut: CpsFuture[T], handle: RuntimeHandle) {.inline.} =
  fut.ownerRuntime = handle.runtime

proc bindFutureRuntime*(fut: CpsVoidFuture, handle: RuntimeHandle) {.inline.} =
  fut.ownerRuntime = handle.runtime

proc setFutureRootContinuation*[T](fut: CpsFuture[T], c: Continuation) {.inline.} =
  fut.rootContinuationPtr = cast[pointer](c)
  if c != nil and c.runtimeOwner != nil:
    fut.ownerRuntime = c.runtimeOwner

proc setFutureRootContinuation*(fut: CpsVoidFuture, c: Continuation) {.inline.} =
  fut.rootContinuationPtr = cast[pointer](c)
  if c != nil and c.runtimeOwner != nil:
    fut.ownerRuntime = c.runtimeOwner

proc pinFutureRuntime*[T](fut: CpsFuture[T]) {.inline.} =
  if fut.ownerRuntime == nil:
    let rt = currentRuntimeCtx
    if rt != nil:
      fut.ownerRuntime = rt
    else:
      let fast = loadMainRuntimeFast()
      if fast != nil:
        fut.ownerRuntime = fast
      else:
        fut.ownerRuntime = ensureMainRuntime()
  fut.runtimePinned.store(true, moRelease)

proc pinFutureRuntime*(fut: CpsVoidFuture) {.inline.} =
  if fut.ownerRuntime == nil:
    let rt = currentRuntimeCtx
    if rt != nil:
      fut.ownerRuntime = rt
    else:
      let fast = loadMainRuntimeFast()
      if fast != nil:
        fut.ownerRuntime = fast
      else:
        fut.ownerRuntime = ensureMainRuntime()
  fut.runtimePinned.store(true, moRelease)

proc isRuntimePinned*[T](fut: CpsFuture[T]): bool {.inline.} =
  fut.runtimePinned.load(moAcquire)

proc isRuntimePinned*(fut: CpsVoidFuture): bool {.inline.} =
  fut.runtimePinned.load(moAcquire)

proc tryMigrateTo*[T](fut: CpsFuture[T], handle: RuntimeHandle): bool =
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
  if not tryMigrateTo(fut, handle):
    raise newException(RuntimeAffinityError,
      "cannot migrate future to runtime " & $handle.runtimeId() &
      ": future is runtime-pinned")

proc migrateTo*(fut: CpsVoidFuture, handle: RuntimeHandle) =
  if not tryMigrateTo(fut, handle):
    raise newException(RuntimeAffinityError,
      "cannot migrate future to runtime " & $handle.runtimeId() &
      ": future is runtime-pinned")

proc isCurrentRuntimeWorker(rt: CpsRuntime): bool {.inline.} =
  rt != nil and isSchedulerWorker and currentSchedulerPtr != nil and
    currentSchedulerPtr == cast[pointer](rt.schedulerPtr)

proc dispatchCallback(rt: CpsRuntime, cb: proc() {.closure.}) {.inline.} =
  ## Fire a single callback on the target runtime, dispatching to workers
  ## when the runtime has a scheduler dispatcher configured.
  statInc(rtCallbacksFired)
  if rt != nil and rt.callbackDispatcher != nil and not isCurrentRuntimeWorker(rt):
    let targetRt = rt
    {.cast(gcsafe).}:
      rt.callbackDispatcher(proc() {.closure.} =
        let prevRt = currentRuntimeCtx
        setCurrentRuntime(targetRt)
        try:
          cb()
        finally:
          setCurrentRuntime(prevRt)
      )
  else:
    let prevRt = currentRuntimeCtx
    var mustEnter = rt != nil and rt != prevRt
    # ST fast path: if this callback targets the default current-thread
    # runtime and no explicit runtime is entered, avoid enter/leave churn.
    if mustEnter and prevRt == nil and rt.flavor == rfCurrentThread and rt == loadMainRuntimeFast():
      mustEnter = false
    if mustEnter:
      setCurrentRuntime(rt)
    try:
      cb()
    finally:
      if mustEnter:
        setCurrentRuntime(prevRt)

proc allocCallbackThunk(cb: proc() {.closure.}, targetRt: CpsRuntime): CallbackThunk {.inline.} =
  result = CallbackThunk(cb: cb, targetRuntime: targetRt)
  GC_ref(result)

proc allocCallbackNode(thunk: CallbackThunk): ptr CallbackNode {.inline.} =
  result = cast[ptr CallbackNode](allocShared0(sizeof(CallbackNode)))
  result.next = nil
  result.thunk = cast[pointer](thunk)
  statInc(rtCallbackNodesAllocated)

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
    let cb = fut.inlineCallback
    let rt = fut.inlineTargetRuntime
    fut.inlineCallback = nil
    fut.inlineTargetRuntime = nil
    if cb != nil:
      if rt == nil:
        cb()
      else:
        dispatchCallback(rt, cb)
    return
  var p = head
  var firstErr: ref CatchableError = nil
  while p != nil and p != CallbackClosed:
    let node = cast[ptr CallbackNode](p)
    p = node.next
    let thunk = cast[CallbackThunk](node.thunk)
    try:
      if thunk != nil:
        if thunk.targetRuntime == nil:
          thunk.cb()
        else:
          dispatchCallback(thunk.targetRuntime, thunk.cb)
    except CatchableError as e:
      if firstErr == nil:
        firstErr = e
    finally:
      if thunk != nil:
        GC_unref(thunk)
      freeCallbackNode(node)
  if firstErr != nil:
    raise firstErr

proc fireCallbacks(fut: CpsVoidFuture, head: pointer) {.inline.} =
  if head == CallbackInline:
    let cb = fut.inlineCallback
    let rt = fut.inlineTargetRuntime
    fut.inlineCallback = nil
    fut.inlineTargetRuntime = nil
    if cb != nil:
      if rt == nil:
        cb()
      else:
        dispatchCallback(rt, cb)
    return
  var p = head
  var firstErr: ref CatchableError = nil
  while p != nil and p != CallbackClosed:
    let node = cast[ptr CallbackNode](p)
    p = node.next
    let thunk = cast[CallbackThunk](node.thunk)
    try:
      if thunk != nil:
        if thunk.targetRuntime == nil:
          thunk.cb()
        else:
          dispatchCallback(thunk.targetRuntime, thunk.cb)
    except CatchableError as e:
      if firstErr == nil:
        firstErr = e
    finally:
      if thunk != nil:
        GC_unref(thunk)
      freeCallbackNode(node)
  if firstErr != nil:
    raise firstErr

proc wakeReactorIfNeeded(rt: CpsRuntime) {.inline.} =
  if rt != nil and rt.wakeReactor != nil:
    rt.wakeReactor()

proc wakeRunCpsWaitersIfNeeded(rt: CpsRuntime) {.inline.} =
  if rt == nil:
    return
  if rt.waiters.load(moAcquire) > 0:
    statInc(rtRunCpsWakeSignals)
    discard rt.waitWakeSeq.fetchAdd(1'u64, moAcquireRelease)

proc complete*[T](fut: CpsFuture[T], val: T) =
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
  wakeReactorIfNeeded(ownerRuntimeRef(fut))

proc complete*(fut: CpsVoidFuture) =
  ## Complete a void future. Lock-free.
  var expected = FutureStatePending
  if not fut.atomicState.compareExchange(expected, FutureStateCompleting, moAcquireRelease, moAcquire):
    return
  fut.atomicState.store(FutureStateDone, moRelease)
  fut.rootContinuationPtr = nil
  statInc(rtCompletions)
  fireCallbacks(fut, closeAndTakeCallbackStack(fut))
  wakeRunCpsWaitersIfNeeded(ownerRuntimeRef(fut))
  wakeReactorIfNeeded(ownerRuntimeRef(fut))

proc fail*[T](fut: CpsFuture[T], err: ref CatchableError) =
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
  wakeReactorIfNeeded(ownerRuntimeRef(fut))

proc fail*(fut: CpsVoidFuture, err: ref CatchableError) =
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
  wakeReactorIfNeeded(ownerRuntimeRef(fut))

proc hasError*[T](fut: CpsFuture[T]): bool {.inline.} =
  fut.error != nil

proc hasError*(fut: CpsVoidFuture): bool {.inline.} =
  fut.error != nil

proc getError*[T](fut: CpsFuture[T]): ref CatchableError {.inline.} =
  fut.error

proc getError*(fut: CpsVoidFuture): ref CatchableError {.inline.} =
  fut.error

proc read*[T](fut: CpsFuture[T]): T =
  assert fut.finished, "Future not yet completed"
  if fut.error != nil:
    raise fut.error
  result = fut.value

proc fireCallbackInline(targetRt: CpsRuntime, cb: proc() {.closure.}) {.inline.} =
  if targetRt == nil:
    cb()
  else:
    dispatchCallback(targetRt, cb)

proc defaultCallbackRuntime(): CpsRuntime {.inline.} =
  let rt = currentRuntimeCtx
  if rt != nil:
    return rt
  if gMainRuntimeCallbacksInlineFast.load(moAcquire) != 0:
    return nil
  result = loadMainRuntimeFast()

proc addCallbackOnRuntime[T](fut: CpsFuture[T], targetRt: CpsRuntime, cb: proc() {.closure.}) {.inline.} =
  statInc(rtCallbacksRegistered)
  while true:
    let head = fut.callbackHead.load(moAcquire)
    if head == CallbackClosed:
      fireCallbackInline(targetRt, cb)
      return

    if head == nil:
      var expectedNil = cast[pointer](nil)
      if fut.callbackHead.compareExchange(
        expectedNil,
        CallbackInlineInit,
        moAcquireRelease,
        moAcquire
      ):
        fut.inlineCallback = cb
        fut.inlineTargetRuntime = targetRt
        fut.callbackHead.store(CallbackInline, moRelease)
        return
      continue

    if head == CallbackInlineInit:
      cpuRelax()
      continue

    if head == CallbackInline:
      let oldThunk = allocCallbackThunk(fut.inlineCallback, fut.inlineTargetRuntime)
      let oldNode = allocCallbackNode(oldThunk)
      let newThunk = allocCallbackThunk(cb, targetRt)
      let newNode = allocCallbackNode(newThunk)
      newNode.next = cast[pointer](oldNode)
      var expectedInline = CallbackInline
      if fut.callbackHead.compareExchange(
        expectedInline,
        cast[pointer](newNode),
        moAcquireRelease,
        moAcquire
      ):
        fut.inlineCallback = nil
        fut.inlineTargetRuntime = nil
        return

      freeCallbackNode(newNode)
      GC_unref(newThunk)
      freeCallbackNode(oldNode)
      GC_unref(oldThunk)

      if expectedInline == CallbackClosed:
        fireCallbackInline(targetRt, cb)
        return
      if expectedInline == CallbackInlineInit:
        cpuRelax()
      continue

    let thunk = allocCallbackThunk(cb, targetRt)
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
    GC_unref(thunk)
    if expected == CallbackClosed:
      fireCallbackInline(targetRt, cb)
      return
    if expected == CallbackInlineInit:
      cpuRelax()

proc addCallbackOnRuntime(fut: CpsVoidFuture, targetRt: CpsRuntime, cb: proc() {.closure.}) {.inline.} =
  statInc(rtCallbacksRegistered)
  while true:
    let head = fut.callbackHead.load(moAcquire)
    if head == CallbackClosed:
      fireCallbackInline(targetRt, cb)
      return

    if head == nil:
      var expectedNil = cast[pointer](nil)
      if fut.callbackHead.compareExchange(
        expectedNil,
        CallbackInlineInit,
        moAcquireRelease,
        moAcquire
      ):
        fut.inlineCallback = cb
        fut.inlineTargetRuntime = targetRt
        fut.callbackHead.store(CallbackInline, moRelease)
        return
      continue

    if head == CallbackInlineInit:
      cpuRelax()
      continue

    if head == CallbackInline:
      let oldThunk = allocCallbackThunk(fut.inlineCallback, fut.inlineTargetRuntime)
      let oldNode = allocCallbackNode(oldThunk)
      let newThunk = allocCallbackThunk(cb, targetRt)
      let newNode = allocCallbackNode(newThunk)
      newNode.next = cast[pointer](oldNode)
      var expectedInline = CallbackInline
      if fut.callbackHead.compareExchange(
        expectedInline,
        cast[pointer](newNode),
        moAcquireRelease,
        moAcquire
      ):
        fut.inlineCallback = nil
        fut.inlineTargetRuntime = nil
        return

      freeCallbackNode(newNode)
      GC_unref(newThunk)
      freeCallbackNode(oldNode)
      GC_unref(oldThunk)

      if expectedInline == CallbackClosed:
        fireCallbackInline(targetRt, cb)
        return
      if expectedInline == CallbackInlineInit:
        cpuRelax()
      continue

    let thunk = allocCallbackThunk(cb, targetRt)
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
    GC_unref(thunk)
    if expected == CallbackClosed:
      fireCallbackInline(targetRt, cb)
      return
    if expected == CallbackInlineInit:
      cpuRelax()

proc addCallbackOn*[T](fut: CpsFuture[T], rt: RuntimeHandle, cb: proc() {.closure.}) {.inline.} =
  addCallbackOnRuntime(fut, rt.runtime, cb)

proc addCallbackOn*(fut: CpsVoidFuture, rt: RuntimeHandle, cb: proc() {.closure.}) {.inline.} =
  addCallbackOnRuntime(fut, rt.runtime, cb)

proc addCallback*[T](fut: CpsFuture[T], cb: proc() {.closure.}) {.inline.} =
  addCallbackOnRuntime(fut, defaultCallbackRuntime(), cb)

proc addCallback*(fut: CpsVoidFuture, cb: proc() {.closure.}) {.inline.} =
  addCallbackOnRuntime(fut, defaultCallbackRuntime(), cb)

# ============================================================
# Cancellation
# ============================================================

proc isCancelled*[T](fut: CpsFuture[T]): bool {.inline.} =
  ## Check if a future has been cancelled.
  fut.atomicState.load(moAcquire) == FutureStateCancelled

proc isCancelled*(fut: CpsVoidFuture): bool {.inline.} =
  ## Check if a void future has been cancelled.
  fut.atomicState.load(moAcquire) == FutureStateCancelled

proc cancel*[T](fut: CpsFuture[T]) =
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
  wakeReactorIfNeeded(ownerRuntimeRef(fut))

proc cancel*(fut: CpsVoidFuture) =
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
  wakeReactorIfNeeded(ownerRuntimeRef(fut))

# ============================================================
# Atomic counter for thread-safe waitAll / allTasks
# ============================================================

type
  AtomicCounter* = object
    value*: Atomic[int]
    failed*: Atomic[bool]

proc newAtomicCounter*(initial: int): ptr AtomicCounter =
  result = cast[ptr AtomicCounter](allocShared0(sizeof(AtomicCounter)))
  result.value.store(initial, moRelaxed)
  result.failed.store(false, moRelaxed)

proc freeAtomicCounter*(c: ptr AtomicCounter) =
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
