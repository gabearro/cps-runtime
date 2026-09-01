## CPS Event Loop
##
## Provides an event loop that drives CPS continuations. Integrates with
## the OS selector for async I/O (sockets, timers).
##
## The event loop manages:
## - Timers (for sleep / timeouts)
## - Socket readiness (readable / writable)
## - Pending continuations (ready to run immediately)

import std/[selectors, nativesockets, monotimes, times, os, atomics, sysatomics, locks]
when not defined(windows):
  import std/posix
import ./runtime
import ./private/mpsc_queue
import ./private/platform

when compileOption("gc", "orc"):
  {.pragma: cpsMtLoopAcyclic, acyclic.}
else:
  {.pragma: cpsMtLoopAcyclic.}

export runtime

type LoopStats* = object
  ## Event loop performance counters.
  tickCount*: int64           ## Total number of tick() calls
  totalCallbacksRun*: int64   ## Total ready-queue callbacks executed
  totalTimersFired*: int64    ## Total timers that fired
  totalIoEvents*: int64       ## Total I/O events processed
  callbackErrors*: int64      ## Callback exceptions isolated by the loop
  wakeSignalsSent*: int64     ## Wake callbacks processed on the reactor thread
  wakeSignalErrors*: int64    ## Wake-pipe write failures (best-effort, optional)
  maxTickDurationUs*: int64   ## Maximum tick duration in microseconds
  lastTickDurationUs*: int64  ## Last tick duration in microseconds

type
  EventLoopRawProc* = proc(ctx: pointer) {.nimcall, gcsafe.}
    ## Unmanaged callback accepted by ``postRawToEventLoop``.

  TimerState = ref object
    cancelled: Atomic[bool]

  TimerHandle* = object
    ## Handle for a scheduled timer. Call cancel() to suppress callback.
    state: TimerState

  TimerEntry = ref object
    deadline: MonoTime
    callback: proc() {.closure.}
    state: TimerState

  IoCallback = proc() {.closure.}

  PostedCallback = object
    task: OwnedClosureTask
    sourceWorker: int
    returnRoute: ClosureReturnRoute

  EventLoop* {.cpsMtLoopAcyclic.} = ref object
    selector: Selector[IoCallback]
    timers: seq[TimerEntry]
    timerCompactAt: int
    readyQueue: seq[proc() {.closure.}]
    readyScratch: seq[proc() {.closure.}]
    ioEvents: array[64, ReadyKey]
    running: bool
    ownerRuntime* {.cursor.}: CpsRuntime
    ownerThreadToken: pointer
    # MT extensions (nil/default when single-threaded)
    crossThreadQueue*: MpscQueue[PostedCallback]   ## Lock-free MPSC queue for cross-thread callbacks
    wakePipeRead*: SocketHandle   ## Read end of wake pipe (SocketHandle(-1) = not initialized)
    wakePipeWrite*: SocketHandle  ## Write end of wake pipe (SocketHandle(-1) = not initialized)
    wakePending: Atomic[bool]  ## Coalesce wake-pipe writes
    mtActive*: bool       ## Whether MT extensions are active
    when defined(linux):
      # One-shot I/O callbacks commonly rearm the same descriptor from the
      # continuation they wake. Keep those descriptors in epoll until the
      # next wait so a same-mask rearm only replaces selector data instead of
      # paying EPOLL_CTL_DEL + EPOLL_CTL_ADD. The list is reactor-local and is
      # normally bounded by the 64-entry readiness batch.
      deferredDisarms: seq[SocketHandle]
    stats*: LoopStats

const RawPostedCallback = -2
const MinTimerCompactAt = 256

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
  new(result)
  result.cancelled.store(false, moRelaxed)

proc cancel*(h: TimerHandle) {.inline.} =
  ## Cancel a timer callback if it has not fired yet.
  ## Marks the timer as cancelled. Callback release is performed on the
  ## event-loop thread when the entry is pruned from the timer heap.
  if h.state != nil:
    h.state.cancelled.store(true, moRelease)

proc isCancelled*(h: TimerHandle): bool {.inline.} =
  ## Return whether the operation was cancelled.
  h.state == nil or h.state.cancelled.load(moAcquire)

proc newEventLoop*(): EventLoop =
  ## Create a new EventLoop with default (single-threaded) configuration.
  new(result)
  result.selector = newSelector[IoCallback]()
  result.timers = @[]
  result.timerCompactAt = MinTimerCompactAt
  result.readyQueue = @[]
  result.readyScratch = @[]
  result.running = false
  result.ownerRuntime = nil
  result.ownerThreadToken = currentThreadIdentity()
  result.wakePipeRead = SocketHandle(-1)
  result.wakePipeWrite = SocketHandle(-1)
  result.mtActive = false

proc timerHeapPush(loop: EventLoop, entry: TimerEntry) {.inline.} =
  loop.timers.add(entry)
  var i = loop.timers.len - 1
  while i > 0:
    let p = (i - 1) shr 1
    if timerLess(loop.timers[i], loop.timers[p]):
      swap(loop.timers[i], loop.timers[p])
      i = p
    else:
      break

  if loop.timers.len >= loop.timerCompactAt:
    var write = 0
    for read in 0 ..< loop.timers.len:
      let state = loop.timers[read].state
      if state != nil and state.cancelled.load(moAcquire):
        loop.timers[read].callback = nil
        loop.timers[read].state = nil
      else:
        if write != read:
          loop.timers[write] = move(loop.timers[read])
        inc write
    loop.timers.setLen(write)

    # Filtering arbitrary heap slots does not preserve heap order. Rebuild it
    # bottom-up; compaction runs only when the heap doubles, so its cost is
    # amortized while cancelled callback graphs remain bounded.
    if write > 1:
      var parent = (write shr 1) - 1
      while true:
        var i = parent
        while true:
          let left = (i shl 1) + 1
          if left >= write:
            break
          let right = left + 1
          var smallest = left
          if right < write and timerLess(loop.timers[right], loop.timers[left]):
            smallest = right
          if not timerLess(loop.timers[smallest], loop.timers[i]):
            break
          swap(loop.timers[i], loop.timers[smallest])
          i = smallest
        if parent == 0:
          break
        dec parent
    loop.timerCompactAt = max(MinTimerCompactAt, write * 2)

