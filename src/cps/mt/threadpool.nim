## Thread Pool for CPS MT Runtime
##
## Worker thread pool using a lock-free MPMC ring queue for task dispatch.
## Workers park on an atomic wake epoch when idle. Used by spawnBlocking
## to offload blocking work without stalling the event loop.

import std/[cpuinfo, atomics, sysatomics]
import ../private/mpmc_ring
import ../private/mpsc_queue
import ../private/atomic_parker
import ../private/cross_thread_closure
when defined(linux):
  import ../private/platform

type
  TaskProc = proc() {.gcsafe.}
  PoolState = object
    tasks: MpmcRingQueue[OwnedClosureTask]
    releaseQueues: ptr UncheckedArray[MpscQueue[OwnedClosureTask]]
    workerCount: int
    pendingReleases: Atomic[int]
    parker: AtomicParker
    shutdown: Atomic[bool]
    parkedCount: Atomic[int]

  WorkerArg = object
    state: ptr PoolState
    idx: int
    setup: proc() {.gcsafe.}

  ThreadPool* {.acyclic.} = ref object
    workers: seq[Thread[WorkerArg]]
    state: ptr PoolState
    dead: bool

proc retainReturnedClosure(ctx: pointer) {.nimcall, gcsafe.} =
  let s = cast[ptr PoolState](ctx)
  discard s.pendingReleases.fetchAdd(1, moAcquireRelease)

proc returnClosure(ctx: pointer, owner: int,
                   task: OwnedClosureTask) {.nimcall, gcsafe.} =
  let s = cast[ptr PoolState](ctx)
  var owned = task
  let node = allocNode(owned)
  enqueue(s.releaseQueues[owner], node)
  # A shared parker keeps idle memory to one epoch. Wake every pool worker so
  # the exact ORC owner drains its shard without per-worker kernel objects.
  s.parker.notifyAll()

proc drainReturnedClosures(s: ptr PoolState, owner: int) {.inline.} =
  while true:
    let node = dequeue(s.releaseQueues[owner])
    if node == nil:
      break
    var task = takePayload(node)
    freeNode(node)
    releaseClosureTask(task, TaskProc)
    let previous = s.pendingReleases.fetchSub(1, moAcquireRelease)
    if previous == 1 and s.shutdown.load(moAcquire):
      s.parker.notifyAll()

proc workerMain(arg: WorkerArg) {.thread.} =
  if arg.setup != nil:
    arg.setup()
  let s = arg.state
  bindClosureReturnRoute(ClosureReturnRoute(
    ctx: cast[pointer](s), owner: arg.idx,
    retain: retainReturnedClosure, release: returnClosure))
  while true:
    drainReturnedClosures(s, arg.idx)
    var task: OwnedClosureTask
    if s.tasks.tryDequeue(task):
      try:
        runClosureTask(task, TaskProc)
      except CatchableError:
        discard
      continue

    # No work available — park until signalled
    if s.shutdown.load(moAcquire) and
       s.pendingReleases.load(moAcquire) == 0:
      break
    let observedEpoch = s.parker.prepareWait()
    discard s.parkedCount.fetchAdd(1, moAcquireRelease)
    # Re-check after marking parked so producers see parkedCount > 0
    if s.tasks.tryDequeue(task):
      discard s.parkedCount.fetchSub(1, moAcquireRelease)
      try:
        runClosureTask(task, TaskProc)
      except CatchableError:
        discard
      continue
    if s.shutdown.load(moAcquire) and
       s.pendingReleases.load(moAcquire) == 0:
      discard s.parkedCount.fetchSub(1, moAcquireRelease)
      break
    s.parker.wait(observedEpoch)
    discard s.parkedCount.fetchSub(1, moAcquireRelease)
  drainReturnedClosures(s, arg.idx)
  clearClosureReturnRoute()

proc wakeOne(s: ptr PoolState) {.inline.} =
  if s.parkedCount.load(moAcquire) <= 0:
    return
  s.parker.notifyOne()

proc newThreadPool*(numThreads: int = 0,
                    workerSetup: proc() {.gcsafe.} = nil,
                    maxPendingTasks: int = 65536): ThreadPool =
  ## Create a thread pool with the given number of workers.
  ## If numThreads is 0, defaults to the process's available processors.
  ## workerSetup is called once on each worker thread before it starts processing.
  let detectedProcessors =
    when defined(linux):
      let allowed = platform.allowedCpuIds()
      if allowed.len > 0: allowed.len else: countProcessors()
    else:
      countProcessors()
  let n = max(1, if numThreads <= 0: detectedProcessors else: numThreads)
  let cap = if maxPendingTasks <= 0: 65536 else: maxPendingTasks
  result = ThreadPool()
  result.state = cast[ptr PoolState](allocShared0(sizeof(PoolState)))
  initMpmcRingQueue(result.state.tasks, cap)
  result.state.workerCount = n
  result.state.releaseQueues = cast[ptr UncheckedArray[MpscQueue[OwnedClosureTask]]](
    allocShared0(n * sizeof(MpscQueue[OwnedClosureTask])))
  for i in 0 ..< n:
    initMpscQueue(result.state.releaseQueues[i])
  result.state.pendingReleases.store(0, moRelaxed)
  initAtomicParker(result.state.parker)
  result.state.shutdown.store(false, moRelaxed)
  result.state.parkedCount.store(0, moRelaxed)
  result.workers = newSeq[Thread[WorkerArg]](n)
  var setup = workerSetup
  if setup != nil:
    prepareCrossThreadClosure(setup)
  for i in 0 ..< n:
    let arg = WorkerArg(state: result.state, idx: i, setup: setup)
    createThread(result.workers[i], workerMain, arg)

proc trySubmit*(pool: ThreadPool, taskArg: sink TaskProc): bool =
  ## Non-blocking submit. Returns false if the queue is full or pool is shut down.
  if pool.state.shutdown.load(moAcquire):
    return false
  var closure = move(taskArg)
  var task = takeClosureTask(closure)
  result = pool.state.tasks.tryEnqueue(task)
  if result:
    task = default(OwnedClosureTask)
    wakeOne(pool.state)
  else:
    releaseClosureTask(task, TaskProc)

proc submit*(pool: ThreadPool, taskArg: sink TaskProc) =
  ## Submit a task. Spins briefly if the queue is full, then yields.
  if pool.state.shutdown.load(moAcquire):
    return
  var closure = move(taskArg)
  var task = takeClosureTask(closure)
  while not pool.state.tasks.tryEnqueue(task):
    if pool.state.shutdown.load(moAcquire):
      releaseClosureTask(task, TaskProc)
      return
    cpuRelax()
  task = default(OwnedClosureTask)
  wakeOne(pool.state)

proc len*(pool: ThreadPool): int =
  ## Number of worker threads.
  pool.workers.len

proc shutdown*(pool: ThreadPool) =
  ## Signal all workers to stop and wait for them to finish.
  if pool.dead:
    return
  pool.dead = true
  pool.state.shutdown.store(true, moRelease)
  pool.state.parker.notifyAll()
  for i in 0 ..< pool.workers.len:
    joinThread(pool.workers[i])
  # Retire createThread argument closures while their allocating scheduler
  # worker is still alive; retaining Thread[WorkerArg] past scheduler shutdown
  # leaves allocator metadata pointing into destroyed thread-local storage.
  pool.workers.setLen(0)
  deinitMpmcRingQueue(pool.state.tasks)
  for i in 0 ..< pool.state.workerCount:
    discardAll(pool.state.releaseQueues[i])
  deallocShared(pool.state.releaseQueues)
  deallocShared(pool.state)
  pool.state = nil
