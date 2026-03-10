## CPS Broadcast and Watch Channels
##
## Broadcast channels provide one-to-many message distribution: every
## subscriber receives a copy of each sent message. Each receiver has its
## own per-receiver ring buffer so slow consumers don't block the sender
## or other receivers. When a receiver's buffer overflows, the oldest
## messages are dropped (lagging receiver).
##
## Watch channels hold a single "current value" that receivers can read
## at any time without blocking (borrow). Receivers can also wait for
## the value to change (recv). Every receiver sees the latest value
## regardless of how many updates they missed.
##
## Thread safety: when the MT runtime is active, channel state is protected
## by a CAS-based SpinLock (not pthread_mutex) to ensure the reactor thread
## is never blocked by a syscall. Future completions happen outside all
## locks to avoid deadlocks.
##
## Lock ordering: channel lock is always acquired before receiver locks.

import std/[options, deques]
import ../runtime
import ../private/spinlock

proc runtimeMtEnabled(): bool {.inline.} =
  let rt = currentRuntime().runtime
  rt != nil and rt.flavor == rfMultiThread

template withLock(lock: var SpinLock, mt: bool, body: untyped) =
  ## Execute body with conditional spinlock protection.
  ## When mt is true, acquires the lock and guarantees release via
  ## try/finally (exception-safe). When false, executes body directly.
  if mt:
    withSpinLock(lock):
      body
  else:
    body

type
  BroadcastClosed* = object of CatchableError
    ## Raised when operating on a closed broadcast or watch channel.

  ReceiverLagged* = object of CatchableError
    ## Raised when a receiver missed messages due to buffer overflow.

  BroadcastReceiver*[T] = ref object
    ## Per-subscriber receiver with its own ring buffer.
    buffer: seq[T]
    head, tail, count, capacity: int
    waiters: Deque[CpsFuture[T]]
    closed: bool
    lock: SpinLock
    mtEnabled: bool

  BroadcastChannel*[T] = ref object
    ## A broadcast channel. Messages sent are delivered to all subscribers.
    receivers: seq[BroadcastReceiver[T]]
    closed: bool
    lock: SpinLock
    mtEnabled: bool
    capacity: int

  WatchReceiver*[T] = ref object
    ## A watch channel receiver. Tracks the last version seen.
    lastVersion: int
    channel: WatchChannel[T]
    waiters: Deque[CpsFuture[T]]
    lock: SpinLock
    mtEnabled: bool

  WatchChannel*[T] = ref object
    ## A watch channel holding a single current value.
    value: T
    version: int
    receivers: seq[WatchReceiver[T]]
    closed: bool
    lock: SpinLock
    mtEnabled: bool

# ============================================================
# Ring buffer helpers
# ============================================================

proc ringPush[T](rx: BroadcastReceiver[T], value: T) {.inline.} =
  ## Push value into ring buffer. Drops oldest if full.
  if rx.count >= rx.capacity:
    rx.head = (rx.head + 1) mod rx.capacity
    dec rx.count
  rx.buffer[rx.tail] = value
  rx.tail = (rx.tail + 1) mod rx.capacity
  inc rx.count

proc ringPop[T](rx: BroadcastReceiver[T]): T {.inline.} =
  ## Pop oldest value from ring buffer. Caller must ensure count > 0.
  result = move rx.buffer[rx.head]
  rx.head = (rx.head + 1) mod rx.capacity
  dec rx.count

# ============================================================
# Broadcast Channel
# ============================================================

proc newBroadcast*[T](capacity: int = 16): BroadcastChannel[T] =
  ## Create a new broadcast channel. Each subscriber will have a
  ## ring buffer of the given capacity. When a receiver's buffer is
  ## full, the oldest message is dropped.
  assert capacity >= 1, "Broadcast capacity must be >= 1"
  result = BroadcastChannel[T](
    receivers: @[],
    closed: false,
    capacity: capacity,
  )
  if runtimeMtEnabled():
    result.mtEnabled = true
    initSpinLock(result.lock)