proc timerHeapPeek(loop: EventLoop): TimerEntry =
  if loop.timers.len == 0:
    return TimerEntry()
  loop.timers[0]

proc timerHeapPop(loop: EventLoop): TimerEntry =
  let last = loop.timers.len - 1
  result = loop.timers[0]
  if last == 0:
    loop.timers.setLen(0)
    return

  loop.timers[0] = loop.timers[last]
  loop.timers.setLen(last)

  var i = 0
  while true:
    let left = (i shl 1) + 1
    if left >= loop.timers.len:
      break
    let right = left + 1
    var smallest = left
    if right < loop.timers.len and timerLess(loop.timers[right], loop.timers[left]):
      smallest = right
    if timerLess(loop.timers[smallest], loop.timers[i]):
      swap(loop.timers[i], loop.timers[smallest])
      i = smallest
    else:
      break

proc pruneCancelledTimerRoots(loop: EventLoop) =
  while loop.timers.len > 0:
    # Check the root directly without copying (avoid extra refcount bumps)
    let st = loop.timers[0].state
    if st == nil or not st.cancelled.load(moAcquire):
      break
    # Nil out callback and state in-place before popping so captured
    # closures are released on the event-loop thread in a deterministic spot.
    loop.timers[0].callback = nil
    loop.timers[0].state = nil
    discard loop.timerHeapPop()

proc recordCallbackError(loop: EventLoop) {.inline.} =
  loop.stats.callbackErrors += 1

proc runLoopCallback(loop: EventLoop, cb: proc() {.closure.}): bool {.inline.} =
  ## Run a user/runtime callback without allowing its exception to stop the
  ## reactor. The callback's own future should carry task failure semantics.
  if cb == nil:
    return false
  try:
    cb()
  except Exception:
    loop.recordCallbackError()
  true

proc processTimersCount(loop: EventLoop): int =
  ## Process due timers, returning the number of timers that fired.
  when defined(debugTimers):
    echo "[timer] process len=", loop.timers.len
  loop.pruneCancelledTimerRoots()
  let now = getMonoTime()
  while loop.timers.len > 0:
    # Check deadline directly to avoid copying the entry
    if loop.timers[0].deadline > now:
      break
    # Check if cancelled; nil out callback before popping if so
    let isCancelled = loop.timers[0].state != nil and
                      loop.timers[0].state.cancelled.load(moAcquire)
    if isCancelled:
      loop.timers[0].callback = nil
      loop.timers[0].state = nil
      discard loop.timerHeapPop()
    else:
      let fired = loop.timerHeapPop()
      if loop.runLoopCallback(fired.callback):
        inc result
    loop.pruneCancelledTimerRoots()

proc getEventLoopForRuntime*(rt: CpsRuntime): EventLoop =
  ## Resolve or lazily create the runtime's event loop.
  assert rt != nil, "runtime must not be nil"
  if currentEventLoopPtr != nil and
     currentEventLoopRuntimePtr == cast[pointer](rt):
    return cast[EventLoop](currentEventLoopPtr)
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
  ## Return the event loop bound to the current thread.
  let mainHandle = if handle.runtime == nil: mainRuntime() else: default(RuntimeHandle)
  let rt {.cursor.} =
    if handle.runtime != nil: handle.runtime else: mainHandle.runtime
  getEventLoopForRuntime(rt)

proc getEventLoop*(): EventLoop =
  ## Return the event loop bound to the current thread.
  let rt {.cursor.} = cast[CpsRuntime](currentRuntimePointer())
  getEventLoopForRuntime(rt)

proc setEventLoop*(loop: EventLoop) =
  ## Compatibility helper: sets the main runtime's loop.
  let handle = mainRuntime()
  let rt {.cursor.} = handle.runtime
  ensureLoopInitLockReady()
  acquire(gLoopInitLock)
  loop.ownerRuntime = rt
  rt.eventLoopPtr = cast[RootRef](cast[pointer](loop))
  release(gLoopInitLock)

proc tryWakeSelector*(loop: EventLoop) =
  ## Coalesced wake for selector waiters. Safe from any thread.
  if not loop.mtActive or loop.wakePipeWrite == SocketHandle(-1):
    return
  if loop.wakePending.exchange(true, moAcquireRelease):
    return  # Wake already in flight
  platform.wakePipeSignal(loop.wakePipeWrite)

proc claimCurrentThread*(loop: EventLoop) {.inline.} =
  ## Transfer selector ownership to the calling runtime worker.
  loop.ownerThreadToken = currentThreadIdentity()

proc isCurrentThreadOwner*(loop: EventLoop): bool {.inline.} =
  ## Return whether the calling thread owns this selector.
  loop.ownerThreadToken == currentThreadIdentity()

proc markWakeDrained*(loop: EventLoop) {.inline.} =
  ## Mark the wake signal as drained so producers can signal again.
  loop.wakePending.store(false, moRelease)

proc recordWakeSignal*(loop: EventLoop) {.inline.} =
  ## Record that a wake callback was processed on the reactor thread.
  loop.stats.wakeSignalsSent += 1

proc postToEventLoop*(loop: EventLoop, cbArg: sink CrossThreadCallback) =
  ## Thread-safe: post a callback to the event loop via lock-free MPSC queue.
  ## Writes a byte to the wake pipe to unblock the reactor's select().
  assert loop.mtActive, "postToEventLoop called on non-MT event loop"
  var cb = move(cbArg)
  var posted = PostedCallback(
    task: takeClosureTask(cb),
    sourceWorker: -1,
    returnRoute: default(ClosureReturnRoute))
  when not compileOption("gc", "atomicArc"):
    if isSchedulerWorker and loop.ownerRuntime != nil and
       currentSchedulerPtr == cast[pointer](loop.ownerRuntime.schedulerPtr):
      posted.sourceWorker = currentWorkerId
    else:
      let route = currentClosureReturnRoute()
      if route.release != nil:
        route.retain(route.ctx)
        posted.returnRoute = route
  let node = allocNode(posted)
  enqueue(loop.crossThreadQueue, node)
  loop.tryWakeSelector()

