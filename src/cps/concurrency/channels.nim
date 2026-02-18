## CPS Async Channels
##
## Provides async channels for producer/consumer communication between
## CPS coroutines. Supports both bounded (ring buffer) and unbounded channels.
##
## Bounded channels use a fixed-size ring buffer for O(1) enqueue/dequeue
## with zero allocation on the hot path. When the buffer is full, senders
## suspend until space opens. When empty, receivers suspend until data arrives.
##
## Unbounded channels never block senders — they grow as needed.
##
## Thread safety: when mtModeEnabled is true (MT runtime active), channel
## state is protected by a Lock with minimal hold time. Future completions
## happen outside the lock to avoid deadlocks.

import std/[options, deques, locks]
import ../runtime

proc runtimeMtEnabled(): bool {.inline.} =
  let rt = currentRuntime().runtime
  rt != nil and rt.flavor == rfMultiThread

type
  ChannelClosed* = object of CatchableError
    ## Raised when operating on a closed channel.

  WaitingReceiver[T] = object
    fut: CpsFuture[T]

  WaitingSender[T] = object
    fut: CpsVoidFuture
    value: T  ## The value this sender wants to push (for bounded full case)

  AsyncChannel*[T] = ref object
    ## An async channel for producer/consumer communication.
    ## Can be bounded (fixed capacity ring buffer) or unbounded.
    bounded: bool
    closed: bool
    # Ring buffer (bounded mode)
    buf: seq[T]
    head: int        ## Index of next item to dequeue
    tail: int        ## Index of next slot to enqueue
    count: int       ## Number of items in buffer
    cap: int         ## Capacity (0 = unbounded)
    # Unbounded buffer
    unboundedBuf: Deque[T]
    # Waiter queues
    waitingReceivers: Deque[WaitingReceiver[T]]
    waitingSenders: Deque[WaitingSender[T]]
    # MT safety
    lock: Lock
    mtEnabled: bool

# ============================================================
# Construction
# ============================================================

proc newAsyncChannel*[T](capacity: int): AsyncChannel[T] =
  ## Create a bounded async channel with the given capacity.
  ## The capacity must be >= 1.
  assert capacity >= 1, "Channel capacity must be >= 1"
  result = AsyncChannel[T](
    bounded: true,
    closed: false,
    buf: newSeq[T](capacity),
    head: 0,
    tail: 0,
    count: 0,
    cap: capacity,
    waitingReceivers: initDeque[WaitingReceiver[T]](),
    waitingSenders: initDeque[WaitingSender[T]](),
  )
  if runtimeMtEnabled():
    result.mtEnabled = true
    initLock(result.lock)

proc newAsyncChannel*[T](): AsyncChannel[T] =
  ## Create an unbounded async channel. Senders never block.
  result = AsyncChannel[T](
    bounded: false,
    closed: false,
    cap: 0,
    unboundedBuf: initDeque[T](),
    waitingReceivers: initDeque[WaitingReceiver[T]](),
    waitingSenders: initDeque[WaitingSender[T]](),
  )
  if runtimeMtEnabled():
    result.mtEnabled = true
    initLock(result.lock)

# ============================================================
# Stats
# ============================================================

proc len*[T](ch: AsyncChannel[T]): int =
  ## Number of items currently buffered in the channel.
  if ch.mtEnabled:
    acquire(ch.lock)
    result = if ch.bounded: ch.count else: ch.unboundedBuf.len
    release(ch.lock)
  else:
    result = if ch.bounded: ch.count else: ch.unboundedBuf.len

proc capacity*[T](ch: AsyncChannel[T]): int =
  ## Capacity of the channel. Returns 0 for unbounded channels.
  ch.cap

proc isClosed*[T](ch: AsyncChannel[T]): bool =
  ## Whether the channel has been closed.
  if ch.mtEnabled:
    acquire(ch.lock)
    result = ch.closed
    release(ch.lock)
  else:
    result = ch.closed

proc isEmpty*[T](ch: AsyncChannel[T]): bool =
  ## Whether the channel's buffer is empty (no items to receive).
  ch.len == 0

proc isFull*[T](ch: AsyncChannel[T]): bool =
  ## Whether the channel's buffer is full (bounded channels only).
  ## Always returns false for unbounded channels.
  ch.capacity > 0 and ch.len == ch.capacity

# ============================================================
# Internal ring buffer operations
# ============================================================

