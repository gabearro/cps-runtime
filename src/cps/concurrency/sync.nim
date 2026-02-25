## CPS Async Synchronization Primitives
##
## Provides async-aware synchronization primitives for coordinating
## concurrent CPS tasks:
## - AsyncSemaphore: counting semaphore with FIFO fairness
## - AsyncMutex: mutual exclusion lock (semaphore with 1 permit)
## - AsyncEvent: manual-reset event for signaling
##
## All primitives support both single-threaded and multi-threaded modes.
## MT safety uses Lock from std/locks when mtModeEnabled is true.
##
## Performance: fast paths (permit available, mutex unlocked, event set)
## complete synchronously with no future allocation for waiters.

import std/[deques, locks]
import ../runtime

proc runtimeMtEnabled(): bool {.inline.} =
  let rt = currentRuntime().runtime
  rt != nil and rt.flavor == rfMultiThread

type
  SyncClosed* = object of CatchableError
    ## Raised when operating on a closed sync primitive.

# ============================================================
# AsyncSemaphore
# ============================================================

type
  AsyncSemaphore* = ref object
    ## A counting semaphore for limiting concurrent access.
    ## Waiters are served in FIFO order.
    permits: int
    maxPermits: int
    waiters: Deque[CpsVoidFuture]
    closed: bool
    lock: Lock
    mtEnabled: bool

proc newAsyncSemaphore*(permits: int): AsyncSemaphore =
  ## Create a new semaphore with the given number of permits.
  assert permits > 0, "Semaphore permits must be positive"
  result = AsyncSemaphore(
    permits: permits,
    maxPermits: permits,
    waiters: initDeque[CpsVoidFuture](),
    closed: false,
    mtEnabled: runtimeMtEnabled()
  )
  if result.mtEnabled:
    initLock(result.lock)

proc acquire*(sem: AsyncSemaphore): CpsVoidFuture =
  ## Acquire a permit from the semaphore.
  ## If a permit is available, completes synchronously (zero overhead).
  ## Otherwise, the returned future blocks until a permit is released.
  if sem.mtEnabled:
    acquire(sem.lock)
    if sem.closed:
      release(sem.lock)
      result = newCpsVoidFuture()
      fail(result, newException(SyncClosed, "Semaphore is closed"))
      return result
    if sem.permits > 0:
      dec sem.permits
      release(sem.lock)
      result = newCpsVoidFuture()
      complete(result)
      return result
    else:
      result = newCpsVoidFuture()
      sem.waiters.addLast(result)
      release(sem.lock)
      return result
  else:
    if sem.closed:
      result = newCpsVoidFuture()
      fail(result, newException(SyncClosed, "Semaphore is closed"))
      return result
    if sem.permits > 0:
      dec sem.permits
      result = newCpsVoidFuture()
      complete(result)
      return result
    else:
      result = newCpsVoidFuture()
      sem.waiters.addLast(result)
      return result

proc release*(sem: AsyncSemaphore) =
  ## Release a permit back to the semaphore.
  ## If there are waiters, the oldest waiter is woken (FIFO).
  ## Otherwise, the permit count is incremented.
  if sem.mtEnabled:
    acquire(sem.lock)
    var waiter: CpsVoidFuture = nil
    while sem.waiters.len > 0:
      let candidate = sem.waiters.popFirst()
      if not candidate.finished:
        waiter = candidate
        break
    if waiter != nil:
      release(sem.lock)
      complete(waiter)
    else:
      inc sem.permits
      assert sem.permits <= sem.maxPermits,
        "Released more permits than maximum (" & $sem.maxPermits & ")"
      release(sem.lock)
  else:
    var waiter: CpsVoidFuture = nil
    while sem.waiters.len > 0:
      let candidate = sem.waiters.popFirst()
      if not candidate.finished:
        waiter = candidate
        break
    if waiter != nil:
      complete(waiter)
    else:
      inc sem.permits
      assert sem.permits <= sem.maxPermits,
        "Released more permits than maximum (" & $sem.maxPermits & ")"

proc tryAcquire*(sem: AsyncSemaphore): bool =
  ## Try to acquire a permit without blocking.
  ## Returns true if a permit was acquired, false otherwise.
  if sem.mtEnabled:
    acquire(sem.lock)
    if sem.permits > 0:
      dec sem.permits
      release(sem.lock)
      return true
    else:
      release(sem.lock)
      return false
  else:
    if sem.permits > 0:
      dec sem.permits
      return true
    else:
      return false

