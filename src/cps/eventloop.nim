## CPS Event Loop
##
## Provides an event loop that drives CPS continuations. Integrates with
## the OS selector for async I/O (sockets, timers).
##
## The event loop manages:
## - Timers (for sleep / timeouts)
## - Socket readiness (readable / writable)
## - Pending continuations (ready to run immediately)

import std/[selectors, nativesockets, monotimes, times, os, posix, atomics, sysatomics, locks]
import ./runtime
import ./private/mpsc_queue

export runtime

type LoopStats* = object
  ## Event loop performance counters.
  tickCount*: int64           ## Total number of tick() calls
  totalCallbacksRun*: int64   ## Total ready-queue callbacks executed
  totalTimersFired*: int64    ## Total timers that fired
  totalIoEvents*: int64       ## Total I/O events processed
  wakeSignalsSent*: int64     ## Wake callbacks processed on the reactor thread
  wakeSignalErrors*: int64    ## Wake-pipe write failures (best-effort, optional)
  maxTickDurationUs*: int64   ## Maximum tick duration in microseconds
  lastTickDurationUs*: int64  ## Last tick duration in microseconds

type
  TimerState = ptr Atomic[bool]

  TimerHandle* = object
    ## Handle for a scheduled timer. Call cancel() to suppress callback.
    state: TimerState

  TimerEntry = object
    deadline: MonoTime
    callbackId: int
    state: TimerState

  IoCallback = proc() {.closure.}

  EventLoop* = ref object
    selector: Selector[IoCallback]
    timers: seq[TimerEntry]
    timerCallbacks: seq[proc() {.closure.}]
    readyQueue: seq[proc() {.closure.}]
    running: bool
    ownerRuntime*: CpsRuntime
    # MT extensions (nil/default when single-threaded)
    crossThreadQueue*: MpscQueue   ## Lock-free MPSC queue for cross-thread callbacks
    wakePipeRead*: cint   ## Read end of wake pipe (-1 = not initialized)
    wakePipeWrite*: cint  ## Write end of wake pipe (-1 = not initialized)
    wakePending: Atomic[bool]  ## Coalesce wake-pipe writes
    mtActive*: bool       ## Whether MT extensions are active
    stats*: LoopStats

proc timerLess(a, b: TimerEntry): bool {.inline.} =
  a.deadline < b.deadline

# Runtime loop creation lock
var gLoopInitLock: Lock
var gLoopInitLockInit: Atomic[int]  ## 0=uninit, 1=initializing, 2=ready

proc ensureLoopInitLockReady() {.inline.} =
  if gLoopInitLockInit.load(moAcquire) == 2:
    return
  var expected = 0
  if gLoopInitLockInit.compareExchange(expected, 1, moAcquireRelease, moAcquire):
    initLock(gLoopInitLock)
    gLoopInitLockInit.store(2, moRelease)
  else:
    while gLoopInitLockInit.load(moAcquire) != 2:
      cpuRelax()

proc newTimerState(): TimerState {.inline.} =
  result = cast[TimerState](allocShared0(sizeof(Atomic[bool])))
  result[].store(false, moRelaxed)

proc cancel*(h: TimerHandle) {.inline.} =
  ## Cancel a timer callback if it has not fired yet.
  if h.state != nil:
    h.state[].store(true, moRelease)

proc isCancelled*(h: TimerHandle): bool {.inline.} =
  h.state == nil or h.state[].load(moAcquire)

proc newEventLoop*(): EventLoop =
  ## Create a new EventLoop with default (single-threaded) configuration.
  new(result)
  result.selector = newSelector[IoCallback]()
  result.timers = @[]
  result.timerCallbacks = @[]
  result.readyQueue = @[]
  result.running = false
  result.ownerRuntime = nil
  result.wakePipeRead = -1
  result.wakePipeWrite = -1
  result.mtActive = false

proc timerHeapPush(loop: EventLoop, entry: TimerEntry) {.inline.} =
  let insertAt = loop.timers.len
  loop.timers.setLen(insertAt + 1)
  loop.timers[insertAt] = entry

proc timerHeapPeek(loop: EventLoop): TimerEntry =
  if loop.timers.len == 0:
    return TimerEntry()
  var minIdx = 0
  for i in 1 ..< loop.timers.len:
    if timerLess(loop.timers[i], loop.timers[minIdx]):
      minIdx = i
  result = loop.timers[minIdx]