proc postOwnedToEventLoop*(loop: EventLoop, task: OwnedClosureTask) =
  ## Post an already-owned callback task without changing its release owner.
  ## The event-loop thread takes ownership of the closure environment.
  assert loop.mtActive, "postOwnedToEventLoop called on non-MT event loop"
  var posted = PostedCallback(
    task: task,
    sourceWorker: -1,
    returnRoute: default(ClosureReturnRoute))
  let node = allocNode(posted)
  enqueue(loop.crossThreadQueue, node)
  loop.tryWakeSelector()

proc postRawToEventLoop*(loop: EventLoop, cb: EventLoopRawProc,
                         ctx: pointer) =
  ## Post an unmanaged function/context pair to the event-loop owner.
  ## No managed closure environment crosses the thread boundary.
  assert loop.mtActive, "postRawToEventLoop called on non-MT event loop"
  var posted = PostedCallback(
    task: OwnedClosureTask(fn: cast[pointer](cb), env: ctx),
    sourceWorker: RawPostedCallback,
    returnRoute: default(ClosureReturnRoute))
  let node = allocNode(posted)
  enqueue(loop.crossThreadQueue, node)
  loop.tryWakeSelector()

proc shouldProxyToReactor*(loop: EventLoop): bool {.inline.} =
  ## In MT mode, selector/timer/ready-queue mutation must happen on the reactor
  ## thread. During bootstrap (queue/pipe not initialized) run inline.
  loop.mtActive and
    not loop.isCurrentThreadOwner() and
    loop.crossThreadQueue.isInitialized() and
    loop.wakePipeWrite != SocketHandle(-1)

proc registerTimer*(loop: EventLoop, delayMs: int, cb: proc() {.closure.}): TimerHandle {.discardable.} =
  ## Register a one-shot timer with the event loop.
  let timerState = newTimerState()
  let timerCb = cb
  if loop.shouldProxyToReactor():
    # Called from non-reactor thread — compute deadline now, then proxy to reactor.
    let deadline = getMonoTime() + initDuration(milliseconds = delayMs)
    loop.postToEventLoop(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        let entry = TimerEntry(deadline: deadline, callback: timerCb, state: timerState)
        loop.timerHeapPush(entry)
        when defined(debugTimers):
          echo "[timer] queued(mt) len=", loop.timers.len
    )
  else:
    let deadline = getMonoTime() + initDuration(milliseconds = delayMs)
    let entry = TimerEntry(deadline: deadline, callback: timerCb, state: timerState)
    loop.timerHeapPush(entry)
    when defined(debugTimers):
      echo "[timer] queued len=", loop.timers.len
  result = TimerHandle(state: timerState)

proc registerHandleSafe(loop: EventLoop, fd: SocketHandle, events: set[Event],
                        cb: proc() {.closure.}) =
  ## Defensive registration that handles fd recycling and invalid fds.
  ##
  ## Key issues addressed:
  ## 1. kqueue auto-removes events when a socket closes, but the selector's
  ##    internal table retains stale entries. updateHandle is a no-op when the
  ##    event mask matches, so recycled fds never get kevent EV_ADD.
  ## 2. On macOS/kqueue, registering a closed fd causes EBADF which corrupts
  ##    Nim's selector changes buffer (changesLength not reset on error),
  ##    poisoning ALL subsequent kevent calls.
  ## Fix: validate the fd before touching the selector.
  when defined(debugMtIo):
    debugEcho "[MT-IO] registerHandleSafe fd=", int(fd), " events=", events, " contains=", loop.selector.contains(fd)
  # This preflight is required by kqueue: a failed registration can leave its
  # buffered change list poisoned. epoll/poll do not have that failure mode,
  # and an extra fcntl for every readiness wait is pure overhead there.
  when defined(macosx) or defined(freebsd) or defined(netbsd) or
       defined(openbsd) or defined(dragonfly):
    if posix.fcntl(cint(int(fd)), F_GETFD) < 0:
      # fd is closed or invalid — skip registration to avoid corrupting
      # the kqueue selector's changes buffer.
      return
  try:
    when defined(linux):
      if loop.selector.contains(fd):
        # Linux keeps selector data separately from the epoll interest. A
        # same-mask update is syscall-free; a read/write transition is one
        # EPOLL_CTL_MOD instead of a DEL+ADD pair.
        discard loop.selector.setData(fd, cb)
        loop.selector.updateHandle(fd, events)
        var i = 0
        while i < loop.deferredDisarms.len:
          if loop.deferredDisarms[i] == fd:
            loop.deferredDisarms[i] = loop.deferredDisarms[^1]
            loop.deferredDisarms.setLen(loop.deferredDisarms.len - 1)
            break
          inc i
      else:
        loop.selector.registerHandle(fd, events, cb)
    else:
      if loop.selector.contains(fd):
        # Always re-register to handle fd recycling correctly.
        try:
          loop.selector.unregister(fd)
        except Exception:
          discard  # ENOENT from kqueue is normal for recycled fds
      loop.selector.registerHandle(fd, events, cb)
  except Exception:
    try:
      loop.selector.unregister(fd)
    except Exception:
      discard
    try:
      loop.selector.registerHandle(fd, events, cb)
    except Exception:
      discard

proc queueReadyIfAlreadySignaled(loop: EventLoop, fd: SocketHandle,
                                 events: set[Event], cb: proc() {.closure.}) =
  ## kqueue can miss a readiness edge when registration is deferred from
  ## a non-reactor thread. After proxy registration, probe once and queue
  ## the callback if the fd is already readable/writable.
  if cb == nil:
    return
  when not defined(windows):
    var pollMask: cshort = 0
    if Event.Read in events:
      pollMask = pollMask or POLLIN
    if Event.Write in events:
      pollMask = pollMask or POLLOUT
    if pollMask == 0:
      return
    var pfd = TPollfd(fd: cint(int(fd)), events: pollMask, revents: 0)
    if poll(addr pfd, Tnfds(1), 0.cint) <= 0:
      return
    let readyMask = pollMask or POLLERR or POLLHUP
    if (pfd.revents and readyMask) != 0:
      loop.readyQueue.add(cb)

