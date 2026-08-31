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
when defined(linux):
  import ../private/platform

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
    # Each loop and its managed callbacks belong to its scheduler worker.
    # Other threads only need the raw address for atomic wake operations.
    loops: seq[pointer]

  MtIoStartState = object
    started: Atomic[int]
    failed: Atomic[bool]
    setup: MtIoSetup

  BlockingProc*[T] = proc(): T {.gcsafe.}
    ## Thread-pool work that returns a value without touching reactor state.
  BlockingVoidProc* = proc() {.gcsafe.}
    ## Thread-pool work that completes without returning a value.

  BlockingJob[T] = object
    header: RawPoolJobHeader
    runtime: pointer
    future: pointer
    ownerWorker: int
    body: OwnedClosureTask

  BlockingVoidJob = object
    header: RawPoolJobHeader
    runtime: pointer
    future: pointer
    ownerWorker: int
    body: OwnedClosureTask

  TransferredWorkerError {.cpsMtShardAcyclic.} = object of CatchableError

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

template blockingPoolPointer(rt: CpsRuntime): pointer =
  (if rt == nil: nil else: cast[pointer](rt.blockingPoolPtr))

template asEventLoop(rt: CpsRuntime): EventLoop =
  cast[EventLoop](if rt == nil: nil else: cast[pointer](rt.eventLoopPtr))

template asIoShardSet(rt: CpsRuntime): MtIoShardSet =
  cast[MtIoShardSet](if rt == nil: nil else: cast[pointer](rt.ioShardSetPtr))

proc ioShardSetup(ctx: pointer, workerId: int) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let shards {.cursor.} = cast[MtIoShardSet](ctx)
    let loop = newEventLoop()
    loop.mtActive = true
    loop.ownerRuntime = shards.runtime
    loop.enableCrossThreadWake()
    GC_ref(loop)
    shards.loops[workerId] = cast[pointer](loop)
    bindCurrentEventLoop(shards.runtime, cast[pointer](loop), workerId)
    setLocalFutureDefault(true)
    isReactorThread = true

proc ioShardPoll(ctx: pointer, workerId: int) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let shards {.cursor.} = cast[MtIoShardSet](ctx)
    let loop {.cursor.} = cast[EventLoop](shards.loops[workerId])
    loop.tick()

