## Lightweight CAS-based spinlock for microsecond-hold critical sections.
##
## Unlike std/locks.Lock (pthread_mutex), this never makes a syscall,
## ensuring the reactor thread is never blocked by the OS scheduler.
## Suitable only for very short critical sections (< 10µs).
##
## Properties:
##   - Lock-free progress for the system (some thread always makes progress)
##   - No priority inversion (no OS scheduler involvement)
##   - No syscall overhead (pure userspace CAS + PAUSE)
##   - Bounded spin: yields via cpuRelax() (~1-5ns per iteration)

import std/atomics

type
  SpinLock* = object
    state: Atomic[int]  ## 0 = unlocked, 1 = locked

proc initSpinLock*(sl: var SpinLock) {.inline.} =
  sl.state.store(0, moRelaxed)

proc acquire*(sl: var SpinLock) {.inline.} =
  ## Acquire the spinlock. Spins with PAUSE until available.
  var expected = 0
  while not sl.state.compareExchangeWeak(expected, 1, moAcquire, moRelaxed):
    expected = 0
    cpuRelax()

proc release*(sl: var SpinLock) {.inline.} =
  ## Release the spinlock.
  sl.state.store(0, moRelease)

proc tryAcquire*(sl: var SpinLock): bool {.inline.} =
  ## Try to acquire the spinlock without spinning.
  ## Returns true if acquired, false if already held.
  var expected = 0
  sl.state.compareExchangeWeak(expected, 1, moAcquire, moRelaxed)

template withSpinLock*(sl: var SpinLock, body: untyped) =
  ## Acquire the spinlock, execute body, then release.
  ## Guarantees release even if body raises an exception.
  acquire(sl)
  try:
    body
  finally:
    release(sl)