proc registerRead*(loop: EventLoop, fd: SocketHandle, cb: proc() {.closure.}) =
  ## Register a one-shot socket-read callback.
  if loop.shouldProxyToReactor():
    let fdVal = fd
    let cbVal = cb
    loop.postToEventLoop(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        registerHandleSafe(loop, fdVal, {Event.Read}, cbVal)
        queueReadyIfAlreadySignaled(loop, fdVal, {Event.Read}, cbVal)
    )
  else:
    registerHandleSafe(loop, fd, {Event.Read}, cb)

proc registerRead*(loop: EventLoop, fd: int, cb: proc() {.closure.}) =
  ## Register a one-shot socket-read callback.
  registerRead(loop, SocketHandle(fd), cb)

proc registerWrite*(loop: EventLoop, fd: SocketHandle, cb: proc() {.closure.}) =
  ## Register a one-shot socket-write callback.
  if loop.shouldProxyToReactor():
    let fdVal = fd
    let cbVal = cb
    loop.postToEventLoop(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        registerHandleSafe(loop, fdVal, {Event.Write}, cbVal)
        queueReadyIfAlreadySignaled(loop, fdVal, {Event.Write}, cbVal)
    )
  else:
    registerHandleSafe(loop, fd, {Event.Write}, cb)

proc registerWrite*(loop: EventLoop, fd: int, cb: proc() {.closure.}) =
  ## Register a one-shot socket-write callback.
  registerWrite(loop, SocketHandle(fd), cb)

proc unregister*(loop: EventLoop, fd: SocketHandle) =
  ## Remove the socket registration from the event loop.
  if loop.shouldProxyToReactor():
    let fdVal = fd
    loop.postToEventLoop(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        try:
          loop.selector.unregister(fdVal)
        except Exception:
          discard
    )
  else:
    when defined(linux):
      var i = 0
      while i < loop.deferredDisarms.len:
        if loop.deferredDisarms[i] == fd:
          loop.deferredDisarms[i] = loop.deferredDisarms[^1]
          loop.deferredDisarms.setLen(loop.deferredDisarms.len - 1)
          break
        inc i
    if loop.selector.contains(fd):
      try:
        loop.selector.unregister(fd)
      except Exception:
        discard

proc unregister*(loop: EventLoop, fd: int) =
  ## Remove the socket registration from the event loop.
  unregister(loop, SocketHandle(fd))

proc disarm*(loop: EventLoop, fd: SocketHandle) =
  ## Consume a one-shot readiness callback without closing the descriptor.
  ##
  ## Linux defers the kernel deletion until the next selector wait. Rearming
  ## the descriptor before then replaces its callback in-place and avoids
  ## redundant epoll_ctl calls. Other selectors retain the established
  ## unregister behavior.
  when defined(linux):
    if loop.shouldProxyToReactor():
      let fdVal = fd
      loop.postToEventLoop(proc() {.closure, gcsafe.} =
        {.cast(gcsafe).}:
          loop.disarm(fdVal)
      )
    elif loop.selector.contains(fd):
      var emptyCallback: IoCallback
      discard loop.selector.setData(fd, emptyCallback)
      for pending in loop.deferredDisarms:
        if pending == fd:
          return
      loop.deferredDisarms.add(fd)
  else:
    loop.unregister(fd)

proc disarm*(loop: EventLoop, fd: int) =
  ## Consume a one-shot readiness callback without closing the descriptor.
  loop.disarm(SocketHandle(fd))

proc flushDeferredDisarms(loop: EventLoop) {.inline.} =
  ## Remove callbacks that were not rearmed before the next kernel wait.
  when defined(linux):
    if loop.deferredDisarms.len == 0:
      return
    for fd in loop.deferredDisarms:
      if loop.selector.contains(fd):
        try:
          loop.selector.unregister(fd)
        except Exception:
          discard
    loop.deferredDisarms.setLen(0)

proc scheduleCallback*(loop: EventLoop, cb: proc() {.closure.}) =
  ## Queue a callback for execution on the event-loop thread.
  if loop.shouldProxyToReactor():
    let cbCopy = cb
    loop.postToEventLoop(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        loop.readyQueue.add(cbCopy)
    )
  else:
    loop.readyQueue.add(cb)

proc scheduleCallback*(cb: proc() {.closure.}) =
  ## Queue a callback for execution on the event-loop thread.
  getEventLoop().scheduleCallback(cb)

proc drainCrossThreadQueue*(loop: EventLoop) =
  ## Drain all callbacks from the lock-free MPSC queue (event loop thread only).
  if not loop.mtActive:
    return
  var drained = 0
  while true:
    let node = dequeue(loop.crossThreadQueue)
    if node == nil:
      if loop.crossThreadQueue.hasPending():
        cpuRelax()
        continue
      break
    var posted = takePayload(node)
    freeNode(node)
    if posted.task.fn != nil:
      if posted.sourceWorker == RawPostedCallback:
        try:
          cast[EventLoopRawProc](posted.task.fn)(posted.task.env)
          inc drained
        except CatchableError:
          loop.recordCallbackError()
        posted.task = default(OwnedClosureTask)
        continue
      when not compileOption("gc", "atomicArc"):
        if posted.sourceWorker >= 0 and
           (not isSchedulerWorker or currentWorkerId != posted.sourceWorker):
          type RawClosureCall = proc(env: pointer) {.nimcall, gcsafe.}
          try:
            cast[RawClosureCall](posted.task.fn)(posted.task.env)
            inc drained
          except CatchableError:
            loop.recordCallbackError()
          let rt {.cursor.} = loop.ownerRuntime
          if rt == nil or rt.closureReleaseDispatcher == nil or
             not rt.closureReleaseDispatcher(posted.sourceWorker, posted.task):
            # The owner runtime is already stopping. Leaking the environment
            # is safer than destroying an ARC/ORC graph on the wrong thread.
            posted.task = default(OwnedClosureTask)
        elif posted.returnRoute.release != nil:
          type RawClosureCall = proc(env: pointer) {.nimcall, gcsafe.}
          try:
            cast[RawClosureCall](posted.task.fn)(posted.task.env)
            inc drained
          except CatchableError:
            loop.recordCallbackError()
          posted.returnRoute.release(posted.returnRoute.ctx,
                                     posted.returnRoute.owner, posted.task)
          posted.task = default(OwnedClosureTask)
        else:
          try:
            runClosureTask(posted.task, CrossThreadCallback)
            inc drained
          except CatchableError:
            loop.recordCallbackError()
      else:
        try:
          runClosureTask(posted.task, CrossThreadCallback)
          inc drained
        except CatchableError:
          loop.recordCallbackError()
  when defined(debugMtIo):
    if drained > 0:
      debugEcho "[MT-IO] drainCrossThreadQueue: drained ", drained, " callbacks, selector.count=", loop.selector.count

