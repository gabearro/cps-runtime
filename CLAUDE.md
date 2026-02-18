# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

**Compile and run a single test:**
```bash
nim c -r tests/core/test_cps_core.nim
```

**Run the nimble test suite** (core, macro, event loop, HTTPS, compression — including HTTP, WebSocket, and SSE compression):
```bash
nimble test
```

**Compile and run MT (multi-threaded) tests** — must use `--mm:atomicArc`:
```bash
nim c -r --mm:atomicArc tests/mt/test_mt_basic.nim
```

**Compile with BoringSSL** (for full TLS fingerprinting):
```bash
bash scripts/build_boringssl.sh   # first time only — installs to deps/boringssl/
nim c -r -d:useBoringSSL tests/http/test_fingerprint.nim
```

**Compile with tracing enabled:**
```bash
nim c -r -d:cpsTrace tests/core/test_trace.nim
```

There is no linter or formatter configured. Tests use `assert` + `echo "PASS: ..."` (no test framework). Each test file is self-contained and runs as a standalone binary.

**Note:** `nimble test` only runs 8 core tests (core/macro/eventloop/https/4 compression). MT tests (`tests/mt/test_mt_*.nim`) must be run individually with `--mm:atomicArc`. Python interop tests (`tests/http/test_python_*.nim`, `tests/http/test_tls_interop.nim`) require Python 3 with `h2`/`hpack` packages. Network tests (`tests/http/test_fingerprint_cloudflare.nim`) require internet access.

**Test directory layout:** `tests/core/` (CPS runtime/macro), `tests/concurrency/` (channels, sync, taskgroup), `tests/io/` (tcp, udp, files, buffered), `tests/mt/` (multi-threaded), `tests/http/` (HTTP client/server, TLS, WebSocket, SSE, compression).

## Compiler Configuration

Requires **Nim >= 2.0.0**. Dependencies: `zippy >= 0.10.0` (HTTP compression).

**`nim.cfg`** sets: `--path:"src"`, `--threads:on`, `--mm:orc`, `--deepcopy:on`. These apply to all compilations. MT code must override with `--mm:atomicArc` because ORC's cycle collector is not thread-safe.

**`config.nims`** handles SSL/TLS linking:
- Default: Homebrew OpenSSL 3.x (`/opt/homebrew/opt/openssl@3/`) linked at compile-time via `--dynlibOverride` (not runtime `dlopen`)
- `-d:useBoringSSL`: links against `deps/boringssl/` instead (requires C++ stdlib: `-lc++`)

Optional defines: `-d:useZstd` and `-d:useBrotli` enable zstd/brotli compression via C FFI. `-d:cpsTrace` enables event loop metrics and task tracing.

## Architecture

This is a CPS (Continuation-Passing Style) async runtime for Nim. A macro transforms `{.cps.}` procs by splitting them at `await` points into a chain of continuation steps, which a trampoline executes without stack growth.

### Core layers (bottom-up):

1. **`runtime.nim`** — `Continuation`, `CpsFuture[T]`, `CpsVoidFuture`, trampoline (`run`), `complete`/`fail`/`addCallback`/`cancel`/`isCancelled`. Combinators: `waitAll`, `allTasks`, `race`, `select`, `raceCancel`. Task types: `Task[T]`, `VoidTask` (with optional `name` field). Lock-free futures use atomic state + lock-free callback LIFO stack. Also holds MT global hooks (`mtCallbackDispatcher`, `mtWakeReactor`, `isSchedulerWorker`).

2. **`transform.nim`** (~2k lines, the largest module) — The `{.cps.}` untyped macro. Generates an env type per proc, splits the body at awaits into step functions, rewrites variables to `env.varName`. Handles: control flow with await (if/while/for), try/except with await (including await inside except handler bodies), lambda lifting, `return await`, recursive CPS calls, generic procs, type aliases for typeof chains.

3. **`eventloop.nim`** — Selector-based I/O (kqueue/epoll), timer heap, ready-callback deque. Drives the single-threaded event loop via `tick()` and `runCps()`. Extended with a wake pipe and cross-thread callback queue for MT mode. Supports `shutdownGracefully()`.

4. **`io/`** — Async I/O built on the event loop. `streams.nim` defines `AsyncStream` (proc-field vtable). Implementations: `tcp.nim`, `udp.nim`, `unix.nim` (Unix domain sockets), `files.nim`, `process.nim` (async subprocess with piped I/O), `dns.nim` (thread-pooled async DNS with TTL cache). `buffered.nim` wraps any stream with buffered reads/writes. `timeouts.nim` provides `withTimeout`. Barrel: `io.nim`.

5. **`http/`** — Full HTTP stack (see detailed section below).

6. **`concurrency/`** — Async concurrency primitives. `channels.nim` (bounded ring buffer + unbounded), `broadcast.nim` (`BroadcastChannel[T]`, `WatchChannel[T]`), `sync.nim` (`AsyncSemaphore`, `AsyncMutex`, `AsyncEvent`), `signals.nim` (async signal handling via self-pipe), `taskgroup.nim` (structured concurrency), `asynciter.nim` (`AsyncIterator[T]` with combinators). Barrel: `concurrency.nim`.

