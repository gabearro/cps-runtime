## Sharded reactor pool.
##
## Each thread owns its runtime, selector, callbacks, and connections. This
## keeps the normal I/O path thread-local while allowing a process to scale
## across cores. A minimal wake descriptor is used only to stop each shard;
## the data path never touches the MT callback queue.
##
## Futures constructed on a shard default to local-fast state. Applications
## must keep futures and GC-managed shard state on their owning reactor thread;
## use the work-stealing MT runtime when tasks need to cross threads.

import std/[atomics, cpuinfo, os]
import ../runtime
import ../eventloop
import ../private/platform

type
  ReactorSetup* = proc(shardId: int) {.nimcall, gcsafe.}
    ## Setup must construct shard-owned state and must not capture GC-managed
    ## values. This permits isolated reactor pools to use ARC safely.

  ReactorPoolState = object
    stopping: Atomic[bool]
    started: Atomic[int]
    failed: Atomic[bool]
    wakeFds: ptr UncheckedArray[SocketHandle]

  ReactorThreadArg = object
    shardId: int
    state: ptr ReactorPoolState
    setup: ReactorSetup

  ReactorPool* = ref object
    state: ptr ReactorPoolState
    threads: seq[Thread[ReactorThreadArg]]
    joined: bool

proc shutdown*(pool: ReactorPool)

proc reactorMain(arg: ReactorThreadArg) {.thread.} =
  isReactorThread = true
  var loop: EventLoop
  var running = true
  let (wakeRead, wakeWrite) = platform.createWakePipe()
  {.cast(gcsafe).}:
    let rt = newCurrentThreadRuntime()
    setCurrentRuntime(rt)
    setLocalFutureDefault(true)
    loop = getEventLoop()
    loop.registerRead(wakeRead, proc() =
      platform.wakePipeDrain(wakeRead)
      running = false
    )
  arg.state.wakeFds[arg.shardId] = wakeWrite
  try:
    arg.setup(arg.shardId)
  except CatchableError:
    arg.state.failed.store(true, moRelease)
  discard arg.state.started.fetchAdd(1, moRelease)
  while running:
    {.cast(gcsafe).}:
      loop.tick()
  {.cast(gcsafe).}:
    loop.unregister(wakeRead)
  platform.closePipeFd(wakeRead)
  platform.closePipeFd(wakeWrite)
  isReactorThread = false
  {.cast(gcsafe).}:
    setLocalFutureDefault(false)
    setCurrentRuntime(nil)

proc startReactorPool*(setup: ReactorSetup,
                       numReactors: int = 0): ReactorPool =
  ## Start one independent event-loop thread per requested reactor.
  if setup == nil:
    raise newException(ValueError, "reactor pool requires a setup callback")
  let n = if numReactors <= 0: countProcessors() else: numReactors
  if n <= 0:
    raise newException(ValueError, "reactor pool requires at least one reactor")
  result = ReactorPool()
  result.state = cast[ptr ReactorPoolState](allocShared0(sizeof(ReactorPoolState)))
  result.state.wakeFds = cast[ptr UncheckedArray[SocketHandle]](
    allocShared0(sizeof(SocketHandle) * n))
  result.state.stopping.store(false, moRelaxed)
  result.state.started.store(0, moRelaxed)
  result.state.failed.store(false, moRelaxed)
  result.threads = newSeq[Thread[ReactorThreadArg]](n)
  for shardId in 0 ..< n:
    createThread(result.threads[shardId], reactorMain,
      ReactorThreadArg(shardId: shardId, state: result.state, setup: setup))
  while result.state.started.load(moAcquire) != n:
    sleep(0)
  if result.state.failed.load(moAcquire):
    result.shutdown()
    raise newException(CatchableError, "reactor pool setup failed")

proc stop*(pool: ReactorPool) =
  ## Request stop and wake every selector so its thread observes the request.
  if pool == nil or pool.state == nil:
    return
  if pool.state.stopping.exchange(true, moAcquireRelease):
    return
  for i in 0 ..< pool.threads.len:
    platform.wakePipeSignal(pool.state.wakeFds[i])

proc join*(pool: ReactorPool) =
  if pool == nil or pool.state == nil or pool.joined:
    return
  for i in 0 ..< pool.threads.len:
    joinThread(pool.threads[i])
  pool.joined = true
  deallocShared(pool.state.wakeFds)
  deallocShared(pool.state)
  pool.state = nil

proc shutdown*(pool: ReactorPool) =
  pool.stop()
  pool.join()

proc runReactorPool*(setup: ReactorSetup, numReactors: int = 0) =
  ## Start and join a long-running sharded reactor service.
  let pool = startReactorPool(setup, numReactors)
  pool.join()
