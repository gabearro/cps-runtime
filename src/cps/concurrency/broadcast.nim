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
## Thread safety: when mtModeEnabled is true (MT runtime active), channel
## state is protected by a Lock with minimal hold time. Future completions
## happen outside the lock to avoid deadlocks.

import std/[options, locks, deques]
import ../runtime

proc runtimeMtEnabled(): bool {.inline.} =
  let rt = currentRuntime().runtime
  rt != nil and rt.flavor == rfMultiThread

type
  BroadcastClosed* = object of CatchableError
    ## Raised when operating on a closed broadcast or watch channel.

  ReceiverLagged* = object of CatchableError
    ## Raised when a receiver missed messages due to buffer overflow.

  # ============================================================
  # Broadcast Channel types
  # ============================================================

  BroadcastReceiver*[T] = ref object
    ## Per-subscriber receiver with its own ring buffer.
    buffer: seq[T]       ## Ring buffer for this receiver
    head: int            ## Index of next item to dequeue
    tail: int            ## Index of next slot to enqueue
    count: int           ## Number of items currently buffered
    capacity: int        ## Max items in ring buffer
    waiters: Deque[CpsFuture[T]]  ## Futures waiting for data
    closed: bool         ## Whether this receiver has been closed
    lock: Lock
    mtEnabled: bool

  BroadcastChannel*[T] = ref object
    ## A broadcast channel. Messages sent are delivered to all subscribers.
    receivers: seq[BroadcastReceiver[T]]
    closed: bool
    lock: Lock
    mtEnabled: bool
    capacity: int        ## Default capacity for new receivers

  # ============================================================
  # Watch Channel types
  # ============================================================

  WatchReceiver*[T] = ref object
    ## A watch channel receiver. Tracks the last version seen.
    lastVersion: int     ## Last version this receiver has seen
    channel: WatchChannel[T]  ## Back-reference to parent channel
    waiters: Deque[CpsFuture[T]]  ## Futures waiting for value change
    lock: Lock
    mtEnabled: bool

  WatchChannel*[T] = ref object
    ## A watch channel holding a single current value.
    value: T             ## Current value
    version: int         ## Incremented on each send
    receivers: seq[WatchReceiver[T]]
    closed: bool
    lock: Lock
    mtEnabled: bool

# ============================================================
# Broadcast Channel: Construction
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
    initLock(result.lock)

# ============================================================
# Broadcast Channel: Subscribe / Unsubscribe
# ============================================================

proc subscribe*[T](ch: BroadcastChannel[T]): BroadcastReceiver[T] =
  ## Create a new receiver for this broadcast channel. The receiver
  ## will receive all future messages (not past ones).
  let rx = BroadcastReceiver[T](
    buffer: newSeq[T](ch.capacity),
    head: 0,
    tail: 0,
    count: 0,
    capacity: ch.capacity,
    waiters: initDeque[CpsFuture[T]](),
    closed: false,
  )
  if runtimeMtEnabled():
    rx.mtEnabled = true
    initLock(rx.lock)
  if ch.mtEnabled:
    acquire(ch.lock)
    if ch.closed:
      rx.closed = true
    ch.receivers.add(rx)
    release(ch.lock)
  else:
    if ch.closed:
      rx.closed = true
    ch.receivers.add(rx)
  result = rx

proc unsubscribe*[T](ch: BroadcastChannel[T], rx: BroadcastReceiver[T]) =
  ## Remove a receiver from the broadcast channel.
  if ch.mtEnabled:
    acquire(ch.lock)
    for i in 0 ..< ch.receivers.len:
      if ch.receivers[i] == rx:
        ch.receivers.delete(i)
        break
    release(ch.lock)
  else:
    for i in 0 ..< ch.receivers.len:
      if ch.receivers[i] == rx:
        ch.receivers.delete(i)
        break
  # Close the receiver and fail any pending waiters
  var pendingWaiters: seq[CpsFuture[T]] = @[]
  if rx.mtEnabled:
    acquire(rx.lock)
    rx.closed = true
    while rx.waiters.len > 0:
      pendingWaiters.add(rx.waiters.popFirst())
    release(rx.lock)
  else:
    rx.closed = true
    while rx.waiters.len > 0:
      pendingWaiters.add(rx.waiters.popFirst())
  let err = newException(BroadcastClosed, "Receiver unsubscribed")
  for f in pendingWaiters:
    f.fail(err)

