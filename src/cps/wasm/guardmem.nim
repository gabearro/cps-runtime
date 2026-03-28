## Guard-page backed WASM linear memory
##
## Reserves a large virtual address space (5 GiB by default) for each WASM
## memory instance. Only the pages up to the current memory size are mapped
## PROT_READ|PROT_WRITE; the rest are PROT_NONE (guard pages).
##
## When the JIT accesses WASM memory with a valid i32 address, the hardware
## bounds check is free — any out-of-range access hits the PROT_NONE region
## and raises SIGSEGV (Linux) or SIGBUS (macOS), which our signal handler
## converts to a WASM trap via siglongjmp.
##
## Usage:
##   1. Call `installGuardPageHandlers()` once at startup.
##   2. Wrap JIT invocations with the `wasmGuardedCall` template which sets up
##      the per-call sigsetjmp checkpoint.
##   3. Allocate memory instances with `allocGuardedMem` and grow them with
##      `growGuardedMem` instead of using seq[byte].
##   4. Pass `mem.base` and `high(uint64)` as the memBase/memSize pair to JIT
##      functions — the hardware guards replace the explicit bounds check.
##
## Enable with:  -d:wasmGuardPages
## Supported on: macOS (AArch64 + x86-64) and Linux (x86-64 + AArch64)
##
## Safety note: this module uses POSIX signals and C-level setjmp/longjmp.
## The signal handler must not call async-signal-unsafe functions.  All Nim
## exception machinery is bypassed during the longjmp path; the caller is
## responsible for restoring invariants after a trapped access.

{.used.}

import posix

const
  WasmPageSize* = 65536           ## WASM page size (64 KiB)
  MaxWasmPages* = 65536           ## maximum WASM pages (4 GiB)
  ## Total virtual reservation per memory instance.
  ## 5 GiB covers the full 4 GiB i32 address space plus a guard region.
  GuardReservationBytes* = 5'u64 * 1024'u64 * 1024'u64 * 1024'u64

# ---------------------------------------------------------------------------
# C-level sigsetjmp / siglongjmp helpers
# ---------------------------------------------------------------------------
#
# Nim does not expose sigsetjmp/siglongjmp directly (they are often C macros).
# We use {.emit.} to declare a thin shim that the Nim compiler emits verbatim.
#
{.emit: """
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* Per-thread checkpoint for guard-page fault recovery. */
static __thread sigjmp_buf _wasmGuardJmpBuf;
static __thread int        _wasmGuardActive = 0;
static __thread void*      _wasmFaultAddr   = NULL;

/* Called from the signal handler to jump back to the checkpoint. */
static void _wasmSigJmpRestore(void* faultAddr) {
    _wasmFaultAddr = faultAddr;
    _wasmGuardActive = 0;
    siglongjmp(_wasmGuardJmpBuf, 1);
}

/* Signal handler — must be async-signal-safe. */
static void _wasmGuardSigAction(int sig, siginfo_t* info, void* ctx) {
    (void)ctx;
    if (_wasmGuardActive) {
        _wasmSigJmpRestore(info->si_addr);
    }
    /* Not our fault: re-raise with default disposition. */
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

/* Returns 0 on first entry, 1 after a fault-induced longjmp. */
int _wasmGuardSetCheckpoint(void) {
    _wasmGuardActive = 1;
    return sigsetjmp(_wasmGuardJmpBuf, /*savemask=*/1);
}

void _wasmGuardClear(void) {
    _wasmGuardActive = 0;
}

void* _wasmFaultAddress(void) {
    return _wasmFaultAddr;
}

static int _wasmHandlersInstalled = 0;

void _wasmInstallGuardHandlers(void) {
    if (_wasmHandlersInstalled) return;
    _wasmHandlersInstalled = 1;
    struct sigaction sa;
    sa.sa_sigaction = _wasmGuardSigAction;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
#ifdef SIGBUS
    sigaction(SIGBUS, &sa, NULL);
#endif
}
""".}

