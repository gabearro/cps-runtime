## Tests for CPS async synchronization primitives
##
## Tests AsyncSemaphore, AsyncMutex, and AsyncEvent from cps/sync.

import cps/runtime
import cps/transform
import cps/eventloop
import cps/concurrency/sync

# ============================================================
# Semaphore Tests
# ============================================================

# --- Test 1: Basic acquire and release ---

proc semAcquireRelease(sem: AsyncSemaphore): CpsVoidFuture {.cps.} =
  await acquire(sem)
  release(sem)

block testSemBasic:
  let sem = newAsyncSemaphore(1)
  assert sem.availablePermits == 1
  runCps(semAcquireRelease(sem))
  assert sem.availablePermits == 1
  echo "PASS: Semaphore basic acquire and release"

# --- Test 2: tryAcquire succeeds when permits available ---

proc semTryAcquireSuccess(sem: AsyncSemaphore, result_fut: CpsFuture[bool]): CpsVoidFuture {.cps.} =
  let ok = tryAcquire(sem)
  complete(result_fut, ok)

block testSemTryAcquireSuccess:
  let sem = newAsyncSemaphore(1)
  let fut = newCpsFuture[bool]()
  runCps(semTryAcquireSuccess(sem, fut))
  assert fut.finished
  assert fut.read() == true
  assert sem.availablePermits == 0
  release(sem)  # clean up
  echo "PASS: Semaphore tryAcquire succeeds when permits available"

# --- Test 3: tryAcquire fails when no permits ---

proc semTryAcquireFail(sem: AsyncSemaphore, result_fut: CpsFuture[bool]): CpsVoidFuture {.cps.} =
  let ok = tryAcquire(sem)
  complete(result_fut, ok)

block testSemTryAcquireFail:
  let sem = newAsyncSemaphore(1)
  # Exhaust the one permit
  assert tryAcquire(sem) == true
  assert sem.availablePermits == 0

  let fut = newCpsFuture[bool]()
  runCps(semTryAcquireFail(sem, fut))
  assert fut.finished
  assert fut.read() == false
  release(sem)  # clean up
  echo "PASS: Semaphore tryAcquire fails when no permits"

# --- Test 4: acquire blocks when no permits, release unblocks ---

var semBlockOrder: seq[string]

proc semHolder(sem: AsyncSemaphore): CpsVoidFuture {.cps.} =
  await acquire(sem)
  semBlockOrder.add "holder:acquired"
  await cpsSleep(30)
  semBlockOrder.add "holder:releasing"
  release(sem)

proc semWaiter(sem: AsyncSemaphore): CpsVoidFuture {.cps.} =
  semBlockOrder.add "waiter:waiting"
  await acquire(sem)
  semBlockOrder.add "waiter:acquired"
  release(sem)

block testSemAcquireBlocks:
  let sem = newAsyncSemaphore(1)
  semBlockOrder = @[]
  # Holder grabs the permit first
  let t1 = spawn semHolder(sem)
  # Waiter tries to acquire - should block until holder releases
  let t2 = spawn semWaiter(sem)
  runCps(waitAll(t1.future, t2.future))
  # Holder acquired first, waiter waited, then holder released, then waiter acquired
  assert "holder:acquired" in semBlockOrder
  assert "waiter:waiting" in semBlockOrder
  assert "holder:releasing" in semBlockOrder
  assert "waiter:acquired" in semBlockOrder
  let holderReleasingIdx = semBlockOrder.find("holder:releasing")
  let waiterAcquiredIdx = semBlockOrder.find("waiter:acquired")
  assert holderReleasingIdx < waiterAcquiredIdx,
    "Waiter should acquire after holder releases: " & $semBlockOrder
  echo "PASS: Semaphore acquire blocks when no permits, release unblocks"

# --- Test 5: FIFO ordering of waiters ---

var semFifoOrder: seq[int]

proc semFifoWaiter(sem: AsyncSemaphore, id: int): CpsVoidFuture {.cps.} =
  await acquire(sem)
  semFifoOrder.add id
  release(sem)

