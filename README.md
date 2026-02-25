# CPS - Continuation-Passing Style Async Runtime for Nim

A high-performance async runtime for Nim built on CPS (Continuation-Passing Style) transformation. A macro rewrites `{.cps.}` procedures by splitting them at `await` points into a chain of continuation steps, which a trampoline executes without stack growth.

**Features at a glance:**

- Zero-overhead async/await with lock-free futures
- Selector-based event loop (kqueue/epoll)
- Full I/O library: TCP, UDP, Unix sockets, files, DNS, subprocess, proxy
- HTTP/1.1, HTTP/2, and HTTP/3 client and server with TLS fingerprinting
- Sinatra-style HTTP server DSL with routing, middleware, WebSocket, SSE
- Concurrency primitives: channels, broadcast, semaphore, mutex, task groups
- Multi-threaded work-stealing scheduler with blocking thread pool
- Terminal UI framework with flexbox layout and declarative widgets
- React-like frontend framework compiling to WebAssembly
- IRC client library

## Requirements

- **Nim >= 2.0.0**
- **zippy >= 0.10.0** (HTTP compression)
- macOS or Linux (kqueue/epoll)

## Installation

```bash
nimble install
```

## Quick Start

### Hello Async

```nim
import cps

proc greet(name: string): CpsFuture[string] {.cps.} =
  await cpsSleep(100)
  return "Hello, " & name & "!"

let message = runCps(greet("world"))
echo message  # Hello, world!
```

### Key concepts

- **`{.cps.}` pragma** -- marks a proc for CPS transformation. The macro splits it at every `await` into continuation steps.
- **`CpsFuture[T]`** / **`CpsVoidFuture`** -- lock-free futures. Returned by every `{.cps.}` proc.
- **`await`** -- suspends the current continuation until the awaited future completes. Works inside `if`, `while`, `for`, `try/except`.
- **`runCps()`** -- drives the event loop until a future completes and returns its value.
- **`cpsSleep(ms)`** -- async timer.
- **`Task[T]`** / **`VoidTask`** -- named wrappers around futures, used with `spawn` and `allTasks` for structured concurrency.

## Modules and Imports

| Import | What you get |
|--------|-------------|
| `import cps` | Runtime, transform macro, event loop, concurrency (channels, broadcast, sync, signals, taskgroup, asynciter) |
| `import cps/io` | AsyncStream, TCP, UDP, Unix sockets, buffered I/O, files, DNS, subprocess, proxy, timeouts |
| `import cps/mt` | Multi-threaded scheduler, blocking thread pool, `spawnBlocking` |
| `import cps/httpclient` | HTTPS client with HTTP/1.1, HTTP/2, connection pooling, TLS fingerprinting |
| `import cps/httpserver` | HTTP server, router, SSE, WebSocket, chunked streaming, compression, multipart |
| `import cps/http/server/dsl` | Sinatra-style macro DSL (also re-exports all server types) |
| `import cps/tui` | Terminal UI framework: widgets, layout, rendering, events, reactive state |
| `import cps/ui` | Frontend VDOM framework: hooks, reconciler, router, SSR (compiles to WASM) |
| `import cps/ircclient` | IRC protocol, client, DCC file transfer |

---

## Core Runtime

### Futures and Combinators

```nim
import cps

proc fetchA(): CpsFuture[int] {.cps.} =
  await cpsSleep(50)
  return 1

proc fetchB(): CpsFuture[int] {.cps.} =
  await cpsSleep(50)
  return 2

# Wait for both futures concurrently
proc both(): CpsVoidFuture {.cps.} =
  let a = fetchA()
  let b = fetchB()
  await waitAll(a, b)
  echo "a=", a.read(), " b=", b.read()

runCps(both())
```

**Available combinators:**