# Nim declarations for the C helpers
proc wasmGuardSetCheckpoint(): cint {.importc: "_wasmGuardSetCheckpoint", nodecl.}
proc wasmGuardClear() {.importc: "_wasmGuardClear", nodecl.}
proc wasmFaultAddress(): pointer {.importc: "_wasmFaultAddress", nodecl.}
proc installGuardHandlersC() {.importc: "_wasmInstallGuardHandlers", nodecl.}

# ---------------------------------------------------------------------------
# Guarded memory object
# ---------------------------------------------------------------------------

type
  GuardedMem* = object
    base*: ptr UncheckedArray[byte] ## base of the virtual reservation
    accessibleBytes*: uint64        ## PROT_RW bytes (= currentPages * 64K)
    totalBytes*: uint64             ## total mmap reservation
    maxBytes*: uint64               ## hard cap from module memory type

proc allocGuardedMem*(initialPages, maxPages: int): GuardedMem =
  ## Reserve a large virtual region and make `initialPages` pages accessible.
  ## `maxPages` is the module's declared maximum (0 = uncapped).
  let effective_max = if maxPages > 0: maxPages else: MaxWasmPages
  let accessible = initialPages.uint64 * WasmPageSize.uint64
  let capacity   = GuardReservationBytes

  let base = mmap(nil, capacity.csize_t, PROT_NONE,
                  MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
  if base == MAP_FAILED:
    raise newException(OSError, "WASM guard mmap failed")

  if accessible > 0:
    if mprotect(base, accessible.csize_t, PROT_READ or PROT_WRITE) != 0:
      discard munmap(base, capacity.csize_t)
      raise newException(OSError, "WASM guard mprotect failed")

  result.base            = cast[ptr UncheckedArray[byte]](base)
  result.accessibleBytes = accessible
  result.totalBytes      = capacity
  result.maxBytes        = effective_max.uint64 * WasmPageSize.uint64

proc growGuardedMem*(mem: var GuardedMem, newPages: int): bool =
  ## Expand the accessible region to cover `newPages` pages.
  ## Returns false if this exceeds maxBytes or the reservation.
  let newBytes = newPages.uint64 * WasmPageSize.uint64
  if newBytes > mem.maxBytes or newBytes > mem.totalBytes:
    return false
  if newBytes <= mem.accessibleBytes:
    return true  # no-op: already large enough
  let p = cast[pointer](mem.base)
  if mprotect(p, newBytes.csize_t, PROT_READ or PROT_WRITE) != 0:
    return false
  mem.accessibleBytes = newBytes
  true

proc freeGuardedMem*(mem: var GuardedMem) =
  ## Release the virtual reservation.
  if mem.base != nil:
    discard munmap(cast[pointer](mem.base), mem.totalBytes.csize_t)
    mem.base = nil
    mem.accessibleBytes = 0
    mem.totalBytes      = 0

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc installGuardPageHandlers*() =
  ## Install SIGSEGV / SIGBUS handlers for guard-page fault recovery.
  ## Call once at startup before any JIT invocations.
  installGuardHandlersC()

template wasmGuardedCall*(trapBody: untyped, callExpr: untyped): untyped =
  ## Execute `callExpr` (a JIT function call) inside a guard-page checkpoint.
  ## If a hardware memory fault occurs, `trapBody` is evaluated instead.
  ## `trapBody` should raise a WasmTrap or handle the fault gracefully.
  ##
  ## Usage:
  ##   wasmGuardedCall:
  ##     raise newException(WasmTrap, "out of bounds memory access")
  ##   do:
  ##     funcPtr(vsp, locals, guardedMemBase, high(uint64))
  block guardedBlock:
    if wasmGuardSetCheckpoint() != 0:
      wasmGuardClear()
      trapBody
    else:
      callExpr
      wasmGuardClear()
