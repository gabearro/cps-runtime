## Work-Stealing Scheduler for CPS MT Runtime
##
## N worker threads execute CPS continuations with work-stealing
## load balancing. Each worker has a local deque; when empty, it
## tries the global inject queue, then steals from a random peer.
##
## Workers park on a condition variable when no work is available.

import std/[locks, cpuinfo, atomics, sysatomics, os]
import ../runtime
import ../private/chase_lev
import ../private/mpmc_ring
import ../private/mpsc_queue
import ../private/xorshift

type
  SchedulerTask* = proc() {.closure, gcsafe.}

  WorkerState = object
    deque: ChaseLevDeque[SchedulerTask]  ## Lock-free work-stealing deque
    pinnedQueue: MpscQueue[SchedulerTask]  ## Lock-free MPSC queue for worker-pinned tasks
    parked: bool

  WorkerArg = object
    scheduler: ptr SchedulerObj
    idx: int
    runtime: CpsRuntime

  SchedulerObj = object
    workers: seq[ptr WorkerState]
    threads: seq[Thread[WorkerArg]]
    injectQueue: MpmcRingQueue[SchedulerTask]  ## Lock-free external submissions
    injectLen: Atomic[int]
    globalLock: Lock
    globalCond: Cond
    numWorkers: int
    maxGlobalQueue: int
    shutdown: Atomic[bool]
    parkedCount: Atomic[int]

  Scheduler* = ref object
    obj: ptr SchedulerObj

# Thread-local worker index within the scheduler (for deque access).
# Only meaningful when isSchedulerWorker is true.
var workerIdx {.threadvar.}: int

proc popLocal(ws: ptr WorkerState): SchedulerTask {.inline.} =
  ## Owner: pop from local deque (LIFO, lock-free).
  ws.deque.pop()

proc popGlobal(s: ptr SchedulerObj): SchedulerTask {.inline.} =
  ## Pop from lock-free MPMC inject queue.
  var task: SchedulerTask = nil
  if s.injectQueue.tryDequeue(task):
    result = task
    discard s.injectLen.fetchSub(1, moRelaxed)
  else:
    result = nil

proc popPinned(ws: ptr WorkerState): SchedulerTask {.inline.} =
  let node = dequeue(ws.pinnedQueue)
  if node == nil:
    return nil
  result = node.payload
  freeNode(node)

proc tryReserveInjectSlot(s: ptr SchedulerObj): bool {.inline.} =
  ## CAS-based admission control for the inject queue.
  ## Separate from the ring's own capacity so producers get bounded backpressure
  ## without entering the MPMC CAS loop.
  while true:
    let cur = s.injectLen.load(moRelaxed)
    if cur >= s.maxGlobalQueue:
      return false
    var expected = cur
    if s.injectLen.compareExchange(expected, cur + 1, moAcquireRelease, moRelaxed):
      return true

proc enqueueInjectTask(s: ptr SchedulerObj, task: SchedulerTask): bool {.inline.} =
  s.injectQueue.tryEnqueue(task)

proc wakeOneWorkerIfParked(s: ptr SchedulerObj) {.inline.} =
  ## Best-effort wake for parked workers.
  ## Uses an atomic fast path to avoid taking the park lock when idle.
  if s.parkedCount.load(moAcquire) <= 0:
    return
  acquire(s.globalLock)
  signal(s.globalCond)
  release(s.globalLock)

proc wakeAllWorkersIfParked(s: ptr SchedulerObj) {.inline.} =
  ## Wake all parked workers. Used for worker-pinned queues where only one
  ## specific worker can execute the task and signal() may wake the wrong one.
  if s.parkedCount.load(moAcquire) <= 0:
    return
  acquire(s.globalLock)
  broadcast(s.globalCond)
  release(s.globalLock)

proc tryEnqueueInjectTask(s: ptr SchedulerObj, task: SchedulerTask): bool {.inline.} =
  if not s.tryReserveInjectSlot():
    return false
  if s.enqueueInjectTask(task):
    return true
  # Should be rare: if the ring is transiently full despite reservation,
  # roll back the occupancy reservation.
  discard s.injectLen.fetchSub(1, moRelaxed)
  false

proc enqueueInjectTaskBlocking(s: ptr SchedulerObj, task: SchedulerTask): bool =
  var spins = 128
  while not s.shutdown.load(moAcquire):
    if s.tryReserveInjectSlot():
      if s.enqueueInjectTask(task):
        s.wakeOneWorkerIfParked()
        return true
      discard s.injectLen.fetchSub(1, moRelaxed)
    # Queue saturation can happen after a missed wake race. Keep nudging one
    # parked worker so producers can't spin forever on a full inject queue.
    s.wakeOneWorkerIfParked()
    if spins > 0:
      cpuRelax()
      dec spins
    else:
      sleep(0)
      spins = 32
  result = false

