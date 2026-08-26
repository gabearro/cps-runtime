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

The current-thread runtime owns one event loop. The MT runtime gives every
worker its own selector and keeps resumed CPS, futures, and I/O callbacks on
that owner worker. Its CPU deque can still steal scheduled closure work; a
thief invokes the raw two-word closure and sends destruction back to the source
worker. Reactor pools remain fully isolated runtimes. Both designs support
regular ARC and ORC, with AtomicARC available for application-managed sharing.

## Invariants

- A local-fast future stays on its owning reactor thread.
- GC-managed reactor-pool state never crosses a reactor thread boundary.
- Promote a future with `ensureShared` before it crosses a thread boundary.
- A selector and its registered descriptors are owned by one event-loop thread.
- Completion is terminal. A future cannot complete, fail, or cancel twice.
- Cancellation is observable through the future and propagated through task
  groups; it does not silently discard owned resources.
- Runtime callbacks must not retain stack addresses or borrowed buffers after
  the call returns.
- Blocking system calls belong in the blocking pool, not on a reactor thread.

## Cross-thread message ownership

Scheduler messages are exactly two pointers and move-only. Resumed
continuations enter the bounded injection ring of their owner worker because an
awaited future can still alias that continuation. Worker-created closure tasks
may enter the Chase-Lev stealing deque, but the thief does not own the closure
environment: it invokes the raw pair and returns a release marker to the source
worker. Pinned callbacks use the same rule when they cross workers.

Runtime references inside continuations, futures, event loops, and dispatch
closures are non-owning back-pointers. The active runtime is retained by its
owner; hot CPS wrappers read its thread-local pointer directly, avoiding a
shared non-atomic refcount operation on every invocation. ORC closure types
crossing a queue are marked acyclic before transfer so their object headers do
not enter a producer thread's cycle-root list.

Blocking-pool workers bind a per-worker closure return route. A scheduler may
invoke a completion callback on its target reactor, but it returns the raw
two-word closure to the blocking worker for destruction. The return queues are
allocated only when the blocking pool is created; HTTP-only runtimes do not pay
their memory or dispatch cost.

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
nimble testReactorMms
nimble testMtMms
```

The generated Nim API reference is committed under `docs/api`; open
`docs/api/theindex.html` to search exported symbols and their `##` docstrings.

Run the MT and socket tests when changing runtime scheduling or I/O. Run
`testReactorMms` when changing reactor ownership or event-loop storage. Build
AtomicARC variants separately when changing shared future storage or thread
affinity.