# ============================================================
# Broadcast Channel: Send
# ============================================================

proc send*[T](ch: BroadcastChannel[T], value: T) =
  ## Send a value to all receivers. This is non-blocking for the sender.
  ## Each receiver either gets direct delivery (if waiting), gets the
  ## value buffered, or drops its oldest message if its buffer is full.
  var deliveries: seq[tuple[fut: CpsFuture[T], val: T]]

  if ch.mtEnabled:
    acquire(ch.lock)
    if ch.closed:
      release(ch.lock)
      raise newException(BroadcastClosed, "Cannot send on closed broadcast channel")
    for rx in ch.receivers:
      if rx.mtEnabled:
        acquire(rx.lock)
      if rx.waiters.len > 0:
        # Direct delivery: take the oldest waiter
        let waiter = rx.waiters.popFirst()
        if rx.mtEnabled:
          release(rx.lock)
        deliveries.add((fut: waiter, val: value))
      elif rx.count < rx.capacity:
        # Buffer the value
        rx.buffer[rx.tail] = value
        rx.tail = (rx.tail + 1) mod rx.capacity
        inc rx.count
        if rx.mtEnabled:
          release(rx.lock)
      else:
        # Buffer full: drop oldest (lagging receiver)
        rx.head = (rx.head + 1) mod rx.capacity
        rx.buffer[rx.tail] = value
        rx.tail = (rx.tail + 1) mod rx.capacity
        # count stays the same (dropped one, added one)
        if rx.mtEnabled:
          release(rx.lock)
    release(ch.lock)
  else:
    if ch.closed:
      raise newException(BroadcastClosed, "Cannot send on closed broadcast channel")
    for rx in ch.receivers:
      if rx.waiters.len > 0:
        let waiter = rx.waiters.popFirst()
        deliveries.add((fut: waiter, val: value))
      elif rx.count < rx.capacity:
        rx.buffer[rx.tail] = value
        rx.tail = (rx.tail + 1) mod rx.capacity
        inc rx.count
      else:
        # Buffer full: drop oldest
        rx.head = (rx.head + 1) mod rx.capacity
        rx.buffer[rx.tail] = value
        rx.tail = (rx.tail + 1) mod rx.capacity

  # Complete futures outside all locks
  for d in deliveries:
    d.fut.complete(d.val)

# ============================================================
# Broadcast Channel: Recv
# ============================================================

proc recv*[T](rx: BroadcastReceiver[T]): CpsFuture[T] =
  ## Receive the next message from the broadcast channel.
  ## If the receiver's buffer is empty, the returned future suspends
  ## until a message arrives. If the receiver is closed, fails with
  ## BroadcastClosed.
  let fut = newCpsFuture[T]()
  if rx.mtEnabled:
    acquire(rx.lock)
    if rx.count > 0:
      # Fast path: buffered data available
      let val = move rx.buffer[rx.head]
      rx.head = (rx.head + 1) mod rx.capacity
      dec rx.count
      release(rx.lock)
      fut.complete(val)
      return fut
    if rx.closed:
      release(rx.lock)
      fut.fail(newException(BroadcastClosed, "Broadcast channel is closed"))
      return fut
    # Slow path: wait for data
    rx.waiters.addLast(fut)
    release(rx.lock)
  else:
    if rx.count > 0:
      let val = move rx.buffer[rx.head]
      rx.head = (rx.head + 1) mod rx.capacity
      dec rx.count
      fut.complete(val)
      return fut
    if rx.closed:
      fut.fail(newException(BroadcastClosed, "Broadcast channel is closed"))
      return fut
    rx.waiters.addLast(fut)
  return fut

