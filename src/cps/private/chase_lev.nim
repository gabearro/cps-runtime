## Chase-Lev Work-Stealing Deque
##
## Lock-free deque for work-stealing schedulers. The owner thread pushes
## and pops from the bottom (LIFO, cache-friendly). Thief threads steal
## from the top (FIFO, fair distribution).
##
## Based on "Dynamic Circular Work-Stealing Deque" by Chase & Lev (SPAA 2005).
## Uses a fixed-size circular buffer.
##
## Memory ordering:
## - push: release store on bottom (makes item visible to stealers)
## - pop: seq-cst fence between bottom store and top load (linearization point)
## - steal: acquire loads + CAS on top (linearization point)

import std/atomics

const
  ChaseLevCapacity* = 8192  ## Fixed buffer size (power of 2)
  ChaseLevMask = ChaseLevCapacity - 1

type
  StealResult*[T] = enum
    srSuccess, srEmpty, srAbort  ## abort = lost CAS race, retry

  ChaseLevDeque*[T] = object
    buffer: ptr UncheckedArray[T]
    top: Atomic[int64]       ## Thieves steal from here (CAS)
    bottom: Atomic[int64]    ## Owner pushes/pops here

proc initChaseLevDeque*[T](d: var ChaseLevDeque[T]) =
  ## Initialize the deque with a fixed-size buffer.
  d.buffer = cast[ptr UncheckedArray[T]](allocShared0(sizeof(T) * ChaseLevCapacity))
  d.top.store(0, moRelaxed)
  d.bottom.store(0, moRelaxed)

proc destroyChaseLevDeque*[T](d: var ChaseLevDeque[T]) =
  ## Free the buffer. Must be called after all threads are done.
  if d.buffer != nil:
    deallocShared(d.buffer)
    d.buffer = nil

proc push*[T](d: var ChaseLevDeque[T], item: T): bool {.discardable.} =
  ## Owner: push an item to the bottom (LIFO end).
  let b = d.bottom.load(moRelaxed)
  let t = d.top.load(moAcquire)
  let size = b - t
  if size >= ChaseLevCapacity:
    return false
  d.buffer[b and ChaseLevMask] = item
  fence(moRelease)
  d.bottom.store(b + 1, moRelaxed)
  result = true

proc pop*[T](d: var ChaseLevDeque[T]): T =
  ## Owner: pop an item from the bottom (LIFO end).
  ## Returns default(T) if empty.
  let b = d.bottom.load(moRelaxed) - 1
  d.bottom.store(b, moRelaxed)
  fence(moSequentiallyConsistent)
  let t = d.top.load(moRelaxed)
  if t <= b:
    # Non-empty
    let item = d.buffer[b and ChaseLevMask]
    if t == b:
      # Last element — race with steal
      var expected = t
      if not d.top.compareExchange(expected, t + 1, moSequentiallyConsistent, moRelaxed):
        # Lost race to a thief
        d.bottom.store(b + 1, moRelaxed)
        return default(T)
      d.bottom.store(b + 1, moRelaxed)
    return item
  else:
    # Empty
    d.bottom.store(b + 1, moRelaxed)
    return default(T)

proc steal*[T](d: var ChaseLevDeque[T]): T =
  ## Thief: steal an item from the top (FIFO end).
  ## Returns default(T) if empty or lost CAS race.
  let t = d.top.load(moAcquire)
  fence(moSequentiallyConsistent)
  let b = d.bottom.load(moAcquire)
  if t < b:
    let item = d.buffer[t and ChaseLevMask]
    var expected = t
    if not d.top.compareExchange(expected, t + 1, moSequentiallyConsistent, moRelaxed):
      # Lost race — another thief or owner got it
      return default(T)
    return item
  else:
    return default(T)

proc len*[T](d: var ChaseLevDeque[T]): int {.inline.} =
  ## Approximate length (may be stale immediately).
  let b = d.bottom.load(moRelaxed)
  let t = d.top.load(moRelaxed)
  result = max(0, int(b - t))