proc enableCrossThreadWake*(loop: EventLoop) =
  ## Add a wake descriptor and MPSC inbox to an event loop. Reactor pools use
  ## this for control messages while all normal I/O remains shard-local.
  if loop.wakePipeRead != SocketHandle(-1):
    loop.mtActive = true
    return
  let (readEnd, writeEnd) = platform.createWakePipe()
  loop.wakePipeRead = readEnd
  loop.wakePipeWrite = writeEnd
  loop.mtActive = true
  initMpscQueue(loop.crossThreadQueue)
  # Wake readiness is handled directly by processIo. Keeping a managed
  # callback in the selector both allocates an unnecessary closure and makes
  # its destruction part of ARC/ORC shutdown ordering.
  loop.registerRead(readEnd, nil)

proc disableCrossThreadWake*(loop: EventLoop) =
  ## Remove cross-thread control state and release its descriptors/closures.
  if loop.wakePipeRead == SocketHandle(-1):
    loop.mtActive = false
    return
  try:
    loop.unregister(loop.wakePipeRead)
  except Exception:
    discard
  platform.closePipeFd(loop.wakePipeRead)
  platform.closePipeFd(loop.wakePipeWrite)
  loop.wakePipeRead = SocketHandle(-1)
  loop.wakePipeWrite = SocketHandle(-1)
  discardAll(loop.crossThreadQueue)
  loop.mtActive = false
  loop.markWakeDrained()

proc processIo(loop: EventLoop, timeoutMs: int): int {.warning[ProveInit]: off.} =
  ## Process I/O events, returning the number of events processed.
  ## Suppress a known ioselectors_kqueue `ProveInit` false-positive from
  ## `getData` template instantiation (tracked upstream in Nim stdlib).
  # A non-blocking poll is often interleaved with the continuation that rearms
  # a one-shot descriptor. Keep the userspace tombstone through those polls so
  # rearming can cancel it without a DEL+ADD kernel round trip. Before a
  # blocking wait, remove any tombstones so a still-ready fd cannot wake us
  # repeatedly with no callback.
  if timeoutMs != 0:
    loop.flushDeferredDisarms()
  if loop.selector.isEmpty:
    when defined(debugMtIo):
      debugEcho "[MT-IO] processIo: selector is empty"
    return 0
  when defined(debugMtIo):
    debugEcho "[MT-IO] processIo: calling select(", timeoutMs, ") count=", loop.selector.count
  var eventCount = 0
  try:
    eventCount = loop.selector.selectInto(timeoutMs, loop.ioEvents)
  except Exception:
    # kqueue AssertionDefect or other selector corruption — skip this tick
    return 0
  when defined(debugMtIo):
    if eventCount > 0:
      for i in 0 ..< eventCount:
        let ev = loop.ioEvents[i]
        debugEcho "[MT-IO] processIo: event fd=", ev.fd, " events=", ev.events
  for i in 0 ..< eventCount:
    let ev = loop.ioEvents[i]
    # Guard: a previous callback in this batch may have unregistered this fd.
    # Nim's selector.getData() returns `var T`; when the fd is no longer
    # registered the result pointer is never assigned (nil), and the
    # caller's dereference would SIGSEGV at address 0x0.
    if not loop.selector.contains(ev.fd):
      continue
    if ev.fd == int(loop.wakePipeRead):
      platform.wakePipeDrain(loop.wakePipeRead)
      loop.recordWakeSignal()
      # The readiness event covers every producer that observed the old true
      # state. Publish false before running callbacks so a completion arriving
      # during the drain must emit a fresh byte instead of being stranded when
      # this reactor returns to a blocking select.
      loop.markWakeDrained()
      loop.drainCrossThreadQueue()
      if loop.crossThreadQueue.hasPending():
        loop.tryWakeSelector()
      inc result
      continue
    let cb = loop.selector.getData(ev.fd)
    if cb != nil:
      try:
        cb()
      except Exception:
        loop.recordCallbackError()
        # Callback error — unregister the fd to prevent repeated failures
        try: loop.selector.unregister(ev.fd)
        except Exception: discard
      inc result

proc processReady(loop: EventLoop): int =
  ## Run callbacks queued for immediate execution.
  if loop.readyQueue.len == 0:
    return 0
  swap(loop.readyQueue, loop.readyScratch)
  for cb in loop.readyScratch:
    if loop.runLoopCallback(cb):
      inc result
  loop.readyScratch.setLen(0)

