# Lock-Free Migration TODO

## Goal
- Make CPS runtime hot paths lock-free while preserving correctness and multi-runtime behavior.

## Current State
- [x] Runtime ownership/lifetime safety fixes landed (`RootRef` runtime-owned objects).
- [x] Core/MT regression tests passing after safety fixes.
- [x] Callback path is lock-free (Treiber stack + closed sentinel).
- [x] `runCps` wait path is lock-free (eventcount + spin/yield wait).
- [x] MT scheduler inject queue is lock-free (bounded MPMC ring + atomic capacity).

## Phase 1: Lock-Free Future Callbacks (Highest Priority)
- [x] Replace `callbackLock + seq[CallbackEntry]` with atomic callback stack head.
- [x] Add lock-free callback node type and allocation strategy.
- [x] Implement CAS push in `addCallbackOn` with terminal-state fast path.
- [x] Implement `exchange(closedSentinel)` drain in `complete/fail/cancel`.
- [x] Add closure lifetime ownership policy (`GC_ref/GC_unref` or equivalent) for node safety.
- [x] Add stress tests: add-callback vs complete/fail/cancel races.
- [x] Benchmark callback registration/completion throughput vs current branch.

## Phase 2: Lock-Free `runCps` Wait/Wake Path
- [x] Replace per-runtime condvar waiting with eventcount/sequence-based wake path.
- [x] Ensure no lost wakeups under race (waiter snapshots sequence before park/yield).
- [x] Keep spin-then-park fallback for low latency.
- [x] Add tests for wait/wake race correctness (single and multi-threaded).
- [x] Add benchmark: runCps idle wait overhead before/after.

## Phase 3: Lock-Free MT Scheduler Inject Queue
- [x] Replace scheduler global `Deque + Lock + Cond` with lock-free bounded MPMC ring inject queue.
- [x] Drain inject queue in worker loop before steal/park.
- [x] Keep bounded-backpressure policy (CAS reserve + adaptive yield); document behavior.
- [x] Add fairness test: no starvation under heavy external submissions.
- [x] Benchmark: external submit throughput and tail latency.

## Phase 4: Production Hardening
- [ ] Add TSAN/helgrind race checks for callback + scheduler changes.
- [ ] Add soak test (long-running mixed ST/MT + timer + IO + migration).
- [x] Verify no allocator leaks in callback node lifecycle.
- [x] Document lock-free guarantees and non-guarantees in `CLAUDE.md`.

## Exit Criteria
- [x] No locks in callback hot path.
- [x] No condvar wait in normal `runCps` completion wake path.
- [x] No scheduler global lock on external submission hot path.
- [ ] All core/mt/http tests pass in CI modes.
- [ ] Criterion benchmarks show non-regression and improved CPS runtime throughput.
