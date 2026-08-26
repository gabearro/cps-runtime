## Atomic parking primitive for lock-free worker queues.
##
## The sequence counter closes the enqueue-before-sleep race without a mutex:
## a waiter snapshots the counter, publishes that it is parked, rechecks its
## queue, then sleeps only while the counter still matches. Notifications
## advance the counter before waking the kernel waiter, so an early wake is
## observed instead of lost.

import std/atomics
when not (defined(linux) or defined(macosx) or defined(windows)):
  import std/os

type
  AtomicParker* = object
    epoch: Atomic[int32]

proc initAtomicParker*(parker: var AtomicParker) {.inline.} =
  ## Initialize a parker before it becomes visible to another thread.
  parker.epoch.store(0'i32, moRelaxed)

proc prepareWait*(parker: var AtomicParker): int32 {.inline.} =
  ## Snapshot the wake epoch before publishing the parked state.
  parker.epoch.load(moAcquire)

when defined(linux):
  {.emit: """
#include <linux/futex.h>
#include <limits.h>
#include <sys/syscall.h>
#include <unistd.h>

static inline void cps_futex_wait(volatile int *addr, int expected) {
  (void)syscall(SYS_futex, addr, FUTEX_WAIT_PRIVATE, expected, 0, 0, 0);
}

static inline void cps_futex_wake_one(volatile int *addr) {
  (void)syscall(SYS_futex, addr, FUTEX_WAKE_PRIVATE, 1, 0, 0, 0);
}

static inline void cps_futex_wake_all(volatile int *addr) {
  (void)syscall(SYS_futex, addr, FUTEX_WAKE_PRIVATE, INT_MAX, 0, 0, 0);
}
""".}

  proc platformWait(epochPtr: ptr int32, expected: int32) {.
    importc: "cps_futex_wait", nodecl.}
  proc platformWakeOne(epochPtr: ptr int32) {.
    importc: "cps_futex_wake_one", nodecl.}
  proc platformWakeAll(epochPtr: ptr int32) {.
    importc: "cps_futex_wake_all", nodecl.}

elif defined(macosx):
  # ulock is Darwin's native address-wait primitive. Keep the declarations
  # local because public SDKs do not install sys/ulock.h even though the
  # symbols are part of libSystem.
  {.emit: """
#include <stdint.h>

extern int __ulock_wait(uint32_t operation, void *addr,
                        uint64_t value, uint32_t timeout);
extern int __ulock_wake(uint32_t operation, void *addr,
                        uint64_t wake_value);

#define CPS_UL_COMPARE_AND_WAIT 1u
#define CPS_ULF_WAKE_ALL 0x00000100u

static inline void cps_ulock_wait(volatile int *addr, int expected) {
  (void)__ulock_wait(CPS_UL_COMPARE_AND_WAIT, (void *)addr,
                     (uint32_t)expected, 0);
}

static inline void cps_ulock_wake_one(volatile int *addr) {
  (void)__ulock_wake(CPS_UL_COMPARE_AND_WAIT, (void *)addr, 0);
}

static inline void cps_ulock_wake_all(volatile int *addr) {
  (void)__ulock_wake(CPS_UL_COMPARE_AND_WAIT | CPS_ULF_WAKE_ALL,
                     (void *)addr, 0);
}
""".}

  proc platformWait(epochPtr: ptr int32, expected: int32) {.
    importc: "cps_ulock_wait", nodecl.}
  proc platformWakeOne(epochPtr: ptr int32) {.
    importc: "cps_ulock_wake_one", nodecl.}
  proc platformWakeAll(epochPtr: ptr int32) {.
    importc: "cps_ulock_wake_all", nodecl.}

elif defined(windows):
  {.emit: """
#include <windows.h>

static inline void cps_address_wait(volatile LONG *addr, LONG expected) {
  (void)WaitOnAddress((volatile VOID *)addr, &expected,
                      sizeof(expected), INFINITE);
}

static inline void cps_address_wake_one(volatile LONG *addr) {
  WakeByAddressSingle((PVOID)addr);
}

static inline void cps_address_wake_all(volatile LONG *addr) {
  WakeByAddressAll((PVOID)addr);
}
""".}

  proc platformWait(epochPtr: ptr int32, expected: int32) {.
    importc: "cps_address_wait", nodecl.}
  proc platformWakeOne(epochPtr: ptr int32) {.
    importc: "cps_address_wake_one", nodecl.}
  proc platformWakeAll(epochPtr: ptr int32) {.
    importc: "cps_address_wake_all", nodecl.}

else:
  proc platformWait(epochPtr: ptr int32, expected: int32) =
    # Rare-platform fallback remains mutex-free. A one-millisecond sleep
    # avoids consuming an idle core when no native address-wait API is available.
    while cast[ptr Atomic[int32]](epochPtr)[].load(moAcquire) == expected:
      sleep(1)

  proc platformWakeOne(epochPtr: ptr int32) {.inline.} = discard
  proc platformWakeAll(epochPtr: ptr int32) {.inline.} = discard

proc wait*(parker: var AtomicParker, observedEpoch: int32) =
  ## Park only if no notification arrived since ``prepareWait``.
  if parker.epoch.load(moAcquire) == observedEpoch:
    platformWait(cast[ptr int32](addr parker.epoch), observedEpoch)

proc notifyOne*(parker: var AtomicParker) =
  ## Publish a wake and release at most one kernel waiter.
  discard parker.epoch.fetchAdd(1'i32, moRelease)
  platformWakeOne(cast[ptr int32](addr parker.epoch))

proc notifyAll*(parker: var AtomicParker) =
  ## Publish a wake and release every kernel waiter on this address.
  discard parker.epoch.fetchAdd(1'i32, moRelease)
  platformWakeAll(cast[ptr int32](addr parker.epoch))