proc tickImpl(loop: EventLoop, nonBlocking: bool): bool =
  ## Run one blocking or non-blocking event-loop iteration.
  let prevRt {.cursor.} = cast[CpsRuntime](currentRuntimePointer())
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

  # If we actually ran callbacks this tick, do a non-blocking I/O poll
  # before returning. This prevents I/O starvation when the readyQueue
  # is perpetually busy (e.g., async file writes, cpsYield loops).
  # Without this, processIo is never reached and socket events (IRC,
  # TCP connects) starve indefinitely.
  if hadReady or firedTimers > 0:
    if not loop.selector.isEmpty:
      try:
        ioEventsThisTick = loop.processIo(0)  # non-blocking poll
      except IOSelectorsException:
        loop.selector = newSelector[IoCallback]()
        ioEventsThisTick = 0
      if loop.mtActive:
        loop.drainCrossThreadQueue()
    if loop.readyQueue.len > 0:
      readyRan2 = loop.processReady()
    loop.stats.tickCount += 1
    loop.stats.totalCallbacksRun += int64(readyRan1 + readyRan2)
    loop.stats.totalTimersFired += int64(firedTimers)
    loop.stats.totalIoEvents += int64(ioEventsThisTick)
    result = readyRan1 + readyRan2 + firedTimers + ioEventsThisTick > 0
    when defined(cpsTrace):
      let tickEnd = getMonoTime()
      let durationUs = (tickEnd - tickStart).inMicroseconds
      loop.stats.lastTickDurationUs = durationUs
      if durationUs > loop.stats.maxTickDurationUs:
        loop.stats.maxTickDurationUs = durationUs
    return

  # Calculate timeout for selector
  var timeoutMs = if nonBlocking: 0 else: -1
  if loop.readyQueue.len > 0:
    timeoutMs = 0
    loop.pruneCancelledTimerRoots()
  else:
    loop.pruneCancelledTimerRoots()
    if loop.timers.len > 0:
      let now = getMonoTime()
      let nextTimer = loop.timerHeapPeek()
      let delta = nextTimer.deadline - now
      let timerTimeout = max(0, int(delta.inMilliseconds))
      if not nonBlocking:
        timeoutMs = timerTimeout

  if not loop.selector.isEmpty:
    # A non-worker manually driving the primary MT loop is a synchronous
    # selector waiter just like blockOn/runCps. Track only the duration of the
    # blocking poll so cross-thread completions wake it without reintroducing
    # wake-pipe traffic on worker-local HTTP completions.
    let tracksExternalWait = not nonBlocking and loop.ownerRuntime != nil and
      loop.ownerRuntime.flavor == rfMultiThread and not isSchedulerWorker
    if tracksExternalWait:
      runCpsWaitEnter(loop.ownerRuntime)
    try:
      try:
        ioEventsThisTick = loop.processIo(timeoutMs)
      except IOSelectorsException:
        # Recover from selector descriptor invalidation without taking down
        # the runtime; timer and ready-queue work can still make progress.
        loop.selector = newSelector[IoCallback]()
        ioEventsThisTick = 0
    finally:
      if tracksExternalWait:
        runCpsWaitLeave(loop.ownerRuntime)
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
  result = readyRan1 + firedTimers + ioEventsThisTick > 0
  when defined(cpsTrace):
    let tickEnd = getMonoTime()
    let durationUs = (tickEnd - tickStart).inMicroseconds
    loop.stats.lastTickDurationUs = durationUs
    if durationUs > loop.stats.maxTickDurationUs:
      loop.stats.maxTickDurationUs = durationUs

proc tick*(loop: EventLoop) {.inline.} =
  ## Run one event-loop iteration, blocking until readiness when idle.
  discard loop.tickImpl(false)

proc poll*(loop: EventLoop): bool {.inline, discardable.} =
  ## Run one non-blocking event-loop iteration and report whether work ran.
  loop.tickImpl(true)

proc userIoHandleCount*(loop: EventLoop): int {.inline.} =
  ## Return selector handles excluding the runtime's internal wake descriptor.
  let controlHandles = if loop.wakePipeRead == SocketHandle(-1): 0 else: 1
  max(0, loop.selector.count - controlHandles)

proc hasUserIoWork*(loop: EventLoop): bool {.inline.} =
  ## Return whether a worker loop has work beyond its scheduler wake handle.
  loop.readyQueue.len > 0 or loop.timers.len > 0 or
    loop.userIoHandleCount() > 0 or
    (loop.mtActive and loop.crossThreadQueue.hasPending())

proc pendingTimerCount*(loop: EventLoop): int {.inline.} =
  ## Return the number of timer entries currently retained by the loop.
  loop.timers.len

proc hasWork*(loop: EventLoop): bool =
  ## Return whether the event loop has work ready to run.
  loop.pruneCancelledTimerRoots()
  loop.readyQueue.len > 0 or
  loop.timers.len > 0 or
  not loop.selector.isEmpty or
  (loop.mtActive and loop.crossThreadQueue.hasPending())

proc runForever*(loop: EventLoop) =
  ## Run forever until it completes or is stopped.
  loop.running = true
  while loop.running and loop.hasWork:
    loop.tick()

proc runForever*() =
  ## Run forever until it completes or is stopped.
  getEventLoop().runForever()

proc stop*(loop: EventLoop) =
  ## Stop eventloop and wake any pending work.
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
  let rt {.cursor.} = cast[CpsRuntime](currentRuntimePointer())
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

type
  SleepSignalState = ref object
    resolved: Atomic[bool]
    result: CpsVoidFuture
    timer: TimerHandle

proc completeSleepSignal(st: SleepSignalState, cancelTimer: bool) {.inline.} =
  var expected = false
  if st.resolved.compareExchange(expected, true, moAcquireRelease, moAcquire):
    if cancelTimer:
      st.timer.cancel()
    let rf = st.result
    st.result = nil
    if rf != nil:
      rf.complete()

proc sleepOrSignal*(ms: int, signal: CpsVoidFuture): CpsVoidFuture =
  ## Sleep for `ms` unless `signal` completes first.
  if signal != nil and signal.finished:
    return completedVoidFuture()
  let delayMs = if ms < 0: 0 else: ms
  if delayMs == 0:
    return completedVoidFuture()

  let resultFut = newCpsVoidFuture()
  resultFut.pinFutureRuntime()
  let st = SleepSignalState(result: resultFut)
  st.resolved.store(false, moRelaxed)

  proc makeTimerCb(state: SleepSignalState): proc() {.closure.} =
    result = proc() =
      completeSleepSignal(state, false)

  proc makeSignalCb(state: SleepSignalState): proc() {.closure.} =
    result = proc() =
      completeSleepSignal(state, true)

  let loop = getEventLoop()
  st.timer = loop.registerTimer(delayMs, makeTimerCb(st))
  if signal != nil:
    signal.addCallback(makeSignalCb(st))
  result = resultFut

