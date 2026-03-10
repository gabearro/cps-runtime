## CPS Async Synchronization Primitives
##
## Provides async-aware synchronization primitives for coordinating
## concurrent CPS tasks:
## - AsyncSemaphore: counting semaphore with FIFO fairness
## - AsyncMutex: mutual exclusion lock (semaphore with 1 permit)
## - AsyncEvent: manual-reset event for signaling
##
## All primitives support both single-threaded and multi-threaded modes.
## MT safety uses a CAS-based SpinLock (not pthread_mutex) to ensure the
## reactor thread is never blocked by a syscall on contended paths.
##
## Performance: fast paths (permit available, mutex unlocked, event set)
## return pre-completed futures with no callback dispatch overhead.

import std/deques
import ../runtime
import ../private/spinlock

proc runtimeMtEnabled(): bool {.inline.} =
  let rt = currentRuntime().runtime
  rt != nil and rt.flavor == rfMultiThread

template withOptLock(lock: var SpinLock, mt: bool, body: untyped) =
  ## Execute body with conditional spinlock protection.
  ## When mt is true, acquires the lock and guarantees release via
  ## try/finally (exception-safe). When false, executes body directly.
  if mt:
    withSpinLock(lock):
      body
  else:
    body

proc popLiveWaiter(waiters: var Deque[CpsVoidFuture]): CpsVoidFuture {.inline.} =
  ## Pop and return the first non-finished waiter, or nil if none remain.
  while waiters.len > 0:
    let candidate = waiters.popFirst()
    if not candidate.finished:
      return candidate

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
    lock: SpinLock
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
    initSpinLock(result.lock)

proc acquire*(sem: AsyncSemaphore): CpsVoidFuture =
  ## Acquire a permit from the semaphore.
  ## If a permit is available, returns a pre-completed future (zero overhead).
  ## Otherwise, the returned future blocks until a permit is released.
  withOptLock(sem.lock, sem.mtEnabled):
    if sem.closed:
      return failedVoidFuture(newException(SyncClosed, "Semaphore is closed"))
    if sem.permits > 0:
      dec sem.permits
      return completedVoidFuture()
    result = newCpsVoidFuture()
    sem.waiters.addLast(result)

proc release*(sem: AsyncSemaphore) =
  ## Release a permit back to the semaphore.
  ## If there are waiters, the oldest waiter is woken (FIFO).
  ## Otherwise, the permit count is incremented.
  var waiter: CpsVoidFuture
  withOptLock(sem.lock, sem.mtEnabled):
    waiter = popLiveWaiter(sem.waiters)
    if waiter.isNil:
      inc sem.permits
      assert sem.permits <= sem.maxPermits,
        "Released more permits than maximum (" & $sem.maxPermits & ")"
  # Complete outside lock to avoid callback re-entrancy under spinlock
  if not waiter.isNil:
    complete(waiter)

proc tryAcquire*(sem: AsyncSemaphore): bool =
  ## Try to acquire a permit without blocking.
  ## Returns true if a permit was acquired, false otherwise.
  withOptLock(sem.lock, sem.mtEnabled):
    if sem.permits > 0:
      dec sem.permits
      return true
    return false

proc availablePermits*(sem: AsyncSemaphore): int =
  ## Return the number of currently available permits.
  withOptLock(sem.lock, sem.mtEnabled):
    return sem.permits

proc close*(sem: AsyncSemaphore) =
  ## Close the semaphore. All pending waiters are failed with SyncClosed.
  var pending: seq[CpsVoidFuture]
  withOptLock(sem.lock, sem.mtEnabled):
    sem.closed = true
    while sem.waiters.len > 0:
      let waiter = sem.waiters.popFirst()
      if not waiter.finished:
        pending.add(waiter)
  # Fail outside lock
  let err = newException(SyncClosed, "Semaphore is closed")
  for f in pending:
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
    lock: SpinLock
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
    initSpinLock(result.lock)

