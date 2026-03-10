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
## Thread safety: when the MT runtime is active, channel state is protected
## by a CAS-based SpinLock (not pthread_mutex) to ensure the reactor thread
## is never blocked by a syscall. Future completions happen outside the lock
## to avoid deadlocks (callbacks may re-enter the channel).

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
    lock: SpinLock
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
    buf: newSeq[T](capacity),
    cap: capacity,
    waitingReceivers: initDeque[WaitingReceiver[T]](),
    waitingSenders: initDeque[WaitingSender[T]](),
  )
  if runtimeMtEnabled():
    result.mtEnabled = true
    initSpinLock(result.lock)

proc newAsyncChannel*[T](): AsyncChannel[T] =
  ## Create an unbounded async channel. Senders never block.
  result = AsyncChannel[T](
    unboundedBuf: initDeque[T](),
    waitingReceivers: initDeque[WaitingReceiver[T]](),
    waitingSenders: initDeque[WaitingSender[T]](),
  )
  if runtimeMtEnabled():
    result.mtEnabled = true
    initSpinLock(result.lock)

# ============================================================
# Stats
# ============================================================

proc len*[T](ch: AsyncChannel[T]): int =
  ## Number of items currently buffered. Snapshot — may be stale under MT.
  withLock(ch.lock, ch.mtEnabled):
    result = if ch.bounded: ch.count else: ch.unboundedBuf.len

proc capacity*[T](ch: AsyncChannel[T]): int =
  ## Capacity of the channel. Returns 0 for unbounded channels.
  ch.cap

proc isClosed*[T](ch: AsyncChannel[T]): bool =
  ## Whether the channel has been closed.
  withLock(ch.lock, ch.mtEnabled):
    result = ch.closed

proc isEmpty*[T](ch: AsyncChannel[T]): bool =
  ## Whether the channel's buffer is empty. Atomic under MT.
  withLock(ch.lock, ch.mtEnabled):
    result = if ch.bounded: ch.count == 0 else: ch.unboundedBuf.len == 0

proc isFull*[T](ch: AsyncChannel[T]): bool =
  ## Whether the channel's buffer is full. Atomic under MT.
  ## Always returns false for unbounded channels.
  withLock(ch.lock, ch.mtEnabled):
    result = ch.bounded and ch.count == ch.cap

# ============================================================
# Internal ring buffer operations
# ============================================================

proc ringPush[T](ch: AsyncChannel[T], value: sink T) {.inline.} =
  ch.buf[ch.tail] = move(value)
  inc ch.tail
  if ch.tail == ch.cap: ch.tail = 0
  inc ch.count

proc ringPop[T](ch: AsyncChannel[T]): T {.inline.} =
  result = move(ch.buf[ch.head])
  inc ch.head
  if ch.head == ch.cap: ch.head = 0
  dec ch.count

proc popLiveReceiver[T](ch: AsyncChannel[T], receiver: var WaitingReceiver[T]): bool {.inline.} =
  while ch.waitingReceivers.len > 0:
    let candidate = ch.waitingReceivers.popFirst()
    if not candidate.fut.finished:
      receiver = candidate
      return true
  false

proc popLiveSender[T](ch: AsyncChannel[T], sender: var WaitingSender[T]): bool {.inline.} =
  while ch.waitingSenders.len > 0:
    let candidate = ch.waitingSenders.popFirst()
    if not candidate.fut.finished:
      sender = candidate
      return true
  false

# ============================================================
# Close
# ============================================================

proc close*[T](ch: AsyncChannel[T]) =
  ## Close the channel. All waiting senders and receivers are woken
  ## with a ChannelClosed error. After close, trySend returns false
  ## and tryRecv drains remaining buffered items then returns none.
  var pendingReceivers: seq[CpsFuture[T]]
  var pendingSenders: seq[CpsVoidFuture]
  withLock(ch.lock, ch.mtEnabled):
    ch.closed = true
    while ch.waitingReceivers.len > 0:
      let receiver = ch.waitingReceivers.popFirst()
      if not receiver.fut.finished:
        pendingReceivers.add(receiver.fut)
    while ch.waitingSenders.len > 0:
      let sender = ch.waitingSenders.popFirst()
      if not sender.fut.finished:
        pendingSenders.add(sender.fut)
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
  var receiver: WaitingReceiver[T]
  withLock(ch.lock, ch.mtEnabled):
    if ch.closed:
      return false
    if ch.popLiveReceiver(receiver):
      discard  # complete outside lock
    elif ch.bounded:
      if ch.count >= ch.cap:
        return false
      ch.ringPush(move(value))
      return true
    else:
      ch.unboundedBuf.addLast(move(value))
      return true
  # Direct handoff outside lock
  receiver.fut.complete(move(value))
  true

