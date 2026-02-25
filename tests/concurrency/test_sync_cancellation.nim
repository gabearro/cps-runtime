## Cancellation-safety regression tests for sync primitives.

import cps/runtime
import cps/concurrency/sync

block testSemaphoreCanceledWaiterDoesNotConsumePermit:
  let sem = newAsyncSemaphore(1)
  assert sem.tryAcquire(), "Initial tryAcquire should consume the only permit"

  let waiter = sem.acquire()
  assert not waiter.finished, "Second acquire should wait"
  waiter.cancel()
  assert waiter.isCancelled(), "Waiter should be cancelled"

  sem.release()
  assert sem.tryAcquire(), "release() should restore permit when only cancelled waiters exist"
  echo "PASS: AsyncSemaphore skips cancelled waiters on release"

block testMutexCanceledWaiterDoesNotRetainLock:
  let m = newAsyncMutex()
  assert m.tryLock(), "Initial tryLock should succeed"

  let waiter = m.lock()
  assert not waiter.finished, "Second lock should wait"
  waiter.cancel()
  assert waiter.isCancelled(), "Waiter should be cancelled"

  m.unlock()
  assert m.tryLock(), "unlock() should release mutex when queued waiters were cancelled"
  m.unlock()
  echo "PASS: AsyncMutex skips cancelled waiters on unlock"


echo "All sync cancellation tests passed!"
