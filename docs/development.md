# Runtime developer guide

The runtime is small on purpose. Continuations carry control flow, futures carry
completion, and an event loop decides when suspended work runs again. The
multi-threaded layers build on those pieces instead of introducing a second
async model.

## Source layout

| Path | Responsibility |
| --- | --- |
| `cps/runtime` | Continuations, futures, runtime handles, cancellation, callbacks |
| `cps/transform` | Compile-time CPS transformation and `await` lowering |
| `cps/eventloop` | Ready queue, timers, selector registration, synchronous runner |
| `cps/reactorpool` | Isolated event-loop threads for shard-owned services |
| `cps/mt` | Work-stealing runtime and blocking-task integration |
| `cps/concurrency` | Channels, task groups, synchronization, and signals |
| `cps/io` | TCP, UDP, Unix sockets, files, DNS, buffering, and timeouts |
| `cps/private` | Platform adapters and internal concurrent data structures |

## Execution model

A `{.cps.}` procedure becomes a continuation state machine. Calling it creates
its root continuation and result future. `await` stores the remaining state,
registers a callback on the awaited future, and returns control to the runtime.
Completion schedules the continuation that consumes the result.

The current-thread runtime owns one event loop. The MT runtime owns worker
queues and schedules shared-safe continuations across them. A reactor pool is
different: each reactor thread owns its complete runtime, selector, callbacks,
and application state. The reactor data path stays thread-local.

## Invariants

- A local-fast future stays on its owning reactor thread.
- Promote a future with `ensureShared` before it crosses a thread boundary.
- A selector and its registered descriptors are owned by one event-loop thread.
- Completion is terminal. A future cannot complete, fail, or cancel twice.
- Cancellation is observable through the future and propagated through task
  groups; it does not silently discard owned resources.
- Runtime callbacks must not retain stack addresses or borrowed buffers after
  the call returns.
- Blocking system calls belong in the blocking pool, not on a reactor thread.

## Extending the runtime

Keep the current-thread path allocation-light. Put cross-thread bookkeeping
behind the shared-safe path and measure it separately. When adding an I/O
primitive, define descriptor ownership first, register only the readiness that
can make progress, and unregister before closing the descriptor.

New exported callables need `##` developer documentation. Explain ownership,
thread affinity, terminal behavior, or wake-up semantics where those details
are not obvious from the signature. Do not document an implementation detail
as an API guarantee.

## Validation

```sh
nimble checkDocs
nimble docs
nimble test
```

The generated Nim API reference is committed under `docs/api`; open
`docs/api/theindex.html` to search exported symbols and their `##` docstrings.

Run the MT and socket tests when changing runtime scheduling or I/O. Build ARC,
atomic ARC, and shared-futures-only variants when changing future storage or
thread affinity.