proc lock*(m: AsyncMutex): CpsVoidFuture =
  ## Acquire the mutex. If unlocked, returns a pre-completed future.
  ## Otherwise, the returned future blocks until the mutex is released.
  withOptLock(m.lock, m.mtEnabled):
    if m.closed:
      return failedVoidFuture(newException(SyncClosed, "Mutex is closed"))
    if not m.locked:
      m.locked = true
      return completedVoidFuture()
    result = newCpsVoidFuture()
    m.waiters.addLast(result)

proc unlock*(m: AsyncMutex) =
  ## Release the mutex. If there are waiters, the oldest waiter
  ## acquires the lock (FIFO). Otherwise, the mutex becomes unlocked.
  var waiter: CpsVoidFuture
  withOptLock(m.lock, m.mtEnabled):
    assert m.locked, "Mutex is not locked"
    waiter = popLiveWaiter(m.waiters)
    if waiter.isNil:
      m.locked = false
  # Complete outside lock — lock transfers directly to next waiter
  if not waiter.isNil:
    complete(waiter)

proc tryLock*(m: AsyncMutex): bool =
  ## Try to acquire the mutex without blocking.
  ## Returns true if the lock was acquired, false otherwise.
  withOptLock(m.lock, m.mtEnabled):
    if not m.locked:
      m.locked = true
      return true
    return false

proc isLocked*(m: AsyncMutex): bool =
  ## Check if the mutex is currently locked.
  withOptLock(m.lock, m.mtEnabled):
    return m.locked

proc close*(m: AsyncMutex) =
  ## Close the mutex. All pending waiters are failed with SyncClosed.
  var pending: seq[CpsVoidFuture]
  withOptLock(m.lock, m.mtEnabled):
    m.closed = true
    while m.waiters.len > 0:
      let waiter = m.waiters.popFirst()
      if not waiter.finished:
        pending.add(waiter)
  let err = newException(SyncClosed, "Mutex is closed")
  for f in pending:
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
    lock: SpinLock
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
    initSpinLock(result.lock)

proc wait*(ev: AsyncEvent): CpsVoidFuture =
  ## Wait for the event to be set. If already set, completes immediately.
  ## Otherwise, the returned future blocks until set() is called.
  withOptLock(ev.lock, ev.mtEnabled):
    if ev.closed:
      return failedVoidFuture(newException(SyncClosed, "Event is closed"))
    if ev.flag:
      return completedVoidFuture()
    result = newCpsVoidFuture()
    ev.waiters.add(result)

proc set*(ev: AsyncEvent) =
  ## Set the event, waking all current waiters.
  ## Future calls to wait() will complete immediately until clear() is called.
  var waitersToWake: seq[CpsVoidFuture]
  withOptLock(ev.lock, ev.mtEnabled):
    ev.flag = true
    waitersToWake = move(ev.waiters)
    ev.waiters = @[]
  for w in waitersToWake:
    complete(w)

proc clear*(ev: AsyncEvent) =
  ## Clear the event. New calls to wait() will block until set() is called.
  withOptLock(ev.lock, ev.mtEnabled):
    ev.flag = false

proc isSet*(ev: AsyncEvent): bool =
  ## Check if the event is currently set.
  withOptLock(ev.lock, ev.mtEnabled):
    return ev.flag

proc close*(ev: AsyncEvent) =
  ## Close the event. All pending waiters are failed with SyncClosed.
  var pending: seq[CpsVoidFuture]
  withOptLock(ev.lock, ev.mtEnabled):
    ev.closed = true
    pending = move(ev.waiters)
    ev.waiters = @[]
  let err = newException(SyncClosed, "Event is closed")
  for f in pending:
    fail(f, err)

# ============================================================
# RAII-style helpers (for use inside CPS procs only)
# ============================================================

template withPermit*(sem: AsyncSemaphore, body: untyped) {.dirty.} =
  ## Acquire a semaphore permit, execute body, then release.
  ## Must be used inside a {.cps.} proc.
  await acquire(sem)
  try:
    body
  finally:
    release(sem)

template withLock*(m: AsyncMutex, body: untyped) {.dirty.} =
  ## Acquire a mutex, execute body, then release.
  ## Must be used inside a {.cps.} proc.
  await lock(m)
  try:
    body
  finally:
    unlock(m)