proc availablePermits*(sem: AsyncSemaphore): int =
  ## Return the number of currently available permits.
  if sem.mtEnabled:
    acquire(sem.lock)
    result = sem.permits
    release(sem.lock)
  else:
    result = sem.permits

proc close*(sem: AsyncSemaphore) =
  ## Close the semaphore. All pending waiters are failed with SyncClosed.
  var pendingWaiters: seq[CpsVoidFuture]
  if sem.mtEnabled:
    acquire(sem.lock)
    sem.closed = true
    while sem.waiters.len > 0:
      let waiter = sem.waiters.popFirst()
      if not waiter.finished:
        pendingWaiters.add(waiter)
    release(sem.lock)
  else:
    sem.closed = true
    while sem.waiters.len > 0:
      let waiter = sem.waiters.popFirst()
      if not waiter.finished:
        pendingWaiters.add(waiter)
  let err = newException(SyncClosed, "Semaphore is closed")
  for f in pendingWaiters:
    fail(f, err)

# ============================================================
# AsyncMutex
# ============================================================

type
  AsyncMutex* = ref object
    ## An async-aware mutual exclusion lock.
    ## Only one task can hold the lock at a time.
    ## Waiters are served in FIFO order.
    locked: bool
    waiters: Deque[CpsVoidFuture]
    closed: bool
    lock: Lock
    mtEnabled: bool

proc newAsyncMutex*(): AsyncMutex =
  ## Create a new unlocked mutex.
  result = AsyncMutex(
    locked: false,
    waiters: initDeque[CpsVoidFuture](),
    closed: false,
    mtEnabled: runtimeMtEnabled()
  )
  if result.mtEnabled:
    initLock(result.lock)

proc lock*(m: AsyncMutex): CpsVoidFuture =
  ## Acquire the mutex. If unlocked, completes synchronously.
  ## Otherwise, the returned future blocks until the mutex is released.
  if m.mtEnabled:
    acquire(m.lock)
    if m.closed:
      release(m.lock)
      result = newCpsVoidFuture()
      fail(result, newException(SyncClosed, "Mutex is closed"))
      return result
    if not m.locked:
      m.locked = true
      release(m.lock)
      result = newCpsVoidFuture()
      complete(result)
      return result
    else:
      result = newCpsVoidFuture()
      m.waiters.addLast(result)
      release(m.lock)
      return result
  else:
    if m.closed:
      result = newCpsVoidFuture()
      fail(result, newException(SyncClosed, "Mutex is closed"))
      return result
    if not m.locked:
      m.locked = true
      result = newCpsVoidFuture()
      complete(result)
      return result
    else:
      result = newCpsVoidFuture()
      m.waiters.addLast(result)
      return result

proc unlock*(m: AsyncMutex) =
  ## Release the mutex. If there are waiters, the oldest waiter
  ## acquires the lock (FIFO). Otherwise, the mutex becomes unlocked.
  if m.mtEnabled:
    acquire(m.lock)
    assert m.locked, "Mutex is not locked"
    var waiter: CpsVoidFuture = nil
    while m.waiters.len > 0:
      let candidate = m.waiters.popFirst()
      if not candidate.finished:
        waiter = candidate
        break
    if waiter != nil:
      # Lock transfers directly to next live waiter (stays locked)
      release(m.lock)
      complete(waiter)
    else:
      m.locked = false
      release(m.lock)
  else:
    assert m.locked, "Mutex is not locked"
    var waiter: CpsVoidFuture = nil
    while m.waiters.len > 0:
      let candidate = m.waiters.popFirst()
      if not candidate.finished:
        waiter = candidate
        break
    if waiter != nil:
      complete(waiter)
    else:
      m.locked = false

proc tryLock*(m: AsyncMutex): bool =
  ## Try to acquire the mutex without blocking.
  ## Returns true if the lock was acquired, false otherwise.
  if m.mtEnabled:
    acquire(m.lock)
    if not m.locked:
      m.locked = true
      release(m.lock)
      return true
    else:
      release(m.lock)
      return false
  else:
    if not m.locked:
      m.locked = true
      return true
    else:
      return false

proc isLocked*(m: AsyncMutex): bool =
  ## Check if the mutex is currently locked.
  if m.mtEnabled:
    acquire(m.lock)
    result = m.locked
    release(m.lock)
  else:
    result = m.locked