proc cpsYield*(): CpsVoidFuture =
  ## Yield control back to the event loop for one tick.
  ## In MT mode, dispatches the completion to a worker thread
  ## instead of going through the reactor's ready queue.
  let fut = newCpsVoidFuture()
  let rt {.cursor.} = cast[CpsRuntime](currentRuntimePointer())
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
  let targetRt {.cursor.} = rtHandle.runtime
  let futRt {.cursor.} = fut.ownerRuntime
  if futRt == nil:
    fut.bindFutureRuntime(rtHandle)
  elif futRt != targetRt and not fut.tryMigrateTo(rtHandle):
    raise newException(RuntimeAffinityError,
      "future cannot be executed on runtime " & $rtHandle.runtimeId() &
      ": it is pinned to runtime " & $fut.futureRuntime().runtimeId())
  if targetRt != nil and targetRt.flavor == rfMultiThread and
     isSchedulerWorker and fut.isLocalFast():
    fut.ensureShared()
  fut.pinFutureWaitWorker()

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
  let targetRt {.cursor.} = rtHandle.runtime
  let futRt {.cursor.} = fut.ownerRuntime
  if futRt == nil:
    fut.bindFutureRuntime(rtHandle)
  elif futRt != targetRt and not fut.tryMigrateTo(rtHandle):
    raise newException(RuntimeAffinityError,
      "future cannot be executed on runtime " & $rtHandle.runtimeId() &
      ": it is pinned to runtime " & $fut.futureRuntime().runtimeId())
  if targetRt != nil and targetRt.flavor == rfMultiThread and
     isSchedulerWorker and fut.isLocalFast():
    fut.ensureShared()
  fut.pinFutureWaitWorker()

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
  ## Run CPS on until it completes or is stopped.
  blockOn(handle, fut)

proc runCpsOn*(handle: RuntimeHandle, fut: CpsVoidFuture) {.inline.} =
  ## Run CPS on until it completes or is stopped.
  blockOn(handle, fut)

template runOn*(handle: RuntimeHandle, expr: untyped): untyped =
  ## Run on until it completes or is stopped.
  block:
    withRuntime(handle):
      runCpsOn(handle, expr)

proc runCps*[T](fut: CpsFuture[T]): T =
  ## Run CPS until it completes or is stopped.
  let h =
    if fut.ownerRuntime != nil: fut.futureRuntime()
    else: currentRuntime()
  blockOn(h, fut)

proc runCps*(fut: CpsVoidFuture) =
  ## Run CPS until it completes or is stopped.
  let h =
    if fut.ownerRuntime != nil: fut.futureRuntime()
    else: currentRuntime()
  blockOn(h, fut)

type
  WaitAllState = ref object
    remaining: Atomic[int]
    result: CpsVoidFuture

  WaitAllGateState = ref object
    remaining: Atomic[int]
    resolved: Atomic[bool]
    result: CpsVoidFuture
    timer: TimerHandle

proc waitAllImpl[F](futures: openArray[F]): CpsVoidFuture =
  ## Shared implementation for typed/void waitAll openArray overloads.
  var pending = newSeqOfCap[F](futures.len)
  for i in 0 ..< futures.len:
    let fut = futures[i]
    if fut != nil and not fut.finished:
      pending.add(fut)
  if pending.len == 0:
    return completedVoidFuture()

  let resultFut = newCpsVoidFuture()
  resultFut.pinFutureRuntime()
  let state = WaitAllState(result: resultFut)
  state.remaining.store(pending.len, moRelaxed)

  proc makeCallback(st: WaitAllState): proc() {.closure.} =
    result = proc() =
      let prev = st.remaining.fetchSub(1, moAcquireRelease)
      if prev == 1:
        let rf = st.result
        st.result = nil
        if rf != nil:
          rf.complete()

  let cb = makeCallback(state)
  for i in 0 ..< pending.len:
    pending[i].addCallback(cb)
  result = resultFut

proc completeWaitGate(st: WaitAllGateState, cancelTimer: bool) {.inline.} =
  var expected = false
  if st.resolved.compareExchange(expected, true, moAcquireRelease, moAcquire):
    if cancelTimer:
      st.timer.cancel()
    let rf = st.result
    st.result = nil
    if rf != nil:
      rf.complete()

proc waitAllOrSignalImpl[F](futures: openArray[F], timeoutMs: int,
                            signal: CpsVoidFuture): CpsVoidFuture =
  ## Complete when all non-nil futures complete, or timeout elapses, or
  ## optional stop signal completes.
  if signal != nil and signal.finished:
    return completedVoidFuture()

  var pending = newSeqOfCap[F](futures.len)
  for i in 0 ..< futures.len:
    let fut = futures[i]
    if fut != nil and not fut.finished:
      pending.add(fut)
  if pending.len == 0:
    return completedVoidFuture()

  let resultFut = newCpsVoidFuture()
  resultFut.pinFutureRuntime()
  let state = WaitAllGateState(result: resultFut)
  state.remaining.store(pending.len, moRelaxed)
  state.resolved.store(false, moRelaxed)

  proc makeTimerCb(st: WaitAllGateState): proc() {.closure.} =
    result = proc() =
      completeWaitGate(st, false)

  proc makeFutureCb(st: WaitAllGateState): proc() {.closure.} =
    result = proc() =
      let prev = st.remaining.fetchSub(1, moAcquireRelease)
      if prev == 1:
        completeWaitGate(st, true)

  proc makeSignalCb(st: WaitAllGateState): proc() {.closure.} =
    result = proc() =
      completeWaitGate(st, true)

  let loop = getEventLoop()
  let delayMs = if timeoutMs < 0: 0 else: timeoutMs
  state.timer = loop.registerTimer(delayMs, makeTimerCb(state))
  if signal != nil:
    signal.addCallback(makeSignalCb(state))
  let futCb = makeFutureCb(state)
  for i in 0 ..< pending.len:
    pending[i].addCallback(futCb)
  result = resultFut

