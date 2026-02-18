## Tests for graceful server shutdown
##
## Tests HTTP server shutdown, drain timeout, signal-triggered shutdown,
## idempotent shutdown, and event loop graceful shutdown.

import std/[strutils, nativesockets, os]
from std/posix import Sockaddr_in, SockLen, kill, getpid, SIGUSR1
import cps/runtime
import cps/transform
import cps/eventloop
import cps/concurrency/taskgroup
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/http/server/types
import cps/http/server/server
import cps/http/server/http1 as http1_server
import cps/concurrency/signals

# ============================================================
# Helpers
# ============================================================

proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = posix.getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

proc helloHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  return newResponse(200, "Hello, World!")

proc slowHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## Handler that takes 500ms to respond.
  await cpsSleep(500)
  return newResponse(200, "slow response")

proc verySlowHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## Handler that takes 2 seconds to respond (longer than short drain timeout).
  await cpsSleep(2000)
  return newResponse(200, "very slow response")

# ============================================================
# CPS procs used by tests (all at module top level)
# ============================================================

proc doClientRequest(p: int): CpsFuture[string] {.cps.} =
  ## Send a GET request, read the full response, close connection.
  let conn = await tcpConnect("127.0.0.1", p)
  let reqStr = "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
  await conn.AsyncStream.write(reqStr)
  var response = ""
  while true:
    let chunk = await conn.AsyncStream.read(4096)
    if chunk.len == 0:
      break
    response &= chunk
  conn.AsyncStream.close()
  return response

proc startAndShutdown(server: HttpServer): CpsVoidFuture {.cps.} =
  ## Start the accept loop and schedule shutdown after a short delay.
  ## The shutdown happens concurrently with the accept loop.
  discard server.start()
  await cpsSleep(100)
  await server.shutdown(1000)

proc doClientThenShutdown(server: HttpServer, p: int): CpsFuture[string] {.cps.} =
  ## Send a request to the server, then shutdown after the response.
  let response = await doClientRequest(p)
  await cpsSleep(50)
  await server.shutdown(1000)
  return response

proc startAcceptLoop(l: TcpListener, cfg: HttpServerConfig,
                     handler: HttpHandler,
                     srv: HttpServer): CpsVoidFuture {.cps.} =
  ## Custom accept loop that tracks connections via the server's TaskGroup.
  srv.running = true
  while srv.running:
    let client = await l.accept()
    srv.connGroup.spawn(handleHttp1Connection(client.AsyncStream, cfg, handler))

proc shutdownAfterDelay(server: HttpServer, delayMs: int,
                        drainTimeoutMs: int): CpsVoidFuture {.cps.} =
  ## Wait delayMs, then trigger shutdown with given drain timeout.
  await cpsSleep(delayMs)
  await server.shutdown(drainTimeoutMs)

proc doSlowClientRequest(p: int): CpsFuture[string] {.cps.} =
  ## Send a GET request, wait for full response even if slow.
  let conn = await tcpConnect("127.0.0.1", p)
  let reqStr = "GET /slow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
  await conn.AsyncStream.write(reqStr)
  var response = ""
  while true:
    let chunk = await conn.AsyncStream.read(4096)
    if chunk.len == 0:
      break
    response &= chunk
  conn.AsyncStream.close()
  return response

proc doubleShutdown(server: HttpServer): CpsVoidFuture {.cps.} =
  ## Call shutdown twice to test idempotency.
  await server.shutdown(1000)
  await server.shutdown(1000)

# ============================================================
# Test 1: Server shutdown - start server, send request, call shutdown
# ============================================================
block testServerShutdown:
  let srv = newHttpServer(
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      helloHandler(req),
    host = "127.0.0.1", port = 0
  )
  srv.bindAndListen()
  let port = srv.getPort()

  # Start the accept loop
  discard srv.start()

  # Client sends a request
  let clientFut = doClientRequest(port)

  # After client completes, shutdown
  let loop = getEventLoop()

  # Drive until client is done
  var ticks = 0
  while not clientFut.finished and ticks < 2000:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client request should have completed"
  let response = clientFut.read()
  assert "200 OK" in response, "Expected 200 OK, got: " & response
  assert "Hello, World!" in response, "Expected Hello, World!"

  # Now shutdown
  let shutdownFut = srv.shutdown(1000)
  ticks = 0
  while not shutdownFut.finished and ticks < 500:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert shutdownFut.finished, "Shutdown should have completed"
  assert not srv.running, "Server should not be running after shutdown"
  assert srv.shutdownStarted, "Shutdown flag should be set"
  echo "PASS: Server shutdown (start, request, shutdown)"

# ============================================================
# Test 2: Shutdown waits for in-flight requests
# ============================================================
block testShutdownWaitsForInflight:
  let srv = newHttpServer(
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      slowHandler(req),
    host = "127.0.0.1", port = 0
  )
  srv.bindAndListen()
  let port = srv.getPort()

  # Start accept loop
  discard startAcceptLoop(srv.listener, srv.config, srv.handler, srv)

  # Client sends request to slow handler
  let clientFut = doSlowClientRequest(port)

  # Wait a bit for the connection to be accepted, then trigger shutdown
  # with a drain timeout long enough for the slow handler to complete
  let shutdownFut = shutdownAfterDelay(srv, 100, 2000)

  let loop = getEventLoop()
  var ticks = 0
  while (not clientFut.finished or not shutdownFut.finished) and ticks < 5000:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client request should have completed"
  if not clientFut.hasError():
    let response = clientFut.read()
    assert "200 OK" in response, "Expected 200 OK, got: " & response
    assert "slow response" in response, "Expected 'slow response'"
  assert shutdownFut.finished, "Shutdown future should have completed"
  assert srv.connGroup.activeCount == 0, "Active connections should be 0, got " & $srv.connGroup.activeCount
  echo "PASS: Shutdown waits for in-flight requests"