proc stealFrom(ws: ptr WorkerState): SchedulerTask {.inline.} =
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
    setCurrentRuntime(arg.runtime)

  let myState = s.workers[myIdx]
  var rng = initXorShift32(myIdx * 31 + 17)

  template unparkAndUnlock() =
    myState.parked = false
    discard s.parkedCount.fetchSub(1, moAcquireRelease)
    release(s.globalLock)

  while true:
    var task: SchedulerTask = nil

    # 0. Try worker-pinned inbox first.
    task = popPinned(myState)

    # 1. Try local deque (LIFO, cache-friendly)
    if task == nil:
      task = popLocal(myState)

    # 2. Try global queue (FIFO, fair)
    if task == nil:
      task = popGlobal(s)

    # 3. Steal from peers: random-start round-robin ensures every peer
    #    is checked exactly once (vs pure random which can revisit peers).
    if task == nil and s.numWorkers > 1:
      let start = rng.rand(s.numWorkers)
      for i in 1 ..< s.numWorkers:
        let victimIdx = (start + i) mod s.numWorkers
        if victimIdx != myIdx:
          task = stealFrom(s.workers[victimIdx])
          if task != nil:
            break

    if task != nil:
      {.cast(gcsafe).}:
        task()
      continue

    # No work found — check shutdown before parking
    if s.shutdown.load(moAcquire):
      break

    # Park: wait on global condition.
    # Mark parked before checking queues so producers can reliably see
    # parkedCount > 0 and wake us for newly enqueued work.
    acquire(s.globalLock)
    myState.parked = true
    discard s.parkedCount.fetchAdd(1, moAcquireRelease)
    if s.injectLen.load(moAcquire) > 0:
      unparkAndUnlock()
      continue
    if hasPending(myState.pinnedQueue):
      unparkAndUnlock()
      continue
    if s.shutdown.load(moAcquire):
      unparkAndUnlock()
      break
    wait(s.globalCond, s.globalLock)
    unparkAndUnlock()
  currentWorkerId = -1

proc newScheduler*(runtime: CpsRuntime, numWorkers: int = 0, maxGlobalQueue: int = 65536): Scheduler =
  let n = if numWorkers <= 0: countProcessors() else: numWorkers
  let maxQ = if maxGlobalQueue <= 0: high(int) else: maxGlobalQueue
  let obj = cast[ptr SchedulerObj](allocShared0(sizeof(SchedulerObj)))
  obj.numWorkers = n
  obj.maxGlobalQueue = maxQ
  obj.shutdown.store(false, moRelaxed)
  obj.parkedCount.store(0, moRelaxed)
  obj.injectLen.store(0, moRelaxed)
  initMpmcRingQueue(obj.injectQueue, maxQ)
  initLock(obj.globalLock)
  initCond(obj.globalCond)
  obj.workers = newSeq[ptr WorkerState](n)
  for i in 0 ..< n:
    let ws = cast[ptr WorkerState](allocShared0(sizeof(WorkerState)))
    initChaseLevDeque(ws.deque)
    initMpscQueue(ws.pinnedQueue)
    ws.parked = false
    obj.workers[i] = ws
  obj.threads = newSeq[Thread[WorkerArg]](n)
  for i in 0 ..< n:
    let arg = WorkerArg(scheduler: obj, idx: i, runtime: runtime)
    createThread(obj.threads[i], workerMain, arg)
  result = Scheduler(obj: obj)

proc schedule*(s: Scheduler, task: SchedulerTask) =
  ## Schedule a task for execution.
  ## If called from a worker thread, pushes to the local deque (lock-free).
  ## Otherwise, pushes to the global inject queue and wakes a worker.
  let obj = s.obj
  if isSchedulerWorker and currentSchedulerPtr == cast[pointer](obj):
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
      # Local deque overflow: prefer global queue fallback; if that is also
      # saturated, execute inline to preserve progress without unbounded growth.
      if obj.tryEnqueueInjectTask(task):
        obj.wakeOneWorkerIfParked()
      else:
        {.cast(gcsafe).}:
          task()
  else:
    # External thread - lock-free push to inject queue + wake.
    # enqueueInjectTaskBlocking already wakes a worker on success.
    discard obj.enqueueInjectTaskBlocking(task)

proc schedulePinned*(s: Scheduler, workerId: int, task: SchedulerTask): bool =
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
  let node = allocNode(task)
  enqueue(ws.pinnedQueue, node)
  obj.wakeAllWorkersIfParked()
  result = true

proc shutdownScheduler*(s: Scheduler) =
  let obj = s.obj
  obj.shutdown.store(true, moRelease)

  # Wake all parked workers
  acquire(obj.globalLock)
  broadcast(obj.globalCond)
  release(obj.globalLock)

  for i in 0 ..< obj.numWorkers:
    joinThread(obj.threads[i])

  for i in 0 ..< obj.numWorkers:
    # Drain remaining items so their ref counts are properly released
    # before the buffer is freed. All workers have stopped at this point.
    drainAll(obj.workers[i].deque)
    destroyChaseLevDeque(obj.workers[i].deque)
    discardAll(obj.workers[i].pinnedQueue)
    deallocShared(obj.workers[i])

  deinitMpmcRingQueue(obj.injectQueue)
  deinitLock(obj.globalLock)
  deinitCond(obj.globalCond)
  deallocShared(obj)
  s.obj = nil
