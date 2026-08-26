## Work-Stealing Scheduler for CPS MT Runtime
##
## N worker threads execute CPS continuations with work-stealing
## load balancing. Each worker has a local deque; when empty, it
## tries its sharded injection queue, then steals from a random peer.
##
## Workers park on cache-local atomic epochs when no work is available.

import std/[cpuinfo, atomics, sysatomics, os]
import ../runtime
import ../private/chase_lev
import ../private/mpsc_queue
import ../private/mpsc_ring
import ../private/xorshift
import ../private/atomic_parker
import ../private/cross_thread_closure

const DefaultGlobalQueueCapacity = 65536

type
  SchedulerTask* = proc() {.closure, gcsafe.}
  OwnedSchedulerTask = OwnedClosureTask
  SchedulerReactorHook* = proc(ctx: pointer, workerId: int) {.nimcall, gcsafe.}
  SchedulerReactorPollHook* = proc(ctx: pointer, workerId: int): bool {.nimcall, gcsafe.}
  SchedulerReactorPredicateHook* = proc(ctx: pointer, workerId: int): bool {.nimcall, gcsafe.}

  WorkerState = object
    deque: ChaseLevDeque[OwnedSchedulerTask]  ## Lock-free work-stealing deque
    injectQueue: MpscRingQueue[OwnedSchedulerTask]  ## Bounded external submissions
    pinnedQueue: MpscQueue[OwnedSchedulerTask]  ## Worker-pinned tasks
    parker: AtomicParker
    parked: Atomic[bool]

  WorkerArg = object
    scheduler: ptr SchedulerObj
    idx: int
    runtime: pointer

  SchedulerObj = object
    workers: seq[ptr WorkerState]
    threads: seq[Thread[WorkerArg]]
    numWorkers: int
    shutdown: Atomic[bool]
    parkedCount: Atomic[int]
    wakeCursor: Atomic[int]
    routeSeed: Atomic[int]
    reactorCtx: pointer
    reactorSetup: SchedulerReactorHook
    reactorPoll: SchedulerReactorHook
    reactorPollNow: SchedulerReactorPollHook
    reactorShouldDrain: SchedulerReactorPredicateHook
    reactorWake: SchedulerReactorHook
    reactorTeardown: SchedulerReactorHook

  RemoteClosure = object
    task: OwnedSchedulerTask
    sourceWorker: int

  ReturnedClosure = object
    task: OwnedSchedulerTask
    route: ClosureReturnRoute

  Scheduler* {.acyclic.} = ref object
    obj: ptr SchedulerObj

# Thread-local worker index within the scheduler (for deque access).
# Only meaningful when isSchedulerWorker is true.
var workerIdx {.threadvar.}: int
var injectScheduler {.threadvar.}: pointer
var injectCursor {.threadvar.}: int

proc continuationTaskMarker() {.nimcall, gcsafe.} = discard
proc remoteInvokeMarker() {.nimcall, gcsafe.} = discard
proc remoteReleaseMarker() {.nimcall, gcsafe.} = discard
proc returnedInvokeMarker() {.nimcall, gcsafe.} = discard
proc wakeWorkerIfParked(s: ptr SchedulerObj, workerId: int) {.inline.}

proc takeTask(task: var SchedulerTask): OwnedSchedulerTask {.inline.} =
  ## SchedulerTask is Nim's two-word closure pair. Transfer it without an RC
  ## edge so ORC never records a cycle root on the producer thread.
  result = takeClosureTask(task)

proc takeContinuation(c: var Continuation): OwnedSchedulerTask {.inline.} =
  result.fn = cast[pointer](continuationTaskMarker)
  result.env = cast[pointer](c)
  zeroMem(addr c, sizeof(c))

proc releaseContinuation(task: var OwnedSchedulerTask) {.inline.} =
  var c: Continuation
  copyMem(addr c, addr task.env, sizeof(c))
  task.fn = nil
  task.env = nil