proc ringPush[T](ch: AsyncChannel[T], value: sink T) {.inline.} =
  ## Push a value into the ring buffer. Caller must ensure space is available.
  ch.buf[ch.tail] = move(value)
  ch.tail = (ch.tail + 1) mod ch.cap
  inc ch.count

proc ringPop[T](ch: AsyncChannel[T]): T {.inline.} =
  ## Pop a value from the ring buffer. Caller must ensure buffer is non-empty.
  result = move(ch.buf[ch.head])
  ch.head = (ch.head + 1) mod ch.cap
  dec ch.count

# ============================================================
# Close
# ============================================================

proc close*[T](ch: AsyncChannel[T]) =
  ## Close the channel. All waiting senders and receivers are woken
  ## with a ChannelClosed error. After close, trySend returns false
  ## and tryRecv drains remaining buffered items then returns none.
  var pendingReceivers: seq[CpsFuture[T]]
  var pendingSenders: seq[CpsVoidFuture]
  if ch.mtEnabled:
    acquire(ch.lock)
    ch.closed = true
    while ch.waitingReceivers.len > 0:
      pendingReceivers.add(ch.waitingReceivers.popFirst().fut)
    while ch.waitingSenders.len > 0:
      pendingSenders.add(ch.waitingSenders.popFirst().fut)
    release(ch.lock)
  else:
    ch.closed = true
    while ch.waitingReceivers.len > 0:
      pendingReceivers.add(ch.waitingReceivers.popFirst().fut)
    while ch.waitingSenders.len > 0:
      pendingSenders.add(ch.waitingSenders.popFirst().fut)
  # Fail all waiters outside the lock
  let err = newException(ChannelClosed, "Channel is closed")
  for f in pendingReceivers:
    f.fail(err)
  for f in pendingSenders:
    f.fail(err)

# ============================================================
# Non-blocking operations
# ============================================================

proc trySend*[T](ch: AsyncChannel[T], value: sink T): bool =
  ## Try to send a value without blocking. Returns true if the value
  ## was sent, false if the channel is full or closed.
  if ch.mtEnabled:
    acquire(ch.lock)
    if ch.closed:
      release(ch.lock)
      return false
    # Direct handoff to a waiting receiver
    if ch.waitingReceivers.len > 0:
      let receiver = ch.waitingReceivers.popFirst()
      release(ch.lock)
      receiver.fut.complete(move(value))
      return true
    if ch.bounded:
      if ch.count >= ch.cap:
        release(ch.lock)
        return false
      ch.ringPush(move(value))
    else:
      ch.unboundedBuf.addLast(move(value))
    release(ch.lock)
    return true
  else:
    if ch.closed:
      return false
    if ch.waitingReceivers.len > 0:
      let receiver = ch.waitingReceivers.popFirst()
      receiver.fut.complete(move(value))
      return true
    if ch.bounded:
      if ch.count >= ch.cap:
        return false
      ch.ringPush(move(value))
    else:
      ch.unboundedBuf.addLast(move(value))
    return true

proc tryRecv*[T](ch: AsyncChannel[T]): Option[T] =
  ## Try to receive a value without blocking. Returns none if the
  ## channel is empty. After close, drains remaining buffered items.
  if ch.mtEnabled:
    acquire(ch.lock)
    if ch.bounded:
      if ch.count > 0:
        var val = ch.ringPop()
        # If a sender is waiting (buffer was full), push their value
        # into the now-open slot and complete their future.
        if ch.waitingSenders.len > 0:
          var sender = ch.waitingSenders.popFirst()
          ch.ringPush(move(sender.value))
          release(ch.lock)
          sender.fut.complete()
        else:
          release(ch.lock)
        return some(move(val))
      else:
        release(ch.lock)
        return none(T)
    else:
      if ch.unboundedBuf.len > 0:
        var val = ch.unboundedBuf.popFirst()
        release(ch.lock)
        return some(move(val))
      else:
        release(ch.lock)
        return none(T)
  else:
    if ch.bounded:
      if ch.count > 0:
        var val = ch.ringPop()
        if ch.waitingSenders.len > 0:
          var sender = ch.waitingSenders.popFirst()
          ch.ringPush(move(sender.value))
          sender.fut.complete()
        return some(move(val))
      return none(T)
    else:
      if ch.unboundedBuf.len > 0:
        return some(ch.unboundedBuf.popFirst())
      return none(T)

# ============================================================
# Blocking (async) operations
# ============================================================

