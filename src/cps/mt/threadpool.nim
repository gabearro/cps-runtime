## Thread Pool for CPS MT Runtime
##
## Worker thread pool using a lock-free MPMC ring queue for task dispatch.
## Workers park on an atomic wake epoch when idle. Used by spawnBlocking
## to offload blocking work without stalling the event loop.

import std/[cpuinfo, atomics, sysatomics]
import ../private/mpmc_ring
import ../private/atomic_parker
import ../private/cross_thread_closure
when defined(linux):
  import ../private/platform

type
  ThreadSetupProc* = proc(ctx: pointer) {.nimcall, gcsafe.}
    ## Initialize one blocking-pool worker from unmanaged state.
  RawPoolTaskProc* = proc(ctx: pointer) {.nimcall, gcsafe.}
    ## Execute an unmanaged blocking-pool work item.
  RawPoolJobHeader* = object
    ## Header embedded at offset zero in jobs submitted with ``submitRawJob``.
    run*: RawPoolTaskProc
  PoolState = object
    tasks: MpmcRingQueue[OwnedClosureTask]
    parker: AtomicParker
    shutdown: Atomic[bool]
    parkedCount: Atomic[int]

  WorkerArg = object
    state: ptr PoolState
    setup: ThreadSetupProc
    setupCtx: pointer

  ThreadPool* {.acyclic.} = ref object
    workers: seq[Thread[WorkerArg]]
    state: ptr PoolState
    dead: bool

proc rawPoolTaskMarker() {.nimcall, gcsafe.} = discard

proc runPoolTask(task: var OwnedClosureTask) {.inline.} =
  assert task.fn == cast[pointer](rawPoolTaskMarker),
    "blocking pool received a managed closure task"
  let job = cast[ptr RawPoolJobHeader](task.env)
  task = default(OwnedClosureTask)
  job.run(cast[pointer](job))

proc workerMain(arg: WorkerArg) {.thread.} =
  if arg.setup != nil:
    arg.setup(arg.setupCtx)
  let s = arg.state
  while true:
    var task: OwnedClosureTask
    if s.tasks.tryDequeue(task):
      try:
        runPoolTask(task)
      except CatchableError:
        discard
      continue

    # No work available — park until signalled
    if s.shutdown.load(moAcquire):
      break
    let observedEpoch = s.parker.prepareWait()
    discard s.parkedCount.fetchAdd(1, moAcquireRelease)
    # Re-check after marking parked so producers see parkedCount > 0
    if s.tasks.tryDequeue(task):
      discard s.parkedCount.fetchSub(1, moAcquireRelease)
      try:
        runPoolTask(task)
      except CatchableError:
        discard
      continue
    if s.shutdown.load(moAcquire):
      discard s.parkedCount.fetchSub(1, moAcquireRelease)
      break
    s.parker.wait(observedEpoch)
    discard s.parkedCount.fetchSub(1, moAcquireRelease)

proc wakeOne(s: ptr PoolState) {.inline.} =
  if s.parkedCount.load(moAcquire) <= 0:
    return
  s.parker.notifyOne()

proc newThreadPool*(numThreads: int = 0,
                    workerSetup: ThreadSetupProc = nil,
                    workerSetupCtx: pointer = nil,
                    maxPendingTasks: int = 65536): ThreadPool =
  ## Create a thread pool with the given number of workers.
  ## If numThreads is 0, defaults to the process's available processors.
  ## ``workerSetup`` is called with unmanaged context once on every worker.
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
  initAtomicParker(result.state.parker)
  result.state.shutdown.store(false, moRelaxed)
  result.state.parkedCount.store(0, moRelaxed)
  result.workers = newSeq[Thread[WorkerArg]](n)
  for i in 0 ..< n:
    let arg = WorkerArg(state: result.state,
                        setup: workerSetup, setupCtx: workerSetupCtx)
    createThread(result.workers[i], workerMain, arg)

proc submitRawJob*(pool: ThreadPool, job: pointer): bool =
  ## Submit a shared unmanaged job whose first field is ``RawPoolJobHeader``.
  ## The job owns its storage and must retire it from its ``run`` callback.
  if job == nil or pool.state.shutdown.load(moAcquire):
    return false
  let header = cast[ptr RawPoolJobHeader](job)
  assert header.run != nil, "raw blocking-pool job has no runner"
  var task = OwnedClosureTask(
    fn: cast[pointer](rawPoolTaskMarker), env: job)
  while not pool.state.tasks.tryEnqueue(task):
    if pool.state.shutdown.load(moAcquire):
      return false
    cpuRelax()
  wakeOne(pool.state)
  result = true

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
  deallocShared(pool.state)
  pool.state = nil