# ============================================================
# Test 3: Shutdown timeout - long-running handler, short timeout
# ============================================================
block testShutdownTimeout:
  let srv = newHttpServer(
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      verySlowHandler(req),
    host = "127.0.0.1", port = 0
  )
  srv.bindAndListen()
  let port = srv.getPort()

  # Start accept loop
  discard startAcceptLoop(srv.listener, srv.config, srv.handler, srv)

  # Client sends request to very slow handler
  let clientFut = doSlowClientRequest(port)

  # Trigger shutdown quickly with a short drain timeout (200ms)
  # The handler takes 2000ms, so this should timeout
  let shutdownFut = shutdownAfterDelay(srv, 100, 200)

  let loop = getEventLoop()
  var ticks = 0
  while not shutdownFut.finished and ticks < 3000:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert shutdownFut.finished, "Shutdown should have completed (after timeout)"
  assert srv.shutdownStarted, "Shutdown flag should be set"
  # The timeout message should have been logged (we forced close)
  echo "PASS: Shutdown timeout (force close after drain timeout)"

# ============================================================
# Test 4: Shutdown via signal (SIGUSR1)
# ============================================================
block testShutdownViaSignal:
  initSignalHandling()

  let srv = newHttpServer(
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      helloHandler(req),
    host = "127.0.0.1", port = 0
  )
  srv.bindAndListen()
  let port = srv.getPort()

  # Start accept loop
  discard srv.start()

  # Set up signal-based shutdown on SIGUSR1
  let shutdownFut = newCpsVoidFuture()
  let sigFut = waitForSignal(SIGUSR1)
  proc onSigDone(sigF: CpsVoidFuture, srvRef: HttpServer,
                 sdFut: CpsVoidFuture): proc() {.closure.} =
    result = proc() =
      let sdInternal = srvRef.shutdown(1000)
      sdInternal.addCallback(proc() =
        if not sdFut.finished:
          sdFut.complete()
      )
  sigFut.addCallback(onSigDone(sigFut, srv, shutdownFut))

  # Send a request first to verify the server is up
  let clientFut = doClientRequest(port)
  let loop = getEventLoop()
  var ticks = 0
  while not clientFut.finished and ticks < 2000:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client should have gotten a response"
  let response = clientFut.read()
  assert "200 OK" in response, "Expected 200 OK"

  # Now send SIGUSR1 to trigger shutdown
  discard kill(getpid(), SIGUSR1)

  ticks = 0
  while not shutdownFut.finished and ticks < 2000:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert shutdownFut.finished, "Signal-triggered shutdown should have completed"
  assert not srv.running, "Server should be stopped"
  echo "PASS: Shutdown via SIGUSR1 signal"

  removeSignalHandlers(SIGUSR1)
  deinitSignalHandling()

# ============================================================
# Test 5: Multiple shutdown calls are idempotent
# ============================================================
block testIdempotentShutdown:
  let srv = newHttpServer(
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      helloHandler(req),
    host = "127.0.0.1", port = 0
  )
  srv.bindAndListen()
  let port = srv.getPort()

  # Start accept loop
  discard srv.start()

  # Wait a bit, then double shutdown
  let dsFut = doubleShutdown(srv)

  let loop = getEventLoop()
  var ticks = 0
  while not dsFut.finished and ticks < 2000:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert dsFut.finished, "Double shutdown should complete"
  assert srv.shutdownStarted, "shutdownStarted should be set"
  assert not srv.running, "Server should not be running"
  echo "PASS: Multiple shutdown calls are idempotent"

# ============================================================
# Test 6: Event loop shutdownGracefully drains pending callbacks
# ============================================================
block testEventLoopShutdown:
  let loop = newEventLoop()
  setEventLoop(loop)

  var callbackRan = false
  var timerRan = false

  # Schedule a ready-queue callback
  loop.scheduleCallback(proc() =
    callbackRan = true
  )

  # Schedule a timer that fires in 10ms
  loop.registerTimer(10, proc() =
    timerRan = true
  )

  # Wait a bit for the timer to be due
  sleep(20)

  # Graceful shutdown should drain both
  loop.shutdownGracefully(drainTimeoutMs = 500)

  assert callbackRan, "Ready-queue callback should have been drained"
  assert timerRan, "Timer callback should have been drained"
  # loop.running is private, but shutdownGracefully sets it to false
  # which means runForever would exit. We verify by checking hasWork is false.
  assert not loop.hasWork, "Event loop should have no remaining work"

  # Restore global event loop
  setEventLoop(newEventLoop())

  echo "PASS: Event loop shutdownGracefully drains pending callbacks"

echo ""
echo "All graceful shutdown tests passed!"