proc tryRecv*[T](ch: AsyncChannel[T]): Option[T] =
  ## Try to receive a value without blocking. Returns none if the
  ## channel is empty. After close, drains remaining buffered items.
  var val: T
  var senderFut: CpsVoidFuture
  withLock(ch.lock, ch.mtEnabled):
    if ch.bounded:
      if ch.count == 0:
        return none(T)
      val = ch.ringPop()
      var sender: WaitingSender[T]
      if ch.popLiveSender(sender):
        ch.ringPush(move(sender.value))
        senderFut = sender.fut
    else:
      if ch.unboundedBuf.len == 0:
        return none(T)
      val = ch.unboundedBuf.popFirst()
  # Complete sender outside lock
  if not senderFut.isNil:
    senderFut.complete()
  some(move(val))

# ============================================================
# Blocking (async) operations
# ============================================================

proc send*[T](ch: AsyncChannel[T], value: sink T): CpsVoidFuture =
  ## Send a value to the channel. If the channel is bounded and full,
  ## the returned future suspends until space is available. If the
  ## channel is closed, the future fails with ChannelClosed.
  let fut = newCpsVoidFuture()
  var receiverFut: CpsFuture[T]
  var doClosed, doHandoff, doComplete: bool
  withLock(ch.lock, ch.mtEnabled):
    if ch.closed:
      doClosed = true
    else:
      var receiver: WaitingReceiver[T]
      if ch.popLiveReceiver(receiver):
        receiverFut = receiver.fut
        doHandoff = true
      elif ch.bounded:
        if ch.count < ch.cap:
          ch.ringPush(move(value))
          doComplete = true
        else:
          # Buffer full — park the sender with its value.
          # When a receiver pops, it will push this value into
          # the ring and complete the sender's future.
          ch.waitingSenders.addLast(WaitingSender[T](fut: fut, value: move(value)))
          return fut
      else:
        ch.unboundedBuf.addLast(move(value))
        doComplete = true
  if doClosed:
    fut.fail(newException(ChannelClosed, "Cannot send on closed channel"))
  elif doHandoff:
    receiverFut.complete(move(value))
    fut.complete()
  elif doComplete:
    fut.complete()
  # else: parked (bounded full) — completed later by a receiver
  fut

proc recv*[T](ch: AsyncChannel[T]): CpsFuture[T] =
  ## Receive a value from the channel. If the channel is empty,
  ## the returned future suspends until a value is available. If the
  ## channel is closed and empty, the future fails with ChannelClosed.
  let fut = newCpsFuture[T]()
  var val: T
  var gotValue = false
  var senderFut: CpsVoidFuture
  var doClosed = false
  withLock(ch.lock, ch.mtEnabled):
    if ch.bounded:
      if ch.count > 0:
        val = ch.ringPop()
        gotValue = true
        var sender: WaitingSender[T]
        if ch.popLiveSender(sender):
          ch.ringPush(move(sender.value))
          senderFut = sender.fut
      else:
        # Empty buffer — direct handoff from waiting sender
        var sender: WaitingSender[T]
        if ch.popLiveSender(sender):
          val = move(sender.value)
          senderFut = sender.fut
          gotValue = true
    else:
      if ch.unboundedBuf.len > 0:
        val = ch.unboundedBuf.popFirst()
        gotValue = true
    if not gotValue:
      if ch.closed:
        doClosed = true
      else:
        ch.waitingReceivers.addLast(WaitingReceiver[T](fut: fut))
  # Complete futures outside lock
  if doClosed:
    fut.fail(newException(ChannelClosed, "Channel is closed and empty"))
  elif gotValue:
    if not senderFut.isNil:
      senderFut.complete()
    fut.complete(move(val))
  # else: parked — completed later by a sender
  fut
