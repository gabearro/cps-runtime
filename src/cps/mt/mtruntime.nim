## CPS Multithreaded Runtime (Work-Stealing)
##
## Provides a Tokio-like multi-threaded runtime:
## - Reactor thread: handles I/O + timers via the event loop
## - N worker threads: trampoline CPS continuations with work-stealing
## - Blocking thread pool: for spawnBlocking (separate from workers)

when not defined(gcAtomicArc) and not defined(useMalloc):
  {.error: "MT CPS runtime requires --mm:atomicArc (recommended) or -d:useMalloc for thread-safe ref counting. ORC's non-atomic refcounting causes double-free/SIGSEGV when continuations cross thread boundaries.".}

import std/[posix, locks, atomics, sysatomics]
import ../runtime
import ../eventloop
import ../private/mpsc_queue
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
    while mtRuntimeLockInit.load(moAcquire) != 2:
      cpuRelax()

proc asScheduler(rt: CpsRuntime): Scheduler {.inline.} =
  if rt == nil or rt.schedulerPtr == nil:
    return nil
  cast[Scheduler](cast[pointer](rt.schedulerPtr))

proc asBlockingPool(rt: CpsRuntime): ThreadPool {.inline.} =
  if rt == nil or rt.blockingPoolPtr == nil:
    return nil
  cast[ThreadPool](cast[pointer](rt.blockingPoolPtr))

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
      let loop = cast[EventLoop](cast[pointer](rt.eventLoopPtr))
      if loop != nil:
        loop.tryWakeSelector()

proc makeCallbackDispatcher(rt: CpsRuntime): proc(cb: proc() {.closure.}) {.closure, gcsafe.} =
  result = proc(cb: proc() {.closure.}) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let sched = asScheduler(rt)
      if sched != nil:
        let task = cast[SchedulerTask](cb)
        sched.schedule(task)

proc makeYieldDispatcher(rt: CpsRuntime): proc(cb: proc() {.closure, gcsafe.}) {.closure, gcsafe.} =
  result = proc(cb: proc() {.closure, gcsafe.}) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let sched = asScheduler(rt)
      if sched != nil:
        sched.schedule(cb)

proc setupMtReactor(loop: EventLoop) =
  ## Configure wake pipe + cross-thread queue for MT reactor operation.
  var pipeFds: array[2, cint]
  if posix.pipe(pipeFds) != 0:
    raise newException(OSError, "Failed to create wake pipe")
  loop.wakePipeRead = pipeFds[0]
  loop.wakePipeWrite = pipeFds[1]

  let readFlags = posix.fcntl(loop.wakePipeRead, F_GETFL, 0)
  discard posix.fcntl(loop.wakePipeRead, F_SETFL, readFlags or O_NONBLOCK)
  let writeFlags = posix.fcntl(loop.wakePipeWrite, F_GETFL, 0)
  discard posix.fcntl(loop.wakePipeWrite, F_SETFL, writeFlags or O_NONBLOCK)

  let wakeCb: proc() {.closure.} = proc() =
    var buf: array[64, byte]
    while posix.read(loop.wakePipeRead.cint, addr buf[0], 64) > 0:
      discard
    loop.recordWakeSignal()
    loop.markWakeDrained()
    loop.drainCrossThreadQueue()
  loop.registerRead(loop.wakePipeRead.int, wakeCb)

  initMpscQueue(loop.crossThreadQueue)

proc createMtRuntime(config: RuntimeConfig): CpsRuntime {.nimcall.} =
  ## Factory used by runtime.newMultiThreadRuntime().
  ensureMtRuntimeLockReady()
  acquire(mtRuntimeLock)
  try:
    let rt = newCurrentThreadRuntime()
    rt.flavor = rfMultiThread
    rt.mtActive = true

    let loop = newEventLoop()
    loop.mtActive = true
    loop.ownerRuntime = rt
    rt.eventLoopPtr = cast[RootRef](cast[pointer](loop))

    setupMtReactor(loop)

    let sched = newScheduler(rt, config.numWorkers, config.maxSchedulerQueue)
    rt.schedulerPtr = cast[RootRef](cast[pointer](sched))

    rt.callbackDispatcher = makeCallbackDispatcher(rt)
    rt.yieldDispatcher = makeYieldDispatcher(rt)
    rt.wakeReactor = makeWakeDispatcher(rt)

    let workerSetup = proc() {.gcsafe.} =
      {.cast(gcsafe).}:
        setCurrentRuntime(rt)
    let pool = newThreadPool(config.numBlockingThreads, workerSetup, config.maxBlockingQueue)
    rt.blockingPoolPtr = cast[RootRef](cast[pointer](pool))

    result = rt
  finally:
    release(mtRuntimeLock)

type
  WorkerError = object
    ## Value type for transferring error info across threads.
    msg: string
    typeName: string

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
  result = cast[EventLoop](cast[pointer](rt.eventLoopPtr))

proc spawnBlockingOn*[T](handle: RuntimeHandle, body: proc(): T {.gcsafe.}): CpsFuture[T] =
  ## Offload blocking work to a runtime's blocking pool.
  let rt = runtimeFromHandle(handle)
  let pool = asBlockingPool(rt)
  assert rt != nil and rt.flavor == rfMultiThread and pool != nil,
    "MT runtime not initialized for this handle"

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
        GC_unref(fut)
    except CatchableError as e:
      let errInfo = WorkerError(msg: e.msg, typeName: $e.name)
      {.cast(gcsafe).}:
        let newErr = newException(CatchableError, errInfo.msg)
        newErr.msg = errInfo.typeName & ": " & errInfo.msg
        fut.fail(newErr)
        GC_unref(fut)
  )
  result = fut

proc spawnBlockingOn*(handle: RuntimeHandle, body: proc() {.gcsafe.}): CpsVoidFuture =
  ## Offload blocking void work to a runtime's blocking pool.
  let rt = runtimeFromHandle(handle)
  let pool = asBlockingPool(rt)
  assert rt != nil and rt.flavor == rfMultiThread and pool != nil,
    "MT runtime not initialized for this handle"

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
        GC_unref(fut)
    except CatchableError as e:
      let errInfo = WorkerError(msg: e.msg, typeName: $e.name)
      {.cast(gcsafe).}:
        let newErr = newException(CatchableError, errInfo.msg)
        newErr.msg = errInfo.typeName & ": " & errInfo.msg
        fut.fail(newErr)
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

    let loop = cast[EventLoop](cast[pointer](rt.eventLoopPtr))
    if loop != nil and loop.wakePipeRead >= 0:
      try:
        loop.unregister(loop.wakePipeRead.int)
      except Exception:
        discard
      discard posix.close(loop.wakePipeRead)
      discard posix.close(loop.wakePipeWrite)
      loop.wakePipeRead = -1
      loop.wakePipeWrite = -1

      while true:
        let node = dequeue(loop.crossThreadQueue)
        if node == nil:
          break
        freeNode(node)
      loop.mtActive = false
      loop.markWakeDrained()

    rt.callbackDispatcher = nil
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
  if curRt != nil and cast[EventLoop](cast[pointer](curRt.eventLoopPtr)) == loop:
    shutdownMtRuntime(curRt)
    return

  let mainRt = mainRuntime().runtime
  if mainRt != nil and cast[EventLoop](cast[pointer](mainRt.eventLoopPtr)) == loop:
    shutdownMtRuntime(mainRt)

registerMtRuntimeFactory(createMtRuntime)