proc ioShardPollNow(ctx: pointer, workerId: int): bool {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let shards {.cursor.} = cast[MtIoShardSet](ctx)
    let loop {.cursor.} = cast[EventLoop](shards.loops[workerId])
    if loop.hasUserIoWork():
      return loop.poll()
    false

proc ioShardShouldDrain(ctx: pointer, workerId: int): bool {.nimcall, gcsafe.} =
  ## Sparse selectors are cheaper to revisit through the normal blocking path;
  ## busy selectors benefit from draining locally before remote deque probes.
  {.cast(gcsafe).}:
    let shards {.cursor.} = cast[MtIoShardSet](ctx)
    let loop {.cursor.} = cast[EventLoop](shards.loops[workerId])
    loop.userIoHandleCount() >= MtIoDrainHandleThreshold

proc ioShardWake(ctx: pointer, workerId: int) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let shards {.cursor.} = cast[MtIoShardSet](ctx)
    let loop {.cursor.} = cast[EventLoop](shards.loops[workerId])
    if loop != nil:
      loop.tryWakeSelector()

proc ioShardTeardown(ctx: pointer, workerId: int) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let shards {.cursor.} = cast[MtIoShardSet](ctx)
    let loop {.cursor.} = cast[EventLoop](shards.loops[workerId])
    if loop != nil:
      # Destroy selector callbacks and the loop root on the worker whose ARC/
      # ORC allocator created them. Publishing nil first prevents late wakes
      # from observing a loop being dismantled.
      shards.loops[workerId] = nil
      loop.disableCrossThreadWake()
      loop.ownerRuntime = nil
      clearCurrentEventLoop()
      GC_unref(loop)
    else:
      clearCurrentEventLoop()
    setLocalFutureDefault(false)
    isReactorThread = false

proc runMtIoSetup(ctx: pointer, workerId: int) {.nimcall, gcsafe.} =
  let state = cast[ptr MtIoStartState](ctx)
  try:
    state.setup(workerId)
  except CatchableError:
    state.failed.store(true, moRelease)
  finally:
    discard state.started.fetchAdd(1, moAcquireRelease)

proc setupBlockingWorker(ctx: pointer) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    setCurrentRuntimeBorrowed(cast[CpsRuntime](ctx))

proc ensureBlockingPool(rt: CpsRuntime): pointer =
  ## Lazily create the blocking pool. Most asynchronous applications never
  ## submit blocking work, so starting another CPU-sized thread set at runtime
  ## initialization wastes memory and scheduler resources.
  result = blockingPoolPointer(rt)
  if result != nil:
    return
  ensureMtRuntimeLockReady()
  acquire(mtRuntimeLock)
  try:
    if not rt.mtActive:
      return nil
    result = blockingPoolPointer(rt)
    if result == nil:
      let rtPtr = cast[pointer](rt)
      let created = newThreadPool(rt.blockingThreadCount, setupBlockingWorker,
                                  rtPtr, rt.maxBlockingQueue)
      GC_ref(created)
      copyMem(addr rt.blockingPoolPtr, unsafeAddr created,
              sizeof(rt.blockingPoolPtr))
      result = cast[pointer](created)
  finally:
    release(mtRuntimeLock)

proc runtimeFromHandle(handle: RuntimeHandle): pointer {.inline.} =
  if handle.runtime != nil:
    return cast[pointer](handle.runtime)
  currentRuntimePointer()

proc captureWorkerError(e: ref CatchableError): ref CatchableError {.inline.}

proc cleanupBlockingJob[T](ctx: pointer,
                           workerId: int) {.nimcall, gcsafe.} =
  ## Retire the body and future root on their submitting scheduler worker.
  let job = cast[ptr BlockingJob[T]](ctx)
  releaseClosureTask(job.body, BlockingProc[T])
  {.cast(gcsafe).}:
    let fut {.cursor.} = cast[CpsFuture[T]](job.future)
    GC_unref(fut)
  deallocShared(job)

proc cleanupMainBlockingJob[T](ctx: pointer) {.nimcall, gcsafe.} =
  cleanupBlockingJob[T](ctx, MainReactorCallbackWorker)

proc cleanupBlockingVoidJob(ctx: pointer,
                            workerId: int) {.nimcall, gcsafe.} =
  ## Retire a void body and future root on their submitting scheduler worker.
  let job = cast[ptr BlockingVoidJob](ctx)
  releaseClosureTask(job.body, BlockingVoidProc)
  {.cast(gcsafe).}:
    let fut {.cursor.} = cast[CpsVoidFuture](job.future)
    GC_unref(fut)
  deallocShared(job)

proc cleanupMainBlockingVoidJob(ctx: pointer) {.nimcall, gcsafe.} =
  cleanupBlockingVoidJob(ctx, MainReactorCallbackWorker)

proc returnBlockingJob[T](job: ptr BlockingJob[T]) {.gcsafe.} =
  let rt {.cursor.} = cast[CpsRuntime](job.runtime)
  if job.ownerWorker >= 0:
    let sched {.cursor.} = asScheduler(rt)
    if sched != nil and sched.schedulePinnedCall(
        job.ownerWorker, cleanupBlockingJob[T], cast[pointer](job)):
      return
  else:
    let loop {.cursor.} = asEventLoop(rt)
    if loop != nil and loop.mtActive:
      loop.postRawToEventLoop(cleanupMainBlockingJob[T], cast[pointer](job))
      return
  when compileOption("gc", "atomicArc"):
    cleanupMainBlockingJob[T](cast[pointer](job))

proc returnBlockingVoidJob(job: ptr BlockingVoidJob) {.gcsafe.} =
  let rt {.cursor.} = cast[CpsRuntime](job.runtime)
  if job.ownerWorker >= 0:
    let sched {.cursor.} = asScheduler(rt)
    if sched != nil and sched.schedulePinnedCall(
        job.ownerWorker, cleanupBlockingVoidJob, cast[pointer](job)):
      return
  else:
    let loop {.cursor.} = asEventLoop(rt)
    if loop != nil and loop.mtActive:
      loop.postRawToEventLoop(cleanupMainBlockingVoidJob, cast[pointer](job))
      return
  when compileOption("gc", "atomicArc"):
    cleanupMainBlockingVoidJob(cast[pointer](job))

proc runBlockingJob[T](ctx: pointer) {.nimcall, gcsafe.} =
  let job = cast[ptr BlockingJob[T]](ctx)
  {.cast(gcsafe).}:
    let workerRt {.cursor.} = cast[CpsRuntime](job.runtime)
    let workerFut {.cursor.} = cast[CpsFuture[T]](job.future)
    setCurrentRuntimeBorrowed(workerRt)
  type RawBodyCall = proc(env: pointer): T {.nimcall, gcsafe.}
  try:
    var val = cast[RawBodyCall](job.body.fn)(job.body.env)
    {.cast(gcsafe).}:
      workerFut.completeTransferred(move(val))
  except CatchableError as e:
    {.cast(gcsafe).}:
      var copied = captureWorkerError(e)
      workerFut.failTransferred(move(copied))
  finally:
    returnBlockingJob(job)

proc runBlockingVoidJob(ctx: pointer) {.nimcall, gcsafe.} =
  let job = cast[ptr BlockingVoidJob](ctx)
  {.cast(gcsafe).}:
    let workerRt {.cursor.} = cast[CpsRuntime](job.runtime)
    let workerFut {.cursor.} = cast[CpsVoidFuture](job.future)
    setCurrentRuntimeBorrowed(workerRt)
  type RawBodyCall = proc(env: pointer) {.nimcall, gcsafe.}
  try:
    cast[RawBodyCall](job.body.fn)(job.body.env)
    {.cast(gcsafe).}:
      workerFut.complete()
  except CatchableError as e:
    {.cast(gcsafe).}:
      var copied = captureWorkerError(e)
      workerFut.failTransferred(move(copied))
  finally:
    returnBlockingVoidJob(job)

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
        let loop {.cursor.} = cast[EventLoop](shards.loops[workerId])
        if loop != nil:
          loop.tryWakeSelector()

proc makeCallbackDispatcher(rt: CpsRuntime): proc(cb: sink proc() {.closure.}) {.closure, gcsafe.} =
  let rtPtr = cast[pointer](rt)
  result = proc(cb: sink proc() {.closure.}) {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      let rt {.cursor.} = cast[CpsRuntime](rtPtr)
      let sched {.cursor.} = asScheduler(rt)
      if sched != nil:
        let workerId =
          if isSchedulerWorker and currentRuntimePointer() == rtPtr:
            currentWorkerId
          else:
            closureWorker(cb, rt.ioShardCount)
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
      if workerId == MainReactorCallbackWorker:
        let loop {.cursor.} = asEventLoop(rt)
        if loop == nil or not loop.mtActive:
          return false
        var task = takeClosureTask(cb)
        loop.postOwnedToEventLoop(task)
        return true
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
      if workerId == MainReactorCallbackWorker:
        let loop {.cursor.} = asEventLoop(rt)
        if loop == nil or not loop.mtActive:
          return false
        loop.postOwnedToEventLoop(task)
        return true
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
        # Yielding is an owner-local scheduling point. Keep the completion on
        # the calling reactor shard instead of hashing its fresh closure onto
        # an unrelated worker and hopping the local future back afterwards.
        let workerId =
          if isSchedulerWorker and currentRuntimePointer() == rtPtr:
            currentWorkerId
          else:
            closureWorker(cb, rt.ioShardCount)
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
    GC_ref(loop)
    copyMem(addr rt.eventLoopPtr, unsafeAddr loop, sizeof(rt.eventLoopPtr))

    loop.enableCrossThreadWake()

    let detectedProcessors =
      when defined(linux):
        let allowed = platform.allowedCpuIds()
        if allowed.len > 0: allowed.len else: countProcessors()
      else:
        countProcessors()
    let workerCount = max(1,
      if config.numWorkers <= 0: detectedProcessors else: config.numWorkers)
    let shards = MtIoShardSet(runtime: rt,
                              loops: newSeq[pointer](workerCount))
    GC_ref(shards)
    copyMem(addr rt.ioShardSetPtr, unsafeAddr shards,
            sizeof(rt.ioShardSetPtr))
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
      pinWorkers = config.pinWorkers,
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
  result = newException(TransferredWorkerError, msg)

proc initMtRuntime*(numWorkers: int = 0,
                    numBlockingThreads: int = 0,
                    maxSchedulerQueue: int = 65536,
                    maxBlockingQueue: int = 65536,
                    pinWorkers: bool = true): EventLoop =
  ## Compatibility wrapper: create an MT runtime and install it as main/current.
  let rt = newMultiThreadRuntime(
    numWorkers = numWorkers,
    pinWorkers = pinWorkers,
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
  ## Return the calling worker's I/O loop for diagnostics and tests.
  let shards = asIoShardSet(rt)
  if shards == nil or shardId < 0 or shardId >= shards.loops.len:
    raise newException(IndexDefect, "I/O shard index out of bounds")
  if not isSchedulerWorker or
      currentRuntimePointer() != cast[pointer](rt) or
      currentWorkerId != shardId:
    raise newException(ValueError,
      "I/O shard loops are only borrowable from their owning worker")
  cast[EventLoop](shards.loops[shardId])

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
  state.setup = setup

  for shardId in 0 ..< rt.ioShardCount:
    if not sched.schedulePinnedCall(shardId, runMtIoSetup,
                                    cast[pointer](state)):
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

proc spawnBlockingOn*[T](handle: RuntimeHandle,
                         bodyArg: sink BlockingProc[T]): CpsFuture[T] =
  ## Offload blocking work to a runtime's blocking pool.
  let rt {.cursor.} = cast[CpsRuntime](runtimeFromHandle(handle))
  if rt == nil or rt.flavor != rfMultiThread:
    raise newException(ValueError, "MT runtime not initialized for this handle")
  let poolPtr = ensureBlockingPool(rt)
  if poolPtr == nil:
    raise newException(ValueError, "MT runtime is shutting down")
  let pool {.cursor.} = cast[ThreadPool](poolPtr)

  let fut = newCpsFuture[T]()
  fut.bindFutureRuntime(toHandle(rt))
  fut.ensureShared()
  GC_ref(fut)
  let job = cast[ptr BlockingJob[T]](allocShared0(sizeof(BlockingJob[T])))
  job.header.run = runBlockingJob[T]
  job.runtime = cast[pointer](rt)
  job.future = cast[pointer](fut)
  job.ownerWorker = if isSchedulerWorker: currentWorkerId else: -1
  var body = move(bodyArg)
  job.body = takeClosureTask(body)
  if not pool.submitRawJob(cast[pointer](job)):
    fut.fail(newException(CatchableError, "blocking pool is shutting down"))
    if job.ownerWorker >= 0:
      cleanupBlockingJob[T](cast[pointer](job), job.ownerWorker)
    else:
      cleanupMainBlockingJob[T](cast[pointer](job))
  result = fut

proc spawnBlockingOn*(handle: RuntimeHandle,
                      bodyArg: sink BlockingVoidProc): CpsVoidFuture =
  ## Offload blocking void work to a runtime's blocking pool.
  let rt {.cursor.} = cast[CpsRuntime](runtimeFromHandle(handle))
  if rt == nil or rt.flavor != rfMultiThread:
    raise newException(ValueError, "MT runtime not initialized for this handle")
  let poolPtr = ensureBlockingPool(rt)
  if poolPtr == nil:
    raise newException(ValueError, "MT runtime is shutting down")
  let pool {.cursor.} = cast[ThreadPool](poolPtr)

  let fut = newCpsVoidFuture()
  fut.bindFutureRuntime(toHandle(rt))
  fut.ensureShared()
  GC_ref(fut)
  let job = cast[ptr BlockingVoidJob](allocShared0(sizeof(BlockingVoidJob)))
  job.header.run = runBlockingVoidJob
  job.runtime = cast[pointer](rt)
  job.future = cast[pointer](fut)
  job.ownerWorker = if isSchedulerWorker: currentWorkerId else: -1
  var body = move(bodyArg)
  job.body = takeClosureTask(body)
  if not pool.submitRawJob(cast[pointer](job)):
    fut.fail(newException(CatchableError, "blocking pool is shutting down"))
    if job.ownerWorker >= 0:
      cleanupBlockingVoidJob(cast[pointer](job), job.ownerWorker)
    else:
      cleanupMainBlockingVoidJob(cast[pointer](job))
  result = fut

proc spawnBlocking*[T](body: sink BlockingProc[T]): CpsFuture[T] =
  ## Schedule blocking for asynchronous execution.
  spawnBlockingOn(currentRuntime(), move(body))

proc spawnBlocking*(body: sink BlockingVoidProc): CpsVoidFuture =
  ## Schedule blocking for asynchronous execution.
  spawnBlockingOn(currentRuntime(), move(body))

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
    let pool {.cursor.} = cast[ThreadPool](blockingPoolPointer(rt))

    # Blocking jobs may complete futures by dispatching callbacks to scheduler
    # workers, and the pool may have been lazily allocated by one of those
    # workers. Drain and release it before joining the scheduler threads.
    if pool != nil:
      pool.shutdown()
      zeroMem(addr rt.blockingPoolPtr, sizeof(rt.blockingPoolPtr))
      GC_unref(pool)

    let loop = asEventLoop(rt)
    if loop != nil and loop.isCurrentThreadOwner():
      # Pool workers return their manual future roots through this queue.
      # Joining the pool first guarantees that every cleanup is now visible.
      loop.drainCrossThreadQueue()

    if sched != nil:
      shutdownScheduler(sched)
      zeroMem(addr rt.schedulerPtr, sizeof(rt.schedulerPtr))
      GC_unref(sched)

    if shards != nil:
      # ioShardTeardown released every managed loop on its owning worker.
      zeroMem(addr rt.ioShardSetPtr, sizeof(rt.ioShardSetPtr))
      rt.ioShardCount = 0
      GC_unref(shards)

    if loop != nil:
      loop.disableCrossThreadWake()
      loop.ownerRuntime = nil
      zeroMem(addr rt.eventLoopPtr, sizeof(rt.eventLoopPtr))
      GC_unref(loop)

    rt.continuationDispatcher = nil
    rt.callbackDispatcher = nil
    rt.pinnedCallbackDispatcher = nil
    rt.closureReleaseDispatcher = nil
    rt.ownedClosureDispatcher = nil
    rt.yieldDispatcher = nil
    rt.wakeReactor = nil
    rt.wakeIoShard = nil
    rt.mtActive = false

    if cast[CpsRuntime](currentRuntimePointer()) == rt:
      let replacement = newCurrentThreadRuntime()
      setMainRuntime(replacement)
      setCurrentRuntime(replacement)
      isReactorThread = false
  finally:
    release(mtRuntimeLock)

proc shutdownMtRuntime*(loop: EventLoop) =
  ## Compatibility wrapper for existing call sites.
  let curRt {.cursor.} = cast[CpsRuntime](currentRuntimePointer())
  if curRt != nil and asEventLoop(curRt) == loop:
    shutdownMtRuntime(curRt)
    return

  let mainHandle = mainRuntime()
  let mainRt {.cursor.} = mainHandle.runtime
  if mainRt != nil and asEventLoop(mainRt) == loop:
    shutdownMtRuntime(mainRt)

registerMtRuntimeFactory(createMtRuntime)