| Combinator | Description |
|-----------|-------------|
| `waitAll(f1, f2)` | Wait for two futures to complete |
| `waitAll(futures)` | Wait for all futures in a seq |
| `allTasks(tasks)` | Collect results from `seq[Task[T]]` into `seq[T]` |
| `race(futures)` | Return the first completed value |
| `raceCancel(futures)` | Return the first completed value, cancel the rest |
| `select(futures)` | Return the index of the first completed future |

### Cancellation

```nim
proc longWork(): CpsVoidFuture {.cps.} =
  for i in 0 ..< 100:
    await cpsSleep(100)
    echo "step ", i

proc demo(): CpsVoidFuture {.cps.} =
  let task = spawn longWork()
  await cpsSleep(250)
  task.cancel()  # cancels the running task

runCps(demo())
```

### Error Handling

`await` inside `try/except` works naturally:

```nim
proc riskyFetch(): CpsFuture[string] {.cps.} =
  try:
    let data = await fetchFromNetwork()
    return data
  except CatchableError as e:
    return "fallback: " & e.msg
```

---

## I/O

### TCP

```nim
import cps
import cps/io

# Client
proc tcpClient(): CpsVoidFuture {.cps.} =
  let conn = await tcpConnect("127.0.0.1", 9000)
  await conn.AsyncStream.write("hello")
  let reply = await conn.AsyncStream.read(1024)
  echo "got: ", reply
  conn.AsyncStream.close()

# Server
proc tcpServer(): CpsVoidFuture {.cps.} =
  let listener = tcpListen("127.0.0.1", 9000)
  while true:
    let client = await listener.accept()
    let data = await client.AsyncStream.read(1024)
    await client.AsyncStream.write("echo: " & data)
    client.AsyncStream.close()
```

### UDP

```nim
import cps
import cps/io

proc udpDemo(): CpsVoidFuture {.cps.} =
  let sock = newUdpSocket("127.0.0.1", 5000)
  await sock.sendTo("hello", "127.0.0.1", 5001)
  let (data, addr, port) = await sock.recvFrom(1024)
  echo "from ", addr, ":", port, " -> ", data
  sock.close()
```

### Files

```nim
import cps
import cps/io

proc fileDemo(): CpsVoidFuture {.cps.} =
  await asyncWriteFile("/tmp/test.txt", "hello from CPS")
  let content = await asyncReadFile("/tmp/test.txt")
  echo content
```

### DNS

```nim
import cps
import cps/io

proc dnsDemo(): CpsVoidFuture {.cps.} =
  let ip = await dnsResolve("example.com")
  echo "resolved: ", ip
  let allIps = await dnsResolveAll("example.com")
  echo "all: ", allIps
```

### Buffered I/O

```nim
import cps
import cps/io

proc bufferedDemo(): CpsVoidFuture {.cps.} =
  let conn = await tcpConnect("127.0.0.1", 9000)
  let reader = newBufferedReader(conn.AsyncStream)
  let line = await reader.readLine()
  echo "line: ", line
```

### Timeouts

```nim
import cps
import cps/io

proc timeoutDemo(): CpsFuture[string] {.cps.} =
  try:
    let data = await withTimeout(fetchData(), 5000)
    return data
  except CancellationError:
    return "timed out"
```

### Proxy Tunneling

```nim
import cps
import cps/io

proc proxyDemo(): CpsVoidFuture {.cps.} =
  let proxies = @[
    ProxyConfig(kind: pkSocks5, host: "proxy1.example.com", port: 1080),
    ProxyConfig(kind: pkHttpConnect, host: "proxy2.example.com", port: 8080),
  ]
  let conn = await proxyChainConnect("target.com", 443, proxies)
  # conn is a normal AsyncStream -- use it for TLS, HTTP, etc.
```

---

## Concurrency

### Channels

```nim
import cps

proc producer(ch: AsyncChannel[int]): CpsVoidFuture {.cps.} =
  for i in 0 ..< 10:
    await ch.send(i)
  ch.close()

proc consumer(ch: AsyncChannel[int]): CpsVoidFuture {.cps.} =
  while not ch.isClosed:
    try:
      let val = await ch.recv()
      echo "got: ", val
    except CatchableError:
      break

proc channelDemo(): CpsVoidFuture {.cps.} =
  let ch = newAsyncChannel[int](capacity = 4)  # bounded
  let p = producer(ch)
  let c = consumer(ch)
  await waitAll(p, c)

runCps(channelDemo())
```