proc runTask(s: ptr SchedulerObj,
             task: var OwnedSchedulerTask) {.inline.} =
  if task.fn == cast[pointer](continuationTaskMarker):
    var c: Continuation
    copyMem(addr c, addr task.env, sizeof(c))
    task.fn = nil
    task.env = nil
    discard runUntilSuspend(move(c))
  elif task.fn == cast[pointer](remoteInvokeMarker):
    let remote = cast[ptr RemoteClosure](task.env)
    task.fn = nil
    task.env = nil
    if remote.sourceWorker == currentWorkerId:
      var localTask = remote.task
      remote.task = default(OwnedSchedulerTask)
      deallocShared(remote)
      try:
        runClosureTask(localTask, SchedulerTask)
      except CatchableError:
        discard
      return
    type RawClosureCall = proc(env: pointer) {.nimcall, gcsafe.}
    try:
      cast[RawClosureCall](remote.task.fn)(remote.task.env)
    except CatchableError:
      discard
    var releaseTask = OwnedSchedulerTask(
      fn: cast[pointer](remoteReleaseMarker), env: cast[pointer](remote))
    let ws = s.workers[remote.sourceWorker]
    while not ws.injectQueue.tryEnqueue(releaseTask):
      cpuRelax()
    s.wakeWorkerIfParked(remote.sourceWorker)
  elif task.fn == cast[pointer](remoteReleaseMarker):
    let remote = cast[ptr RemoteClosure](task.env)
    task.fn = nil
    task.env = nil
    releaseClosureTask(remote.task, SchedulerTask)
    deallocShared(remote)
  elif task.fn == cast[pointer](returnedInvokeMarker):
    let returned = cast[ptr ReturnedClosure](task.env)
    task.fn = nil
    task.env = nil
    type RawClosureCall = proc(env: pointer) {.nimcall, gcsafe.}
    try:
      cast[RawClosureCall](returned.task.fn)(returned.task.env)
    except CatchableError:
      discard
    returned.route.release(returned.route.ctx, returned.route.owner,
                           returned.task)
    deallocShared(returned)
  else:
    try:
      runClosureTask(task, SchedulerTask)
    except CatchableError:
      discard

proc floorPowerOfTwo(value: int): int {.inline.} =
  ## Largest power of two not greater than a positive value.
  result = 1
  while result <= value shr 1:
    result = result shl 1

proc popLocal(ws: ptr WorkerState): OwnedSchedulerTask {.inline.} =
  ## Owner: pop from local deque (LIFO, lock-free).
  ws.deque.pop()

proc popInjected(ws: ptr WorkerState): OwnedSchedulerTask {.inline.} =
  ## Pop from this worker's lock-free MPSC injection shard.
  var task: OwnedSchedulerTask
  if ws.injectQueue.tryDequeue(task):
    result = task
  else:
    result = default(OwnedSchedulerTask)

proc popPinned(ws: ptr WorkerState): OwnedSchedulerTask {.inline.} =
  let node = dequeue(ws.pinnedQueue)
  if node == nil:
    return default(OwnedSchedulerTask)
  result = takePayload(node)
  freeNode(node)

proc wakeWorkerIfParked(s: ptr SchedulerObj, workerId: int) {.inline.} =
  ## Wake one exact worker. The epoch prevents lost notifications if the
  ## worker is between publishing ``parked`` and entering the kernel wait.
  let ws = s.workers[workerId]
  if ws.parked.load(moAcquire):
    if s.reactorWake != nil:
      s.reactorWake(s.reactorCtx, workerId)
    else:
      ws.parker.notifyOne()

proc wakeOneWorkerIfParked(s: ptr SchedulerObj) {.inline.} =
  ## Wake a parked worker without contending on a global mutex.
  if s.parkedCount.load(moAcquire) <= 0:
    return

  let start = s.wakeCursor.fetchAdd(1, moRelaxed)
  for offset in 0 ..< s.numWorkers:
    let ws = s.workers[(start + offset) mod s.numWorkers]
    if ws.parked.load(moAcquire):
      let workerId = (start + offset) mod s.numWorkers
      if s.reactorWake != nil:
        s.reactorWake(s.reactorCtx, workerId)
      else:
        ws.parker.notifyOne()
      return