proc tryRecv*[T](rx: BroadcastReceiver[T]): Option[T] =
  ## Try to receive without blocking. Returns none if no data is buffered.
  if rx.mtEnabled:
    acquire(rx.lock)
    if rx.count > 0:
      var val = move rx.buffer[rx.head]
      rx.head = (rx.head + 1) mod rx.capacity
      dec rx.count
      release(rx.lock)
      return some(move(val))
    else:
      release(rx.lock)
      return none(T)
  else:
    if rx.count > 0:
      var val = move rx.buffer[rx.head]
      rx.head = (rx.head + 1) mod rx.capacity
      dec rx.count
      return some(move(val))
    else:
      return none(T)

proc len*[T](rx: BroadcastReceiver[T]): int =
  ## Number of items currently buffered in this receiver.
  if rx.mtEnabled:
    acquire(rx.lock)
    result = rx.count
    release(rx.lock)
  else:
    result = rx.count

# ============================================================
# Broadcast Channel: Close
# ============================================================

proc close*[T](ch: BroadcastChannel[T]) =
  ## Close the broadcast channel. All receivers are closed and
  ## their pending waiters are failed with BroadcastClosed.
  var allWaiters: seq[CpsFuture[T]]
  if ch.mtEnabled:
    acquire(ch.lock)
    ch.closed = true
    for rx in ch.receivers:
      if rx.mtEnabled:
        acquire(rx.lock)
      rx.closed = true
      while rx.waiters.len > 0:
        allWaiters.add(rx.waiters.popFirst())
      if rx.mtEnabled:
        release(rx.lock)
    release(ch.lock)
  else:
    ch.closed = true
    for rx in ch.receivers:
      rx.closed = true
      while rx.waiters.len > 0:
        allWaiters.add(rx.waiters.popFirst())
  # Fail all waiters outside locks
  let err = newException(BroadcastClosed, "Broadcast channel is closed")
  for f in allWaiters:
    f.fail(err)

# ============================================================
# Watch Channel: Construction
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
    initLock(result.lock)

# ============================================================
# Watch Channel: Subscribe
# ============================================================

proc subscribe*[T](ch: WatchChannel[T]): WatchReceiver[T] =
  ## Create a new receiver for this watch channel.
  ## The receiver starts having already seen the current value,
  ## so recv() will block until the next change. Use borrow()
  ## to read the current value immediately.
  result = WatchReceiver[T](
    lastVersion: 0,  # Start at 0 so first borrow/recv sees the initial value
    channel: ch,
    waiters: initDeque[CpsFuture[T]](),
  )
  # Capture mtEnabled from the channel, not from the global, for consistency
  if ch.mtEnabled:
    result.mtEnabled = true
    initLock(result.lock)
  if ch.mtEnabled:
    acquire(ch.lock)
    ch.receivers.add(result)
    release(ch.lock)
  else:
    ch.receivers.add(result)

# ============================================================
# Watch Channel: Send
# ============================================================

