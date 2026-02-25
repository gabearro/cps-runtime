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

**Build UI wasm example (standalone wasm32):**
```bash
bash scripts/check_wasm_toolchain.sh
bash scripts/build_ui_wasm.sh examples/ui/counter_app.nim examples/ui/counter_app.wasm
bash scripts/build_ui_wasm.sh examples/ui/todo_keyed_app.nim examples/ui/todo_keyed_app.wasm
bash scripts/build_ui_wasm.sh examples/ui/router_app.nim examples/ui/router_app.wasm
bash scripts/build_ui_wasm.sh examples/ui/controlled_input_app.nim examples/ui/controlled_input_app.wasm
bash scripts/build_ui_wasm.sh examples/ui/fail_soft_app.nim examples/ui/fail_soft_app.wasm
```
UI wasm builds now use pure `clang` + `wasm-ld`; set `WASI_SYSROOT` if auto-detection does not find your `wasi-libc` sysroot.

**Run UI tests:**
```bash
bash scripts/check_ui_schema_generated.sh
for f in tests/ui/test_*.nim; do nim c -r "$f"; done
bash tests/ui/test_wasm_integration.sh
bash tests/ui/test_wasm_fail_soft.sh
```

**Regenerate UI schema-derived sources:**
```bash
python3 scripts/generate_ui_schema.py
bash scripts/check_ui_schema_generated.sh
```

**Run UI browser matrix locally (Playwright):**
```bash
bash tests/ui/test_wasm_integration.sh
bash tests/ui/test_wasm_fail_soft.sh
cd tests/ui/browser
npm install
npx playwright install --with-deps chromium firefox webkit
npm test
```

There is no linter or formatter configured. Tests use `assert` + `echo "PASS: ..."` (no test framework). Each test file is self-contained and runs as a standalone binary.

**Note:** `nimble test` runs the primary core/hardening suites plus HTTP smoke tests. MT tests (`tests/mt/test_mt_*.nim`) should still be run explicitly for full validation. Python interop tests (`tests/http/test_python_*.nim`, `tests/http/test_tls_interop.nim`) require Python 3 with `h2`/`hpack` packages. Network tests (`tests/http/test_fingerprint_cloudflare.nim`) require internet access.

**Run TUI tests:**
```bash
nim c -r tests/tui/test_tui_core.nim         # Style, cell, layout, widgets, rendering, DSL
nim c -r tests/tui/test_tui_components.nim   # SplitView, scrollable text, dialog, tree view
nim c -r tests/tui/test_tui_events.nim       # Hit map, event routing, focus management
```

**Run the IRC TUI example:**
```bash
nim c -r examples/tui/irc_tui.nim
nim c -r examples/tui/irc_tui.nim irc.libera.chat 6667 mynick "#nim"
nim c -r examples/tui/irc_tui.nim --reset    # Reset config
```

**Test directory layout:** `tests/core/` (CPS runtime/macro), `tests/concurrency/` (channels, sync, taskgroup), `tests/io/` (tcp, udp, files, buffered, proxy), `tests/mt/` (multi-threaded), `tests/http/` (HTTP client/server, TLS, WebSocket, SSE, compression), `tests/tui/` (TUI widget/event/component tests), `tests/ui/` (frontend DSL/runtime + wasm integration).

## Compiler Configuration

Requires **Nim >= 2.0.0**. Dependencies: `zippy >= 0.10.0` (HTTP compression).

**`nim.cfg`** sets: `--path:"src"`, `--threads:on`, `--mm:atomicArc`, `--deepcopy:on`. Atomic ARC is the production default for all runtime paths.

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

4. **`io/`** — Async I/O built on the event loop. `streams.nim` defines `AsyncStream` (proc-field vtable). Implementations: `tcp.nim`, `udp.nim`, `unix.nim` (Unix domain sockets), `files.nim`, `process.nim` (async subprocess with piped I/O), `dns.nim` (thread-pooled async DNS with TTL cache). `buffered.nim` wraps any stream with buffered reads/writes. `timeouts.nim` provides `withTimeout`. `proxy.nim` provides SOCKS4/4a, SOCKS5, and HTTP CONNECT proxy tunneling as `ProxyStream` (AsyncStream subtype), with unbounded proxy chaining via `proxyChainConnect`. Barrel: `io.nim`.

