## MT Runtime Sample Program
##
## Demonstrates the multithreaded CPS runtime with:
## - Concurrent async tasks with spawn/allTasks
## - Blocking work offloaded to thread pool (spawnBlocking)
## - TCP I/O mixed with background computation
## - Timer interleaving proving non-blocking behavior
## - Error propagation from worker threads
##
## Compile: nim c --mm:atomicArc --run examples/mt_sample.nim

import cps/mt
import cps/transform
import cps/io/streams
import cps/io/tcp
import std/[os, monotimes, times, strutils, nativesockets]
from std/posix import Sockaddr_in, getsockname, SockLen

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

proc getPort(fd: SocketHandle): int =
  var addr4: Sockaddr_in
  var len: SockLen = sizeof(addr4).SockLen
  assert getsockname(fd, cast[ptr SockAddr](addr addr4), addr len) == 0
  ntohs(addr4.sin_port).int

proc elapsed(start: MonoTime): int64 =
  (getMonoTime() - start).inMilliseconds

# ------------------------------------------------------------------
# 1. Fan-out / fan-in: spawn N tasks, collect results
# ------------------------------------------------------------------

proc fibonacci(n: int): int =
  ## Deliberately slow recursive fib for CPU work.
  if n <= 1: return n
  fibonacci(n - 1) + fibonacci(n - 2)

proc computeFib(n: int): CpsFuture[int] {.cps.} =
  let val = await spawnBlocking(proc(): int {.gcsafe.} =
    fibonacci(n)
  )
  return val

proc fanOutFanIn(): CpsFuture[seq[int]] {.cps.} =
  var tasks: seq[Task[int]]
  tasks.add spawn computeFib(30)
  tasks.add spawn computeFib(25)
  tasks.add spawn computeFib(20)
  tasks.add spawn computeFib(15)
  let results = await allTasks(tasks)
  return results

# ------------------------------------------------------------------
# 2. Pipeline: async stages connected by futures
# ------------------------------------------------------------------

proc stage1(input: string): CpsFuture[string] {.cps.} =
  ## Simulate fetch: async delay then return data.
  await cpsSleep(20)
  return input & " -> fetched"

proc stage2(input: string): CpsFuture[string] {.cps.} =
  ## Offload CPU-heavy transform to blocking pool.
  let data = input
  let transformed = await spawnBlocking(proc(): string {.gcsafe.} =
    sleep(10)  # simulate CPU work
    var out_s = ""
    for c in data:
      out_s.add c.toUpperAscii()
    out_s
  )
  return transformed

proc stage3(input: string): CpsFuture[string] {.cps.} =
  ## Simulate store: async delay then confirm.
  await cpsSleep(10)
  return input & " -> stored"

proc pipeline(input: string): CpsFuture[string] {.cps.} =
  let a = await stage1(input)
  let b = await stage2(a)
  let c = await stage3(b)
  return c

# ------------------------------------------------------------------
# 3. TCP echo server with blocking-pool processing
# ------------------------------------------------------------------

proc uppercaseBlocking(s: string): CpsFuture[string] =
  let copy = s
  spawnBlocking(proc(): string {.gcsafe.} =
    var out_s = ""
    for c in copy:
      out_s.add c.toUpperAscii()
    out_s
  )

proc echoServer(listener: TcpListener, nClients: int): CpsVoidFuture {.cps.} =
  for i in 0 ..< nClients:
    let client = await listener.accept()
    let data = await client.AsyncStream.read(1024)
    let processed = await uppercaseBlocking(data)
    await client.AsyncStream.write(processed)
    client.AsyncStream.close()

proc echoClient(port: int, msg: string): CpsFuture[string] {.cps.} =
  let conn = await tcpConnect("127.0.0.1", port)
  await conn.AsyncStream.write(msg)
  let reply = await conn.AsyncStream.read(1024)
  conn.AsyncStream.close()
  return reply

# ------------------------------------------------------------------
# 4. Error propagation from spawnBlocking
# ------------------------------------------------------------------

proc failingWork(): CpsFuture[int] {.cps.} =
  let val = await spawnBlocking(proc(): int {.gcsafe.} =
    raise newException(ValueError, "simulated worker failure")
  )
  return val

# ------------------------------------------------------------------
# 5. Error handling: return inside except + try/except catching
# ------------------------------------------------------------------

proc errorHandler(shouldFail: bool): CpsFuture[string] {.cps.} =
  ## Demonstrates return inside except handler.
  ## Note: spawnBlocking recreates errors as CatchableError with the original
  ## type name embedded in the message (e.g., "ValueError: worker error").
  try:
    let val = await spawnBlocking(proc(): int {.gcsafe.} =
      if shouldFail:
        raise newException(ValueError, "worker error")
      42
    )
    return "ok: " & $val
  except CatchableError as e:
    return "caught: " & e.msg

proc tryCatchDemo(): CpsFuture[string] {.cps.} =
  ## Demonstrates that except handler value is preserved (not overwritten).
  var msg = "not set"
  try:
    let val = await spawnBlocking(proc(): int {.gcsafe.} =
      raise newException(ValueError, "boom")
    )
    msg = "unexpected: got " & $val
  except CatchableError as e:
    msg = "caught: " & e.msg
  return msg

