## CPS Multithreaded Runtime (Work-Stealing)
##
## Provides a Tokio-like multi-threaded runtime:
## - N worker threads: each owns an I/O selector and CPS task queues
## - Thread-affine I/O: readiness and continuations stay on their owning shard
## - Work-stealing: idle workers can still balance CPU continuations
## - Blocking thread pool: for spawnBlocking (separate from workers)

when not compileOption("gc", "atomicArc") and
     not compileOption("gc", "arc") and
     not compileOption("gc", "orc"):
  {.error: "newMultiThreadRuntime requires --mm:arc, --mm:orc, or --mm:atomicArc.".}

import std/[locks, atomics, sysatomics, os, cpuinfo]
import ../runtime
import ../eventloop
import ./threadpool
import ./scheduler

export eventloop, threadpool, scheduler

when compileOption("gc", "orc"):
  {.pragma: cpsMtShardAcyclic, acyclic.}
else:
  {.pragma: cpsMtShardAcyclic.}

type
  MtIoSetup* = proc(shardId: int) {.nimcall, gcsafe.}
    ## Initialize I/O resources owned by one MT scheduler worker.

  MtIoShardSet {.cpsMtShardAcyclic.} = ref object of RootObj
    runtime {.cursor.}: CpsRuntime
    loops: seq[EventLoop]

  MtIoStartState = object
    started: Atomic[int]
    failed: Atomic[bool]

const MtIoDrainHandleThreshold = 16

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

template asScheduler(rt: CpsRuntime): Scheduler =
  cast[Scheduler](if rt == nil: nil else: cast[pointer](rt.schedulerPtr))

template asBlockingPool(rt: CpsRuntime): ThreadPool =
  cast[ThreadPool](if rt == nil: nil else: cast[pointer](rt.blockingPoolPtr))

template asEventLoop(rt: CpsRuntime): EventLoop =
  cast[EventLoop](if rt == nil: nil else: cast[pointer](rt.eventLoopPtr))

template asIoShardSet(rt: CpsRuntime): MtIoShardSet =
  cast[MtIoShardSet](if rt == nil: nil else: cast[pointer](rt.ioShardSetPtr))

proc ioShardSetup(ctx: pointer, workerId: int) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let shards = cast[MtIoShardSet](ctx)
    let loop = shards.loops[workerId]
    loop.claimCurrentThread()
    bindCurrentEventLoop(shards.runtime, cast[pointer](loop), workerId)
    setLocalFutureDefault(true)
    isReactorThread = true

proc ioShardPoll(ctx: pointer, workerId: int) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    cast[MtIoShardSet](ctx).loops[workerId].tick()