proc subscribe*[T](ch: BroadcastChannel[T]): BroadcastReceiver[T] =
  ## Create a new receiver for this broadcast channel. The receiver
  ## will receive all future messages (not past ones).
  let rx = BroadcastReceiver[T](
    buffer: newSeq[T](ch.capacity),
    head: 0, tail: 0, count: 0,
    capacity: ch.capacity,
    waiters: initDeque[CpsFuture[T]](),
    closed: false,
  )
  if runtimeMtEnabled():
    rx.mtEnabled = true
    initSpinLock(rx.lock)
  withLock(ch.lock, ch.mtEnabled):
    if ch.closed:
      rx.closed = true
    ch.receivers.add(rx)
  result = rx

proc unsubscribe*[T](ch: BroadcastChannel[T], rx: BroadcastReceiver[T]) =
  ## Remove a receiver from the broadcast channel.
  withLock(ch.lock, ch.mtEnabled):
    for i in 0 ..< ch.receivers.len:
      if ch.receivers[i] == rx:
        ch.receivers.delete(i)
        break
  var pendingWaiters: seq[CpsFuture[T]]
  withLock(rx.lock, rx.mtEnabled):
    rx.closed = true
    while rx.waiters.len > 0:
      pendingWaiters.add(rx.waiters.popFirst())
  let err = newException(BroadcastClosed, "Receiver unsubscribed")
  for f in pendingWaiters:
    f.fail(err)

proc send*[T](ch: BroadcastChannel[T], value: T) =
  ## Send a value to all receivers. This is non-blocking for the sender.
  ## Each receiver either gets direct delivery (if waiting), gets the
  ## value buffered, or drops its oldest message if its buffer is full.
  var deliveries: seq[tuple[fut: CpsFuture[T], val: T]]
  withLock(ch.lock, ch.mtEnabled):
    if ch.closed:
      raise newException(BroadcastClosed, "Cannot send on closed broadcast channel")
    for rx in ch.receivers:
      withLock(rx.lock, rx.mtEnabled):
        if rx.waiters.len > 0:
          deliveries.add((fut: rx.waiters.popFirst(), val: value))
        else:
          rx.ringPush(value)
  # Complete futures outside all locks
  for d in deliveries:
    d.fut.complete(d.val)

proc recv*[T](rx: BroadcastReceiver[T]): CpsFuture[T] =
  ## Receive the next message from the broadcast channel.
  ## If the receiver's buffer is empty, the returned future suspends
  ## until a message arrives. If the receiver is closed, fails with
  ## BroadcastClosed.
  let fut = newCpsFuture[T]()
  var fastVal: T
  var gotVal = false
  var isClosed = false
  withLock(rx.lock, rx.mtEnabled):
    if rx.count > 0:
      fastVal = rx.ringPop()
      gotVal = true
    elif rx.closed:
      isClosed = true
    else:
      rx.waiters.addLast(fut)
  if gotVal:
    fut.complete(move fastVal)
  elif isClosed:
    fut.fail(newException(BroadcastClosed, "Broadcast channel is closed"))
  return fut

proc tryRecv*[T](rx: BroadcastReceiver[T]): Option[T] =
  ## Try to receive without blocking. Returns none if no data is buffered.
  withLock(rx.lock, rx.mtEnabled):
    if rx.count > 0:
      result = some(rx.ringPop())
    else:
      result = none(T)

proc len*[T](rx: BroadcastReceiver[T]): int =
  ## Number of items currently buffered in this receiver.
  withLock(rx.lock, rx.mtEnabled):
    result = rx.count

proc close*[T](ch: BroadcastChannel[T]) =
  ## Close the broadcast channel. All receivers are closed and
  ## their pending waiters are failed with BroadcastClosed.
  var allWaiters: seq[CpsFuture[T]]
  withLock(ch.lock, ch.mtEnabled):
    ch.closed = true
    for rx in ch.receivers:
      withLock(rx.lock, rx.mtEnabled):
        rx.closed = true
        while rx.waiters.len > 0:
          allWaiters.add(rx.waiters.popFirst())
  let err = newException(BroadcastClosed, "Broadcast channel is closed")
  for f in allWaiters:
    f.fail(err)