5. **`http/`** — Full HTTP stack (see detailed section below).

6. **`concurrency/`** — Async concurrency primitives. `channels.nim` (bounded ring buffer + unbounded), `broadcast.nim` (`BroadcastChannel[T]`, `WatchChannel[T]`), `sync.nim` (`AsyncSemaphore`, `AsyncMutex`, `AsyncEvent`), `signals.nim` (async signal handling via self-pipe), `taskgroup.nim` (structured concurrency), `asynciter.nim` (`AsyncIterator[T]` with combinators). Barrel: `concurrency.nim`.

7. **`mt/`** — Multi-threaded runtime. `scheduler.nim` (work-stealing: per-worker Chase-Lev deques + global inject queue + peer stealing), `threadpool.nim` (blocking pool for `spawnBlocking`), `mtruntime.nim` (init/shutdown, reactor/worker coordination). Barrel: `mt.nim`.

### TUI Framework (`src/cps/tui/`)

Terminal UI framework built on the CPS event loop. Declarative widget trees rebuilt each frame, diffed via CellBuffer for minimal ANSI output.

**Render pipeline:** Widget tree → flexbox layout computation → CellBuffer drawing → diff against previous frame → ANSI output (wrapped in synchronized update for tear-free rendering).

**Core modules:**
- `style.nim` — Colors (4-bit, 8-bit, 24-bit), text attributes, ANSI escape sequences, border styles
- `cell.nim` — CellBuffer (2D grid of styled cells), double buffering, diff rendering
- `input.nim` — Terminal input parsing (keys, mouse, resize, paste), async reader via event loop
- `layout.nim` — Flexbox-inspired layout engine (direction, flex/fixed/percent/auto sizing, padding, gap, alignment, min/max constraints)
- `widget.nim` — Widget tree nodes (Container, Text, Border, Input, List, Table, Spacer, ScrollView, ProgressBar, Tabs, Custom). Event handler fields (onClick, onKey, onScroll, onMouse, onFocus, onBlur). Builder pattern (`.withWidth()`, `.withOnClick()`, etc.)
- `renderer.nim` — Tree traversal → layout → draw. `renderWidget` (draw only) and `renderWidgetWithEvents` (draw + build HitMap + focus order). `collectWidgetEvents` (event-only traversal for custom widget children, no drawing)
- `events.nim` — HitMap (widget rects collected during render), FocusManager (focus order, focus trap), event routing (deepest-first for mouse, focused-widget-first for keys with bubble-up)
- `components.nim` — SplitView (draggable divider), ScrollableTextView (chat log), StatusBar, Dialog, NotificationArea, TreeView, CommandPalette. Each has `.toWidgetWithEvents()` for declarative event handling
- `textinput.nim` — Text editing state (cursor, selection, kill ring, history, clipboard, masking)
- `reactive.nim` — Signal[T] (mutable state + dirty tracking), Computed[T] (lazy cached), ReactiveContext
- `component.nim` — ComponentState (persistent across frames), useSignal/useEffect hooks, ComponentRegistry
- `dsl.nim` — Macro DSL for declarative widget construction
- `app.nim` — TuiApp: main loop integrating widgets with CPS event loop (raw mode, alt screen, mouse, rendering, input routing, FPS limiting)

**Key design:** Widgets are declarative descriptions (like VDOM nodes), not stateful objects. State lives in the application layer and flows down. Custom widgets (`wkCustom`) use `customChildren`/`customChildRects` to expose internal children for event routing without re-drawing them. Focus trapping (`withFocusTrap`) confines Tab cycling and key events to a widget subtree (used for modals/dialogs).

### IRC Client (`src/cps/irc/`)

