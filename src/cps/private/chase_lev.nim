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
## - push: release fence before bottom store (makes item visible to stealers)
## - pop: seq-cst fence between bottom store and top load (linearization point)
## - steal: acquire loads + seq-cst CAS on top (linearization point)
##
## ARC safety: pop/steal use raw memory ops (copyMem/zeroMem) to bypass
## ARC hooks, preventing double-ref-count when two threads read the same
## slot during the last-element race. push uses normal ARC assignment
## (=copy) since only the owner thread pushes — no concurrent writes.
## Ref count protocol:
## - push: ARC =copy increments ref count for the buffer slot
## - pop/steal success: rawRead (bitwise copy, no rc change) + rawClear
##   (zero without =destroy) transfers the slot's ref count to the caller
## - pop/steal failure: zeroMem on local copy (no =destroy, no rc change)
##
## Cache lines: `top` and `bottom` are padded to separate cache lines to
## avoid false sharing between the owner (writes `bottom`) and thieves
## (CAS on `top`).

import std/atomics

const
  ChaseLevCapacity* = 8192  ## Fixed buffer size (power of 2)
  ChaseLevMask = ChaseLevCapacity - 1
  CacheLineBytes = 64

type
  ChaseLevDeque*[T] = object
    buffer: ptr UncheckedArray[T]
    top: Atomic[int64]                           ## Thieves CAS here
    topPad {.align(CacheLineBytes).}: array[CacheLineBytes - sizeof(Atomic[int64]), byte]
    bottom: Atomic[int64]                        ## Owner pushes/pops here

# Raw memory helpers — bypass ARC hooks for buffer slot management.
# This ensures that concurrent reads from the same slot (pop/steal race)
# do not each increment the ref count, which would leave the buffer
# with a stale counted reference after one side wins the CAS.

proc slotAddr[T](d: var ChaseLevDeque[T], idx: int64): pointer {.inline.} =
  addr d.buffer[idx and ChaseLevMask]

proc rawRead[T](d: var ChaseLevDeque[T], idx: int64): T {.inline.} =
  ## Read a slot without touching ref counts (bitwise copy).
  copyMem(addr result, d.slotAddr(idx), sizeof(T))

proc rawClear[T](d: var ChaseLevDeque[T], idx: int64) {.inline.} =
  ## Zero a slot without calling =destroy on the old value.
  zeroMem(d.slotAddr(idx), sizeof(T))

proc initChaseLevDeque*[T](d: var ChaseLevDeque[T]) =
  ## Initialize the deque. Allocates a zero-initialized shared buffer.
  d.buffer = cast[ptr UncheckedArray[T]](allocShared0(sizeof(T) * ChaseLevCapacity))
  d.top.store(0, moRelaxed)
  d.bottom.store(0, moRelaxed)

proc destroyChaseLevDeque*[T](d: var ChaseLevDeque[T]) =
  ## Free the buffer. Caller must drain all live items first (see scheduler
  ## shutdown) so no ref-counted values are leaked.
  if d.buffer != nil:
    deallocShared(d.buffer)
    d.buffer = nil

proc push*[T](d: var ChaseLevDeque[T], item: T): bool {.inline, discardable.} =
  ## Owner: push an item to the bottom. Returns false if full.
  let b = d.bottom.load(moRelaxed)
  let t = d.top.load(moAcquire)
  if b - t >= ChaseLevCapacity:
    return false
  # Normal Nim assignment: ARC's =copy increments the ref count for the buffer.
  # Safe because only the owner thread pushes (no concurrent writes).
  # The slot is always zero (from allocShared0 or rawClear) so =destroy on the
  # old value is a no-op.
  d.buffer[b and ChaseLevMask] = item
  fence(moRelease)
  d.bottom.store(b + 1, moRelaxed)
  result = true

proc pop*[T](d: var ChaseLevDeque[T]): T {.inline.} =
  ## Owner: pop from the bottom. Returns default(T) if empty.
  ## On success, transfers the buffer slot's ref count to the caller and
  ## clears the slot.
  let b = d.bottom.load(moRelaxed) - 1
  d.bottom.store(b, moRelaxed)
  fence(moSequentiallyConsistent)
  let t = d.top.load(moRelaxed)
  if t > b:
    # Was empty — restore bottom
    d.bottom.store(b + 1, moRelaxed)
    return default(T)
  # Raw read: bitwise copy without incrementing ref count.
  # The buffer slot still holds the same bits — we clear it on success
  # so there is exactly one owner of the ref count at all times.
  result = rawRead[T](d, b)
  if t < b:
    # More than one element — owner wins unconditionally.
    # Clear the slot: the ref count now lives solely in `result`.
    rawClear[T](d, b)
    return
  # Last element — CAS race with thieves.
  d.bottom.store(b + 1, moRelaxed)
  var expected = t
  if d.top.compareExchange(expected, t + 1, moSequentiallyConsistent, moRelaxed):
    # Won the race — we own the ref count. Clear the slot.
    rawClear[T](d, b)
    return
  # Lost the race — the thief took ownership of the ref count.
  # Zero our local copy WITHOUT running =destroy (we don't own it).
  zeroMem(addr result, sizeof(T))

proc steal*[T](d: var ChaseLevDeque[T]): T {.inline.} =
  ## Thief: steal from the top. Returns default(T) if empty or lost CAS race.
  ## On success, transfers the buffer slot's ref count to the caller and
  ## clears the slot.
  let t = d.top.load(moAcquire)
  fence(moSequentiallyConsistent)
  let b = d.bottom.load(moAcquire)
  if t < b:
    # Raw read: bitwise copy without incrementing ref count.
    result = rawRead[T](d, t)
    var expected = t
    if d.top.compareExchange(expected, t + 1, moSequentiallyConsistent, moRelaxed):
      # Won the race — we own the ref count. Clear the slot.
      rawClear[T](d, t)
      return
    # Lost the race — the owner (pop) took ownership.
    # Zero our local copy WITHOUT running =destroy (we don't own it).
    zeroMem(addr result, sizeof(T))
  return default(T)

proc drainAll*[T](d: var ChaseLevDeque[T]) =
  ## Owner: pop and destroy all remaining items. Call during shutdown
  ## after all thieves have stopped, to properly release ref counts
  ## for any items left in the buffer.
  while true:
    let item = d.pop()
    if item == default(T):
      break
    # `item` goes out of scope here — ARC runs =destroy, releasing the ref count.

proc isEmpty*[T](d: var ChaseLevDeque[T]): bool {.inline.} =
  ## Approximate emptiness check (may be stale immediately).
  d.bottom.load(moRelaxed) <= d.top.load(moRelaxed)

proc len*[T](d: var ChaseLevDeque[T]): int {.inline.} =
  ## Approximate length (may be stale immediately).
  let b = d.bottom.load(moRelaxed)
  let t = d.top.load(moRelaxed)
  result = max(0, int(b - t))
