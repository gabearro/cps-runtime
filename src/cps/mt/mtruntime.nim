## CPS Multithreaded Runtime (Work-Stealing)
##
## Provides a Tokio-like multi-threaded runtime:
## - Reactor thread: handles I/O + timers via the event loop
## - N worker threads: trampoline CPS continuations with work-stealing
## - Blocking thread pool: for spawnBlocking (separate from workers)

when not defined(gcAtomicArc) and not defined(useMalloc):
  {.error: "MT CPS runtime requires --mm:atomicArc (recommended) or -d:useMalloc for thread-safe ref counting. ORC's non-atomic refcounting causes double-free/SIGSEGV when continuations cross thread boundaries.".}

import std/[locks, atomics, sysatomics, os]
import ../runtime
import ../eventloop
import ./threadpool
import ./scheduler

export eventloop, threadpool, scheduler

var mtRuntimeLock: Lock
var mtRuntimeLockInit: Atomic[int]  ## 0=uninit, 1=initializing, 2=ready

proc ensureMtRuntimeLockReady() {.inline.} =
  if mtRuntimeLockInit.load(moAcquire) == 2:
    return
  var expected = 0
  if mtRuntimeLockInit.compareExchange(expected, 1, moAcquireRelease, moAcquire):
    initLock(mtRuntimeLock)
    mtRuntimeLockInit.store(2, moRelease)
  else:
    var spins = 0
    while mtRuntimeLockInit.load(moAcquire) != 2:
      inc spins
      if spins < 64:
        cpuRelax()
      else:
        sleep(0)  # yield CPU — init should complete quickly

proc asScheduler(rt: CpsRuntime): Scheduler {.inline.} =
  if rt == nil or rt.schedulerPtr == nil:
    return nil
  cast[Scheduler](cast[pointer](rt.schedulerPtr))

proc asBlockingPool(rt: CpsRuntime): ThreadPool {.inline.} =
  if rt == nil or rt.blockingPoolPtr == nil:
    return nil
  cast[ThreadPool](cast[pointer](rt.blockingPoolPtr))

proc asEventLoop(rt: CpsRuntime): EventLoop {.inline.} =
  if rt == nil or rt.eventLoopPtr == nil:
    return nil
  cast[EventLoop](cast[pointer](rt.eventLoopPtr))

proc ensureBlockingPool(rt: CpsRuntime): ThreadPool =
  ## Lazily create the blocking pool. Most asynchronous applications never
  ## submit blocking work, so starting another CPU-sized thread set at runtime
  ## initialization wastes memory and scheduler resources.
  result = asBlockingPool(rt)
  if result != nil:
    return
  ensureMtRuntimeLockReady()
  acquire(mtRuntimeLock)
  try:
    if not rt.mtActive:
      return nil
    result = asBlockingPool(rt)
    if result == nil:
      let workerSetup = proc() {.gcsafe.} =
        {.cast(gcsafe).}:
          setCurrentRuntime(rt)
      result = newThreadPool(rt.blockingThreadCount, workerSetup,
                             rt.maxBlockingQueue)
      rt.blockingPoolPtr = cast[RootRef](cast[pointer](result))
  finally:
    release(mtRuntimeLock)

proc runtimeFromHandle(handle: RuntimeHandle): CpsRuntime {.inline.} =
  if handle.runtime != nil:
    return handle.runtime
  let cur = currentRuntime().runtime
  if cur != nil:
    return cur
  mainRuntime().runtime

proc makeWakeDispatcher(rt: CpsRuntime): proc() {.closure, gcsafe.} =
  result = proc() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let loop = asEventLoop(rt)
      if loop != nil:
        loop.tryWakeSelector()

proc makeCallbackDispatcher(rt: CpsRuntime): proc(cb: proc() {.closure.}) {.closure, gcsafe.} =
  result = proc(cb: proc() {.closure.}) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let sched = asScheduler(rt)
      if sched != nil:
        let task = cast[SchedulerTask](cb)
        sched.schedule(task)

proc makeContinuationDispatcher(rt: CpsRuntime):
    proc(c: sink Continuation) {.closure, gcsafe.} =
  result = proc(c: sink Continuation) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let sched = asScheduler(rt)
      if sched == nil or c == nil:
        return
      let continuation = c
      sched.schedule(proc() {.closure, gcsafe.} =
        {.cast(gcsafe).}:
          discard runUntilSuspend(continuation)
      )