proc processTimersCount(loop: EventLoop): int =
  ## Process due timers, returning the number of timers that fired.
  when defined(debugTimers):
    echo "[timer] process len=", loop.timers.len
  if loop.timers.len > loop.timerCallbacks.len:
    when defined(debugTimers):
      echo "[timer] invalid metadata, resetting queue"
    loop.timers.setLen(0)
    return 0
  let now = getMonoTime()
  if loop.timers.len == 0:
    return
  let originalLen = loop.timers.len
  var write = 0
  for i in 0 ..< originalLen:
    let entry = loop.timers[i]
    if entry.callbackId < 0 or entry.callbackId >= loop.timerCallbacks.len:
      continue
    if entry.deadline <= now:
      if entry.state == nil or not entry.state[].load(moAcquire):
        var cb: proc() {.closure.} = nil
        if entry.callbackId >= 0 and entry.callbackId < loop.timerCallbacks.len:
          cb = loop.timerCallbacks[entry.callbackId]
          loop.timerCallbacks[entry.callbackId] = nil
        if cb != nil:
          when defined(debugTimers):
            echo "[timer] firing id=", entry.callbackId
          cb()
        inc result
    else:
      if write != i:
        loop.timers[write] = entry
      inc write
  # Preserve timers appended by callbacks during this processing pass.
  let appended = loop.timers.len - originalLen
  if appended > 0:
    for j in 0 ..< appended:
      loop.timers[write + j] = loop.timers[originalLen + j]
    write += appended
  if write < loop.timers.len:
    loop.timers.setLen(write)

proc getEventLoopForRuntime*(rt: CpsRuntime): EventLoop =
  ## Resolve or lazily create the runtime's event loop.
  assert rt != nil, "runtime must not be nil"
  when defined(debugTimers):
    echo "[loop] resolve runtime=", rt.id, " ptr=", cast[int](cast[pointer](rt.eventLoopPtr))
  if rt.eventLoopPtr != nil:
    when defined(debugTimers):
      echo "[loop] reuse existing loop"
    return cast[EventLoop](cast[pointer](rt.eventLoopPtr))
  ensureLoopInitLockReady()
  acquire(gLoopInitLock)
  if rt.eventLoopPtr == nil:
    let loop = newEventLoop()
    when defined(debugTimers):
      echo "[loop] create new loop"
    loop.ownerRuntime = rt
    if rt.flavor == rfMultiThread:
      loop.mtActive = true
    rt.eventLoopPtr = cast[RootRef](cast[pointer](loop))
  result = cast[EventLoop](cast[pointer](rt.eventLoopPtr))
  if result.ownerRuntime == nil:
    result.ownerRuntime = rt
  release(gLoopInitLock)

proc getEventLoop*(handle: RuntimeHandle): EventLoop =
  let rt = if handle.runtime != nil: handle.runtime else: mainRuntime().runtime
  getEventLoopForRuntime(rt)

proc getEventLoop*(): EventLoop =
  getEventLoop(currentRuntime())

proc setEventLoop*(loop: EventLoop) =
  ## Compatibility helper: sets the main runtime's loop.
  let rt = mainRuntime().runtime
  ensureLoopInitLockReady()
  acquire(gLoopInitLock)
  loop.ownerRuntime = rt
  rt.eventLoopPtr = cast[RootRef](cast[pointer](loop))
  release(gLoopInitLock)

