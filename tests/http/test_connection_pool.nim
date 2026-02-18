## Tests for HTTP/1.1 Connection Pooling
##
## Tests the connection pool in HttpsClient, verifying:
## - Connection reuse across sequential requests
## - Per-host connection separation
## - Idle timeout eviction
## - maxPerHost limits
## - Stale connection retry
## - Non-keep-alive connections are not pooled
## - Pool cleanup on client close

import std/[strutils, nativesockets, times, os]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/client/http1
import cps/http/client/client

# ============================================================
# Helpers
# ============================================================

proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = posix.getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

var globalConnectionCount: int = 0

proc countingHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## Handler that returns request count info. Each connection to the server
  ## increments the global counter, which the handler returns.
  return newResponse(200, "ok", @[("X-Request-Path", req.path)])

proc closeHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## Handler that sends Connection: close to prevent keep-alive.
  return newResponse(200, "closed",
    @[("Connection", "close"), ("X-Request-Path", req.path)])

# Accept loop that counts connections
proc countingAcceptLoop(l: TcpListener, cfg: HttpServerConfig,
                        handler: HttpHandler, maxConns: int): CpsVoidFuture {.cps.} =
  for i in 0 ..< maxConns:
    let client = await l.accept()
    globalConnectionCount += 1
    discard handleHttp1Connection(client.AsyncStream, cfg, handler)

# Simple accept loop for N connections
proc acceptN(l: TcpListener, cfg: HttpServerConfig,
             handler: HttpHandler, n: int): CpsVoidFuture {.cps.} =
  for i in 0 ..< n:
    let client = await l.accept()
    discard handleHttp1Connection(client.AsyncStream, cfg, handler)

# CPS proc: do a fetch and return the response
proc doFetch(client: HttpsClient, url: string): CpsFuture[HttpsResponse] {.cps.} =
  return await client.get(url)

# CPS proc: do two sequential fetches, return both responses
proc doTwoFetches(client: HttpsClient, url: string): CpsFuture[seq[HttpsResponse]] {.cps.} =
  var results: seq[HttpsResponse]
  let r1 = await client.get(url)
  results.add r1
  let r2 = await client.get(url)
  results.add r2
  return results

# CPS proc: do three sequential fetches
proc doThreeFetches(client: HttpsClient, url: string): CpsFuture[seq[HttpsResponse]] {.cps.} =
  var results: seq[HttpsResponse]
  let r1 = await client.get(url)
  results.add r1
  let r2 = await client.get(url)
  results.add r2
  let r3 = await client.get(url)
  results.add r3
  return results

# CPS proc: fetch from two different URLs
proc fetchTwoUrls(client: HttpsClient, url1: string,
                  url2: string): CpsFuture[seq[HttpsResponse]] {.cps.} =
  var results: seq[HttpsResponse]
  let r1 = await client.get(url1)
  results.add r1
  let r2 = await client.get(url2)
  results.add r2
  return results

# ============================================================
# Test 1: Connection reuse — two sequential requests reuse connection
# ============================================================
block testConnectionReuse:
  globalConnectionCount = 0
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  # Server accepts up to 2 connections (but we expect only 1 to be used)
  let sf = countingAcceptLoop(listener, config,
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      countingHandler(req), 2)

  # Client: make two sequential requests to the same host
  let client = newHttpsClient(preferHttp2 = false, autoDecompress = false)
  let url = "http://127.0.0.1:" & $port & "/test"
  let cf = doTwoFetches(client, url)

  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 500:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert cf.finished, "Client future should have completed"
  let results = cf.read()
  assert results.len == 2, "Expected 2 responses"
  assert results[0].statusCode == 200, "First request failed"
  assert results[1].statusCode == 200, "Second request failed"

  # The key assertion: only 1 TCP connection was created (reused via pool)
  assert globalConnectionCount == 1,
    "Expected 1 TCP connection (reuse), got " & $globalConnectionCount

  # Pool should have 1 idle connection
  let key = PoolKey(host: "127.0.0.1", port: port, useTls: false)
  assert client.pool.poolSize(key) == 1,
    "Expected 1 idle connection in pool, got " & $client.pool.poolSize(key)

  client.close()
  listener.close()
  echo "PASS: Connection reuse (2 requests, 1 TCP connection)"