proc send*[T](ch: AsyncChannel[T], value: sink T): CpsVoidFuture =
  ## Send a value to the channel. If the channel is bounded and full,
  ## the returned future suspends until space is available. If the
  ## channel is closed, the future fails with ChannelClosed.
  let fut = newCpsVoidFuture()
  if ch.mtEnabled:
    acquire(ch.lock)
    if ch.closed:
      release(ch.lock)
      fut.fail(newException(ChannelClosed, "Cannot send on closed channel"))
      return fut
    # Direct handoff to a waiting receiver
    if ch.waitingReceivers.len > 0:
      let receiver = ch.waitingReceivers.popFirst()
      release(ch.lock)
      receiver.fut.complete(move(value))
      fut.complete()
      return fut
    if ch.bounded:
      if ch.count < ch.cap:
        ch.ringPush(move(value))
        release(ch.lock)
        fut.complete()
        return fut
      else:
        # Buffer full — park the sender with its value.
        # When a receiver pops, it will push this value into
        # the ring and complete the sender's future.
        ch.waitingSenders.addLast(WaitingSender[T](fut: fut, value: move(value)))
        release(ch.lock)
        return fut
    else:
      # Unbounded — always has space
      ch.unboundedBuf.addLast(move(value))
      release(ch.lock)
      fut.complete()
      return fut
  else:
    if ch.closed:
      fut.fail(newException(ChannelClosed, "Cannot send on closed channel"))
      return fut
    if ch.waitingReceivers.len > 0:
      let receiver = ch.waitingReceivers.popFirst()
      receiver.fut.complete(move(value))
      fut.complete()
      return fut
    if ch.bounded:
      if ch.count < ch.cap:
        ch.ringPush(move(value))
        fut.complete()
        return fut
      else:
        ch.waitingSenders.addLast(WaitingSender[T](fut: fut, value: move(value)))
        return fut
    else:
      ch.unboundedBuf.addLast(move(value))
      fut.complete()
      return fut

proc recv*[T](ch: AsyncChannel[T]): CpsFuture[T] =
  ## Receive a value from the channel. If the channel is empty,
  ## the returned future suspends until a value is available. If the
  ## channel is closed and empty, the future fails with ChannelClosed.
  let fut = newCpsFuture[T]()
  if ch.mtEnabled:
    acquire(ch.lock)
    if ch.bounded:
      if ch.count > 0:
        var val = ch.ringPop()
        # If a sender is waiting, push their value and wake them
        if ch.waitingSenders.len > 0:
          var sender = ch.waitingSenders.popFirst()
          ch.ringPush(move(sender.value))
          release(ch.lock)
          sender.fut.complete()
          fut.complete(move(val))
        else:
          release(ch.lock)
          fut.complete(move(val))
        return fut
      else:
        # Buffer empty — check for direct handoff from waiting sender
        if ch.waitingSenders.len > 0:
          var sender = ch.waitingSenders.popFirst()
          release(ch.lock)
          sender.fut.complete()
          fut.complete(move(sender.value))
          return fut
    else:
      if ch.unboundedBuf.len > 0:
        var val = ch.unboundedBuf.popFirst()
        release(ch.lock)
        fut.complete(move(val))
        return fut
    # Buffer empty and no waiting senders — suspend or fail
    if ch.closed:
      release(ch.lock)
      fut.fail(newException(ChannelClosed, "Channel is closed and empty"))
      return fut
    ch.waitingReceivers.addLast(WaitingReceiver[T](fut: fut))
    release(ch.lock)
  else:
    if ch.bounded:
      if ch.count > 0:
        var val = ch.ringPop()
        if ch.waitingSenders.len > 0:
          var sender = ch.waitingSenders.popFirst()
          ch.ringPush(move(sender.value))
          sender.fut.complete()
        fut.complete(move(val))
        return fut
      else:
        if ch.waitingSenders.len > 0:
          var sender = ch.waitingSenders.popFirst()
          sender.fut.complete()
          fut.complete(move(sender.value))
          return fut
    else:
      if ch.unboundedBuf.len > 0:
        var val = ch.unboundedBuf.popFirst()
        fut.complete(move(val))
        return fut
    if ch.closed:
      fut.fail(newException(ChannelClosed, "Channel is closed and empty"))
      return fut
    ch.waitingReceivers.addLast(WaitingReceiver[T](fut: fut))
  return fut