block testSemFifo:
  let sem = newAsyncSemaphore(1)
  semFifoOrder = @[]
  # Exhaust the permit
  assert tryAcquire(sem) == true

  # Spawn 3 waiters - they should queue in FIFO order
  let t1 = spawn semFifoWaiter(sem, 1)
  let t2 = spawn semFifoWaiter(sem, 2)
  let t3 = spawn semFifoWaiter(sem, 3)

  # Give them time to all reach the acquire and queue up
  # They are all waiting; now release the permit to start the chain
  release(sem)

  runCps(waitAll(t1.future, t2.future, t3.future))
  assert semFifoOrder == @[1, 2, 3], "Expected FIFO order [1,2,3], got " & $semFifoOrder
  echo "PASS: Semaphore FIFO ordering of waiters"

# --- Test 6: Multiple permits ---

var semMultiActive: int
var semMultiMaxActive: int

proc semMultiWorker(sem: AsyncSemaphore): CpsVoidFuture {.cps.} =
  await acquire(sem)
  inc semMultiActive
  if semMultiActive > semMultiMaxActive:
    semMultiMaxActive = semMultiActive
  await cpsSleep(20)
  dec semMultiActive
  release(sem)

block testSemMultiplePermits:
  let sem = newAsyncSemaphore(3)
  semMultiActive = 0
  semMultiMaxActive = 0

  # Spawn 5 workers with a semaphore of 3 permits
  let t1 = spawn semMultiWorker(sem)
  let t2 = spawn semMultiWorker(sem)
  let t3 = spawn semMultiWorker(sem)
  let t4 = spawn semMultiWorker(sem)
  let t5 = spawn semMultiWorker(sem)

  runCps(waitAll(t1.future, t2.future, t3.future, t4.future, t5.future))
  assert semMultiMaxActive <= 3, "At most 3 workers should be active concurrently, but max was " & $semMultiMaxActive
  assert semMultiMaxActive >= 2, "At least 2 workers should have been active concurrently (got " & $semMultiMaxActive & ")"
  assert sem.availablePermits == 3, "All permits should be returned"
  echo "PASS: Semaphore multiple permits (max active=" & $semMultiMaxActive & ")"

# ============================================================
# Mutex Tests
# ============================================================

# --- Test 7: Mutex lock/unlock basic ---

proc mutexLockUnlock(m: AsyncMutex): CpsVoidFuture {.cps.} =
  await lock(m)
  unlock(m)

block testMutexBasic:
  let m = newAsyncMutex()
  assert not m.isLocked
  runCps(mutexLockUnlock(m))
  assert not m.isLocked
  echo "PASS: Mutex lock/unlock basic"

# --- Test 8: Second lock blocks until first unlocks ---

var mutexBlockOrder: seq[string]

proc mutexHolder(m: AsyncMutex): CpsVoidFuture {.cps.} =
  await lock(m)
  mutexBlockOrder.add "holder:locked"
  await cpsSleep(30)
  mutexBlockOrder.add "holder:unlocking"
  unlock(m)

proc mutexWaiter(m: AsyncMutex): CpsVoidFuture {.cps.} =
  mutexBlockOrder.add "waiter:waiting"
  await lock(m)
  mutexBlockOrder.add "waiter:locked"
  unlock(m)

block testMutexBlocks:
  let m = newAsyncMutex()
  mutexBlockOrder = @[]
  let t1 = spawn mutexHolder(m)
  let t2 = spawn mutexWaiter(m)
  runCps(waitAll(t1.future, t2.future))
  assert "holder:locked" in mutexBlockOrder
  assert "waiter:waiting" in mutexBlockOrder
  assert "holder:unlocking" in mutexBlockOrder
  assert "waiter:locked" in mutexBlockOrder
  let holderUnlockIdx = mutexBlockOrder.find("holder:unlocking")
  let waiterLockedIdx = mutexBlockOrder.find("waiter:locked")
  assert holderUnlockIdx < waiterLockedIdx,
    "Waiter should lock after holder unlocks: " & $mutexBlockOrder
  assert not m.isLocked
  echo "PASS: Mutex second lock blocks until first unlocks"