7. **`mt/`** — Multi-threaded runtime. `scheduler.nim` (work-stealing: per-worker Chase-Lev deques + global inject queue + peer stealing), `threadpool.nim` (blocking pool for `spawnBlocking`), `mtruntime.nim` (init/shutdown, reactor/worker coordination). Barrel: `mt.nim`.

### TLS (`src/cps/tls/`)

- `client.nim` — OpenSSL 3.x client TLS with ALPN, TLS fingerprint application
- `server.nim` — Cert loading, ALPN callback, async SSL_accept
- `fingerprint.nim` — Browser TLS/HTTP/2 fingerprint profiles (`chromeProfile()`, `firefoxProfile()`)
- `boringssl.nim` — BoringSSL FFI for GREASE, extension permutation, cert compression, ALPS (requires `-d:useBoringSSL`)

### HTTP Stack (`src/cps/http/`)

**Shared** (`http/shared/`):
- `hpack.nim` — HPACK encoder/decoder with Huffman coding
- `http2.nim` — HTTP/2 frame types, client session
- `compression.nim` — gzip/deflate via zippy, streaming via zlib C FFI, optional zstd/brotli
- `multipart.nim` — Multipart/form-data parsing (`UploadedFile`, `MultipartData`)
- `http2_stream_adapter.nim` — Maps reads/writes to HTTP/2 DATA frames (protocol-agnostic handlers)
- `ws.nim` — WebSocket types, frame codec, message API (shared between client and server)

**Client** (`http/client/`):
- `http1.nim` — HTTP/1.1 protocol implementation
- `client.nim` — High-level API: ALPN version negotiation, connection pooling, redirect following
- `sse.nim` — SSE consumer
- `ws.nim` — WebSocket client (`wsConnect`/`wssConnect`, plain and TLS with fingerprint support)

**Server** (`http/server/`):
- `types.nim` — Core types: `HttpRequest`, `HttpResponseBuilder`, `HttpHandler`, `HttpServerConfig`. Request `context` table for middleware data passing.
- `server.nim` — Accept loop, `startServer`, `shutdownGracefully`, lifecycle callbacks
- `http1.nim`, `http2.nim` — Protocol-specific request parsing and response writing
- `sse.nim` — SSE writer (auto-detects HTTP/2 adapter)
- `ws.nim` — WebSocket server via `acceptWebSocket` (works for both HTTP/1.1 and HTTP/2)
- `chunked.nim` — `ChunkedWriter` for streaming responses (auto-detects HTTP/2 → DATA frames, HTTP/1.1 → chunked encoding)
- `router.nim` — Route matching (literal, `{param}`, `{param:int}`, `{param:uuid}`, `{param?}`, wildcard `*`), middleware chaining, before/after hooks, error recovery, HEAD/OPTIONS auto-generation, trailing slash normalization, sub-router mounting, named routes with `urlFor`, static file serving with ETag/caching, content negotiation, cookie helpers, security headers
- `dsl.nim` — Sinatra-style macro DSL. Route methods: `get`/`post`/`put`/`delete`/`patch`/`any`. Request helpers: `body()`, `headers()`, `pathParams`, `queryParams`, `jsonBody`, `formParam`, `upload`, `bearerToken`, `basicAuth`, `clientIp`. Response helpers: `respond`, `json`, `html`, `text`, `redirect`, `sendFile`, `download`, status shortcuts. Streaming: `initChunked`/`sendChunk`/`endChunked`, `initSse`/`sendEvent`. WebSocket: `acceptWs`/`recvMessage`/`sendText`/`sendBinary`. Middleware blocks: `cors`, `secure`, `requestId`, `rateLimit`, `methodOverride`, `compress`, `bodyLimit`, `timeout`. Context: `ctx`/`setCtx`/`setCookie`. Content negotiation: `accept { ... }` block.
- `testclient.nim` — In-process test client (constructs `HttpRequest` directly, no TCP/HTTP parsing)

**Middleware** (`http/middleware/`):
- `session.nim` — Cookie-based sessions with HMAC-SHA1 signing
- `metrics.nim` — Prometheus-compatible metrics middleware (histogram buckets)
- `ratelimit.nim` — Token bucket rate limiting

### Key design decisions:

- The transform macro uses `ident` (not `bindSym`) for future-interface procs (`read`, `hasError`, `getError`, `addCallback`) so that `Task[T]` overloads resolve at the call site.
- I/O streams use proc-field vtable dispatch (not Nim method dispatch).
- Protocol-agnostic handlers: SSE, WebSocket, and chunked streaming all detect `Http2StreamAdapter` via `stream of Http2StreamAdapter` and branch. A `statusCode=0` sentinel tells both HTTP/1.1 and HTTP/2 servers the handler already wrote to the stream.
- MT mode: reactor thread owns the selector; workers proxy I/O registration through `postToEventLoop`. SSL objects are not thread-safe — TLS code uses `ensureOnReactor(cb)` to proxy to the reactor thread.
- Middleware are NOT CPS procs — they are callback-based closures: `proc(req, next): CpsFuture[HttpResponseBuilder]`. Route handlers ARE CPS procs (allow `await`). `HttpRequest` is a value object (not ref); middleware passes modified copies to `next`.

