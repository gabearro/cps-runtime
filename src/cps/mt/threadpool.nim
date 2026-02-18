## Thread Pool for CPS MT Runtime
##
## A simple worker thread pool using a shared FIFO queue with
## Lock + Cond. Workers block on the condition variable waiting
## for tasks. Used by spawnBlocking to offload blocking work.

import std/[locks, cpuinfo, deques]

type
  TaskProc = proc() {.gcsafe.}

  WorkQueue = object
    lock: Lock
    cond: Cond
    spaceCond: Cond
    tasks: Deque[TaskProc]
    maxPending: int
    shutdown: bool

  WorkerArg = object
    queue: ptr WorkQueue
    setup: proc() {.gcsafe.}  ## Called once on worker thread before processing tasks

  ThreadPool* = ref object
    workers: seq[Thread[WorkerArg]]
    queue: ptr WorkQueue
    numThreads*: int

proc workerMain(arg: WorkerArg) {.thread.} =
  if arg.setup != nil:
    arg.setup()
  let q = arg.queue
  while true:
    var task: TaskProc
    acquire(q.lock)
    while q.tasks.len == 0 and not q.shutdown:
      wait(q.cond, q.lock)
    if q.shutdown and q.tasks.len == 0:
      release(q.lock)
      break
    task = q.tasks.popFirst()
    if q.tasks.len < q.maxPending:
      signal(q.spaceCond)
    release(q.lock)
    task()

proc newThreadPool*(numThreads: int = 0,
                    workerSetup: proc() {.gcsafe.} = nil,
                    maxPendingTasks: int = 65536): ThreadPool =
  ## Create a thread pool with the given number of workers.
  ## If numThreads is 0, defaults to countProcessors().
  ## workerSetup is called once on each worker thread before it starts processing.
  let n = if numThreads <= 0: countProcessors() else: numThreads
  let maxPending = if maxPendingTasks <= 0: high(int) else: maxPendingTasks
  result = ThreadPool(numThreads: n)
  result.queue = cast[ptr WorkQueue](allocShared0(sizeof(WorkQueue)))
  initLock(result.queue.lock)
  initCond(result.queue.cond)
  initCond(result.queue.spaceCond)
  result.queue.tasks = initDeque[TaskProc]()
  result.queue.maxPending = maxPending
  result.queue.shutdown = false
  result.workers = newSeq[Thread[WorkerArg]](n)
  let arg = WorkerArg(queue: result.queue, setup: workerSetup)
  for i in 0 ..< n:
    createThread(result.workers[i], workerMain, arg)

proc submit*(pool: ThreadPool, task: proc() {.gcsafe.}) =
  ## Submit a task to the thread pool for execution.
  acquire(pool.queue.lock)
  while pool.queue.tasks.len >= pool.queue.maxPending and not pool.queue.shutdown:
    wait(pool.queue.spaceCond, pool.queue.lock)
  if pool.queue.shutdown:
    release(pool.queue.lock)
    return
  pool.queue.tasks.addLast(task)
  signal(pool.queue.cond)
  release(pool.queue.lock)

proc shutdown*(pool: ThreadPool) =
  ## Signal all workers to stop and wait for them to finish.
  acquire(pool.queue.lock)
  pool.queue.shutdown = true
  broadcast(pool.queue.cond)
  broadcast(pool.queue.spaceCond)
  release(pool.queue.lock)
  for i in 0 ..< pool.workers.len:
    joinThread(pool.workers[i])
  deinitLock(pool.queue.lock)
  deinitCond(pool.queue.cond)
  deinitCond(pool.queue.spaceCond)
  deallocShared(pool.queue)
  pool.queue = nil