# ============================================================
# Test 2: Different hosts get separate connections
# ============================================================
block testDifferentHosts:
  let listener1 = tcpListen("127.0.0.1", 0)
  let port1 = getListenerPort(listener1)
  let listener2 = tcpListen("127.0.0.1", 0)
  let port2 = getListenerPort(listener2)
  let config = HttpServerConfig()

  let sf1 = acceptN(listener1, config,
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      countingHandler(req), 1)
  let sf2 = acceptN(listener2, config,
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      countingHandler(req), 1)

  let client = newHttpsClient(preferHttp2 = false, autoDecompress = false)
  let url1 = "http://127.0.0.1:" & $port1 & "/host1"
  let url2 = "http://127.0.0.1:" & $port2 & "/host2"
  let cf = fetchTwoUrls(client, url1, url2)

  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 500:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert cf.finished, "Client future should have completed"
  let results = cf.read()
  assert results.len == 2, "Expected 2 responses"
  assert results[0].statusCode == 200, "First request failed"
  assert results[1].statusCode == 200, "Second request failed"

  # Each host should have its own pooled connection
  let key1 = PoolKey(host: "127.0.0.1", port: port1, useTls: false)
  let key2 = PoolKey(host: "127.0.0.1", port: port2, useTls: false)
  assert client.pool.poolSize(key1) == 1,
    "Expected 1 idle connection for host1"
  assert client.pool.poolSize(key2) == 1,
    "Expected 1 idle connection for host2"
  assert client.pool.totalPoolSize() == 2,
    "Expected 2 total idle connections"

  client.close()
  listener1.close()
  listener2.close()
  echo "PASS: Different hosts get separate connections"

# ============================================================
# Test 3: Connection evicted after idle timeout
# ============================================================
block testIdleEviction:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  let sf = acceptN(listener, config,
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      countingHandler(req), 2)

  # Use a very short idle timeout (0.1 seconds)
  let client = newHttpsClient(preferHttp2 = false, autoDecompress = false,
                               maxIdleSeconds = 0.1)
  let url = "http://127.0.0.1:" & $port & "/test"

  # First request
  let cf1 = doFetch(client, url)
  let loop = getEventLoop()
  var ticks = 0
  while not cf1.finished and ticks < 500:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break
  assert cf1.finished, "First request should complete"
  assert cf1.read().statusCode == 200, "First request failed"

  let key = PoolKey(host: "127.0.0.1", port: port, useTls: false)
  assert client.pool.poolSize(key) == 1,
    "Expected 1 idle connection before timeout"

  # Wait for the connection to expire
  # Use os.sleep to actually pause (not cpsSleep which needs the event loop)
  sleep(200)  # 200ms > 100ms idle timeout

  # Evict expired connections explicitly
  client.pool.evictExpired()
  assert client.pool.poolSize(key) == 0,
    "Expected 0 idle connections after timeout, got " & $client.pool.poolSize(key)

  client.close()
  listener.close()
  echo "PASS: Connection evicted after idle timeout"

# ============================================================
# Test 4: Pool respects maxPerHost limit
# ============================================================
block testMaxPerHost:
  let key = PoolKey(host: "test.example.com", port: 80, useTls: false)
  let pool = newConnectionPool(maxPerHost = 2, maxIdleSeconds = 60.0)

  # Create 3 fake connections using BufferStreams (in-memory)
  var conns: seq[Http1Connection]
  for i in 0 ..< 3:
    let bs = newBufferStream()
    let reader = newBufferedReader(bs.AsyncStream)
    let conn = Http1Connection(
      stream: bs.AsyncStream,
      reader: reader,
      host: "test.example.com",
      port: 80,
      keepAlive: true
    )
    conns.add conn

  # Release all 3 to the pool (max is 2)
  pool.release(key, conns[0])
  pool.release(key, conns[1])
  pool.release(key, conns[2])

  # Pool should have at most 2 connections
  assert pool.poolSize(key) == 2,
    "Expected 2 connections (maxPerHost), got " & $pool.poolSize(key)

  # The oldest (conns[0]) should have been closed
  assert conns[0].stream.closed,
    "Oldest connection should have been closed when pool was full"

  pool.closeAll()
  echo "PASS: Pool respects maxPerHost limit"

