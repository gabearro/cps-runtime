## Bounded lock-free MPSC ring queue.
##
## Multiple producers reserve slots through one enqueue cursor. The single
## consumer owns the dequeue cursor, so consuming an item needs no CAS. Slot
## sequence numbers distinguish empty, published, and recycled generations.

import std/[atomics, math]

const CacheLineBytes = 64

type
  RingSlot[T] = object
    sequence: Atomic[int]
    value: T

  MpscRingQueue*[T] = object
    slots: ptr UncheckedArray[RingSlot[T]]
    capacity: int
    mask: int
    enqueuePos: Atomic[int]
    enqueuePad {.align(CacheLineBytes).}:
      array[CacheLineBytes - sizeof(Atomic[int]), byte]
    dequeuePos: int

proc initMpscRingQueue*[T](q: var MpscRingQueue[T],
                           requestedCapacity: int) =
  ## Initialize a bounded queue, rounding capacity up to a power of two.
  let cap = nextPowerOfTwo(max(requestedCapacity, 2))
  q.slots = cast[ptr UncheckedArray[RingSlot[T]]](
    allocShared0(sizeof(RingSlot[T]) * cap))
  q.capacity = cap
  q.mask = cap - 1
  q.dequeuePos = 0
  q.enqueuePos.store(0, moRelaxed)
  for i in 0 ..< cap:
    q.slots[i].sequence.store(i, moRelaxed)

proc tryEnqueue*[T](q: var MpscRingQueue[T], value: var T): bool {.inline.} =
  ## Move one item into the ring, leaving ``value`` unchanged when full.
  var pos = q.enqueuePos.load(moRelaxed)
  while true:
    let slot = addr q.slots[pos and q.mask]
    let sequence = slot.sequence.load(moAcquire)
    let difference = sequence - pos
    if difference == 0:
      var expected = pos
      if q.enqueuePos.compareExchange(expected, pos + 1,
                                      moAcquireRelease, moRelaxed):
        slot.value = move(value)
        slot.sequence.store(pos + 1, moRelease)
        return true
      pos = expected
    elif difference < 0:
      return false
    else:
      pos = q.enqueuePos.load(moRelaxed)

proc tryDequeue*[T](q: var MpscRingQueue[T], value: var T): bool {.inline.} =
  ## Consume one item. This operation must only be called by the owning worker.
  let pos = q.dequeuePos
  let slot = addr q.slots[pos and q.mask]
  if slot.sequence.load(moAcquire) != pos + 1:
    return false
  q.dequeuePos = pos + 1
  value = move(slot.value)
  slot.sequence.store(pos + q.capacity, moRelease)
  true

proc isEmpty*[T](q: var MpscRingQueue[T]): bool {.inline.} =
  ## Return whether the next consumer-owned slot has not been published.
  let pos = q.dequeuePos
  q.slots[pos and q.mask].sequence.load(moAcquire) != pos + 1

proc deinitMpscRingQueue*[T](q: var MpscRingQueue[T]) =
  ## Drain and release queue storage after all producers have stopped.
  if q.slots == nil:
    return
  var value: T
  while q.tryDequeue(value):
    discard
  deallocShared(q.slots)
  q.slots = nil
  q.capacity = 0
  q.mask = 0
  q.dequeuePos = 0
  q.enqueuePos.store(0, moRelaxed)