proc ioShardPollNow(ctx: pointer, workerId: int): bool {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let loop = cast[MtIoShardSet](ctx).loops[workerId]
    if loop.hasUserIoWork():
      return loop.poll()
    false

proc ioShardShouldDrain(ctx: pointer, workerId: int): bool {.nimcall, gcsafe.} =
  ## Sparse selectors are cheaper to revisit through the normal blocking path;
  ## busy selectors benefit from draining locally before remote deque probes.
  {.cast(gcsafe).}:
    cast[MtIoShardSet](ctx).loops[workerId].userIoHandleCount() >=
      MtIoDrainHandleThreshold

proc ioShardWake(ctx: pointer, workerId: int) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    cast[MtIoShardSet](ctx).loops[workerId].tryWakeSelector()

proc ioShardTeardown(ctx: pointer, workerId: int) {.nimcall, gcsafe.} =
  discard ctx
  discard workerId
  clearCurrentEventLoop()
  setLocalFutureDefault(false)
  isReactorThread = false

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
      let rtPtr = cast[pointer](rt)
      let workerSetup = proc() {.gcsafe.} =
        {.cast(gcsafe).}:
          setCurrentRuntime(cast[CpsRuntime](rtPtr))
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

proc takeSchedulerTask[T](cb: var T): SchedulerTask {.inline.} =
  ## Transfer a compatible Nim closure pair without creating an RC edge.
  static: assert sizeof(T) == sizeof(SchedulerTask)
  copyMem(addr result, addr cb, sizeof(result))
  zeroMem(addr cb, sizeof(cb))

proc closureWorker[T](cb: var T, workerCount: int): int {.inline.} =
  ## Closures sharing an environment must be released on one ORC owner.
  ## Hashing the environment also distributes unrelated callbacks uniformly.
  var words: array[2, pointer]
  static: assert sizeof(T) == sizeof(words)
  copyMem(addr words, addr cb, sizeof(words))
  if words[1] == nil or workerCount <= 1:
    return 0
  int((cast[uint](words[1]) shr 4) mod uint(workerCount))

proc makeWakeDispatcher(rt: CpsRuntime): proc() {.closure, gcsafe.} =
  let rtPtr = cast[pointer](rt)
  result = proc() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let rt {.cursor.} = cast[CpsRuntime](rtPtr)
      let loop {.cursor.} = asEventLoop(rt)
      if loop != nil:
        loop.tryWakeSelector()

proc makeIoShardWakeDispatcher(rt: CpsRuntime):
    proc(workerId: int) {.closure, gcsafe.} =
  let rtPtr = cast[pointer](rt)
  result = proc(workerId: int) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let rt {.cursor.} = cast[CpsRuntime](rtPtr)
      let shards {.cursor.} = asIoShardSet(rt)
      if shards != nil and workerId >= 0 and workerId < shards.loops.len:
        shards.loops[workerId].tryWakeSelector()

proc makeCallbackDispatcher(rt: CpsRuntime): proc(cb: sink proc() {.closure.}) {.closure, gcsafe.} =
  let rtPtr = cast[pointer](rt)
  result = proc(cb: sink proc() {.closure.}) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let rt {.cursor.} = cast[CpsRuntime](rtPtr)
      let sched {.cursor.} = asScheduler(rt)
      if sched != nil:
        let workerId = closureWorker(cb, rt.ioShardCount)
        var task = takeSchedulerTask(cb)
        discard sched.schedulePinned(workerId, move(task))

proc makeContinuationDispatcher(rt: CpsRuntime):
    proc(c: sink Continuation) {.closure, gcsafe.} =
  let rtPtr = cast[pointer](rt)
  result = proc(c: sink Continuation) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let rt {.cursor.} = cast[CpsRuntime](rtPtr)
      let sched {.cursor.} = asScheduler(rt)
      if sched == nil or c == nil:
        return
      sched.scheduleContinuation(move(c))

proc makePinnedCallbackDispatcher(rt: CpsRuntime): proc(workerId: int, cb: sink proc() {.closure.}): bool {.closure, gcsafe.} =
  let rtPtr = cast[pointer](rt)
  result = proc(workerId: int, cb: sink proc() {.closure.}): bool {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let rt {.cursor.} = cast[CpsRuntime](rtPtr)
      let sched {.cursor.} = asScheduler(rt)
      if sched == nil:
        return false
      var task = takeSchedulerTask(cb)
      sched.schedulePinned(workerId, move(task))

proc makeClosureReleaseDispatcher(rt: CpsRuntime):
    proc(workerId: int, task: OwnedClosureTask): bool {.closure, gcsafe.} =
  let rtPtr = cast[pointer](rt)
  result = proc(workerId: int, task: OwnedClosureTask): bool {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let rt {.cursor.} = cast[CpsRuntime](rtPtr)
      let sched {.cursor.} = asScheduler(rt)
      if sched == nil:
        return false
      sched.scheduleClosureRelease(workerId, task)

proc makeOwnedClosureDispatcher(rt: CpsRuntime):
    proc(workerId: int, task: OwnedClosureTask): bool {.closure, gcsafe.} =
  let rtPtr = cast[pointer](rt)
  result = proc(workerId: int, task: OwnedClosureTask): bool {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let rt {.cursor.} = cast[CpsRuntime](rtPtr)
      let sched {.cursor.} = asScheduler(rt)
      if sched == nil:
        return false
      sched.scheduleOwnedClosure(workerId, task)

proc makeYieldDispatcher(rt: CpsRuntime): proc(cb: sink proc() {.closure, gcsafe.}) {.closure, gcsafe.} =
  let rtPtr = cast[pointer](rt)
  result = proc(cb: sink proc() {.closure, gcsafe.}) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let rt {.cursor.} = cast[CpsRuntime](rtPtr)
      let sched {.cursor.} = asScheduler(rt)
      if sched != nil:
        let workerId = closureWorker(cb, rt.ioShardCount)
        var task = takeSchedulerTask(cb)
        discard sched.schedulePinned(workerId, move(task))

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

    let workerCount = max(1,
      if config.numWorkers <= 0: countProcessors() else: config.numWorkers)
    let shards = MtIoShardSet(runtime: rt,
                              loops: newSeq[EventLoop](workerCount))
    for workerId in 0 ..< workerCount:
      let shardLoop = newEventLoop()
      shardLoop.mtActive = true
      shardLoop.ownerRuntime = rt
      shardLoop.enableCrossThreadWake()
      shards.loops[workerId] = shardLoop
    rt.ioShardSetPtr = cast[RootRef](shards)
    rt.ioShardCount = workerCount

    # Publish every runtime hook before workers start. workerMain binds the
    # runtime immediately, so installing these after newScheduler returned
    # allowed workers to read the CpsRuntime while this thread was mutating it.
    rt.continuationDispatcher = makeContinuationDispatcher(rt)
    rt.callbackDispatcher = makeCallbackDispatcher(rt)
    rt.pinnedCallbackDispatcher = makePinnedCallbackDispatcher(rt)
    rt.closureReleaseDispatcher = makeClosureReleaseDispatcher(rt)
    rt.ownedClosureDispatcher = makeOwnedClosureDispatcher(rt)
    rt.yieldDispatcher = makeYieldDispatcher(rt)
    rt.wakeReactor = makeWakeDispatcher(rt)
    rt.wakeIoShard = makeIoShardWakeDispatcher(rt)

    let sched = newScheduler(rt, workerCount, config.maxSchedulerQueue,
      reactorCtx = cast[pointer](shards),
      reactorSetup = ioShardSetup,
      reactorPoll = ioShardPoll,
      reactorPollNow = ioShardPollNow,
      reactorShouldDrain = ioShardShouldDrain,
      reactorWake = ioShardWake,
      reactorTeardown = ioShardTeardown)
    GC_ref(sched)
    copyMem(addr rt.schedulerPtr, unsafeAddr sched, sizeof(rt.schedulerPtr))

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

proc ioShardCount*(rt: CpsRuntime): int {.inline.} =
  ## Return the number of worker-owned I/O reactor shards.
  if rt == nil: 0 else: rt.ioShardCount

proc ioShardLoop*(rt: CpsRuntime, shardId: int): EventLoop =
  ## Return one worker-owned I/O loop for diagnostics and tests.
  let shards = asIoShardSet(rt)
  if shards == nil or shardId < 0 or shardId >= shards.loops.len:
    raise newException(IndexDefect, "I/O shard index out of bounds")
  shards.loops[shardId]

proc startMtIoShards*(rt: CpsRuntime, setup: MtIoSetup) =
  ## Run ``setup`` once on every scheduler worker and wait for initialization.
  ## Each callback executes on the worker that owns the corresponding selector,
  ## so listeners, sockets, timers, and their continuations remain thread-local.
  if rt == nil or rt.flavor != rfMultiThread or not rt.mtActive:
    raise newException(ValueError, "active MT runtime required")
  if setup == nil:
    raise newException(ValueError, "I/O shard setup callback required")
  let sched = asScheduler(rt)
  if sched == nil or rt.ioShardCount <= 0:
    raise newException(ValueError, "MT runtime has no I/O shards")

  let state = cast[ptr MtIoStartState](allocShared0(sizeof(MtIoStartState)))
  state.started.store(0, moRelaxed)
  state.failed.store(false, moRelaxed)

  proc makeSetupTask(shardId: int): SchedulerTask =
    result = proc() {.closure, gcsafe.} =
      try:
        setup(shardId)
      except CatchableError:
        state.failed.store(true, moRelease)
      finally:
        discard state.started.fetchAdd(1, moAcquireRelease)

  for shardId in 0 ..< rt.ioShardCount:
    if not sched.schedulePinned(shardId, makeSetupTask(shardId)):
      state.failed.store(true, moRelease)
      discard state.started.fetchAdd(1, moAcquireRelease)

  while state.started.load(moAcquire) != rt.ioShardCount:
    sleep(0)
  let failed = state.failed.load(moAcquire)
  deallocShared(state)
  if failed:
    raise newException(CatchableError, "one or more MT I/O shards failed to initialize")

proc startMtIoShards*(handle: RuntimeHandle, setup: MtIoSetup) {.inline.} =
  ## Initialize worker-owned I/O shards through a runtime handle.
  startMtIoShards(handle.runtime, setup)

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
  ## Schedule blocking for asynchronous execution.
  spawnBlockingOn(currentRuntime(), body)

proc spawnBlocking*(body: proc() {.gcsafe.}): CpsVoidFuture =
  ## Schedule blocking for asynchronous execution.
  spawnBlockingOn(currentRuntime(), body)

proc shutdownMtRuntime*(rt: CpsRuntime) =
  ## Shut down one MT runtime instance.
  if rt == nil or rt.flavor != rfMultiThread:
    return

  ensureMtRuntimeLockReady()
  acquire(mtRuntimeLock)
  try:
    # Keep typed roots alive while their type-erased runtime slots are cleared.
    # Event-loop unregister releases callbacks that can recursively drop their
    # owner, so shutdown deliberately pays one RC pair outside the hot path.
    let shards = asIoShardSet(rt)
    let sched = asScheduler(rt)
    var pool = asBlockingPool(rt)

    # Blocking jobs may complete futures by dispatching callbacks to scheduler
    # workers, and the pool may have been lazily allocated by one of those
    # workers. Drain and release it before joining the scheduler threads.
    if pool != nil:
      pool.shutdown()
      rt.blockingPoolPtr = nil
      # The pool and its Thread sequence may have been allocated by the
      # scheduler worker that first called spawnBlocking. Retire the typed
      # owner before joining scheduler workers and tearing down that allocator.
      pool = nil

    if sched != nil:
      shutdownScheduler(sched)
      zeroMem(addr rt.schedulerPtr, sizeof(rt.schedulerPtr))
      GC_unref(sched)

    if shards != nil:
      for loop in shards.loops:
        if loop != nil:
          loop.disableCrossThreadWake()
      rt.ioShardSetPtr = nil
      rt.ioShardCount = 0

    let loop = asEventLoop(rt)
    if loop != nil:
      loop.disableCrossThreadWake()
      rt.eventLoopPtr = nil

    rt.continuationDispatcher = nil
    rt.callbackDispatcher = nil
    rt.pinnedCallbackDispatcher = nil
    rt.closureReleaseDispatcher = nil
    rt.ownedClosureDispatcher = nil
    rt.yieldDispatcher = nil
    rt.wakeReactor = nil
    rt.wakeIoShard = nil
    rt.mtActive = false

    if currentRuntime().runtime == rt:
      let replacement = newCurrentThreadRuntime()
      setMainRuntime(replacement)
      setCurrentRuntime(replacement)
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