proc wakeAllWorkersIfParked(s: ptr SchedulerObj) {.inline.} =
  ## Wake every parked worker during shutdown.
  if s.parkedCount.load(moAcquire) <= 0:
    return
  for workerId, ws in s.workers:
    if ws.parked.load(moAcquire):
      if s.reactorWake != nil:
        s.reactorWake(s.reactorCtx, workerId)
      else:
        ws.parker.notifyOne()

proc nextInjectStart(s: ptr SchedulerObj): int {.inline.} =
  ## Seed each producer once, then route without a shared atomic hot spot.
  if injectScheduler != cast[pointer](s):
    injectScheduler = cast[pointer](s)
    injectCursor = s.routeSeed.fetchAdd(1, moRelaxed)
  result = injectCursor mod s.numWorkers
  inc injectCursor

proc tryEnqueueInjectTask(s: ptr SchedulerObj, task: var OwnedSchedulerTask,
                          start: int): bool {.inline.} =
  ## Probe every bounded shard once, starting at the producer's preferred worker.
  for offset in 0 ..< s.numWorkers:
    let ws = s.workers[(start + offset) mod s.numWorkers]
    if ws.injectQueue.tryEnqueue(task):
      s.wakeWorkerIfParked((start + offset) mod s.numWorkers)
      return true

proc enqueueInjectTaskBlocking(s: ptr SchedulerObj,
                               task: var OwnedSchedulerTask): bool =
  var spins = 256
  var start = s.nextInjectStart()
  while not s.shutdown.load(moAcquire):
    if s.tryEnqueueInjectTask(task, start):
      return true
    start = (start + 1) mod s.numWorkers
    # Full shards already guarantee runnable work. Workers recheck their rings
    # after publishing the parked state, so no extra wake probe is needed here.
    if spins > 0:
      cpuRelax()
      dec spins
    else:
      sleep(0)
      spins = 256
  result = false

proc stealFrom(ws: ptr WorkerState): OwnedSchedulerTask {.inline.} =
  ## Thief: steal from peer's deque (FIFO, lock-free CAS).
  ws.deque.steal()

proc workerMain(arg: WorkerArg) {.thread.} =
  let s = arg.scheduler
  let myIdx = arg.idx
  workerIdx = myIdx
  isSchedulerWorker = true
  currentWorkerId = myIdx
  currentSchedulerPtr = cast[pointer](s)
  {.cast(gcsafe).}:
    setCurrentRuntime(cast[CpsRuntime](arg.runtime))
  if s.reactorSetup != nil:
    s.reactorSetup(s.reactorCtx, myIdx)

  let myState = s.workers[myIdx]
  var rng = initXorShift32(myIdx * 31 + 17)
  var tasksUntilIoPoll = 64

  template unpark() =
    myState.parked.store(false, moRelease)
    discard s.parkedCount.fetchSub(1, moAcquireRelease)

  while true:
    var task: OwnedSchedulerTask

    # 0. Try worker-pinned inbox first.
    task = popPinned(myState)

    # 1. Try local deque (LIFO, cache-friendly)
    if task.fn == nil:
      task = popLocal(myState)

    # 2. Try this worker's external injection shard (FIFO, single-consumer)
    if task.fn == nil:
      task = popInjected(myState)

    # Prefer ready work on this worker's selector before touching remote deque
    # cache lines. Under network load this keeps the I/O path thread-affine and
    # avoids an O(workers) steal scan between every readiness batch. When the
    # selector has nothing ready, CPU work stealing proceeds as before.
    if task.fn == nil and s.reactorPollNow != nil and
       (s.reactorShouldDrain == nil or
        s.reactorShouldDrain(s.reactorCtx, myIdx)):
      if s.reactorPollNow(s.reactorCtx, myIdx):
        continue

    # 3. Steal from peers: random-start round-robin ensures every peer
    #    is checked exactly once (vs pure random which can revisit peers).
    if task.fn == nil and s.numWorkers > 1:
      let start = rng.rand(s.numWorkers)
      for i in 1 ..< s.numWorkers:
        let victimIdx = (start + i) mod s.numWorkers
        if victimIdx != myIdx:
          task = stealFrom(s.workers[victimIdx])
          if task.fn != nil:
            break

    if task.fn != nil:
      {.cast(gcsafe).}:
        runTask(s, task)
      if s.reactorPollNow != nil:
        dec tasksUntilIoPoll
        if tasksUntilIoPoll == 0:
          discard s.reactorPollNow(s.reactorCtx, myIdx)
          tasksUntilIoPoll = 64
      continue

    # No work found — check shutdown before parking
    if s.shutdown.load(moAcquire):
      break

    # Snapshot the wake epoch before publishing the parked state. Rechecking
    # both inboxes afterwards closes the enqueue-before-sleep race.
    let observedEpoch = myState.parker.prepareWait()
    myState.parked.store(true, moRelease)
    discard s.parkedCount.fetchAdd(1, moAcquireRelease)
    if not myState.injectQueue.isEmpty():
      unpark()
      continue
    if hasPending(myState.pinnedQueue):
      unpark()
      continue
    if s.shutdown.load(moAcquire):
      unpark()
      break
    if s.reactorPoll != nil:
      s.reactorPoll(s.reactorCtx, myIdx)
    else:
      myState.parker.wait(observedEpoch)
    unpark()
  if s.reactorTeardown != nil:
    s.reactorTeardown(s.reactorCtx, myIdx)
  {.cast(gcsafe).}:
    setCurrentRuntime(nil)
  currentSchedulerPtr = nil
  isSchedulerWorker = false
  currentWorkerId = -1

