## Work-Stealing Scheduler for CPS MT Runtime
##
## N worker threads execute CPS continuations with work-stealing
## load balancing. Each worker has a local deque; when empty, it
## tries the global inject queue, then steals from a random peer.
##
## Workers park on a condition variable when no work is available.

import std/[locks, cpuinfo, atomics, os]
import ../runtime
import ../private/chase_lev
import ../private/mpmc_ring
import ../private/mpsc_queue

# Simple xorshift32 PRNG for random peer selection.
# Avoids importing std/random which causes OpenSSL library conflicts on macOS.
type XorShift32 = object
  state: uint32

proc initXorShift32(seed: int): XorShift32 =
  result.state = uint32(seed)
  if result.state == 0: result.state = 1  # must be non-zero

proc next(rng: var XorShift32): uint32 =
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 17)
  x = x xor (x shl 5)
  rng.state = x
  result = x

proc rand(rng: var XorShift32, maxVal: int): int =
  result = int(rng.next() mod uint32(maxVal + 1))

type
  SchedulerTask* = proc() {.closure, gcsafe.}

  WorkerState = object
    deque: ChaseLevDeque[SchedulerTask]  ## Lock-free work-stealing deque
    pinnedQueue: MpscQueue               ## Lock-free MPSC queue for worker-pinned tasks
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
    obj*: ptr SchedulerObj

# Thread-local worker index within the scheduler (for deque access).
# Only meaningful when isSchedulerWorker is true.
var workerIdx {.threadvar.}: int

proc popLocal(ws: ptr WorkerState): SchedulerTask {.inline.} =
  ## Owner: pop from local deque (LIFO, lock-free).
  ws.deque.pop()

proc popGlobal(s: ptr SchedulerObj): SchedulerTask =
  ## Pop from lock-free MPMC inject queue.
  var task: SchedulerTask = nil
  if s.injectQueue.tryDequeue(task):
    result = task
    discard s.injectLen.fetchSub(1, moAcquireRelease)
  else:
    result = nil

proc popPinned(ws: ptr WorkerState): SchedulerTask {.inline.} =
  let node = dequeue(ws.pinnedQueue)
  if node == nil:
    return nil
  result = cast[SchedulerTask](node.callback)
  freeNode(node)

proc pinnedQueueHasPending(ws: ptr WorkerState): bool {.inline.} =
  ## MPSC enqueue has a brief window where tail is advanced before prev.next
  ## is linked. In that window isEmpty() can transiently read true even though
  ## work is in flight, so also check head != tail.
  if not isEmpty(ws.pinnedQueue):
    return true
  let head = ws.pinnedQueue.head
  let tail = cast[ptr MpscNode](ws.pinnedQueue.tail.load(moAcquire))
  result = head != tail

proc tryReserveInjectSlot(s: ptr SchedulerObj): bool {.inline.} =
  while true:
    let cur = s.injectLen.load(moAcquire)
    if cur >= s.maxGlobalQueue:
      return false
    var expected = cur
    if s.injectLen.compareExchange(expected, cur + 1, moAcquireRelease, moAcquire):
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
  discard s.injectLen.fetchSub(1, moAcquireRelease)
  false

proc enqueueInjectTaskBlocking(s: ptr SchedulerObj, task: SchedulerTask): bool =
  var spins = 128
  while not s.shutdown.load(moAcquire):
    if s.tryReserveInjectSlot():
      if s.enqueueInjectTask(task):
        s.wakeOneWorkerIfParked()
        return true
      discard s.injectLen.fetchSub(1, moAcquireRelease)
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

    # 3. Try stealing from a random peer (FIFO from front)
    if task == nil and s.numWorkers > 1:
      var attempts = s.numWorkers - 1
      while task == nil and attempts > 0:
        let victim = rng.rand(s.numWorkers - 2)
        let victimIdx = if victim >= myIdx: victim + 1 else: victim
        task = stealFrom(s.workers[victimIdx])
        dec attempts

    if task != nil:
      {.cast(gcsafe).}:
        task()
      continue

    # No work found - check shutdown before parking
    if s.shutdown.load(moAcquire):
      break

    # Park: wait on global condition
    acquire(s.globalLock)
    myState.parked = true
    discard s.parkedCount.fetchAdd(1, moAcquireRelease)
    # Mark parked before checking queues so producers can reliably see
    # parkedCount > 0 and wake us for newly enqueued work.
    if s.injectLen.load(moAcquire) > 0:
      myState.parked = false
      discard s.parkedCount.fetchSub(1, moAcquireRelease)
      release(s.globalLock)
      continue
    if pinnedQueueHasPending(myState):
      myState.parked = false
      discard s.parkedCount.fetchSub(1, moAcquireRelease)
      release(s.globalLock)
      continue
    if s.shutdown.load(moAcquire):
      myState.parked = false
      discard s.parkedCount.fetchSub(1, moAcquireRelease)
      release(s.globalLock)
      break
    wait(s.globalCond, s.globalLock)
    myState.parked = false
    discard s.parkedCount.fetchSub(1, moAcquireRelease)
    release(s.globalLock)
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
      if ws.deque.len() > 1 and obj.parkedCount.load(moAcquire) > 0:
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
    # External thread - lock-free push to inject queue + wake
    if not obj.enqueueInjectTaskBlocking(task):
      return
    obj.wakeOneWorkerIfParked()

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
  let node = allocNode(cast[CrossThreadCallback](task))
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
    destroyChaseLevDeque(obj.workers[i].deque)
    while true:
      let node = dequeue(obj.workers[i].pinnedQueue)
      if node == nil:
        break
      freeNode(node)
    deallocShared(obj.workers[i])

  deinitMpmcRingQueue(obj.injectQueue)
  deinitLock(obj.globalLock)
  deinitCond(obj.globalCond)
  deallocShared(obj)
  s.obj = nil