proc waitAll*[T](futures: openArray[CpsFuture[T]]): CpsVoidFuture =
  ## Returns a void future that completes when all non-nil typed futures complete.
  waitAllImpl(futures)

proc waitAll*(futures: openArray[CpsVoidFuture]): CpsVoidFuture =
  ## Returns a future that completes when all non-nil void futures complete.
  waitAllImpl(futures)

proc waitAllOrTimeout*[T](futures: openArray[CpsFuture[T]],
                          timeoutMs: int): CpsVoidFuture {.inline.} =
  ## Complete when all typed futures complete or timeout elapses.
  waitAllOrSignalImpl(futures, timeoutMs, nil)

proc waitAllOrTimeout*(futures: openArray[CpsVoidFuture],
                       timeoutMs: int): CpsVoidFuture {.inline.} =
  ## Complete when all void futures complete or timeout elapses.
  waitAllOrSignalImpl(futures, timeoutMs, nil)

proc waitAllOrSignal*[T](futures: openArray[CpsFuture[T]],
                         timeoutMs: int,
                         signal: CpsVoidFuture): CpsVoidFuture {.inline.} =
  ## Complete when all typed futures complete, timeout elapses, or signal fires.
  waitAllOrSignalImpl(futures, timeoutMs, signal)

proc waitAllOrSignal*(futures: openArray[CpsVoidFuture],
                      timeoutMs: int,
                      signal: CpsVoidFuture): CpsVoidFuture {.inline.} =
  ## Complete when all void futures complete, timeout elapses, or signal fires.
  waitAllOrSignalImpl(futures, timeoutMs, signal)

proc waitAll*(): CpsVoidFuture {.inline.} =
  ## Varargs convenience overload for zero futures.
  completedVoidFuture()

proc waitAll*[T](first: CpsFuture[T], rest: varargs[CpsFuture[T]]): CpsVoidFuture {.inline.} =
  ## Varargs convenience overload for typed futures.
  var futures = newSeqOfCap[CpsFuture[T]](rest.len + 1)
  futures.add(first)
  for fut in rest:
    futures.add(fut)
  waitAll(futures)

proc waitAll*(first: CpsVoidFuture, rest: varargs[CpsVoidFuture]): CpsVoidFuture {.inline.} =
  ## Varargs convenience overload for void futures.
  var futures = newSeqOfCap[CpsVoidFuture](rest.len + 1)
  futures.add(first)
  for fut in rest:
    futures.add(fut)
  waitAll(futures)

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
## Return whether the task's future has completed.
proc finished*[T](t: Task[T]): bool {.inline.} = t.future.finished
## Return the completed task value or raise its terminal error.
proc read*[T](t: Task[T]): T {.inline.} = t.future.read()
proc addCallback*[T](t: Task[T], cb: proc() {.closure.}) {.inline.} =
  ## Register a callback to run when the task completes.
  t.future.addCallback(cb)
## Return whether the operation completed with an error.
proc hasError*[T](t: Task[T]): bool {.inline.} = t.future.hasError()
## Return the error that failed the task.
proc getError*[T](t: Task[T]): ref CatchableError {.inline.} = t.future.getError()

# VoidTask - future-compatible interface
## Return whether the task's future has completed.
proc finished*(t: VoidTask): bool {.inline.} = t.future.finished
proc addCallback*(t: VoidTask, cb: proc() {.closure.}) {.inline.} =
  ## Register a callback to run when the task completes.
  t.future.addCallback(cb)
## Return whether the operation completed with an error.
proc hasError*(t: VoidTask): bool {.inline.} = t.future.hasError()
## Return the error that failed the task.
proc getError*(t: VoidTask): ref CatchableError {.inline.} = t.future.getError()

# Task/VoidTask cancellation
## Cancel eventloop and notify its waiters.
proc cancel*[T](t: Task[T]) {.inline.} = t.future.cancel()
## Cancel eventloop and notify its waiters.
proc cancel*(t: VoidTask) {.inline.} = t.future.cancel()
## Return whether the operation was cancelled.
proc isCancelled*[T](t: Task[T]): bool {.inline.} = t.future.isCancelled()
## Return whether the operation was cancelled.
proc isCancelled*(t: VoidTask): bool {.inline.} = t.future.isCancelled()
proc tryMigrateTo*[T](t: Task[T], handle: RuntimeHandle): bool {.inline.} =
  ## Attempt to move the future to another runtime without blocking.
  t.future.tryMigrateTo(handle)
proc tryMigrateTo*(t: VoidTask, handle: RuntimeHandle): bool {.inline.} =
  ## Attempt to move the future to another runtime without blocking.
  t.future.tryMigrateTo(handle)
proc migrateTo*[T](t: Task[T], handle: RuntimeHandle) {.inline.} =
  ## Move the future to another runtime.
  t.future.migrateTo(handle)
proc migrateTo*(t: VoidTask, handle: RuntimeHandle) {.inline.} =
  ## Move the future to another runtime.
  t.future.migrateTo(handle)

proc spawnOn*[T](handle: RuntimeHandle, fut: CpsFuture[T], name: string = ""): Task[T] =
  ## Spawn a CPS proc as a concurrent task.
  ## The task runs cooperatively on the event loop.
  ## Can be awaited later to retrieve the result.
  ## Optionally provide a name for debugging/tracing.
  let target =
    if handle.runtime != nil: handle
    else: currentRuntime()
  let futRt {.cursor.} = fut.ownerRuntime
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
  let futRt {.cursor.} = fut.ownerRuntime
  if futRt == nil:
    fut.bindFutureRuntime(target)
  elif futRt != target.runtime and not fut.tryMigrateTo(target):
    raise newException(RuntimeAffinityError,
      "task cannot move to runtime " & $target.runtimeId() &
      ": future is runtime-pinned")
  result = VoidTask(future: fut, name: name)

proc spawn*[T](fut: CpsFuture[T], name: string = ""): Task[T] =
  ## Schedule eventloop for asynchronous execution.
  spawnOn(currentRuntime(), fut, name)

proc spawn*(fut: CpsVoidFuture, name: string = ""): VoidTask =
  ## Schedule eventloop for asynchronous execution.
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