### Broadcast and Watch Channels

```nim
import cps

proc broadcastDemo(): CpsVoidFuture {.cps.} =
  let bc = newBroadcastChannel[string](16)
  let sub1 = await bc.subscribe()
  let sub2 = await bc.subscribe()
  await bc.publish("hello everyone")
```

### Synchronization Primitives

```nim
import cps

# Semaphore -- limit concurrency
proc semDemo(): CpsVoidFuture {.cps.} =
  let sem = newAsyncSemaphore(3)  # max 3 concurrent
  await sem.acquire()
  # ... do work ...
  sem.release()

# Mutex -- exclusive access
proc mutexDemo(): CpsVoidFuture {.cps.} =
  let mtx = newAsyncMutex()
  await mtx.lock()
  # ... critical section ...
  mtx.unlock()

# Event -- signal waiters
proc eventDemo(): CpsVoidFuture {.cps.} =
  let evt = newAsyncEvent()
  # In another task: evt.set()
  await evt.wait()
```

### Task Groups (Structured Concurrency)

```nim
import cps

proc compute(n: int): CpsFuture[int] {.cps.} =
  await cpsSleep(10)
  return n * n

proc taskGroupDemo(): CpsVoidFuture {.cps.} =
  var tg = newTaskGroup[int]()
  for i in 1 .. 5:
    tg.spawn(spawn compute(i))
  let results = await tg.wait()
  echo results  # @[1, 4, 9, 16, 25]

runCps(taskGroupDemo())
```

### Async Iterators

```nim
import cps

proc iterDemo(): CpsVoidFuture {.cps.} =
  let iter = asyncRange(0, 10)
    .filter(proc(x: int): bool = x mod 2 == 0)
    .map(proc(x: int): int = x * x)
    .take(3)

  while true:
    let val = await iter.next()
    if val.isNone: break
    echo val.get()  # 0, 4, 16
```

---

## HTTP Client

```nim
import cps
import cps/httpclient

proc httpDemo(): CpsVoidFuture {.cps.} =
  let client = newHttpsClient()

  # GET
  let resp = await client.get("https://httpbin.org/get")
  echo resp.statusCode   # 200
  echo resp.httpVersion   # h2 or HTTP/1.1 (auto-negotiated via ALPN)

  # POST with body
  let post = await client.post("https://httpbin.org/post", "hello")
  echo post.body

runCps(httpDemo())
```

### TLS Fingerprinting

Impersonate real browser TLS/HTTP/2 fingerprints:

```nim
import cps
import cps/httpclient
import cps/tls/fingerprint

proc fingerprintDemo(): CpsVoidFuture {.cps.} =
  let client = newHttpsClient()
  client.fingerprint = chromeProfile()  # or firefoxProfile()
  let resp = await client.get("https://tls.browserleaks.com/json")
  echo resp.body

runCps(fingerprintDemo())
```

### WebSocket Client

```nim
import cps
import cps/httpclient
import cps/http/client/ws

proc wsDemo(): CpsVoidFuture {.cps.} =
  let ws = await wssConnect("wss://echo.websocket.org")
  await ws.sendText("hello")
  let msg = await ws.recvMessage()
  echo msg.data  # "hello"
  await ws.close()

runCps(wsDemo())
```

### SSE Client

```nim
import cps
import cps/httpclient
import cps/http/client/sse

proc sseDemo(): CpsVoidFuture {.cps.} =
  let stream = await sseConnect("https://example.com/events")
  while true:
    let event = await stream.nextEvent()
    echo event.event, ": ", event.data

runCps(sseDemo())
```

---

## HTTP Server

### Server DSL

The Sinatra-style DSL is the easiest way to build HTTP servers:

```nim
import cps/http/server/dsl

let handler = router:
  get "/":
    respond 200, "Hello, World!"

  get "/users/{id}":
    let userId = pathParams["id"]
    json %*{"id": userId, "name": "Alice"}

  post "/upload":
    let file = await upload("file")
    respond 201, "Uploaded: " & file.filename

  get "/search":
    let q = queryParams.getOrDefault("q", "")
    text "Results for: " & q

  ws "/chat":
    while true:
      let msg = await recvMessage()
      await sendText("echo: " & msg.data)

  sse "/events":
    for i in 0 ..< 10:
      await sendEvent($i, event = "tick")
      await cpsSleep(1000)

  serveStatic "/static", "./public"

serve(handler, port = 8080)
```

### Router Features

- **Path parameters**: `"/users/{id}"`, `"/posts/{id:int}"`, `"/items/{id:uuid}"`
- **Optional params**: `"/files/{name?}"`
- **Wildcards**: `"/assets/*"`
- **Sub-routers**: mount routers at prefixes
- **Named routes**: `urlFor("user", {"id": "42"})`
- **Middleware**: `before`/`after` hooks, error recovery
- **Static files**: `serveStatic` with ETag caching

### Request Helpers

| Helper | Description |
|--------|-------------|
| `body()` | Await and return request body |
| `pathParams` | Path parameter table |
| `queryParams` | Query string parameter table |
| `headers()` | Request headers |
| `jsonBody()` | Parse body as JSON |
| `formParams()` | Parse URL-encoded form body |
| `upload(field)` | Get multipart upload |
| `bearerToken()` | Extract Bearer token |
| `basicAuth()` | Extract Basic auth credentials |
| `clientIp()` | Client IP address |

### Response Helpers

| Helper | Description |
|--------|-------------|
| `respond(code, body)` | Send response |
| `json(node)` | Send JSON |
| `html(content)` | Send HTML |
| `text(content)` | Send plain text |
| `redirect(url)` | HTTP redirect |
| `sendFile(path)` | Send file with Content-Type |
| `download(path, name)` | Send file as download |

### Built-in Middleware

```nim
let handler = router:
  cors:
    allowOrigins @["*"]

  compress  # gzip/deflate

  rateLimit 100, 60  # 100 requests per 60 seconds

  bodyLimit 1_048_576  # 1MB max body

  timeout 30_000  # 30s request timeout

  get "/":
    respond 200, "ok"
```

### Chunked Streaming

```nim
let handler = router:
  get "/stream":
    let writer = await initChunked()
    for i in 0 ..< 10:
      await writer.sendChunk("chunk " & $i & "\n")
      await cpsSleep(500)
    await writer.endChunked()
```

### Session Middleware

```nim
import cps/http/middleware/session

let handler = router:
  use sessionMiddleware("secret-key")

  get "/":
    let name = ctx("username", "guest")
    respond 200, "Hello " & name

  post "/login":
    setCookie("username", "alice")
    redirect "/"
```

### TLS / HTTPS Server

```nim
serve(handler, port = 443, useTls = true,
      certFile = "cert.pem", keyFile = "key.pem")
```

---

## Multi-Threading

Compile with `--mm:atomicArc` (required for thread safety):

```nim
# nim c --mm:atomicArc myapp.nim

import cps/mt

# Initialize: 4 async workers + 4 blocking threads
let loop = initMtRuntime(numWorkers = 4, numBlockingThreads = 4)
```

### Offload CPU Work

```nim
import cps/mt

proc fibonacci(n: int): int =
  if n <= 1: return n
  fibonacci(n - 1) + fibonacci(n - 2)

proc computeFib(n: int): CpsFuture[int] {.cps.} =
  # Runs on the blocking thread pool, doesn't stall the event loop
  let val = await spawnBlocking(proc(): int {.gcsafe.} =
    fibonacci(n)
  )
  return val

let loop = initMtRuntime(numWorkers = 4, numBlockingThreads = 4)
echo runCps(computeFib(35))
loop.shutdownMtRuntime()
```