- `protocol.nim` — RFC 2812 message parsing/formatting, IrcEvent enum (26 event types), DccInfo struct
- `client.nim` — Event-driven IRC client with auto-reconnect, IRCv3 CAP negotiation, SASL PLAIN auth, lag tracking. State machine: Disconnected → Connecting → Registering → Connected. Events delivered via `AsyncChannel[IrcEvent]`
- `dcc.nim` — DCC file transfer (SEND, CHAT, ACCEPT, RESUME)
- `xdcc.nim` — XDCC pack-based file server protocol
- `ebook_indexer.nim` — Ebook listing parser for IRC book channels

### UI/WASM Frontend (`src/cps/ui/`)

React-like frontend framework compiling to WebAssembly (standalone wasm32 via clang + wasm-ld, no emscripten).

- `vdom.nim` / `types.nim` — VDOM node types, attribute/event binding
- `dsl.nim` — Karax-style block macro DSL for declarative VDOM
- `hooks.nim` — React-compatible hooks: useState, useEffect, useMemo, useCallback, useContext, useReducer, useRef, useTransition, useDeferredValue, useId
- `runtime.nim` — Component mount/update lifecycle, effect scheduling, error boundaries, suspense, hydration
- `reconciler.nim` — VDOM diffing with keyed list support, produces DOM patches
- `dombridge.nim` — Browser DOM FFI (JS interop)
- `scheduler.nim` — Update lane system (Sync, Default, Transition) for batched prioritization
- `router.nim` — Client-side URL routing with loaders/actions, history API
- `ssr.nim` — Server-side rendering to HTML string

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
- `client.nim` — High-level API: ALPN version negotiation, connection pooling, redirect following, proxy support (SOCKS4/4a/5, HTTP CONNECT, chaining)
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
| `import cps/io` | streams, tcp, udp, unix, buffered, files, timeouts, dns, process, proxy |
| `import cps/mt` | threadpool, scheduler, mtruntime |
| `import cps/httpclient` | streams, tcp, buffered, tls/client, shared/hpack, shared/http2, client/http1, client/client, tls/fingerprint |
| `import cps/httpserver` | server/types, server/server, server/http1, server/http2, server/router, server/sse, server/ws, server/chunked, shared/compression, shared/multipart |
| `import cps/http/server/dsl` | Also exports: types, router, runtime, transform, eventloop, tables, sse, ws, compression, multipart, chunked |
| `import cps/tui` | style, cell, input, layout, widget, renderer, textinput, reactive, dsl, components, events, component, app |
| `import cps/ircclient` | irc/protocol, irc/client, irc/dcc, irc/xdcc, irc/ebook_indexer |
| `import cps/ui` | types, vdom, dombridge, scheduler, reconciler, hooks, runtime, dsl, errors, router, net, ssr |

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
- **MT requires `--mm:atomicArc`**: Enforced at compile time — `mtruntime.nim` emits a `{.error.}` if neither `gcAtomicArc` nor `useMalloc` is defined.
- **ORC is unsupported for production/release gating**: ORC has produced runtime instability in this project. Use Atomic ARC for validation and CI.

### TUI Framework
- **Custom widget event routing**: Custom widgets (`wkCustom`) render children via `customRender` proc which calls `renderWidget` (not event-aware). To route events to children, set `customChildren` and `customChildRects` — the renderer calls `collectWidgetEvents` on them after `customRender` finishes.
- **Focus trap for modals**: Set `withFocusTrap(true)` on modal/dialog widgets. Tab/Shift+Tab only cycles within the subtree, and key events route to focused widget first (before framework Tab handling).
- **POSIX only**: TUI uses `termios`, `SIGWINCH`, raw mode. Not available on Windows.
- **STDOUT non-blocking on macOS**: STDIN is set non-blocking for async input; on Unix terminals STDIN/STDOUT share the same file description, making STDOUT non-blocking too. `writeOutput` handles `EAGAIN` with `poll()` retry to prevent truncated frames.

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
