## Bounded lock-free MPMC ring queue (Vyukov-style sequence algorithm).
##
## Supports multiple producers and multiple consumers with fixed capacity.
## Capacity is rounded up to the next power-of-two.

import std/[atomics, math]

const CacheLinePad = 64

type
  RingSlot[T] = object
    seqNum: Atomic[int]
    value: T

  MpmcRingQueue*[T] = object
    slots: ptr UncheckedArray[RingSlot[T]]
    capacity: int
    mask: int
    enqueuePos: Atomic[int]
    pad0: array[CacheLinePad - sizeof(Atomic[int]), byte]
    dequeuePos: Atomic[int]

proc initMpmcRingQueue*[T](q: var MpmcRingQueue[T], requestedCapacity: int) =
  ## Initialize queue with bounded power-of-two capacity.
  let cap = nextPowerOfTwo(max(requestedCapacity, 2))

  q.capacity = cap
  q.mask = cap - 1
  q.slots = cast[ptr UncheckedArray[RingSlot[T]]](allocShared0(sizeof(RingSlot[T]) * cap))

  for i in 0 ..< cap:
    q.slots[i].seqNum.store(i, moRelaxed)

  q.enqueuePos.store(0, moRelaxed)
  q.dequeuePos.store(0, moRelaxed)

proc tryEnqueue*[T](q: var MpmcRingQueue[T], value: T): bool {.inline.} =
  ## Try to enqueue one item. Returns false when full.
  var pos = q.enqueuePos.load(moRelaxed)
  while true:
    let slot = addr q.slots[pos and q.mask]
    let s = slot.seqNum.load(moAcquire)
    let dif = s - pos

    if dif == 0:
      var expected = pos
      if q.enqueuePos.compareExchange(expected, pos + 1, moAcquireRelease, moRelaxed):
        slot.value = value
        slot.seqNum.store(pos + 1, moRelease)
        return true
      pos = expected
    elif dif < 0:
      return false
    else:
      pos = q.enqueuePos.load(moRelaxed)

proc tryDequeue*[T](q: var MpmcRingQueue[T], value: var T): bool {.inline.} =
  ## Try to dequeue one item. Returns false when empty.
  var pos = q.dequeuePos.load(moRelaxed)
  while true:
    let slot = addr q.slots[pos and q.mask]
    let s = slot.seqNum.load(moAcquire)
    let dif = s - (pos + 1)

    if dif == 0:
      var expected = pos
      if q.dequeuePos.compareExchange(expected, pos + 1, moAcquireRelease, moRelaxed):
        value = slot.value
        slot.value = default(T)
        slot.seqNum.store(pos + q.capacity, moRelease)
        return true
      pos = expected
    elif dif < 0:
      return false
    else:
      pos = q.dequeuePos.load(moRelaxed)

proc len*[T](q: var MpmcRingQueue[T]): int {.inline.} =
  ## Approximate item count (racy under concurrency).
  max(0, q.enqueuePos.load(moRelaxed) - q.dequeuePos.load(moRelaxed))

proc deinitMpmcRingQueue*[T](q: var MpmcRingQueue[T]) =
  ## Drain and release queue storage.
  if q.slots == nil:
    return

  var tmp: T
  while q.tryDequeue(tmp):
    discard

  deallocShared(q.slots)
  q.slots = nil
  q.capacity = 0
  q.mask = 0
  q.enqueuePos.store(0, moRelaxed)
  q.dequeuePos.store(0, moRelaxed)