### Fan-Out / Fan-In

```nim
import cps/mt

proc fanOutFanIn(): CpsFuture[seq[int]] {.cps.} =
  var tasks: seq[Task[int]]
  tasks.add spawn computeFib(30)
  tasks.add spawn computeFib(25)
  tasks.add spawn computeFib(20)
  let results = await allTasks(tasks)
  return results

let loop = initMtRuntime(numWorkers = 4, numBlockingThreads = 4)
let results = runCps(fanOutFanIn())
echo results  # @[832040, 75025, 6765]
loop.shutdownMtRuntime()
```

### Async Pipeline

```nim
proc pipeline(input: string): CpsFuture[string] {.cps.} =
  # Stage 1: async fetch
  await cpsSleep(20)
  let fetched = input & " -> fetched"

  # Stage 2: CPU-heavy transform on blocking pool
  let transformed = await spawnBlocking(proc(): string {.gcsafe.} =
    fetched.toUpperAscii()
  )

  # Stage 3: async store
  await cpsSleep(10)
  return transformed & " -> stored"
```

---

## Terminal UI

The TUI framework provides declarative widget trees with flexbox layout, rebuilt each frame and diffed for minimal terminal output.

```nim
import cps/tui

proc main(): CpsVoidFuture {.cps.} =
  var counter = 0
  let app = newTuiApp()
  app.altScreen = true
  app.mouseMode = true

  app.onRender = proc(w, h: int): Widget =
    container(dkVertical,
      text("Counter: " & $counter).withStyle(bold = true),
      container(dkHorizontal,
        text("[+] Increment").withOnClick(proc() = counter += 1),
        text("[-] Decrement").withOnClick(proc() = counter -= 1),
      ),
      text("Press 'q' to quit"),
    )

  app.onInput = proc(evt: InputEvent): bool =
    if evt.kind == ikKey and evt.key == kkChar and evt.ch == 'q':
      return true  # quit
    return false

  await app.run()

runCps(main())
```

### Widget Types

| Widget | Description |
|--------|-------------|
| `text(content)` | Static text with styling |
| `container(direction, children...)` | Flexbox container (vertical or horizontal) |
| `border(child, style)` | Border around a widget |
| `inputField(...)` | Text input with cursor, history, clipboard |
| `list(items)` | Selectable list |
| `table(...)` | Data table |
| `scrollView(child)` | Scrollable viewport |
| `tabs(labels, activeIdx)` | Tab bar |
| `progressBar(value, max)` | Progress indicator |
| `spacer()` | Flexible space |

### Components

Higher-level components with built-in event handling:

| Component | Description |
|-----------|-------------|
| `SplitView` | Draggable divider between two panes |
| `ScrollableTextView` | Chat log / scrollable text |
| `Dialog` | Modal dialog with focus trapping |
| `TreeView` | Expandable tree structure |
| `NotificationArea` | Toast notifications |
| `CommandPalette` | Fuzzy-search command palette |
| `StatusBar` | Bottom status bar |

### Layout

Flexbox-inspired layout with:
- **Direction**: vertical or horizontal
- **Sizing**: fixed, flex (weight), percent, auto
- **Padding and gap**
- **Alignment**: start, center, end, stretch
- **Min/max constraints**

### Reactive State

```nim
import cps/tui

let count = newSignal(0)
let doubled = newComputed(proc(): int = count.get() * 2)

count.set(5)
echo doubled.get()  # 10
```

---

## Frontend UI (WebAssembly)

A React-like frontend framework that compiles to standalone WebAssembly (via clang + wasm-ld, no emscripten).

### Counter App

```nim
import cps/ui

proc app(): VNode =
  let (count, setCount) = useState(0)

  ui:
    `div`(className="counter"):
      h1: text("Count: " & $count)
      button(onClick=proc(ev: UiEvent) = setCount(count + 1)):
        text("Increment")

setRootComponent(app)
```