# ------------------------------------------------------------------
# 6. Timer interleaving: prove blocking doesn't stall the reactor
# ------------------------------------------------------------------

proc timerProbe(tag: string, log: ptr seq[string]): CpsVoidFuture {.cps.} =
  log[].add tag & ":start"
  await cpsSleep(15)
  log[].add tag & ":done"

proc heavyBlocking(tag: string, log: ptr seq[string]): CpsVoidFuture {.cps.} =
  log[].add tag & ":start"
  await spawnBlocking(proc() {.gcsafe.} =
    sleep(80)
  )
  log[].add tag & ":done"

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

let loop = initMtRuntime(numWorkers = 4, numBlockingThreads = 4)
echo "MT runtime started (4 workers, 4 blocking threads)"
echo "---------------------------------------------------"

# --- Demo 1: Fan-out / fan-in ---
block:
  let start = getMonoTime()
  let results = runCps(fanOutFanIn())
  let ms = elapsed(start)
  echo "1. Fan-out/fan-in (fib 30,25,20,15 on blocking pool):"
  echo "   results = ", results
  echo "   fib(30)=", results[0], " fib(25)=", results[1],
       " fib(20)=", results[2], " fib(15)=", results[3]
  assert results[0] == 832040
  assert results[1] == 75025
  assert results[2] == 6765
  assert results[3] == 610
  echo "   completed in ", ms, "ms (parallel on 4 threads)"
  echo ""

# --- Demo 2: Pipeline ---
block:
  let start = getMonoTime()
  let output = runCps(pipeline("hello world"))
  let ms = elapsed(start)
  echo "2. Async pipeline (fetch -> blocking transform -> store):"
  echo "   output = \"", output, "\""
  assert "HELLO WORLD" in output
  assert "stored" in output
  echo "   completed in ", ms, "ms"
  echo ""

# --- Demo 3: TCP echo with blocking processing ---
block:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getPort(listener.fd)

  let messages = @["hello mt", "async is fun", "cps rocks"]
  let sf = echoServer(listener, messages.len)

  # Spawn 3 clients concurrently
  proc allClients(port: int, msgs: seq[string]): CpsFuture[seq[string]] {.cps.} =
    var tasks: seq[Task[string]]
    for msg in msgs:
      tasks.add spawn echoClient(port, msg)
    let results = await allTasks(tasks)
    return results

  let cf = allClients(port, messages)
  while not sf.finished or not cf.finished:
    loop.tick()
  let replies = cf.read()

  echo "3. TCP echo (3 concurrent clients, server does blocking uppercase):"
  for i, reply in replies:
    echo "   \"", messages[i], "\" -> \"", reply, "\""
    assert reply == messages[i].toUpperAscii()
  listener.close()
  echo ""

# --- Demo 4: Error propagation ---
block:
  let fut = failingWork()
  while not fut.finished:
    loop.tick()
  assert fut.hasError(), "Future should have error"
  let errMsg = fut.getError().msg
  echo "4. Error propagation from blocking pool:"
  echo "   error captured: ", errMsg
  assert "simulated worker failure" in errMsg
  echo ""

# --- Demo 5: Error handling (return inside except + try/except catching) ---
block:
  # Return inside except handler (was: compile error "no return type declared")
  let errResult = runCps(errorHandler(true))
  assert "caught: " in errResult and "worker error" in errResult,
    "Expected error to be caught, got: " & errResult
  let okResult = runCps(errorHandler(false))
  assert okResult == "ok: 42", "Expected 'ok: 42', got: " & okResult
  echo "5. Error handling (return inside except):"
  echo "   errorHandler(fail)  = \"", errResult, "\""
  echo "   errorHandler(ok)    = \"", okResult, "\""

  # Try/except preserves handler value (was: silent default value)
  let catchResult = runCps(tryCatchDemo())
  assert "caught: " in catchResult and "boom" in catchResult,
    "Expected error to be caught, got: " & catchResult
  echo "   tryCatchDemo()      = \"", catchResult, "\""
  echo ""

# --- Demo 6: Timer interleaving ---
block:
  var log: seq[string] = @[]
  let start = getMonoTime()

  let t1 = timerProbe("timer", addr log)
  let t2 = heavyBlocking("block", addr log)
  let combined = waitAll(t1, t2)
  runCps(combined)
  let ms = elapsed(start)

  echo "6. Timer interleaving (15ms timer vs 80ms blocking):"
  echo "   event order: ", log
  let timerDone = log.find("timer:done")
  let blockDone = log.find("block:done")
  assert timerDone < blockDone, "timer should complete before blocking"
  echo "   timer finished before blocking (non-blocking confirmed)"
  echo "   total: ", ms, "ms"
  echo ""

# --- Shutdown ---
loop.shutdownMtRuntime()
echo "---------------------------------------------------"
echo "All demos completed successfully!"