proc tryWakeSelector*(loop: EventLoop) =
  ## Coalesced wake for selector waiters. Safe from any thread.
  if not loop.mtActive or loop.wakePipeWrite < 0:
    return
  if loop.wakePending.exchange(true, moAcquireRelease):
    return  # Wake already in flight
  var buf: array[1, byte] = [1'u8]
  while true:
    let n = posix.write(loop.wakePipeWrite, addr buf[0], 1)
    if n == 1:
      return
    let err = osLastError()
    if err == OSErrorCode(EINTR):
      continue
    # Pipe full means the reactor is already signaled; keep wakePending=true.
    return

proc markWakeDrained*(loop: EventLoop) {.inline.} =
  ## Mark the wake signal as drained so producers can signal again.
  loop.wakePending.store(false, moRelease)

proc recordWakeSignal*(loop: EventLoop) {.inline.} =
  ## Record that a wake callback was processed on the reactor thread.
  loop.stats.wakeSignalsSent += 1

proc postToEventLoop*(loop: EventLoop, cb: CrossThreadCallback) =
  ## Thread-safe: post a callback to the event loop via lock-free MPSC queue.
  ## Writes a byte to the wake pipe to unblock the reactor's select().
  assert loop.mtActive, "postToEventLoop called on non-MT event loop"
  let node = allocNode(cb)
  enqueue(loop.crossThreadQueue, node)
  loop.tryWakeSelector()

proc registerTimer*(loop: EventLoop, delayMs: int, cb: proc() {.closure.}): TimerHandle {.discardable.} =
  let timerState = newTimerState()
  let timerCb = cb
  if loop.mtActive and isSchedulerWorker:
    # Called from a worker thread — compute deadline now, then proxy to reactor.
    let deadline = getMonoTime() + initDuration(milliseconds = delayMs)
    loop.postToEventLoop(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        let cbId = loop.timerCallbacks.len
        loop.timerCallbacks.add(timerCb)
        let entry = TimerEntry(deadline: deadline, callbackId: cbId, state: timerState)
        loop.timerHeapPush(entry)
        when defined(debugTimers):
          echo "[timer] queued(mt) id=", cbId, " len=", loop.timers.len, " cbs=", loop.timerCallbacks.len
    )
  else:
    let deadline = getMonoTime() + initDuration(milliseconds = delayMs)
    let cbId = loop.timerCallbacks.len
    loop.timerCallbacks.add(timerCb)
    let entry = TimerEntry(deadline: deadline, callbackId: cbId, state: timerState)
    loop.timerHeapPush(entry)
    when defined(debugTimers):
      echo "[timer] queued id=", cbId, " len=", loop.timers.len, " cbs=", loop.timerCallbacks.len
  result = TimerHandle(state: timerState)

proc registerRead*(loop: EventLoop, fd: int | SocketHandle, cb: proc() {.closure.}) =
  if loop.mtActive and isSchedulerWorker:
    let fdVal = fd.SocketHandle
    loop.postToEventLoop(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        loop.selector.registerHandle(fdVal, {Event.Read}, cb)
    )
  else:
    loop.selector.registerHandle(fd.SocketHandle, {Event.Read}, cb)

proc registerWrite*(loop: EventLoop, fd: int | SocketHandle, cb: proc() {.closure.}) =
  if loop.mtActive and isSchedulerWorker:
    let fdVal = fd.SocketHandle
    loop.postToEventLoop(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        loop.selector.registerHandle(fdVal, {Event.Write}, cb)
    )
  else:
    loop.selector.registerHandle(fd.SocketHandle, {Event.Write}, cb)

proc unregister*(loop: EventLoop, fd: int | SocketHandle) =
  if loop.mtActive and isSchedulerWorker:
    let fdVal = fd.SocketHandle
    loop.postToEventLoop(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        try:
          loop.selector.unregister(fdVal)
        except Exception:
          discard
    )
  else:
    try:
      loop.selector.unregister(fd.SocketHandle)
    except Exception:
      discard

proc scheduleCallback*(loop: EventLoop, cb: proc() {.closure.}) =
  discard loop.registerTimer(0, cb)

proc scheduleCallback*(cb: proc() {.closure.}) =
  getEventLoop().scheduleCallback(cb)

proc drainCrossThreadQueue*(loop: EventLoop) =
  ## Drain all callbacks from the lock-free MPSC queue (event loop thread only).
  if not loop.mtActive:
    return
  while true:
    let node = dequeue(loop.crossThreadQueue)
    if node == nil:
      break
    let cb = node.callback
    freeNode(node)
    cb()

proc processIo(loop: EventLoop, timeoutMs: int): int =
  ## Process I/O events, returning the number of events processed.
  if loop.selector.isEmpty:
    return 0
  let events = loop.selector.select(timeoutMs)
  for ev in events:
    let cb = loop.selector.getData(ev.fd)
    if cb != nil:
      cb()
      inc result

proc processReady(loop: EventLoop): int =
  ## Ready queue is currently implemented via zero-delay timers.
  0

proc tick*(loop: EventLoop) =
  ## Run one iteration of the event loop.
  let prevRt = currentRuntime().runtime
  if loop.ownerRuntime != nil and loop.ownerRuntime != prevRt:
    setCurrentRuntime(loop.ownerRuntime)
  defer:
    if loop.ownerRuntime != nil and loop.ownerRuntime != prevRt:
      setCurrentRuntime(prevRt)

  when defined(cpsTrace):
    let tickStart = getMonoTime()

  loop.drainCrossThreadQueue()

  let hadReady = loop.readyQueue.len > 0
  let readyRan1 = loop.processReady()
  let firedTimers = loop.processTimersCount()

  var ioEventsThisTick = 0
  var readyRan2 = 0

  # If we actually ran callbacks this tick, return immediately
  # to give callers (runCps) a chance to check future completion
  # before we potentially block in the selector.
  if hadReady or firedTimers > 0:
    if loop.readyQueue.len > 0:
      readyRan2 = loop.processReady()
    loop.stats.tickCount += 1
    loop.stats.totalCallbacksRun += int64(readyRan1 + readyRan2)
    loop.stats.totalTimersFired += int64(firedTimers)
    when defined(cpsTrace):
      let tickEnd = getMonoTime()
      let durationUs = (tickEnd - tickStart).inMicroseconds
      loop.stats.lastTickDurationUs = durationUs
      if durationUs > loop.stats.maxTickDurationUs:
        loop.stats.maxTickDurationUs = durationUs
    return

  # Calculate timeout for selector
  var timeoutMs = -1  # Block indefinitely if nothing else to do
  if loop.readyQueue.len > 0:
    timeoutMs = 0
  elif loop.timers.len > 0:
    let now = getMonoTime()
    let nextTimer = loop.timerHeapPeek()
    let delta = nextTimer.deadline - now
    timeoutMs = max(0, int(delta.inMilliseconds))

  if not loop.selector.isEmpty:
    try:
      ioEventsThisTick = loop.processIo(timeoutMs)
    except IOSelectorsException:
      # Recover from selector descriptor invalidation without taking down
      # the runtime; timer and ready-queue work can still make progress.
      loop.selector = newSelector[IoCallback]()
      ioEventsThisTick = 0
    # Drain cross-thread queue after waking from IO
    if loop.mtActive:
      loop.drainCrossThreadQueue()
  elif timeoutMs > 0:
    # No IO to wait on, just sleep for the timer
    let sleepDur = initDuration(milliseconds = timeoutMs)
    sleep(int(sleepDur.inMilliseconds))

  loop.stats.tickCount += 1
  loop.stats.totalCallbacksRun += int64(readyRan1)
  loop.stats.totalTimersFired += int64(firedTimers)
  loop.stats.totalIoEvents += int64(ioEventsThisTick)
  when defined(cpsTrace):
    let tickEnd = getMonoTime()
    let durationUs = (tickEnd - tickStart).inMicroseconds
    loop.stats.lastTickDurationUs = durationUs
    if durationUs > loop.stats.maxTickDurationUs:
      loop.stats.maxTickDurationUs = durationUs

proc hasWork*(loop: EventLoop): bool =
  loop.readyQueue.len > 0 or
  loop.timers.len > 0 or
  not loop.selector.isEmpty or
  (loop.mtActive and not loop.crossThreadQueue.isEmpty)

proc runForever*(loop: EventLoop) =
  loop.running = true
  while loop.running and loop.hasWork:
    loop.tick()

proc runForever*() =
  getEventLoop().runForever()

proc stop*(loop: EventLoop) =
  loop.running = false

proc shutdownGracefully*(loop: EventLoop, drainTimeoutMs: int = 1000) =
  ## Stop accepting new work, drain pending callbacks, then stop.
  ## Processes ready-queue callbacks and fires due timers for up to
  ## drainTimeoutMs, then sets running = false.
  let deadline = getMonoTime() + initDuration(milliseconds = drainTimeoutMs)
  while getMonoTime() < deadline:
    loop.drainCrossThreadQueue()
    let readyRan = loop.processReady()
    let timersFired = loop.processTimersCount()
    if readyRan == 0 and timersFired == 0:
      # Nothing left to drain
      break
  loop.running = false

proc getStats*(loop: EventLoop): LoopStats =
  ## Get the current event loop performance statistics.
  loop.stats

proc resetStats*(loop: EventLoop) =
  ## Reset all event loop performance counters to zero.
  loop.stats = LoopStats()

# ============================================================
# Async primitives for use within CPS procs
# ============================================================

proc currentRuntimeIsMt(): bool {.inline.} =
  let rt = currentRuntime().runtime
  rt != nil and rt.flavor == rfMultiThread

proc cpsSleep*(ms: int): CpsVoidFuture =
  ## Sleep for `ms` milliseconds. Returns a void future.
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let timerFut = fut
  let loop = getEventLoop()
  loop.registerTimer(ms, proc() =
    timerFut.complete()
  )
  result = fut

proc cpsYield*(): CpsVoidFuture =
  ## Yield control back to the event loop for one tick.
  ## In MT mode, dispatches the completion to a worker thread
  ## instead of going through the reactor's ready queue.
  let fut = newCpsVoidFuture()
  let rt = currentRuntime().runtime
  if rt != nil and rt.yieldDispatcher != nil:
    fut.pinFutureRuntime()
    let cb = proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        fut.complete()
    rt.yieldDispatcher(cb)
  else:
    let loop = getEventLoop()
    loop.scheduleCallback(proc() =
      fut.complete()
    )
  result = fut

# ============================================================
# Running CPS procs from sync code
# ============================================================

proc blockOn*[T](handle: RuntimeHandle, fut: CpsFuture[T]): T =
  ## Block until the future completes, driving the event loop.
  ## In MT mode, complete()/fail() automatically wakes the reactor
  ## via mtWakeReactor so select() returns promptly.
  const SpinIters = 64
  let rtHandle =
    if handle.runtime != nil: handle
    else: currentRuntime()
  let targetRt = rtHandle.runtime
  let futRt = fut.ownerRuntime
  if futRt == nil:
    fut.bindFutureRuntime(rtHandle)
  elif futRt != targetRt and not fut.tryMigrateTo(rtHandle):
    raise newException(RuntimeAffinityError,
      "future cannot be executed on runtime " & $rtHandle.runtimeId() &
      ": it is pinned to runtime " & $fut.futureRuntime().runtimeId())

  let loop = getEventLoop(rtHandle)
  var guard = enter(rtHandle)
  runCpsWaitEnter(targetRt)
  try:
    while not fut.finished:
      loop.tick()
      if not fut.finished and not loop.hasWork:
        var spins = SpinIters
        while spins > 0 and not fut.finished and not loop.hasWork:
          cpuRelax()
          dec spins
        if not fut.finished and not loop.hasWork:
          waitRunCpsSignal(targetRt, fut)
    result = fut.read()
  finally:
    runCpsWaitLeave(targetRt)
    leave(guard)

proc blockOn*(handle: RuntimeHandle, fut: CpsVoidFuture) =
  ## Block until the void future completes, driving the event loop.
  const SpinIters = 64
  let rtHandle =
    if handle.runtime != nil: handle
    else: currentRuntime()
  let targetRt = rtHandle.runtime
  let futRt = fut.ownerRuntime
  if futRt == nil:
    fut.bindFutureRuntime(rtHandle)
  elif futRt != targetRt and not fut.tryMigrateTo(rtHandle):
    raise newException(RuntimeAffinityError,
      "future cannot be executed on runtime " & $rtHandle.runtimeId() &
      ": it is pinned to runtime " & $fut.futureRuntime().runtimeId())

  let loop = getEventLoop(rtHandle)
  var guard = enter(rtHandle)
  runCpsWaitEnter(targetRt)
  try:
    while not fut.finished:
      loop.tick()
      if not fut.finished and not loop.hasWork:
        var spins = SpinIters
        while spins > 0 and not fut.finished and not loop.hasWork:
          cpuRelax()
          dec spins
        if not fut.finished and not loop.hasWork:
          waitRunCpsSignal(targetRt, fut)
  finally:
    runCpsWaitLeave(targetRt)
    leave(guard)

proc runCpsOn*[T](handle: RuntimeHandle, fut: CpsFuture[T]): T {.inline.} =
  blockOn(handle, fut)

proc runCpsOn*(handle: RuntimeHandle, fut: CpsVoidFuture) {.inline.} =
  blockOn(handle, fut)

template runOn*(handle: RuntimeHandle, expr: untyped): untyped =
  block:
    withRuntime(handle):
      runCpsOn(handle, expr)

proc runCps*[T](fut: CpsFuture[T]): T =
  let h =
    if fut.ownerRuntime != nil: fut.futureRuntime()
    else: currentRuntime()
  blockOn(h, fut)

proc runCps*(fut: CpsVoidFuture) =
  let h =
    if fut.ownerRuntime != nil: fut.futureRuntime()
    else: currentRuntime()
  blockOn(h, fut)

proc waitAll*(futures: varargs[CpsVoidFuture]): CpsVoidFuture =
  ## Returns a future that completes when all given futures complete.
  ## Thread-safe: uses atomic counter in MT mode.
  let count = futures.len
  if count == 0:
    return completedVoidFuture()
  let resultFut = newCpsVoidFuture()
  if currentRuntimeIsMt():
    let counter = newAtomicCounter(count)
    for f in futures:
      f.addCallback(proc() =
        let prev = counter.value.fetchSub(1, moAcquireRelease)
        if prev == 1:
          freeAtomicCounter(counter)
          resultFut.complete()
      )
  else:
    var remaining = count
    for f in futures:
      f.addCallback(proc() =
        dec remaining
        if remaining == 0:
          resultFut.complete()
      )
  result = resultFut

# ============================================================
# Tasks - concurrent units of work
# ============================================================

type
  Task*[T] = ref object
    ## A spawned concurrent task that produces a value of type T.
    ## Can be awaited to retrieve the result, or left to run
    ## on the cooperative scheduler if the result isn't needed.
    future*: CpsFuture[T]
    name*: string  ## Optional human-readable name for debugging/tracing

  VoidTask* = ref object
    ## A spawned concurrent task that produces no value.
    future*: CpsVoidFuture
    name*: string  ## Optional human-readable name for debugging/tracing

# Task[T] - future-compatible interface so `await task` works
proc finished*[T](t: Task[T]): bool {.inline.} = t.future.finished
proc read*[T](t: Task[T]): T {.inline.} = t.future.read()
proc addCallback*[T](t: Task[T], cb: proc() {.closure.}) {.inline.} =
  t.future.addCallback(cb)
proc hasError*[T](t: Task[T]): bool {.inline.} = t.future.hasError()
proc getError*[T](t: Task[T]): ref CatchableError {.inline.} = t.future.getError()

# VoidTask - future-compatible interface
proc finished*(t: VoidTask): bool {.inline.} = t.future.finished
proc addCallback*(t: VoidTask, cb: proc() {.closure.}) {.inline.} =
  t.future.addCallback(cb)
proc hasError*(t: VoidTask): bool {.inline.} = t.future.hasError()
proc getError*(t: VoidTask): ref CatchableError {.inline.} = t.future.getError()

# Task/VoidTask cancellation
proc cancel*[T](t: Task[T]) {.inline.} = t.future.cancel()
proc cancel*(t: VoidTask) {.inline.} = t.future.cancel()
proc isCancelled*[T](t: Task[T]): bool {.inline.} = t.future.isCancelled()
proc isCancelled*(t: VoidTask): bool {.inline.} = t.future.isCancelled()
proc tryMigrateTo*[T](t: Task[T], handle: RuntimeHandle): bool {.inline.} =
  t.future.tryMigrateTo(handle)
proc tryMigrateTo*(t: VoidTask, handle: RuntimeHandle): bool {.inline.} =
  t.future.tryMigrateTo(handle)
proc migrateTo*[T](t: Task[T], handle: RuntimeHandle) {.inline.} =
  t.future.migrateTo(handle)
proc migrateTo*(t: VoidTask, handle: RuntimeHandle) {.inline.} =
  t.future.migrateTo(handle)

proc spawnOn*[T](handle: RuntimeHandle, fut: CpsFuture[T], name: string = ""): Task[T] =
  ## Spawn a CPS proc as a concurrent task.
  ## The task runs cooperatively on the event loop.
  ## Can be awaited later to retrieve the result.
  ## Optionally provide a name for debugging/tracing.
  let target =
    if handle.runtime != nil: handle
    else: currentRuntime()
  let futRt = fut.ownerRuntime
  if futRt == nil:
    fut.bindFutureRuntime(target)
  elif futRt != target.runtime and not fut.tryMigrateTo(target):
    raise newException(RuntimeAffinityError,
      "task cannot move to runtime " & $target.runtimeId() &
      ": future is runtime-pinned")
  result = Task[T](future: fut, name: name)

proc spawnOn*(handle: RuntimeHandle, fut: CpsVoidFuture, name: string = ""): VoidTask =
  ## Spawn a void CPS proc as a concurrent task.
  ## Optionally provide a name for debugging/tracing.
  let target =
    if handle.runtime != nil: handle
    else: currentRuntime()
  let futRt = fut.ownerRuntime
  if futRt == nil:
    fut.bindFutureRuntime(target)
  elif futRt != target.runtime and not fut.tryMigrateTo(target):
    raise newException(RuntimeAffinityError,
      "task cannot move to runtime " & $target.runtimeId() &
      ": future is runtime-pinned")
  result = VoidTask(future: fut, name: name)

proc spawn*[T](fut: CpsFuture[T], name: string = ""): Task[T] =
  spawnOn(currentRuntime(), fut, name)

proc spawn*(fut: CpsVoidFuture, name: string = ""): VoidTask =
  spawnOn(currentRuntime(), fut, name)

proc allTasks*[T](tasks: openArray[Task[T]]): CpsFuture[seq[T]] =
  ## Returns a future that completes with all task results once every task finishes.
  ## If any task fails, the returned future fails with that error.
  ## Thread-safe: uses atomic counter in MT mode.
  let count = tasks.len
  if count == 0:
    return completedFuture(newSeq[T]())
  let fut = newCpsFuture[seq[T]]()
  var results = newSeq[T](count)
  if currentRuntimeIsMt():
    let counter = newAtomicCounter(count)
    proc makeCallback(taskFut: CpsFuture[T], idx: int): proc() {.closure.} =
      result = proc() =
        if taskFut.hasError():
          if not counter.failed.exchange(true, moAcquireRelease):
            fut.fail(taskFut.getError())
        else:
          results[idx] = taskFut.read()
        let prev = counter.value.fetchSub(1, moAcquireRelease)
        if prev == 1:
          let failedAny = counter.failed.load(moAcquire)
          freeAtomicCounter(counter)
          if not failedAny:
            fut.complete(results)
    for i in 0 ..< count:
      let taskFut = tasks[i].future
      taskFut.addCallback(makeCallback(taskFut, i))
  else:
    var remaining = count
    proc makeCallback(taskFut: CpsFuture[T], idx: int): proc() {.closure.} =
      result = proc() =
        if taskFut.hasError():
          if not fut.finished:
            fut.fail(taskFut.getError())
        else:
          results[idx] = taskFut.read()
          dec remaining
          if remaining == 0:
            fut.complete(results)
    for i in 0 ..< count:
      let taskFut = tasks[i].future
      taskFut.addCallback(makeCallback(taskFut, i))
  result = fut

proc allTasks*(tasks: openArray[VoidTask]): CpsVoidFuture =
  ## Returns a future that completes when all void tasks finish.
  ## Thread-safe: uses atomic counter in MT mode.
  let count = tasks.len
  if count == 0:
    return completedVoidFuture()
  let fut = newCpsVoidFuture()
  if currentRuntimeIsMt():
    let counter = newAtomicCounter(count)
    proc makeCallback(taskFut: CpsVoidFuture): proc() {.closure.} =
      result = proc() =
        if taskFut.hasError():
          if not counter.failed.exchange(true, moAcquireRelease):
            fut.fail(taskFut.getError())
        let prev = counter.value.fetchSub(1, moAcquireRelease)
        if prev == 1:
          let failedAny = counter.failed.load(moAcquire)
          freeAtomicCounter(counter)
          if not failedAny:
            fut.complete()
    for i in 0 ..< count:
      let taskFut = tasks[i].future
      taskFut.addCallback(makeCallback(taskFut))
  else:
    var remaining = count
    proc makeCallback(taskFut: CpsVoidFuture): proc() {.closure.} =
      result = proc() =
        if taskFut.hasError():
          if not fut.finished:
            fut.fail(taskFut.getError())
        else:
          dec remaining
          if remaining == 0:
            fut.complete()
    for i in 0 ..< count:
      let taskFut = tasks[i].future
      taskFut.addCallback(makeCallback(taskFut))
  result = fut

proc runCps*[T](t: Task[T]): T =
  ## Block until a task completes, driving the event loop.
  runCps(t.future)

proc runCps*(t: VoidTask) =
  ## Block until a void task completes, driving the event loop.
  runCps(t.future)