# ============================================================
# Watch Channel
# ============================================================

proc newWatch*[T](initial: T): WatchChannel[T] =
  ## Create a new watch channel with an initial value.
  result = WatchChannel[T](
    value: initial,
    version: 1,  # Start at version 1 so receivers at version 0 see initial
    receivers: @[],
    closed: false,
  )
  if runtimeMtEnabled():
    result.mtEnabled = true
    initSpinLock(result.lock)

proc subscribe*[T](ch: WatchChannel[T]): WatchReceiver[T] =
  ## Create a new receiver for this watch channel.
  ## The receiver starts at version 0 so the first borrow/recv sees
  ## the initial value. Use borrow() to read immediately.
  result = WatchReceiver[T](
    lastVersion: 0,
    channel: ch,
    waiters: initDeque[CpsFuture[T]](),
  )
  if ch.mtEnabled:
    result.mtEnabled = true
    initSpinLock(result.lock)
  withLock(ch.lock, ch.mtEnabled):
    ch.receivers.add(result)

proc send*[T](ch: WatchChannel[T], value: T) =
  ## Update the watch channel's value and wake all waiting receivers.
  var deliveries: seq[tuple[fut: CpsFuture[T], val: T]]
  withLock(ch.lock, ch.mtEnabled):
    if ch.closed:
      raise newException(BroadcastClosed, "Cannot send on closed watch channel")
    ch.value = value
    inc ch.version
    let currentVersion = ch.version
    let currentValue = ch.value
    for rx in ch.receivers:
      withLock(rx.lock, rx.mtEnabled):
        if rx.waiters.len > 0:
          let waiter = rx.waiters.popFirst()
          rx.lastVersion = currentVersion
          deliveries.add((fut: waiter, val: currentValue))
  # Complete futures outside all locks
  for d in deliveries:
    d.fut.complete(d.val)

proc borrow*[T](rx: WatchReceiver[T]): T =
  ## Read the current value without blocking. Does not update the
  ## receiver's version tracking, so hasChanged() is not affected.
  let ch = rx.channel
  withLock(ch.lock, ch.mtEnabled):
    result = ch.value

proc hasChanged*[T](rx: WatchReceiver[T]): bool =
  ## Check if the watch channel's value has changed since the last
  ## recv() call on this receiver.
  let ch = rx.channel
  withLock(ch.lock, ch.mtEnabled):
    result = ch.version > rx.lastVersion

proc recv*[T](rx: WatchReceiver[T]): CpsFuture[T] =
  ## Wait until the watch channel's value changes, then return
  ## the new value. If the value has already changed since the
  ## last recv, returns immediately with the current value.
  let fut = newCpsFuture[T]()
  let ch = rx.channel
  var fastVal: T
  var gotVal = false
  var isClosed = false
  withLock(ch.lock, ch.mtEnabled):
    if ch.version > rx.lastVersion:
      # Value has changed since we last looked.
      fastVal = ch.value
      rx.lastVersion = ch.version
      gotVal = true
    elif ch.closed:
      isClosed = true
    else:
      withLock(rx.lock, rx.mtEnabled):
        rx.waiters.addLast(fut)
  if gotVal:
    fut.complete(fastVal)
  elif isClosed:
    fut.fail(newException(BroadcastClosed, "Watch channel is closed"))
  return fut

proc close*[T](ch: WatchChannel[T]) =
  ## Close the watch channel. All waiting receivers are woken
  ## with a BroadcastClosed error.
  var allWaiters: seq[CpsFuture[T]]
  withLock(ch.lock, ch.mtEnabled):
    ch.closed = true
    for rx in ch.receivers:
      withLock(rx.lock, rx.mtEnabled):
        while rx.waiters.len > 0:
          allWaiters.add(rx.waiters.popFirst())
  let err = newException(BroadcastClosed, "Watch channel is closed")
  for f in allWaiters:
    f.fail(err)