proc newScheduler*(runtime: CpsRuntime, numWorkers: int = 0,
                   maxGlobalQueue: int = DefaultGlobalQueueCapacity,
                   reactorCtx: pointer = nil,
                   reactorSetup: SchedulerReactorHook = nil,
                   reactorPoll: SchedulerReactorHook = nil,
                   reactorPollNow: SchedulerReactorPollHook = nil,
                   reactorShouldDrain: SchedulerReactorPredicateHook = nil,
                   reactorWake: SchedulerReactorHook = nil,
                   reactorTeardown: SchedulerReactorHook = nil): Scheduler =
  ## Create a new scheduler.
  ## Non-positive queue capacities use the bounded default.
  let n = max(1, if numWorkers <= 0: countProcessors() else: numWorkers)
  let maxQ =
    if maxGlobalQueue <= 0: DefaultGlobalQueueCapacity
    else: maxGlobalQueue
  let obj = cast[ptr SchedulerObj](allocShared0(sizeof(SchedulerObj)))
  obj.numWorkers = n
  obj.shutdown.store(false, moRelaxed)
  obj.parkedCount.store(0, moRelaxed)
  obj.wakeCursor.store(0, moRelaxed)
  obj.routeSeed.store(0, moRelaxed)
  obj.reactorCtx = reactorCtx
  obj.reactorSetup = reactorSetup
  obj.reactorPoll = reactorPoll
  obj.reactorPollNow = reactorPollNow
  obj.reactorShouldDrain = reactorShouldDrain
  obj.reactorWake = reactorWake
  obj.reactorTeardown = reactorTeardown
  # Use power-of-two shards without independently rounding every shard up.
  # A few shards are doubled to consume the remainder, keeping aggregate ring
  # storage bounded by the configured queue budget (except the two-slot minimum).
  let queueBudget = max(maxQ, n * 2)
  let baseShardCapacity = floorPowerOfTwo(max(2, queueBudget div n))
  let largerShardCount = min(n,
    (queueBudget - baseShardCapacity * n) div baseShardCapacity)
  obj.workers = newSeq[ptr WorkerState](n)
  for i in 0 ..< n:
    let ws = cast[ptr WorkerState](allocShared0(sizeof(WorkerState)))
    initChaseLevDeque(ws.deque)
    let shardCapacity =
      if i < largerShardCount: baseShardCapacity * 2
      else: baseShardCapacity
    initMpscRingQueue(ws.injectQueue, shardCapacity)
    initMpscQueue(ws.pinnedQueue)
    initAtomicParker(ws.parker)
    ws.parked.store(false, moRelaxed)
    obj.workers[i] = ws
  obj.threads = newSeq[Thread[WorkerArg]](n)
  for i in 0 ..< n:
    let arg = WorkerArg(scheduler: obj, idx: i,
                        runtime: cast[pointer](runtime))
    createThread(obj.threads[i], workerMain, arg)
  result = Scheduler(obj: obj)