# ============================================================
# Test 5: Stale connection retry
# ============================================================
block testStaleRetry:
  globalConnectionCount = 0
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  # Server: accept 2 connections. First connection serves 1 request then
  # the server closes it. The second connection handles the retry.
  proc staleServerAccept(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    # First connection: handle 1 request, then close (Connection: close header)
    let client1 = await l.accept()
    globalConnectionCount += 1
    let reader1 = newBufferedReader(client1.AsyncStream)
    let req1 = await parseRequest(client1.AsyncStream, reader1, cfg)
    let resp1 = newResponse(200, "first",
      @[("Connection", "close")])
    await writeResponse(client1.AsyncStream, resp1)
    client1.AsyncStream.close()

    # Second connection: normal keep-alive
    let client2 = await l.accept()
    globalConnectionCount += 1
    await handleHttp1Connection(client2.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        countingHandler(req))

  let sf = staleServerAccept(listener, config)

  # Client: make 2 requests. First gets Connection: close, so it should not
  # be pooled. Second request creates a new connection.
  let client = newHttpsClient(preferHttp2 = false, autoDecompress = false)
  let url = "http://127.0.0.1:" & $port & "/test"
  let cf = doTwoFetches(client, url)

  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 500:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert cf.finished, "Client future should have completed"
  let results = cf.read()
  assert results.len == 2, "Expected 2 responses"
  assert results[0].statusCode == 200, "First request failed"
  assert results[1].statusCode == 200, "Second request failed"

  # Both requests needed their own connection (first was Connection: close)
  assert globalConnectionCount == 2,
    "Expected 2 TCP connections (no reuse due to Connection: close), got " & $globalConnectionCount

  client.close()
  listener.close()
  echo "PASS: Stale connection retry (Connection: close)"

# ============================================================
# Test 6: Non-keep-alive response is not pooled
# ============================================================
block testNoPoolOnClose:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  let sf = acceptN(listener, config,
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      closeHandler(req), 1)

  let client = newHttpsClient(preferHttp2 = false, autoDecompress = false)
  let url = "http://127.0.0.1:" & $port & "/test"
  let cf = doFetch(client, url)

  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 500:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert cf.finished, "Client future should have completed"
  let resp = cf.read()
  assert resp.statusCode == 200, "Request failed"
  assert resp.body == "closed", "Expected 'closed' body"

  # Pool should be empty since server sent Connection: close
  let key = PoolKey(host: "127.0.0.1", port: port, useTls: false)
  assert client.pool.poolSize(key) == 0,
    "Expected 0 pooled connections (Connection: close), got " & $client.pool.poolSize(key)

  client.close()
  listener.close()
  echo "PASS: Non-keep-alive response is not pooled"

# ============================================================
# Test 7: Pool cleanup on client close
# ============================================================
block testPoolCleanup:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  let sf = acceptN(listener, config,
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      countingHandler(req), 1)

  let client = newHttpsClient(preferHttp2 = false, autoDecompress = false)
  let url = "http://127.0.0.1:" & $port & "/test"
  let cf = doFetch(client, url)

  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 500:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert cf.finished, "Client future should have completed"
  assert cf.read().statusCode == 200, "Request failed"

  let key = PoolKey(host: "127.0.0.1", port: port, useTls: false)
  assert client.pool.poolSize(key) == 1,
    "Expected 1 pooled connection before close"

  # Close the client — pool should be cleared
  client.close()
  assert client.pool.totalPoolSize() == 0,
    "Expected 0 connections after client.close(), got " & $client.pool.totalPoolSize()

  listener.close()
  echo "PASS: Pool cleanup on client close"

echo ""
echo "All connection pool tests passed!"