proc makePinnedCallbackDispatcher(rt: CpsRuntime): proc(workerId: int, cb: proc() {.closure.}): bool {.closure, gcsafe.} =
  result = proc(workerId: int, cb: proc() {.closure.}): bool {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let sched = asScheduler(rt)
      if sched == nil:
        return false
      let task = cast[SchedulerTask](cb)
      sched.schedulePinned(workerId, task)

proc makeYieldDispatcher(rt: CpsRuntime): proc(cb: proc() {.closure, gcsafe.}) {.closure, gcsafe.} =
  result = proc(cb: proc() {.closure, gcsafe.}) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let sched = asScheduler(rt)
      if sched != nil:
        sched.schedule(cb)

proc createMtRuntime(config: RuntimeConfig): CpsRuntime {.nimcall.} =
  ## Factory used by runtime.newMultiThreadRuntime().
  ensureMtRuntimeLockReady()
  acquire(mtRuntimeLock)
  try:
    let rt = newCurrentThreadRuntime()
    rt.flavor = rfMultiThread
    rt.mtActive = true
    rt.blockingThreadCount = config.numBlockingThreads
    rt.maxBlockingQueue = config.maxBlockingQueue

    let loop = newEventLoop()
    loop.mtActive = true
    loop.ownerRuntime = rt
    rt.eventLoopPtr = cast[RootRef](cast[pointer](loop))

    loop.enableCrossThreadWake()

    let sched = newScheduler(rt, config.numWorkers, config.maxSchedulerQueue)
    rt.schedulerPtr = cast[RootRef](cast[pointer](sched))

    rt.continuationDispatcher = makeContinuationDispatcher(rt)
    rt.callbackDispatcher = makeCallbackDispatcher(rt)
    rt.pinnedCallbackDispatcher = makePinnedCallbackDispatcher(rt)
    rt.yieldDispatcher = makeYieldDispatcher(rt)
    rt.wakeReactor = makeWakeDispatcher(rt)

    result = rt
  finally:
    release(mtRuntimeLock)

proc captureWorkerError(e: ref CatchableError): ref CatchableError {.inline.} =
  ## Reconstruct an exception as a value-safe copy for cross-thread transfer.
  let msg = $e.name & ": " & e.msg
  result = newException(CatchableError, msg)

proc initMtRuntime*(numWorkers: int = 0,
                    numBlockingThreads: int = 0,
                    maxSchedulerQueue: int = 65536,
                    maxBlockingQueue: int = 65536): EventLoop =
  ## Compatibility wrapper: create an MT runtime and install it as main/current.
  let rt = newMultiThreadRuntime(
    numWorkers = numWorkers,
    numBlockingThreads = numBlockingThreads,
    maxSchedulerQueue = maxSchedulerQueue,
    maxBlockingQueue = maxBlockingQueue
  )
  setMainRuntime(rt)
  setCurrentRuntime(rt)
  isReactorThread = true
  result = asEventLoop(rt)

proc spawnBlockingOn*[T](handle: RuntimeHandle, body: proc(): T {.gcsafe.}): CpsFuture[T] =
  ## Offload blocking work to a runtime's blocking pool.
  let rt = runtimeFromHandle(handle)
  if rt == nil or rt.flavor != rfMultiThread:
    raise newException(ValueError, "MT runtime not initialized for this handle")
  let pool = ensureBlockingPool(rt)
  if pool == nil:
    raise newException(ValueError, "MT runtime is shutting down")

  let fut = newCpsFuture[T]()
  fut.bindFutureRuntime(toHandle(rt))
  GC_ref(fut)
  pool.submit(proc() {.gcsafe.} =
    {.cast(gcsafe).}:
      setCurrentRuntime(rt)
    try:
      let val = body()
      {.cast(gcsafe).}:
        fut.complete(val)
    except CatchableError as e:
      {.cast(gcsafe).}:
        fut.fail(captureWorkerError(e))
    finally:
      {.cast(gcsafe).}:
        GC_unref(fut)
  )
  result = fut

proc spawnBlockingOn*(handle: RuntimeHandle, body: proc() {.gcsafe.}): CpsVoidFuture =
  ## Offload blocking void work to a runtime's blocking pool.
  let rt = runtimeFromHandle(handle)
  if rt == nil or rt.flavor != rfMultiThread:
    raise newException(ValueError, "MT runtime not initialized for this handle")
  let pool = ensureBlockingPool(rt)
  if pool == nil:
    raise newException(ValueError, "MT runtime is shutting down")

  let fut = newCpsVoidFuture()
  fut.bindFutureRuntime(toHandle(rt))
  GC_ref(fut)
  pool.submit(proc() {.gcsafe.} =
    {.cast(gcsafe).}:
      setCurrentRuntime(rt)
    try:
      body()
      {.cast(gcsafe).}:
        fut.complete()
    except CatchableError as e:
      {.cast(gcsafe).}:
        fut.fail(captureWorkerError(e))
    finally:
      {.cast(gcsafe).}:
        GC_unref(fut)
  )
  result = fut

proc spawnBlocking*[T](body: proc(): T {.gcsafe.}): CpsFuture[T] =
  spawnBlockingOn(currentRuntime(), body)

proc spawnBlocking*(body: proc() {.gcsafe.}): CpsVoidFuture =
  spawnBlockingOn(currentRuntime(), body)

proc shutdownMtRuntime*(rt: CpsRuntime) =
  ## Shut down one MT runtime instance.
  if rt == nil or rt.flavor != rfMultiThread:
    return

  ensureMtRuntimeLockReady()
  acquire(mtRuntimeLock)
  try:
    let sched = asScheduler(rt)
    if sched != nil:
      shutdownScheduler(sched)
      rt.schedulerPtr = nil

    let pool = asBlockingPool(rt)
    if pool != nil:
      pool.shutdown()
      rt.blockingPoolPtr = nil

    let loop = asEventLoop(rt)
    if loop != nil:
      loop.disableCrossThreadWake()

    rt.continuationDispatcher = nil
    rt.callbackDispatcher = nil
    rt.pinnedCallbackDispatcher = nil
    rt.yieldDispatcher = nil
    rt.wakeReactor = nil
    rt.mtActive = false

    if currentRuntime().runtime == rt:
      setCurrentRuntime(mainRuntime().runtime)
      isReactorThread = false
  finally:
    release(mtRuntimeLock)

proc shutdownMtRuntime*(loop: EventLoop) =
  ## Compatibility wrapper for existing call sites.
  let curRt = currentRuntime().runtime
  if curRt != nil and asEventLoop(curRt) == loop:
    shutdownMtRuntime(curRt)
    return

  let mainRt = mainRuntime().runtime
  if mainRt != nil and asEventLoop(mainRt) == loop:
    shutdownMtRuntime(mainRt)

registerMtRuntimeFactory(createMtRuntime)
