## Thread Pool for CPS MT Runtime
##
## Worker thread pool using a lock-free MPMC ring queue for task dispatch.
## Workers park on a condition variable when idle. Used by spawnBlocking
## to offload blocking work without stalling the event loop.

import std/[locks, cpuinfo, atomics, sysatomics]
import ../private/mpmc_ring

type
  TaskProc = proc() {.gcsafe.}

  PoolState = object
    tasks: MpmcRingQueue[TaskProc]
    parkLock: Lock
    parkCond: Cond
    shutdown: Atomic[bool]
    parkedCount: Atomic[int]

  WorkerArg = object
    state: ptr PoolState
    setup: proc() {.gcsafe.}

  ThreadPool* = ref object
    workers: seq[Thread[WorkerArg]]
    state: ptr PoolState
    dead: bool

proc workerMain(arg: WorkerArg) {.thread.} =
  if arg.setup != nil:
    arg.setup()
  let s = arg.state
  while true:
    var task: TaskProc
    if s.tasks.tryDequeue(task):
      try:
        task()
      except CatchableError:
        discard
      continue

    # No work available — park until signalled
    if s.shutdown.load(moAcquire):
      break
    acquire(s.parkLock)
    discard s.parkedCount.fetchAdd(1, moAcquireRelease)
    # Re-check after marking parked so producers see parkedCount > 0
    if s.tasks.tryDequeue(task):
      discard s.parkedCount.fetchSub(1, moAcquireRelease)
      release(s.parkLock)
      try:
        task()
      except CatchableError:
        discard
      continue
    if s.shutdown.load(moAcquire):
      discard s.parkedCount.fetchSub(1, moAcquireRelease)
      release(s.parkLock)
      break
    wait(s.parkCond, s.parkLock)
    discard s.parkedCount.fetchSub(1, moAcquireRelease)
    release(s.parkLock)

proc wakeOne(s: ptr PoolState) {.inline.} =
  if s.parkedCount.load(moAcquire) <= 0:
    return
  acquire(s.parkLock)
  signal(s.parkCond)
  release(s.parkLock)

proc newThreadPool*(numThreads: int = 0,
                    workerSetup: proc() {.gcsafe.} = nil,
                    maxPendingTasks: int = 65536): ThreadPool =
  ## Create a thread pool with the given number of workers.
  ## If numThreads is 0, defaults to countProcessors().
  ## workerSetup is called once on each worker thread before it starts processing.
  let n = if numThreads <= 0: countProcessors() else: numThreads
  let cap = if maxPendingTasks <= 0: 65536 else: maxPendingTasks
  result = ThreadPool()
  result.state = cast[ptr PoolState](allocShared0(sizeof(PoolState)))
  initMpmcRingQueue(result.state.tasks, cap)
  initLock(result.state.parkLock)
  initCond(result.state.parkCond)
  result.state.shutdown.store(false, moRelaxed)
  result.state.parkedCount.store(0, moRelaxed)
  result.workers = newSeq[Thread[WorkerArg]](n)
  let arg = WorkerArg(state: result.state, setup: workerSetup)
  for i in 0 ..< n:
    createThread(result.workers[i], workerMain, arg)

proc trySubmit*(pool: ThreadPool, task: TaskProc): bool =
  ## Non-blocking submit. Returns false if the queue is full or pool is shut down.
  if pool.state.shutdown.load(moAcquire):
    return false
  result = pool.state.tasks.tryEnqueue(task)
  if result:
    wakeOne(pool.state)

proc submit*(pool: ThreadPool, task: TaskProc) =
  ## Submit a task. Spins briefly if the queue is full, then yields.
  if pool.state.shutdown.load(moAcquire):
    return
  while not pool.state.tasks.tryEnqueue(task):
    if pool.state.shutdown.load(moAcquire):
      return
    cpuRelax()
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
  acquire(pool.state.parkLock)
  broadcast(pool.state.parkCond)
  release(pool.state.parkLock)
  for i in 0 ..< pool.workers.len:
    joinThread(pool.workers[i])
  deinitMpmcRingQueue(pool.state.tasks)
  deinitLock(pool.state.parkLock)
  deinitCond(pool.state.parkCond)
  deallocShared(pool.state)
  pool.state = nil