proc schedule*(s: Scheduler, taskArg: sink SchedulerTask) =
  ## Schedule a task for execution.
  ## If called from a worker thread, pushes to the local deque (lock-free).
  ## Otherwise, routes to a per-worker injection shard and wakes its owner.
  let obj = s.obj
  var ownedArg = move(taskArg)
  prepareCrossThreadClosure(ownedArg)
  var task = takeTask(ownedArg)
  if isSchedulerWorker and currentSchedulerPtr == cast[pointer](obj):
    # A closure created by this worker may be stolen, but its captured graph
    # must still be destroyed by this worker under regular ARC/ORC. The thief
    # invokes it through the raw pair and returns a release marker to source.
    when not compileOption("gc", "atomicArc"):
      let remote = cast[ptr RemoteClosure](allocShared0(sizeof(RemoteClosure)))
      remote.task = task
      remote.sourceWorker = workerIdx
      task = OwnedSchedulerTask(
        fn: cast[pointer](remoteInvokeMarker), env: cast[pointer](remote))
    # On a worker - push to local deque (lock-free LIFO)
    let ws = obj.workers[workerIdx]
    if ws.deque.push(task):
      # Local fan-out can create stealable work on one worker. Wake one parked
      # peer if there is backlog and at least one worker is parked.
      # Check parkedCount first (likely cached) to avoid the deque.len() atomic
      # loads on the thief-contended top cache line in the common case.
      if obj.parkedCount.load(moAcquire) > 0 and ws.deque.len() > 1:
        obj.wakeOneWorkerIfParked()
    else:
      # Local deque overflow: prefer another worker's injection shard; if all
      # saturated, execute inline to preserve progress without unbounded growth.
      let start = (workerIdx + 1) mod obj.numWorkers
      if obj.tryEnqueueInjectTask(task, start):
        discard
      else:
        {.cast(gcsafe).}:
          runTask(obj, task)
  else:
    # External thread - lock-free sharded push + exact-worker wake.
    # enqueueInjectTaskBlocking already wakes a worker on success.
    when not compileOption("gc", "atomicArc"):
      let route = currentClosureReturnRoute()
      if route.release != nil:
        route.retain(route.ctx)
        let returned = cast[ptr ReturnedClosure](
          allocShared0(sizeof(ReturnedClosure)))
        returned.task = task
        returned.route = route
        task = OwnedSchedulerTask(
          fn: cast[pointer](returnedInvokeMarker),
          env: cast[pointer](returned))
    if not obj.enqueueInjectTaskBlocking(task):
      if task.fn == cast[pointer](returnedInvokeMarker):
        let returned = cast[ptr ReturnedClosure](task.env)
        returned.route.release(returned.route.ctx, returned.route.owner,
                               returned.task)
        deallocShared(returned)
      else:
        releaseClosureTask(task, SchedulerTask)

proc scheduleContinuation*(s: Scheduler, continuation: sink Continuation) =
  ## Schedule a continuation without allocating a closure envelope.
  ##
  ## A resumed CPS graph can still be aliased by its pending future. ARC/ORC
  ## reference counts and ORC's cycle-root list are thread-local, so it must
  ## return to its owning worker rather than enter the stealable CPU deque.
  ## Fresh, isolated CPU jobs submitted through ``schedule`` remain stealable.
  let obj = s.obj
  var ownedContinuation = move(continuation)
  var task = takeContinuation(ownedContinuation)
  if isSchedulerWorker and currentSchedulerPtr == cast[pointer](obj):
    let ws = obj.workers[workerIdx]
    # This worker is both producer and sole consumer of its injection shard;
    # using the bounded ring retains the 16-byte task footprint and avoids a
    # pinned-queue node allocation on every await/resume transition.
    if not ws.injectQueue.tryEnqueue(task):
      {.cast(gcsafe).}:
        runTask(obj, task)
  else:
    if not obj.enqueueInjectTaskBlocking(task):
      releaseContinuation(task)