Build:
```bash
bash scripts/build_ui_wasm.sh examples/ui/counter_app.nim examples/ui/counter_app.wasm
```

### Available Hooks

| Hook | Description |
|------|-------------|
| `useState[T](initial)` | Local component state |
| `useEffect(fn, deps)` | Side effects with cleanup |
| `useMemo[T](fn, deps)` | Memoized computation |
| `useCallback(fn, deps)` | Stable callback reference |
| `useContext[T](ctx)` | Read from context provider |
| `useReducer(reducer, init)` | Redux-style state |
| `useRef[T](initial)` | Mutable ref that persists across renders |
| `useTransition()` | Mark updates as non-urgent |
| `useDeferredValue[T](val)` | Deferred rendering for heavy updates |
| `useId()` | Stable unique ID |

### Client-Side Routing

```nim
import cps/ui

proc app(): VNode =
  ui:
    Router:
      Route(path="/"):
        text("Home")
      Route(path="/about"):
        text("About")
      Route(path="/users/{id}"):
        text("User " & useParams()["id"])
```

### Server-Side Rendering

```nim
import cps/ui

let html = renderToString(app)
# Returns full HTML string for hydration
```

---

## IRC Client

```nim
import cps
import cps/ircclient

proc ircDemo(): CpsVoidFuture {.cps.} =
  let client = newIrcClient("irc.libera.chat", 6667)
  await client.connect()
  await client.login("mynick", "myuser", "My Real Name")
  await client.join("#nim")

  while true:
    let event = await client.recv()
    case event.kind
    of iekPrivMsg:
      echo event.nick, ": ", event.message
    of iekJoin:
      echo event.nick, " joined ", event.channel
    else:
      discard

runCps(ircDemo())
```

The IRC client supports auto-reconnect, IRCv3 CAP negotiation, SASL PLAIN authentication, lag tracking, and DCC/XDCC file transfers.

A full-featured IRC TUI client is included at `examples/tui/irc_tui.nim`.

---

## Compiler Configuration

### nim.cfg defaults

```
--path:"src"
--threads:on
--mm:atomicArc
--deepcopy:on
```

### Optional defines

| Define | Effect |
|--------|--------|
| `-d:useBoringSSL` | Link against BoringSSL instead of OpenSSL (GREASE, extension permutation) |
| `-d:useZstd` | Enable zstd compression via C FFI |
| `-d:useBrotli` | Enable brotli compression via C FFI |
| `-d:cpsTrace` | Enable event loop metrics and task tracing |

### TLS Setup

Default: links Homebrew OpenSSL 3.x at compile-time (macOS). For BoringSSL:

```bash
bash scripts/build_boringssl.sh   # first time
nim c -r -d:useBoringSSL myapp.nim
```

---

## Important Notes

- **CPS procs must be at module top level.** Don't define `{.cps.}` procs inside `block` or other procs.
- **Don't use `result` in CPS procs.** Use explicit `return` instead.
- **`--mm:atomicArc` is required for multi-threaded code.** The MT runtime enforces this at compile time.
- **CPS procs capture block-local variables by value.** Assignments inside CPS procs write to the env copy, not the original. Pass mutable state via `ptr` or use channels/futures.
- **Generic CPS procs**: await target variables must have explicit type annotations (e.g., `let val: T = await someFunc[T](x)`).

## Project Structure

```
src/cps/           # Source code
tests/             # Test suites
  core/            #   CPS runtime and macro
  concurrency/     #   Channels, sync, taskgroup
  io/              #   TCP, UDP, files, proxy
  mt/              #   Multi-threaded runtime
  http/            #   HTTP client/server, TLS, WebSocket, SSE
  tui/             #   TUI widgets, events, components
  ui/              #   Frontend VDOM, WASM integration
  quic/            #   QUIC protocol
examples/          # Example applications
  tui/irc_tui.nim  #   Full IRC client
  ui/              #   WASM frontend apps
scripts/           # Build scripts
```

## License

MIT