# --- Test 9: Mutex tryLock succeeds/fails ---

block testMutexTryLock:
  let m = newAsyncMutex()
  # tryLock should succeed when unlocked
  assert tryLock(m) == true
  assert m.isLocked
  # tryLock should fail when locked
  assert tryLock(m) == false
  # Unlock and try again
  unlock(m)
  assert not m.isLocked
  assert tryLock(m) == true
  unlock(m)
  echo "PASS: Mutex tryLock succeeds/fails"

# ============================================================
# Event Tests
# ============================================================

# --- Test 10: Wait on set event returns immediately ---

proc eventWaitSet(ev: AsyncEvent): CpsVoidFuture {.cps.} =
  await wait(ev)

block testEventWaitSetImmediate:
  let ev = newAsyncEvent()
  assert not ev.isSet
  set(ev)
  assert ev.isSet
  # Waiting on an already-set event should complete immediately
  runCps(eventWaitSet(ev))
  echo "PASS: Event wait on set event returns immediately"

# --- Test 11: Wait on unset event blocks, set wakes waiters ---

var eventWakeOrder: seq[string]

proc eventWaiterTask(ev: AsyncEvent, name: string): CpsVoidFuture {.cps.} =
  eventWakeOrder.add name & ":waiting"
  await wait(ev)
  eventWakeOrder.add name & ":woke"

proc eventSetterTask(ev: AsyncEvent): CpsVoidFuture {.cps.} =
  # Give waiters time to queue up
  await cpsSleep(30)
  eventWakeOrder.add "setter:setting"
  set(ev)

block testEventWaitBlocks:
  let ev = newAsyncEvent()
  eventWakeOrder = @[]
  let t1 = spawn eventWaiterTask(ev, "w1")
  let t2 = spawn eventWaiterTask(ev, "w2")
  let t3 = spawn eventSetterTask(ev)
  runCps(waitAll(t1.future, t2.future, t3.future))
  assert "w1:waiting" in eventWakeOrder
  assert "w2:waiting" in eventWakeOrder
  assert "setter:setting" in eventWakeOrder
  assert "w1:woke" in eventWakeOrder
  assert "w2:woke" in eventWakeOrder
  # Setter should set before waiters wake
  let setterIdx = eventWakeOrder.find("setter:setting")
  let w1WokeIdx = eventWakeOrder.find("w1:woke")
  let w2WokeIdx = eventWakeOrder.find("w2:woke")
  assert setterIdx < w1WokeIdx, "w1 should wake after set: " & $eventWakeOrder
  assert setterIdx < w2WokeIdx, "w2 should wake after set: " & $eventWakeOrder
  echo "PASS: Event wait on unset event blocks, set wakes waiters"

# --- Test 12: Event clear resets, new wait blocks ---

var eventClearOrder: seq[string]

proc eventClearWaiter(ev: AsyncEvent): CpsVoidFuture {.cps.} =
  eventClearOrder.add "waiter:waiting"
  await wait(ev)
  eventClearOrder.add "waiter:woke"

proc eventClearSetter(ev: AsyncEvent): CpsVoidFuture {.cps.} =
  await cpsSleep(30)
  eventClearOrder.add "setter:setting"
  set(ev)

block testEventClear:
  let ev = newAsyncEvent()
  # Set then clear -- should reset
  set(ev)
  assert ev.isSet
  clear(ev)
  assert not ev.isSet

  # Now wait should block since event is cleared
  eventClearOrder = @[]
  let t1 = spawn eventClearWaiter(ev)
  let t2 = spawn eventClearSetter(ev)
  runCps(waitAll(t1.future, t2.future))
  assert "waiter:waiting" in eventClearOrder
  assert "setter:setting" in eventClearOrder
  assert "waiter:woke" in eventClearOrder
  let setterIdx = eventClearOrder.find("setter:setting")
  let waiterWokeIdx = eventClearOrder.find("waiter:woke")
  assert setterIdx < waiterWokeIdx,
    "Waiter should wake after set: " & $eventClearOrder
  echo "PASS: Event clear resets, new wait blocks"

echo ""
echo "All sync primitive tests passed!"