proc schedulePinned*(s: Scheduler, workerId: int,
                     taskArg: sink SchedulerTask): bool =
  ## Schedule a task to run on a specific worker's pinned inbox.
  let obj = s.obj
  if obj == nil:
    return false
  if obj.shutdown.load(moAcquire):
    return false
  if workerId < 0 or workerId >= obj.numWorkers:
    return false
  let ws = obj.workers[workerId]
  if ws == nil:
    return false
  var task = move(taskArg)
  prepareCrossThreadClosure(task)
  var ownedTask = takeTask(task)
  if isSchedulerWorker and currentSchedulerPtr == cast[pointer](obj) and
     currentWorkerId != workerId:
    let remote = cast[ptr RemoteClosure](allocShared0(sizeof(RemoteClosure)))
    remote.task = ownedTask
    remote.sourceWorker = currentWorkerId
    ownedTask = OwnedSchedulerTask(
      fn: cast[pointer](remoteInvokeMarker), env: cast[pointer](remote))
  elif not isSchedulerWorker or currentSchedulerPtr != cast[pointer](obj):
    when not compileOption("gc", "atomicArc"):
      let route = currentClosureReturnRoute()
      if route.release != nil:
        route.retain(route.ctx)
        let returned = cast[ptr ReturnedClosure](
          allocShared0(sizeof(ReturnedClosure)))
        returned.task = ownedTask
        returned.route = route
        ownedTask = OwnedSchedulerTask(
          fn: cast[pointer](returnedInvokeMarker),
          env: cast[pointer](returned))
  let node = allocNode(ownedTask)
  enqueue(ws.pinnedQueue, node)
  obj.wakeWorkerIfParked(workerId)
  result = true

proc scheduleClosureRelease*(s: Scheduler, workerId: int,
                             closure: OwnedClosureTask): bool =
  ## Return a previously invoked closure environment to its ARC/ORC owner.
  ## The release marker contains only raw words, so enqueueing it does not
  ## create another managed cross-thread ownership edge.
  let obj = s.obj
  if obj == nil or obj.shutdown.load(moAcquire) or
     workerId < 0 or workerId >= obj.numWorkers:
    return false
  let remote = cast[ptr RemoteClosure](allocShared0(sizeof(RemoteClosure)))
  remote.task = closure
  remote.sourceWorker = workerId
  var releaseTask = OwnedSchedulerTask(
    fn: cast[pointer](remoteReleaseMarker), env: cast[pointer](remote))
  let node = allocNode(releaseTask)
  enqueue(obj.workers[workerId].pinnedQueue, node)
  obj.wakeWorkerIfParked(workerId)
  result = true

proc scheduleOwnedClosure*(s: Scheduler, workerId: int,
                           closure: OwnedClosureTask): bool =
  ## Enqueue a refcount-neutral closure on its designated ARC/ORC owner.
  let obj = s.obj
  if obj == nil or obj.shutdown.load(moAcquire) or
     workerId < 0 or workerId >= obj.numWorkers:
    return false
  var task = closure
  let node = allocNode(task)
  enqueue(obj.workers[workerId].pinnedQueue, node)
  obj.wakeWorkerIfParked(workerId)
  result = true

proc shutdownScheduler*(s: Scheduler) =
  ## Shut down scheduler and release its runtime resources.
  let obj = s.obj
  obj.shutdown.store(true, moRelease)

  obj.wakeAllWorkersIfParked()

  for i in 0 ..< obj.numWorkers:
    joinThread(obj.threads[i])

  for i in 0 ..< obj.numWorkers:
    # Drain remaining items so their ref counts are properly released
    # before the buffer is freed. All workers have stopped at this point.
    drainAll(obj.workers[i].deque)
    destroyChaseLevDeque(obj.workers[i].deque)
    deinitMpscRingQueue(obj.workers[i].injectQueue)
    discardAll(obj.workers[i].pinnedQueue)
    deallocShared(obj.workers[i])

  deallocShared(obj)
  s.obj = nil
