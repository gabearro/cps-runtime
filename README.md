# CPS Runtime

A high-performance async runtime for Nim built around continuation-passing style
(CPS) transformation. The `{.cps.}` macro splits procedures at `await`
points into explicit continuation steps, then runs those steps through a
trampoline without growing the native stack.

This repository is the foundation of the CPS ecosystem. It contains the
transform, futures, event loop, async I/O, concurrency primitives, and the
multi-threaded work-stealing runtime. Protocols such as TLS, HTTP, IRC, and
BitTorrent live in their own packages.

## Features

- Lock-free `CpsFuture[T]` and `CpsVoidFuture`
- Selector-based event loop using kqueue or epoll
- Async TCP, UDP, Unix sockets, files, DNS, subprocesses, and proxy tunnels
- Cancellation, races, timeouts, and future combinators
- Channels, broadcast/watch channels, task groups, signals, and async iterators
- Multi-threaded work-stealing scheduler and blocking thread pool
- Graceful shutdown and optional runtime tracing

## Requirements

- Nim 2.0 or newer
- macOS or Linux

## Install

```sh
nimble install https://github.com/gabearro/cps-runtime@#v1.1.0
```

## Hello async

```nim
import cps

proc greet(name: string): CpsFuture[string] {.cps.} =
  await cpsSleep(100)
  return "Hello, " & name & "!"

echo runCps(greet("world"))
```

The important pieces are:

- `{.cps.}` marks a procedure for CPS transformation.
- `await` suspends the current continuation until its future finishes.
- `runCps` drives the event loop and returns the future's value.
- CPS procedures return `CpsFuture[T]` or `CpsVoidFuture`.

## Run work concurrently

```nim
import cps

proc fetch(id: int): CpsFuture[string] {.cps.} =
  await cpsSleep(50)
  return "result-" & $id

proc main(): CpsVoidFuture {.cps.} =
  let first = fetch(1)
  let second = fetch(2)
  await waitAll(first, second)
  echo first.read()
  echo second.read()

runCps(main())
```

Available combinators include `waitAll`, `allTasks`, `race`, `raceCancel`,
and `select`. Cancellation is propagated through futures and structured task
groups.

## Async I/O

```nim
import cps
import cps/io

proc echoOnce(): CpsVoidFuture {.cps.} =
  let listener = tcpListen("127.0.0.1", 9000)
  let client = await listener.accept()
  let data = await client.AsyncStream.read(4096)
  await client.AsyncStream.write("echo: " & data)
  client.AsyncStream.close()
  listener.close()

runCps(echoOnce())
```

The `AsyncStream` interface is shared by TCP, Unix sockets, proxy tunnels,
TLS, and the higher-level protocol packages. Buffered readers and writers can
wrap any stream implementation.

## Module map

| Import | Functionality |
| --- | --- |
| `cps` | Futures, CPS transform, event loop, and concurrency |
| `cps/io` | TCP, UDP, Unix sockets, files, DNS, subprocesses, proxying |
| `cps/concurrency` | Channels, task groups, synchronization, signals, iterators |
| `cps/mt` | Work-stealing scheduler and blocking thread pool |
| `cps/trace` | Runtime metrics and tracing hooks |

## Multi-threaded runtime

`cps/mt` moves continuations between threads, so the consuming project must
use thread-safe reference counting. Put this in the project's `nim.cfg`:

```cfg
--threads:on
--mm:atomicArc
--deepcopy:on
```

Core single-threaded programs do not need to import `cps/mt`.

## Compiler switches

| Define | Effect |
| --- | --- |
| `-d:cpsTrace` | Enable event-loop metrics and task tracing |
| `-d:useMalloc` | Use malloc-backed allocation for MT integration |

## Current constraints

- CPS procedures must be declared at module scope.
- Use explicit `return` values instead of assigning to `result`.
- Await targets in generic CPS procedures should have explicit type annotations.
- Mutable state crossing task boundaries should use channels, references, or
  another explicit shared-state primitive.

## Related packages

| Package | What it adds |
| --- | --- |
| [cps-tls](https://github.com/gabearro/cps-tls) | TLS client/server streams and fingerprints |
| [cps-quic](https://github.com/gabearro/cps-quic) | QUIC transport |
| [cps-http](https://github.com/gabearro/cps-http) | HTTP clients and servers |
| [cps-irc](https://github.com/gabearro/cps-irc) | IRC, SASL, DCC, and XDCC |
| [cps-irc-bouncer](https://github.com/gabearro/cps-irc-bouncer) | Persistent IRC sessions |
| [cps-bittorrent](https://github.com/gabearro/cps-bittorrent) | BitTorrent client |
| [cps-tui](https://github.com/gabearro/cps-tui) | Declarative terminal UI |
| [cps-web-ui](https://github.com/gabearro/cps-web-ui) | WebAssembly frontend framework |
| [cps-native-gui](https://github.com/gabearro/cps-native-gui) | Native SwiftUI generator |
| [cps-wasm](https://github.com/gabearro/cps-wasm) | WebAssembly VM and WASI |

The complete pre-split tree is preserved on the
[`monorepo-archive`](https://github.com/gabearro/cps-runtime/tree/monorepo-archive)
branch.

## Development

Read the [runtime developer guide](docs/development.md) before changing public
APIs, ownership, protocol state, or execution behavior.

```sh
nimble install -d -y
nimble checkDocs
nimble docs
nimble test
```

`nimble docs` writes the generated API reference to
[`docs/api/theindex.html`](docs/api/theindex.html).

Tests are standalone Nim programs and use `assert` plus explicit
`PASS: ...` output. There is no external test framework.

## License

MIT