proc send*[T](ch: WatchChannel[T], value: T) =
  ## Update the watch channel's value and wake all waiting receivers.
  var deliveries: seq[tuple[fut: CpsFuture[T], val: T]]

  if ch.mtEnabled:
    acquire(ch.lock)
    if ch.closed:
      release(ch.lock)
      raise newException(BroadcastClosed, "Cannot send on closed watch channel")
    ch.value = value
    inc ch.version
    let currentVersion = ch.version
    let currentValue = ch.value
    for rx in ch.receivers:
      if rx.mtEnabled:
        acquire(rx.lock)
      if rx.waiters.len > 0:
        # Wake the first waiter with the new value
        let waiter = rx.waiters.popFirst()
        rx.lastVersion = currentVersion
        if rx.mtEnabled:
          release(rx.lock)
        deliveries.add((fut: waiter, val: currentValue))
      else:
        if rx.mtEnabled:
          release(rx.lock)
    release(ch.lock)
  else:
    if ch.closed:
      raise newException(BroadcastClosed, "Cannot send on closed watch channel")
    ch.value = value
    inc ch.version
    let currentVersion = ch.version
    let currentValue = ch.value
    for rx in ch.receivers:
      if rx.waiters.len > 0:
        let waiter = rx.waiters.popFirst()
        rx.lastVersion = currentVersion
        deliveries.add((fut: waiter, val: currentValue))

  # Complete futures outside all locks
  for d in deliveries:
    d.fut.complete(d.val)

# ============================================================
# Watch Channel: Recv / Borrow / hasChanged
# ============================================================

proc borrow*[T](rx: WatchReceiver[T]): T =
  ## Read the current value without blocking. Does not update the
  ## receiver's version tracking, so hasChanged() is not affected.
  let ch = rx.channel
  if ch.mtEnabled:
    acquire(ch.lock)
    result = ch.value
    release(ch.lock)
  else:
    result = ch.value

proc hasChanged*[T](rx: WatchReceiver[T]): bool =
  ## Check if the watch channel's value has changed since the last
  ## recv() call on this receiver.
  let ch = rx.channel
  if ch.mtEnabled:
    acquire(ch.lock)
    result = ch.version > rx.lastVersion
    release(ch.lock)
  else:
    result = ch.version > rx.lastVersion

proc recv*[T](rx: WatchReceiver[T]): CpsFuture[T] =
  ## Wait until the watch channel's value changes, then return
  ## the new value. If the value has already changed since the
  ## last recv, returns immediately with the current value.
  let fut = newCpsFuture[T]()
  let ch = rx.channel

  if ch.mtEnabled:
    acquire(ch.lock)
    if ch.version > rx.lastVersion:
      # Fast path: value has changed since we last looked.
      # Update lastVersion while ch.lock is still held to avoid TOCTOU:
      # another send() between release(ch.lock) and the update could
      # be missed if lastVersion is stale.
      let val = ch.value
      rx.lastVersion = ch.version
      release(ch.lock)
      fut.complete(val)
      return fut
    if ch.closed:
      release(ch.lock)
      fut.fail(newException(BroadcastClosed, "Watch channel is closed"))
      return fut
    # Slow path: wait for change
    if rx.mtEnabled:
      acquire(rx.lock)
    rx.waiters.addLast(fut)
    if rx.mtEnabled:
      release(rx.lock)
    release(ch.lock)
  else:
    if ch.version > rx.lastVersion:
      let val = ch.value
      rx.lastVersion = ch.version
      fut.complete(val)
      return fut
    if ch.closed:
      fut.fail(newException(BroadcastClosed, "Watch channel is closed"))
      return fut
    rx.waiters.addLast(fut)
  return fut

# ============================================================
# Watch Channel: Close
# ============================================================

proc close*[T](ch: WatchChannel[T]) =
  ## Close the watch channel. All waiting receivers are woken
  ## with a BroadcastClosed error.
  var allWaiters: seq[CpsFuture[T]]
  if ch.mtEnabled:
    acquire(ch.lock)
    ch.closed = true
    for rx in ch.receivers:
      if rx.mtEnabled:
        acquire(rx.lock)
      while rx.waiters.len > 0:
        allWaiters.add(rx.waiters.popFirst())
      if rx.mtEnabled:
        release(rx.lock)
    release(ch.lock)
  else:
    ch.closed = true
    for rx in ch.receivers:
      while rx.waiters.len > 0:
        allWaiters.add(rx.waiters.popFirst())
  # Fail all waiters outside locks
  let err = newException(BroadcastClosed, "Watch channel is closed")
  for f in allWaiters:
    f.fail(err)