### Barrel modules:

| Import | Provides |
|--------|----------|
| `import cps` | runtime, transform, eventloop, concurrency (channels, broadcast, signals, sync, asynciter, taskgroup) |
| `import cps/io` | streams, tcp, udp, unix, buffered, files, timeouts, dns, process |
| `import cps/mt` | threadpool, scheduler, mtruntime |
| `import cps/httpclient` | streams, tcp, buffered, tls/client, shared/hpack, shared/http2, client/http1, client/client, tls/fingerprint |
| `import cps/httpserver` | server/types, server/server, server/http1, server/http2, server/router, server/sse, server/ws, server/chunked, shared/compression, shared/multipart |
| `import cps/http/server/dsl` | Also exports: types, router, runtime, transform, eventloop, tables, sse, ws, compression, multipart, chunked |

## Critical Gotchas

### CPS Macro Constraints
- **No-await fast path**: CPS procs with no `await` calls are automatically optimized — no env allocation, no step functions, no trampoline. The body executes inline and returns a pre-completed future (~19ns, same as raw future alloc). This also speeds up await chains when inner calls use the fast path.
- **CPS procs must be at module top level**: `{.cps.}` procs defined inside `block` statements or other procs will fail with "undeclared identifier: 'await'". Define all CPS procs at the module scope; use blocks only for `runCps()` calls and assertions.
- **Don't use `result` in CPS procs**: The macro emits a compile-time error. It conflicts with the step function's return value.
- **CPS procs capture block-local vars by value**: Assignments inside CPS procs write to the env copy, not the original. Pass mutable state via `ptr` or use channels/futures.
- **`await` as call arguments**: Auto-extracted to temp variables by the macro. `results.add(await ch.recv())` works directly.
- **`await` inside except handler bodies**: Supported. The macro creates handler continuation segments.
- **Generic CPS procs**: Supported via monomorphization. **Limitation**: await target variables must have explicit type annotations (e.g., `let val: T = await someFunc[T](x)` not `let val = await someFunc[T](x)`).
- **`typeof()` resolves iterators over procs**: Handled automatically by the macro — `getOrCreateAlias()` wraps typeof expressions in block statements to force proc resolution. No user action needed.

### Nim Language
- **Closures in for loops**: Nim captures loop variables by reference. All closures see the last value. Use a closure factory proc to force per-iteration capture.
- **`AsyncIoError` vs `IOError`**: Our stream error type is `AsyncIoError` (in `io/streams.nim`). Use `streams.AsyncIoError` in modules that also import `std/os` or `std/nativesockets`.
- **kqueue `AssertionDefect`**: Use `except Exception:` (not bare `except:`) to catch Defects when unregistering fds on macOS.

### OpenSSL / TLS
- **OpenSSL 3.x on macOS**: `SSL_CTX_set_min_proto_version` is a C macro, not a function. Use `SSL_CTX_ctrl(ctx, 123, version, nil)`. Use `TLS_method()` (not `TLS_client_method()`) — the latter is missing under `--dynlibOverride:ssl`.
- **`std/random` clobbers OpenSSL on macOS**: Importing `std/random` loads macOS Security framework → system LibreSSL, overriding Homebrew OpenSSL symbols. Use a custom PRNG instead.
- **ALPN precedence in `tls.nim`**: Explicit `alpnProtocols` parameter takes precedence over fingerprint's list. WebSocket connections must pass `@["http/1.1"]` explicitly to prevent h2 negotiation.

### Multi-Threading
- **MT requires `--mm:atomicArc`**: Enforced at compile time — `mtruntime.nim` emits a `{.error.}` if neither `gcAtomicArc` nor `useMalloc` is defined. ORC's non-atomic refcounting causes double-free when continuations/futures cross thread boundaries.
- **ORC is not thread-safe**: ORC's cycle collector crashes (`SIGSEGV` in `rememberCycle`) when ref objects cross threads. MT code must use `--mm:atomicArc`, not ORC.

## Lock-Free Guarantees

### Guaranteed lock-free hot paths
- Future callback registration/completion in `runtime.nim` is lock-free (atomic state + Treiber callback stack).
- `runCps` wait/wake path is lock-free for normal completion wakeups (eventcount-style wake sequence + spin/yield wait).
- MT scheduler external submit path is lock-free and bounded (MPMC ring inject queue + atomic occupancy accounting).

### Non-guarantees / caveats
- Worker parking still uses a condition variable for idle sleep. This is off hot-path and only used when no work is found.
- Memory allocation is not lock-free (`allocShared0` / runtime allocator may use internal locks).
- Backpressure under saturation is lock-free but not wait-free: submitters may spin/yield until capacity is available.
- No hard fairness or real-time latency guarantees; fairness is best-effort and validated via stress tests.