proc close*(m: AsyncMutex) =
  ## Close the mutex. All pending waiters are failed with SyncClosed.
  var pendingWaiters: seq[CpsVoidFuture]
  if m.mtEnabled:
    acquire(m.lock)
    m.closed = true
    while m.waiters.len > 0:
      let waiter = m.waiters.popFirst()
      if not waiter.finished:
        pendingWaiters.add(waiter)
    release(m.lock)
  else:
    m.closed = true
    while m.waiters.len > 0:
      let waiter = m.waiters.popFirst()
      if not waiter.finished:
        pendingWaiters.add(waiter)
  let err = newException(SyncClosed, "Mutex is closed")
  for f in pendingWaiters:
    fail(f, err)

# ============================================================
# AsyncEvent
# ============================================================

type
  AsyncEvent* = ref object
    ## A manual-reset event for signaling between tasks.
    ## When set, all current and future waiters are woken immediately.
    ## When cleared, new waiters block until the event is set again.
    flag: bool
    waiters: seq[CpsVoidFuture]
    closed: bool
    lock: Lock
    mtEnabled: bool

proc newAsyncEvent*(): AsyncEvent =
  ## Create a new unset event.
  result = AsyncEvent(
    flag: false,
    waiters: @[],
    closed: false,
    mtEnabled: runtimeMtEnabled()
  )
  if result.mtEnabled:
    initLock(result.lock)

proc wait*(ev: AsyncEvent): CpsVoidFuture =
  ## Wait for the event to be set. If already set, completes immediately.
  ## Otherwise, the returned future blocks until set() is called.
  if ev.mtEnabled:
    acquire(ev.lock)
    if ev.closed:
      release(ev.lock)
      result = newCpsVoidFuture()
      fail(result, newException(SyncClosed, "Event is closed"))
      return result
    if ev.flag:
      release(ev.lock)
      result = newCpsVoidFuture()
      complete(result)
      return result
    else:
      result = newCpsVoidFuture()
      ev.waiters.add(result)
      release(ev.lock)
      return result
  else:
    if ev.closed:
      result = newCpsVoidFuture()
      fail(result, newException(SyncClosed, "Event is closed"))
      return result
    if ev.flag:
      result = newCpsVoidFuture()
      complete(result)
      return result
    else:
      result = newCpsVoidFuture()
      ev.waiters.add(result)
      return result

proc set*(ev: AsyncEvent) =
  ## Set the event, waking all current waiters.
  ## Future calls to wait() will complete immediately until clear() is called.
  if ev.mtEnabled:
    var waitersToWake: seq[CpsVoidFuture]
    acquire(ev.lock)
    ev.flag = true
    waitersToWake = move(ev.waiters)
    ev.waiters = @[]
    release(ev.lock)
    for w in waitersToWake:
      complete(w)
  else:
    ev.flag = true
    let waitersToWake = move(ev.waiters)
    ev.waiters = @[]
    for w in waitersToWake:
      complete(w)

proc clear*(ev: AsyncEvent) =
  ## Clear the event. New calls to wait() will block until set() is called.
  if ev.mtEnabled:
    acquire(ev.lock)
    ev.flag = false
    release(ev.lock)
  else:
    ev.flag = false

proc isSet*(ev: AsyncEvent): bool =
  ## Check if the event is currently set.
  if ev.mtEnabled:
    acquire(ev.lock)
    result = ev.flag
    release(ev.lock)
  else:
    result = ev.flag

proc close*(ev: AsyncEvent) =
  ## Close the event. All pending waiters are failed with SyncClosed.
  var pendingWaiters: seq[CpsVoidFuture]
  if ev.mtEnabled:
    acquire(ev.lock)
    ev.closed = true
    pendingWaiters = move(ev.waiters)
    ev.waiters = @[]
    release(ev.lock)
  else:
    ev.closed = true
    pendingWaiters = move(ev.waiters)
    ev.waiters = @[]
  let err = newException(SyncClosed, "Event is closed")
  for f in pendingWaiters:
    fail(f, err)

# ============================================================
# RAII-style helpers (for use inside CPS procs only)
# ============================================================

template withPermit*(sem: AsyncSemaphore, body: untyped) =
  ## Acquire a semaphore permit, execute body, then release.
  ## Must be used inside a {.cps.} proc.
  await acquire(sem)
  try:
    body
  finally:
    release(sem)

template withLock*(m: AsyncMutex, body: untyped) =
  ## Acquire a mutex, execute body, then release.
  ## Must be used inside a {.cps.} proc.
  await lock(m)
  try:
    body
  finally:
    unlock(m)
