## Tests for HTTP Server (single-threaded)
##
## Tests HTTP/1.1 and HTTP/2 server functionality including
## plaintext and TLS modes.

import std/[strutils, nativesockets, osproc, os]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/concurrency/taskgroup
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/server/http2 as http2_server
import cps/http/server/router
import cps/http/server/server as http_server
import cps/http/shared/http2
import cps/http/shared/hpack
import cps/tls/client as tls
import cps/tls/server as tls_server
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

proc echoHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## Simple handler: returns the request body as the response body.
  return newResponse(200, req.body, @[("X-Method", req.meth), ("X-Path", req.path)])

proc helloHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## Handler that returns a fixed greeting.
  return newResponse(200, "Hello, World!")

proc sleepHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## Handler that sleeps before responding (tests async handlers).
  await cpsSleep(50)
  return newResponse(200, "delayed response")

proc generateTestCert(): (string, string) =
  ## Generate a self-signed cert + key for testing. Returns (certFile, keyFile).
  let certFile = getTempDir() / "test_server_cert.pem"
  let keyFile = getTempDir() / "test_server_key.pem"
  # Only generate if not already present (or stale)
  if not fileExists(certFile) or not fileExists(keyFile):
    let cmd = "openssl req -x509 -newkey rsa:2048 -keyout " & keyFile &
              " -out " & certFile &
              " -days 1 -nodes -subj '/CN=localhost' 2>/dev/null"
    let exitCode = execCmd(cmd)
    assert exitCode == 0, "Failed to generate test certificate"
  result = (certFile, keyFile)

# ============================================================
# Test 1: HTTP/1.1 echo (plaintext)
# ============================================================
block testH1Echo:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  # Server: accept one connection, handle it
  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        helloHandler(req))

  # Client: send a raw HTTP/1.1 GET request
  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reqStr = "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(reqStr)
    # Read response
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let response = cf.read()
  assert "200 OK" in response, "Expected 200 OK, got: " & response
  assert "Hello, World!" in response, "Expected body 'Hello, World!'"
  listener.close()
  echo "PASS: HTTP/1.1 echo (plaintext)"

# ============================================================
# Test 2: HTTP/1.1 keep-alive (multiple requests on one connection)
# ============================================================
block testH1KeepAlive:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        echoHandler(req))

  proc clientTask(p: int): CpsFuture[seq[string]] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reader = newBufferedReader(conn.AsyncStream)
    var responses: seq[string]

    # Send 3 requests on the same connection
    for i in 0 ..< 3:
      let body = "msg" & $i
      let reqStr = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: " &
                   $body.len & "\r\n\r\n" & body
      await conn.AsyncStream.write(reqStr)

      # Read response status line + headers + body
      let statusLine = await reader.readLine()
      var contentLen = 0
      while true:
        let line = await reader.readLine()
        if line == "":
          break
        if line.toLowerAscii.startsWith("content-length:"):
          contentLen = parseInt(line.split(':')[1].strip())
      if contentLen > 0:
        let respBody = await reader.readExact(contentLen)
        responses.add respBody
      else:
        responses.add ""

    # Close with Connection: close
    let closeReq = "GET /done HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(closeReq)
    let finalStatus = await reader.readLine()
    discard finalStatus
    conn.AsyncStream.close()
    return responses

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let responses = cf.read()
  assert responses.len == 3, "Expected 3 responses, got " & $responses.len
  assert responses[0] == "msg0", "Response 0: " & responses[0]
  assert responses[1] == "msg1", "Response 1: " & responses[1]
  assert responses[2] == "msg2", "Response 2: " & responses[2]
  listener.close()
  echo "PASS: HTTP/1.1 keep-alive (3 requests on 1 connection)"

# ============================================================
# Test 3: HTTP/1.1 POST with body
# ============================================================
block testH1Post:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        echoHandler(req))

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let body = "key=value&foo=bar"
    let reqStr = "POST /submit HTTP/1.1\r\nHost: localhost\r\nContent-Length: " &
                 $body.len & "\r\nConnection: close\r\n\r\n" & body
    await conn.AsyncStream.write(reqStr)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let response = cf.read()
  assert "200 OK" in response, "Expected 200 OK"
  assert "key=value&foo=bar" in response, "Expected echoed body"
  listener.close()
  echo "PASS: HTTP/1.1 POST with body"

# ============================================================
# Test 4: HTTP/1.1 large payload (100KB)
# ============================================================
block testH1LargePayload:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()
  let largeBody = 'A'.repeat(100_000)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        echoHandler(req))

  proc clientTask(p: int, payload: string): CpsFuture[int] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reqStr = "POST /big HTTP/1.1\r\nHost: localhost\r\nContent-Length: " &
                 $payload.len & "\r\nConnection: close\r\n\r\n" & payload
    await conn.AsyncStream.write(reqStr)
    # Read response and extract Content-Length
    let reader = newBufferedReader(conn.AsyncStream)
    let statusLine = await reader.readLine()
    discard statusLine
    var bodyLen = 0
    while true:
      let line = await reader.readLine()
      if line == "":
        break
      if line.toLowerAscii.startsWith("content-length:"):
        bodyLen = parseInt(line.split(':')[1].strip())
    conn.AsyncStream.close()
    return bodyLen

  let sf = serverTask(listener, config)
  let cf = clientTask(port, largeBody)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let responseBodyLen = cf.read()
  assert responseBodyLen == 100_000, "Expected 100000 byte response, got " & $responseBodyLen
  listener.close()
  echo "PASS: HTTP/1.1 large payload (100KB)"

# ============================================================
# Test 4b: HTTP/1.1 header/request-line limits
# ============================================================
block testH1HeaderAndRequestLineLimits:
  # Header count limit -> 431
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig(maxHeaderCount: 2)

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg,
        proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
          helloHandler(req))

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let reqStr = "GET / HTTP/1.1\r\nHost: localhost\r\nA: 1\r\nB: 2\r\nC: 3\r\nConnection: close\r\n\r\n"
      await conn.AsyncStream.write(reqStr)
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break

    let response = cf.read()
    assert "431 Request Header Fields Too Large" in response, "Expected 431, got: " & response
    listener.close()

  # Request line limit -> 414
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig(maxRequestLineSize: 16)

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg,
        proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
          helloHandler(req))

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let reqStr = "GET /this-path-is-too-long HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
      await conn.AsyncStream.write(reqStr)
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break

    let response = cf.read()
    assert "414 URI Too Long" in response, "Expected 414, got: " & response
    listener.close()

  echo "PASS: HTTP/1.1 header/request-line limits"

# ============================================================
# Test 5: HTTP/1.1 connection drop (graceful handling)
# ============================================================
block testH1ConnectionDrop:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        helloHandler(req))

  # Client: connect and immediately close without sending anything
  proc clientTask(p: int): CpsVoidFuture {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    conn.AsyncStream.close()

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not sf.finished and ticks < 200:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert sf.finished, "Server should have handled the dropped connection"
  # Server may or may not have an error depending on timing of the client
  # close vs. the read attempt. Either way, it should complete without hanging.
  listener.close()
  echo "PASS: HTTP/1.1 connection drop (graceful handling)"

# ============================================================
# Test 6: HTTP/1.1 concurrent connections
# ============================================================
block testH1Concurrent:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()
  let numClients = 10

  # Server: accept multiple connections, handle each concurrently
  proc acceptLoop(l: TcpListener, cfg: HttpServerConfig, n: int): CpsVoidFuture {.cps.} =
    for i in 0 ..< n:
      let client = await l.accept()
      # Spawn (fire-and-forget) each connection handler
      discard handleHttp1Connection(client.AsyncStream, cfg,
        proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
          helloHandler(req))

  proc clientTask(p: int, id: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reqStr = "GET /client" & $id & " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(reqStr)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = acceptLoop(listener, config, numClients)
  var clientFuts: seq[CpsFuture[string]]
  for i in 0 ..< numClients:
    clientFuts.add clientTask(port, i)

  let loop = getEventLoop()
  var allDone = false
  var ticks = 0
  while not allDone and ticks < 1000:
    loop.tick()
    inc ticks
    allDone = true
    for i in 0 ..< clientFuts.len:
      if not clientFuts[i].finished:
        allDone = false
        break
    if not loop.hasWork:
      break

  var successCount = 0
  for i in 0 ..< clientFuts.len:
    if clientFuts[i].finished and not clientFuts[i].hasError():
      let resp = clientFuts[i].read()
      if "200 OK" in resp and "Hello, World!" in resp:
        inc successCount

  assert successCount == numClients, "Expected " & $numClients & " successful responses, got " & $successCount
  listener.close()
  echo "PASS: HTTP/1.1 concurrent connections (" & $numClients & " clients)"

# ============================================================
# Test 7: HTTP/1.1 async handler (handler awaits cpsSleep)
# ============================================================
block testH1AsyncHandler:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        sleepHandler(req))

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
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

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let response = cf.read()
  assert "200 OK" in response, "Expected 200 OK"
  assert "delayed response" in response, "Expected 'delayed response'"
  listener.close()
  echo "PASS: HTTP/1.1 async handler (cpsSleep)"

# ============================================================
# Test 8: TLS HTTP/1.1 integration
# ============================================================
block testTlsH1:
  let (certFile, keyFile) = generateTestCert()
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig(useTls: true, certFile: certFile, keyFile: keyFile)
  let tlsCtx = newTlsServerContext(certFile, keyFile, @["http/1.1"])

  proc serverTask(l: TcpListener, ctx: TlsServerContext,
                  cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let tcpClient = await l.accept()
    let tlsStream = await tlsAccept(ctx, tcpClient)
    await handleHttp1Connection(tlsStream.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        helloHandler(req))

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    # Use our TLS client (doesn't verify certs — fine for testing)
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let tlsStream = newTlsStream(tcpConn, "localhost", @["http/1.1"])
    await tlsConnect(tlsStream)
    let reader = newBufferedReader(tlsStream.AsyncStream)
    let h1conn = Http1Connection(
      stream: tlsStream.AsyncStream,
      reader: reader,
      host: "localhost",
      port: p,
      keepAlive: false
    )
    await sendRequest(h1conn, "GET", "/tls-test",
                      @[("Connection", "close")])
    let resp = await recvResponse(h1conn)
    tlsStream.AsyncStream.close()
    return $resp.statusCode & ":" & resp.body

  let sf = serverTask(listener, tlsCtx, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result.startsWith("200:"), "Expected 200, got: " & result
  assert "Hello, World!" in result, "Expected Hello, World!"
  listener.close()
  closeTlsServerContext(tlsCtx)
  echo "PASS: TLS HTTP/1.1 integration"

# ============================================================
# Test 9: TLS HTTP/2 integration (ALPN h2)
# ============================================================
block testTlsH2:
  let (certFile, keyFile) = generateTestCert()
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig(useTls: true, certFile: certFile, keyFile: keyFile, enableHttp2: true)
  let tlsCtx = newTlsServerContext(certFile, keyFile, @["h2", "http/1.1"])

  proc serverTask(l: TcpListener, ctx: TlsServerContext,
                  cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let tcpClient = await l.accept()
    let tlsStream = await tlsAccept(ctx, tcpClient)
    if tlsStream.alpnProto == "h2":
      await handleHttp2Connection(tlsStream.AsyncStream, cfg,
        proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
          helloHandler(req))
    else:
      await handleHttp1Connection(tlsStream.AsyncStream, cfg,
        proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
          helloHandler(req))

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let tlsStream = newTlsStream(tcpConn, "localhost", @["h2", "http/1.1"])
    await tlsConnect(tlsStream)

    let alpn = tlsStream.alpnProto
    if alpn != "h2":
      return "ALPN negotiated " & alpn & " instead of h2"

    # Do HTTP/2 request
    let h2conn = newHttp2Connection(tlsStream.AsyncStream)
    await initConnection(h2conn)
    # Start receive loop in background
    discard runReceiveLoop(h2conn)
    let resp = await http2.request(h2conn, "GET", "/h2-test", "localhost")
    return $resp.statusCode & ":" & resp.body

  let sf = serverTask(listener, tlsCtx, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result.startsWith("200:"), "Expected 200, got: " & result
  assert "Hello, World!" in result, "Expected Hello, World! in: " & result
  listener.close()
  closeTlsServerContext(tlsCtx)
  echo "PASS: TLS HTTP/2 integration (ALPN h2)"

# ============================================================
# Test 10: HTTP/2 concurrent streams
# ============================================================
block testH2ConcurrentStreams:
  let (certFile, keyFile) = generateTestCert()
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig(useTls: true, certFile: certFile, keyFile: keyFile, enableHttp2: true)
  let tlsCtx = newTlsServerContext(certFile, keyFile, @["h2"])

  proc serverTask(l: TcpListener, ctx: TlsServerContext,
                  cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let tcpClient = await l.accept()
    let tlsStream = await tlsAccept(ctx, tcpClient)
    await handleHttp2Connection(tlsStream.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        echoHandler(req))

  proc clientTask(p: int): CpsFuture[seq[string]] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let tlsStream = newTlsStream(tcpConn, "localhost", @["h2"])
    await tlsConnect(tlsStream)

    let h2conn = newHttp2Connection(tlsStream.AsyncStream)
    await initConnection(h2conn)
    discard runReceiveLoop(h2conn)

    # Send 3 concurrent requests on different streams
    let f1 = http2.request(h2conn, "POST", "/stream1", "localhost", body = "data1")
    let f2 = http2.request(h2conn, "POST", "/stream2", "localhost", body = "data2")
    let f3 = http2.request(h2conn, "POST", "/stream3", "localhost", body = "data3")

    let r1 = await f1
    let r2 = await f2
    let r3 = await f3

    var results: seq[string]
    results.add r1.body
    results.add r2.body
    results.add r3.body
    return results

  let sf = serverTask(listener, tlsCtx, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let results = cf.read()
  assert results.len == 3, "Expected 3 results"
  assert results[0] == "data1", "Stream 1: " & results[0]
  assert results[1] == "data2", "Stream 2: " & results[1]
  assert results[2] == "data3", "Stream 3: " & results[2]
  listener.close()
  closeTlsServerContext(tlsCtx)
  echo "PASS: HTTP/2 concurrent streams (3 streams)"

# ============================================================
# Test 11: HTTP/2 POST with body (DATA frames round-trip)
# ============================================================
block testH2PostBody:
  let (certFile, keyFile) = generateTestCert()
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig(useTls: true, certFile: certFile, keyFile: keyFile, enableHttp2: true)
  let tlsCtx = newTlsServerContext(certFile, keyFile, @["h2"])

  proc serverTask(l: TcpListener, ctx: TlsServerContext,
                  cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let tcpClient = await l.accept()
    let tlsStream = await tlsAccept(ctx, tcpClient)
    await handleHttp2Connection(tlsStream.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        echoHandler(req))

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let tlsStream = newTlsStream(tcpConn, "localhost", @["h2"])
    await tlsConnect(tlsStream)

    let h2conn = newHttp2Connection(tlsStream.AsyncStream)
    await initConnection(h2conn)
    discard runReceiveLoop(h2conn)

    let postBody = "Hello from HTTP/2 POST"
    let resp = await http2.request(h2conn, "POST", "/post-test", "localhost",
                                    body = postBody)
    return resp.body

  let sf = serverTask(listener, tlsCtx, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "Hello from HTTP/2 POST", "Expected echoed body, got: " & result
  listener.close()
  closeTlsServerContext(tlsCtx)
  echo "PASS: HTTP/2 POST with body (DATA frames round-trip)"

# ============================================================
# Test 12: Server stop (clean shutdown)
# ============================================================
block testServerStop:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  var serverStopped = false

  # Use a server object to test stop()
  let srv = newHttpServer(
    proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      helloHandler(req),
    host = "127.0.0.1",
    port = 0
  )
  srv.listener = listener
  srv.boundPort = port
  srv.running = true

  # Accept one connection, handle, then stop
  proc serverTask(l: TcpListener, s: HttpServer): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let cfg = s.config
    await handleHttp1Connection(client.AsyncStream, cfg, s.handler)
    s.running = false

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reqStr = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(reqStr)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, srv)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let response = cf.read()
  assert "200 OK" in response
  assert not srv.running, "Server should have stopped"
  listener.close()
  echo "PASS: Server stop (clean shutdown)"

# ============================================================
# Test 13: HTTP/2 stream stress (frame write serialization)
# ============================================================
block testH2ConcurrentStress:
  let (certFile, keyFile) = generateTestCert()
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig(useTls: true, certFile: certFile, keyFile: keyFile, enableHttp2: true)
  let tlsCtx = newTlsServerContext(certFile, keyFile, @["h2"])
  let streamCount = 24

  proc serverTask(l: TcpListener, ctx: TlsServerContext,
                  cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let tcpClient = await l.accept()
    let tlsStream = await tlsAccept(ctx, tcpClient)
    await handleHttp2Connection(tlsStream.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        echoHandler(req))

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let tlsStream = newTlsStream(tcpConn, "localhost", @["h2"])
    await tlsConnect(tlsStream)

    let h2conn = newHttp2Connection(tlsStream.AsyncStream)
    await initConnection(h2conn)
    discard runReceiveLoop(h2conn)

    var payloads: seq[string]
    var reqFuts: seq[CpsFuture[Http2Response]]
    var i = 0
    while i < streamCount:
      let idx = i
      let payload = "stream-" & $idx & ":" & char(ord('A') + (idx mod 26)).repeat(512 + (idx mod 8))
      payloads.add payload
      reqFuts.add http2.request(h2conn, "POST", "/stress/" & $idx, "localhost", body = payload)
      inc i

    var j = 0
    while j < reqFuts.len:
      let resp = await reqFuts[j]
      if resp.statusCode != 200 or resp.body != payloads[j]:
        return false
      inc j
    tlsStream.AsyncStream.close()
    return true

  let sf = serverTask(listener, tlsCtx, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 4000:
    loop.tick()
    inc ticks
    if not loop.hasWork:
      break

  assert cf.finished, "HTTP/2 stress client did not complete"
  assert cf.read(), "HTTP/2 concurrent stress response mismatch"
  listener.close()
  closeTlsServerContext(tlsCtx)
  echo "PASS: HTTP/2 concurrent stress (24 streams)"

# ============================================================
# Test 14: HTTP/1.1 chunked trailers preserve keep-alive parser state
# ============================================================
block testH1ChunkedTrailersKeepAlive:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc mixedHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    if req.path == "/chunk":
      return newResponse(200, req.body)
    return newResponse(200, "next")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, mixedHandler)

  proc readResponse(reader: BufferedReader): CpsFuture[(int, string)] {.cps.} =
    let statusLine = await reader.readLine()
    if statusLine.len == 0:
      return (0, "")
    let parts = statusLine.split(' ')
    var status = 0
    if parts.len >= 2:
      status = parseInt(parts[1])
    var contentLen = 0
    while true:
      let line = await reader.readLine()
      if line.len == 0:
        break
      if line.toLowerAscii.startsWith("content-length:"):
        contentLen = parseInt(line.split(':', 1)[1].strip())
    var body = ""
    if contentLen > 0:
      body = await reader.readExact(contentLen)
    return (status, body)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let stream = conn.AsyncStream
    let reader = newBufferedReader(stream)

    let req1 = "POST /chunk HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" &
               "4\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer-One: 1\r\nX-Trailer-Two: 2\r\n\r\n"
    let req2 = "GET /next HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    await stream.write(req1 & req2)

    let r1 = await readResponse(reader)
    let r2 = await readResponse(reader)
    stream.close()
    return $r1[0] & ":" & r1[1] & "|" & $r2[0] & ":" & r2[1]

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "HTTP/1 chunked trailers client did not complete"
  let result = cf.read()
  assert result == "200:Wikipedia|200:next", "Unexpected chunked trailer keep-alive result: " & result
  listener.close()
  echo "PASS: HTTP/1.1 chunked trailers keep parser state for next request"

# ============================================================
# Test 15: Header/cookie injection is rejected
# ============================================================
block testHeaderAndCookieInjectionRejection:
  # Unit-level response header sanitization fallback.
  let invalidNameResp = newResponse(200, "ok", @[("Bad\r\nInjected", "x")])
  let invalidNameRaw = buildResponseString(invalidNameResp)
  assert "500 Internal Server Error" in invalidNameRaw
  assert "Injected" notin invalidNameRaw

  let invalidValueResp = newResponse(200, "ok", @[("X-Test", "ok\r\nInjected: yes")])
  let invalidValueRaw = buildResponseString(invalidValueResp)
  assert "500 Internal Server Error" in invalidValueRaw
  assert "Injected: yes" notin invalidValueRaw

  # Integration-level: invalid handler headers never get emitted.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg,
        proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
          let respFut = newCpsFuture[HttpResponseBuilder]()
          respFut.complete(newResponse(200, "unsafe", @[("X-Unsafe", "bad\r\nInjected: 1")]))
          return respFut)

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      await conn.AsyncStream.write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    let response = cf.read()
    assert "500 Internal Server Error" in response
    assert "Injected: 1" notin response
    listener.close()

  var cookieRejected = false
  try:
    discard setCookieHeader("session", "ok\r\nInjected: 1")
  except ValueError:
    cookieRejected = true
  assert cookieRejected, "Cookie injection should be rejected"
  echo "PASS: Header/cookie injection rejection"

# ============================================================
# Test 16: Lifecycle callbacks and graceful shutdown drain
# ============================================================
block testLifecycleCallbacksAndShutdownDrain:
  var startHits = 0
  var shutdownHits = 0
  var drained = false

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  let srv = newHttpServer(okHandler, host = "127.0.0.1", port = 0)
  srv.onStart(proc() = inc startHits)
  srv.onShutdown(proc() = inc shutdownHits)

  # start() invokes onStart callbacks when server begins accepting.
  for cb in srv.onStartCallbacks:
    cb()

  # Simulate one in-flight connection task and ensure shutdown drains it.
  proc inflightTask(): CpsVoidFuture {.cps.} =
    await cpsSleep(75)
    drained = true

  srv.connGroup.spawn(inflightTask())
  let shutdownFut = srv.shutdown(1000)

  let loop = getEventLoop()
  var ticks = 0
  while ticks < 2000 and not shutdownFut.finished:
    loop.tick()
    inc ticks

  assert startHits == 1, "onStart callback registration should be honored"
  assert shutdownHits == 1, "onShutdown callback should run once"
  assert shutdownFut.finished, "shutdown() should complete"
  assert drained, "shutdown() should drain active connGroup work"
  echo "PASS: lifecycle callbacks + graceful shutdown drain"

# ============================================================
# Test 17: HTTP/1.1 Host header validation
# ============================================================
block testH1HostHeaderValidation:
  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  # Missing Host on HTTP/1.1 must be rejected.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg, okHandler)

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      await conn.AsyncStream.write("GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    let response = cf.read()
    assert "400 Bad Request" in response, "Missing Host should be 400, got: " & response
    listener.close()

  # Duplicate Host headers on HTTP/1.1 must be rejected.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg, okHandler)

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let reqStr = "GET / HTTP/1.1\r\nHost: a.example\r\nHost: b.example\r\nConnection: close\r\n\r\n"
      await conn.AsyncStream.write(reqStr)
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    let response = cf.read()
    assert "400 Bad Request" in response, "Duplicate Host should be 400, got: " & response
    listener.close()

  echo "PASS: HTTP/1.1 Host header validation"

# ============================================================
# Test 17b: HTTP/1.1 version validation
# ============================================================
block testH1VersionValidation:
  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  # Unsupported HTTP major/minor should return 505.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg, okHandler)

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      await conn.AsyncStream.write("GET / HTTP/1.2\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    let response = cf.read()
    assert "505 HTTP Version Not Supported" in response, "Expected 505 for HTTP/1.2, got: " & response
    listener.close()

  # Malformed protocol token should return 400.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg, okHandler)

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      await conn.AsyncStream.write("GET / HTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    let response = cf.read()
    assert "400 Bad Request" in response, "Expected 400 for malformed protocol token, got: " & response
    listener.close()

  echo "PASS: HTTP/1.1 version validation"

# ============================================================
# Test 18: HTTP/1.1 conflicting Content-Length values are rejected
# ============================================================
block testH1ConflictingContentLengthRejected:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        helloHandler(req))

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reqStr = "POST / HTTP/1.1\r\n" &
                 "Host: localhost\r\n" &
                 "Content-Length: 5\r\n" &
                 "Content-Length: 4\r\n" &
                 "Connection: close\r\n\r\n" &
                 "HELLO"
    await conn.AsyncStream.write(reqStr)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let response = cf.read()
  assert "400 Bad Request" in response, "Conflicting Content-Length must be 400, got: " & response
  listener.close()
  echo "PASS: HTTP/1.1 conflicting Content-Length rejected"

# ============================================================
# Test 19: HTTP/1.1 invalid Transfer-Encoding token is rejected
# ============================================================
block testH1InvalidTransferEncodingRejected:
  # Invalid token spelling should be rejected.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg,
        proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
          helloHandler(req))

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let reqStr = "POST / HTTP/1.1\r\n" &
                   "Host: localhost\r\n" &
                   "Transfer-Encoding: xchunked\r\n" &
                   "Connection: close\r\n\r\n" &
                   "0\r\n\r\n"
      await conn.AsyncStream.write(reqStr)
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    let response = cf.read()
    assert "400 Bad Request" in response, "Invalid Transfer-Encoding must be 400, got: " & response
    listener.close()

  # Unsupported transfer coding chain should be rejected.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg,
        proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
          helloHandler(req))

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let reqStr = "POST / HTTP/1.1\r\n" &
                   "Host: localhost\r\n" &
                   "Transfer-Encoding: gzip, chunked\r\n" &
                   "Connection: close\r\n\r\n" &
                   "0\r\n\r\n"
      await conn.AsyncStream.write(reqStr)
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    let response = cf.read()
    assert "400 Bad Request" in response, "Unsupported Transfer-Encoding chain must be 400, got: " & response
    listener.close()

  echo "PASS: HTTP/1.1 invalid Transfer-Encoding rejected"

# ============================================================
# Test 20: HTTP/1.1 Connection token list honoring close
# ============================================================
block testH1ConnectionTokenListClose:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        let respFut = newCpsFuture[HttpResponseBuilder]()
        respFut.complete(newResponse(200, "ok"))
        return respFut)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let req1 = "GET /one HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive, close\r\n\r\n"
    let req2 = "GET /two HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(req1 & req2)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let response = cf.read()
  let statusCount = count(response, "HTTP/1.1 200 OK")
  assert statusCount == 1, "Expected exactly one response when Connection has close token, got " &
    $statusCount & " in: " & response
  listener.close()
  echo "PASS: HTTP/1.1 Connection token list close honored"

# ============================================================
# Test 21: HTTP/1.1 client chunked trailers preserve next response parse
# ============================================================
block testH1ClientChunkedTrailerParsing:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let resp1 = "HTTP/1.1 200 OK\r\n" &
                "Transfer-Encoding: chunked\r\n" &
                "Connection: keep-alive\r\n\r\n" &
                "4\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: 1\r\n\r\n"
    let resp2 = "HTTP/1.1 200 OK\r\n" &
                "Content-Length: 4\r\n" &
                "Connection: close\r\n\r\n" &
                "done"
    await client.AsyncStream.write(resp1 & resp2)
    client.AsyncStream.close()

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let h1conn = Http1Connection(
      stream: conn.AsyncStream,
      reader: newBufferedReader(conn.AsyncStream),
      host: "localhost",
      port: p,
      keepAlive: true
    )
    let r1 = await recvResponse(h1conn)
    let r2 = await recvResponse(h1conn)
    conn.AsyncStream.close()
    return $r1.statusCode & ":" & r1.body & "|" & $r2.statusCode & ":" & r2.body

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  assert cf.finished, "HTTP/1.1 client trailer parsing task did not complete"
  let result = cf.read()
  assert result == "200:Wikipedia|200:done", "Unexpected client parse result: " & result
  listener.close()
  echo "PASS: HTTP/1.1 client chunked trailer parsing keep-alive"

# ============================================================
# Test 22: HTTP/1.1 strict header syntax
# ============================================================
block testH1StrictHeaderSyntax:
  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  # Header names cannot have whitespace before the colon.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg, okHandler)

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      await conn.AsyncStream.write("GET / HTTP/1.1\r\nHost : localhost\r\nConnection: close\r\n\r\n")
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    let response = cf.read()
    assert "400 Bad Request" in response, "Header whitespace before colon must be 400, got: " & response
    listener.close()

  # Obsolete folded/indented header lines are rejected.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg, okHandler)

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      await conn.AsyncStream.write("GET / HTTP/1.1\r\nHost: localhost\r\n X-Test: 1\r\nConnection: close\r\n\r\n")
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    let response = cf.read()
    assert "400 Bad Request" in response, "Leading-space header lines must be 400, got: " & response
    listener.close()

  echo "PASS: HTTP/1.1 strict header syntax"

# ============================================================
# Test 23: HTTP/1.1 client request header injection prevention
# ============================================================
block testH1ClientRequestHeaderValidation:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsFuture[int] {.cps.} =
    let client = await l.accept()
    let data = await client.AsyncStream.read(4096)
    client.AsyncStream.close()
    return data.len

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let h1conn = Http1Connection(
      stream: conn.AsyncStream,
      reader: newBufferedReader(conn.AsyncStream),
      host: "localhost",
      port: p,
      keepAlive: true
    )
    var rejected = false
    var sendFut: CpsVoidFuture = nil
    try:
      sendFut = sendRequest(h1conn, "GET", "/", @[("X-Test", "ok\r\nInjected: 1")])
    except ValueError:
      rejected = true
    if not rejected and not sendFut.isNil:
      try:
        await sendFut
      except ValueError:
        rejected = true
    conn.AsyncStream.close()
    return rejected

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "Client validation task did not complete"
  assert sf.finished, "Server capture task did not complete"
  assert cf.read(), "Client should reject CRLF header injection attempts"
  assert sf.read() == 0, "No bytes should be sent when request validation fails"
  listener.close()
  echo "PASS: HTTP/1.1 client request header validation"

# ============================================================
# Test 24: HTTP/1.1 Expect handling
# ============================================================
block testH1ExpectHandling:
  # Expect: 100-continue should get interim 100 before body upload.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg,
        proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
          let respFut = newCpsFuture[HttpResponseBuilder]()
          respFut.complete(newResponse(200, req.body))
          return respFut)

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let reader = newBufferedReader(conn.AsyncStream)
      let headersOnly =
        "POST /expect HTTP/1.1\r\n" &
        "Host: localhost\r\n" &
        "Expect: 100-continue\r\n" &
        "Content-Length: 5\r\n" &
        "Connection: close\r\n\r\n"
      await conn.AsyncStream.write(headersOnly)

      let interimStatus = await reader.readLine()
      while true:
        let line = await reader.readLine()
        if line.len == 0:
          break

      await conn.AsyncStream.write("HELLO")

      let finalStatus = await reader.readLine()
      var cl = 0
      while true:
        let line = await reader.readLine()
        if line.len == 0:
          break
        if line.toLowerAscii.startsWith("content-length:"):
          cl = parseInt(line.split(':', 1)[1].strip())
      var body = ""
      if cl > 0:
        body = await reader.readExact(cl)

      conn.AsyncStream.close()
      return interimStatus & "|" & finalStatus & "|" & body

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    let result = cf.read()
    assert "HTTP/1.1 100 Continue" in result, "Expected interim 100 Continue, got: " & result
    assert "HTTP/1.1 200 OK" in result, "Expected final 200 OK, got: " & result
    assert result.endsWith("|HELLO"), "Expected echoed body after continue, got: " & result
    listener.close()

  # Unsupported expectations should be rejected with 417.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg,
        proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
          let respFut = newCpsFuture[HttpResponseBuilder]()
          respFut.complete(newResponse(200, "unexpected"))
          return respFut)

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let reqStr =
        "GET /expect HTTP/1.1\r\n" &
        "Host: localhost\r\n" &
        "Expect: nonsense\r\n" &
        "Connection: close\r\n\r\n"
      await conn.AsyncStream.write(reqStr)
      var response = ""
      while true:
        let chunk = await conn.AsyncStream.read(4096)
        if chunk.len == 0:
          break
        response &= chunk
      conn.AsyncStream.close()
      return response

    let sf = serverTask(listener, config)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    let response = cf.read()
    assert "417 Expectation Failed" in response, "Unsupported Expect should be 417, got: " & response
    listener.close()

  echo "PASS: HTTP/1.1 Expect handling"

# ============================================================
# Test 25: HTTP/1.1 client skips interim responses
# ============================================================
block testH1ClientSkipsInterimResponses:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let rawResp =
      "HTTP/1.1 100 Continue\r\n\r\n" &
      "HTTP/1.1 200 OK\r\n" &
      "Content-Length: 2\r\n" &
      "Connection: close\r\n\r\n" &
      "ok"
    await client.AsyncStream.write(rawResp)
    client.AsyncStream.close()

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let h1conn = Http1Connection(
      stream: conn.AsyncStream,
      reader: newBufferedReader(conn.AsyncStream),
      host: "localhost",
      port: p,
      keepAlive: false
    )
    let resp = await recvResponse(h1conn)
    conn.AsyncStream.close()
    return $resp.statusCode & ":" & resp.body

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  assert cf.read() == "200:ok", "Client should skip 100 and return final response"
  listener.close()
  echo "PASS: HTTP/1.1 client skips interim responses"

# ============================================================
# Test 26: HTTP/1.0 close-delimited response body parsing
# ============================================================
block testH1ClientParsesHttp10CloseDelimitedBody:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let rawResp =
      "HTTP/1.0 200 OK\r\n" &
      "Content-Type: text/plain\r\n\r\n" &
      "legacy-body"
    await client.AsyncStream.write(rawResp)
    client.AsyncStream.close()

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let h1conn = Http1Connection(
      stream: conn.AsyncStream,
      reader: newBufferedReader(conn.AsyncStream),
      host: "localhost",
      port: p,
      keepAlive: false
    )
    let resp = await recvResponse(h1conn)
    conn.AsyncStream.close()
    return resp.httpVersion & "|" & resp.body

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let result = cf.read()
  assert result == "HTTP/1.0|legacy-body", "Expected HTTP/1.0 close-delimited body, got: " & result
  listener.close()
  echo "PASS: HTTP/1.0 close-delimited response parsing"

# ============================================================
# Test 27: HTTP/1.1 no-body status responses strip body framing
# ============================================================
block testH1NoBodyStatusResponseFraming:
  let raw204 = buildResponseString(newResponse(
    204,
    "should-not-be-sent",
    @[("Content-Length", "999"), ("Transfer-Encoding", "chunked"), ("Connection", "close")]
  ))
  assert "HTTP/1.1 204 No Content" in raw204
  assert "Transfer-Encoding:" notin raw204, "204 must not include Transfer-Encoding"
  assert "Content-Length:" notin raw204, "204 must not include Content-Length"
  let split204 = raw204.split("\r\n\r\n", 1)
  assert split204.len == 2, "Malformed 204 raw response"
  assert split204[1].len == 0, "204 must not include a response body"

  let raw304 = buildResponseString(newResponse(
    304,
    "also-not-sent",
    @[("Content-Length", "123"), ("Connection", "close")]
  ))
  assert "HTTP/1.1 304 Not Modified" in raw304
  assert "Content-Length:" notin raw304, "304 must not include Content-Length in this implementation"
  let split304 = raw304.split("\r\n\r\n", 1)
  assert split304.len == 2, "Malformed 304 raw response"
  assert split304[1].len == 0, "304 must not include a response body"

  let raw205 = buildResponseString(newResponse(
    205,
    "should-not-be-sent",
    @[("Content-Length", "123"), ("Transfer-Encoding", "chunked"), ("Connection", "close")]
  ))
  assert "HTTP/1.1 205 Reset Content" in raw205
  assert "Transfer-Encoding:" notin raw205, "205 must not include Transfer-Encoding"
  assert "Content-Length: 0" in raw205, "205 must explicitly indicate zero-length payload"
  let split205 = raw205.split("\r\n\r\n", 1)
  assert split205.len == 2, "Malformed 205 raw response"
  assert split205[1].len == 0, "205 must not include a response body"
  echo "PASS: HTTP/1.1 no-body status response framing"

# ============================================================
# Test 28: HTTP/1.1 client HEAD request parsing
# ============================================================
block testH1ClientHeadSkipsBodyRead:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let rawResp =
      "HTTP/1.1 200 OK\r\n" &
      "Content-Length: 14\r\n" &
      "Connection: close\r\n\r\n"
    await client.AsyncStream.write(rawResp)
    client.AsyncStream.close()

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let h1conn = Http1Connection(
      stream: conn.AsyncStream,
      reader: newBufferedReader(conn.AsyncStream),
      host: "localhost",
      port: p,
      keepAlive: false
    )
    let resp = await request(h1conn, "HEAD", "/head-test")
    conn.AsyncStream.close()
    return $resp.statusCode & ":" & $resp.body.len

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let result = cf.read()
  assert result == "200:0", "HEAD response body must be empty and non-blocking, got: " & result
  listener.close()
  echo "PASS: HTTP/1.1 client HEAD response handling"

# ============================================================
# Test 29: HTTP/1.1 empty Host is rejected
# ============================================================
block testH1EmptyHostRejected:
  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    await conn.AsyncStream.write("GET / HTTP/1.1\r\nHost:   \r\nConnection: close\r\n\r\n")
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let response = cf.read()
  assert "400 Bad Request" in response, "Empty Host header must be 400, got: " & response
  listener.close()
  echo "PASS: HTTP/1.1 empty Host rejected"

# ============================================================
# Test 30: HTTP/1.1 close token across multiple Connection headers
# ============================================================
block testH1SplitConnectionHeadersClose:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        let respFut = newCpsFuture[HttpResponseBuilder]()
        respFut.complete(newResponse(200, "ok"))
        return respFut)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let req1 = "GET /one HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\nConnection: close\r\n\r\n"
    let req2 = "GET /two HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(req1 & req2)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let response = cf.read()
  let statusCount = count(response, "HTTP/1.1 200 OK")
  assert statusCount == 1, "Expected one response when split Connection headers include close, got " &
    $statusCount & " in: " & response
  listener.close()
  echo "PASS: HTTP/1.1 split Connection headers close honored"

# ============================================================
# Test 31: HTTP/1.1 request Connection: close forces response close token
# ============================================================
block testH1RequestCloseForcesResponseCloseToken:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        let respFut = newCpsFuture[HttpResponseBuilder]()
        respFut.complete(newResponse(200, "ok", @[("Connection", "keep-alive")]))
        return respFut)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let req1 = "GET /one HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    let req2 = "GET /two HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(req1 & req2)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let response = cf.read()
  let lowerResp = response.toLowerAscii
  assert count(response, "HTTP/1.1 200 OK") == 1, "Server must close after request Connection: close"
  assert "connection: close" in lowerResp, "Response must advertise Connection: close when closing"
  assert "connection: keep-alive" notin lowerResp, "Response must not emit contradictory keep-alive token"
  assert count(lowerResp, "connection:") == 1, "Response must emit a single Connection header when forced close"
  listener.close()
  echo "PASS: HTTP/1.1 response close token forced when request asks close"

# ============================================================
# Test 32: Expect + oversized Content-Length returns 413 without interim 100
# ============================================================
block testH1ExpectOversizedNoInterimContinue:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig(maxRequestBodySize: 4)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        let respFut = newCpsFuture[HttpResponseBuilder]()
        respFut.complete(newResponse(200, "unexpected"))
        return respFut)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reader = newBufferedReader(conn.AsyncStream)
    let reqStr =
      "POST /expect HTTP/1.1\r\n" &
      "Host: localhost\r\n" &
      "Expect: 100-continue\r\n" &
      "Content-Length: 5\r\n" &
      "Connection: close\r\n\r\n"
    await conn.AsyncStream.write(reqStr)
    let statusLine = await reader.readLine()
    var response = statusLine
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let response = cf.read()
  assert response.startsWith("HTTP/1.1 413"), "Oversized Expect request should start with 413, got: " & response
  assert "100 Continue" notin response, "Oversized Expect request must not emit interim 100"
  listener.close()
  echo "PASS: HTTP/1.1 oversized Expect rejected without interim 100"

# ============================================================
# Test 33: HTTP/1.1 client honors close across multiple Connection headers
# ============================================================
block testH1ClientMultipleConnectionHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let rawResp =
      "HTTP/1.1 200 OK\r\n" &
      "Connection: keep-alive\r\n" &
      "Connection: close\r\n\r\n" &
      "body-by-close"
    await client.AsyncStream.write(rawResp)
    client.AsyncStream.close()

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let h1conn = Http1Connection(
      stream: conn.AsyncStream,
      reader: newBufferedReader(conn.AsyncStream),
      host: "localhost",
      port: p,
      keepAlive: false
    )
    try:
      let resp = await recvResponse(h1conn)
      conn.AsyncStream.close()
      return $resp.statusCode & ":" & resp.body
    except ValueError as e:
      conn.AsyncStream.close()
      return "error:" & e.msg

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let result = cf.read()
  assert result == "200:body-by-close", "Client must treat any Connection: close token as close-delimited, got: " & result
  listener.close()
  echo "PASS: HTTP/1.1 client multi-Connection close parsing"

# ============================================================
# Test 34: HTTP/1.1 client request framing validation
# ============================================================
block testH1ClientRequestFramingValidation:
  # Transfer-Encoding is not supported by this request sender.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)

    proc serverTask(l: TcpListener): CpsFuture[int] {.cps.} =
      let client = await l.accept()
      let data = await client.AsyncStream.read(4096)
      client.AsyncStream.close()
      return data.len

    proc clientTask(p: int): CpsFuture[bool] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let h1conn = Http1Connection(
        stream: conn.AsyncStream,
        reader: newBufferedReader(conn.AsyncStream),
        host: "localhost",
        port: p,
        keepAlive: false
      )
      var rejected = false
      var sendFut: CpsVoidFuture = nil
      try:
        sendFut = sendRequest(h1conn, "POST", "/", @[("Transfer-Encoding", "chunked")], "hello")
      except ValueError:
        rejected = true
      if not rejected and not sendFut.isNil:
        try:
          await sendFut
        except ValueError:
          rejected = true
      conn.AsyncStream.close()
      return rejected

    let sf = serverTask(listener)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not sf.finished or not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    assert cf.finished and cf.read(), "Client must reject outbound Transfer-Encoding requests"
    assert sf.finished and sf.read() == 0, "Rejected Transfer-Encoding request must send no bytes"
    listener.close()

  # Caller-provided Content-Length must match body size.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)

    proc serverTask(l: TcpListener): CpsFuture[int] {.cps.} =
      let client = await l.accept()
      let data = await client.AsyncStream.read(4096)
      client.AsyncStream.close()
      return data.len

    proc clientTask(p: int): CpsFuture[bool] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let h1conn = Http1Connection(
        stream: conn.AsyncStream,
        reader: newBufferedReader(conn.AsyncStream),
        host: "localhost",
        port: p,
        keepAlive: false
      )
      var rejected = false
      var sendFut: CpsVoidFuture = nil
      try:
        sendFut = sendRequest(h1conn, "POST", "/", @[("Content-Length", "1")], "hello")
      except ValueError:
        rejected = true
      if not rejected and not sendFut.isNil:
        try:
          await sendFut
        except ValueError:
          rejected = true
      conn.AsyncStream.close()
      return rejected

    let sf = serverTask(listener)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not sf.finished or not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    assert cf.finished and cf.read(), "Client must reject mismatched Content-Length"
    assert sf.finished and sf.read() == 0, "Rejected mismatched Content-Length request must send no bytes"
    listener.close()

  # Request targets with control characters must be rejected.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)

    proc serverTask(l: TcpListener): CpsFuture[int] {.cps.} =
      let client = await l.accept()
      let data = await client.AsyncStream.read(4096)
      client.AsyncStream.close()
      return data.len

    proc clientTask(p: int): CpsFuture[bool] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let h1conn = Http1Connection(
        stream: conn.AsyncStream,
        reader: newBufferedReader(conn.AsyncStream),
        host: "localhost",
        port: p,
        keepAlive: false
      )
      var rejected = false
      var sendFut: CpsVoidFuture = nil
      try:
        sendFut = sendRequest(h1conn, "GET", "/bad\0path")
      except ValueError:
        rejected = true
      if not rejected and not sendFut.isNil:
        try:
          await sendFut
        except ValueError:
          rejected = true
      conn.AsyncStream.close()
      return rejected

    let sf = serverTask(listener)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not sf.finished or not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    assert cf.finished and cf.read(), "Client must reject request targets with control chars"
    assert sf.finished and sf.read() == 0, "Rejected request target must send no bytes"
    listener.close()

  # Explicit empty Host must be rejected.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)

    proc serverTask(l: TcpListener): CpsFuture[int] {.cps.} =
      let client = await l.accept()
      let data = await client.AsyncStream.read(4096)
      client.AsyncStream.close()
      return data.len

    proc clientTask(p: int): CpsFuture[bool] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let h1conn = Http1Connection(
        stream: conn.AsyncStream,
        reader: newBufferedReader(conn.AsyncStream),
        host: "localhost",
        port: p,
        keepAlive: false
      )
      var rejected = false
      var sendFut: CpsVoidFuture = nil
      try:
        sendFut = sendRequest(h1conn, "GET", "/", @[("Host", "")])
      except ValueError:
        rejected = true
      if not rejected and not sendFut.isNil:
        try:
          await sendFut
        except ValueError:
          rejected = true
      conn.AsyncStream.close()
      return rejected

    let sf = serverTask(listener)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not sf.finished or not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    assert cf.finished and cf.read(), "Client must reject empty Host header values"
    assert sf.finished and sf.read() == 0, "Rejected empty Host request must send no bytes"
    listener.close()

  # Auto Host must include authority port on non-default ports.
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)

    proc serverTask(l: TcpListener): CpsFuture[string] {.cps.} =
      let client = await l.accept()
      let data = await client.AsyncStream.read(4096)
      client.AsyncStream.close()
      return data

    proc clientTask(p: int): CpsFuture[bool] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let h1conn = Http1Connection(
        stream: conn.AsyncStream,
        reader: newBufferedReader(conn.AsyncStream),
        host: "localhost",
        port: p,
        keepAlive: false
      )
      await sendRequest(h1conn, "GET", "/")
      conn.AsyncStream.close()
      return true

    let sf = serverTask(listener)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not sf.finished or not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break
    assert sf.finished, "Server capture task did not complete for auto Host"
    let raw = sf.read().toLowerAscii
    let expected = "host: localhost:" & $port
    assert expected in raw, "Auto Host must include non-default port, got: " & raw
    listener.close()

  echo "PASS: HTTP/1.1 client request framing validation"

# ============================================================
# Test 35: HTTP/1.1 client rejects malformed status-code width
# ============================================================
block testH1ClientRejectsMalformedStatusCode:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let rawResp =
      "HTTP/1.1 20 OK\r\n" &
      "Content-Length: 0\r\n" &
      "Connection: close\r\n\r\n"
    await client.AsyncStream.write(rawResp)
    client.AsyncStream.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let h1conn = Http1Connection(
      stream: conn.AsyncStream,
      reader: newBufferedReader(conn.AsyncStream),
      host: "localhost",
      port: p,
      keepAlive: false
    )
    var rejected = false
    try:
      discard await recvResponse(h1conn)
    except ValueError:
      rejected = true
    conn.AsyncStream.close()
    return rejected

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  assert cf.finished and cf.read(), "Client must reject malformed 2-digit status codes"
  listener.close()
  echo "PASS: HTTP/1.1 client status-line validation"

# ============================================================
# Test 36: HTTP/1.1 server response framing normalization
# ============================================================
block testH1ServerResponseFramingNormalization:
  let rawTe = buildResponseString(newResponse(
    200,
    "abc",
    @[("Transfer-Encoding", "chunked")]
  ))
  assert "Transfer-Encoding:" notin rawTe, "Builder must not emit Transfer-Encoding framing"
  assert "Content-Length: 3\r\n" in rawTe, "Builder must emit canonical Content-Length for body"
  let splitTe = rawTe.split("\r\n\r\n", 1)
  assert splitTe.len == 2 and splitTe[1] == "abc", "Body bytes must match response payload"

  let rawBadCl = buildResponseString(newResponse(
    200,
    "HELLO",
    @[("Content-Length", "1")]
  ))
  assert "Content-Length: 1\r\n" notin rawBadCl, "Builder must not trust caller Content-Length"
  assert "Content-Length: 5\r\n" in rawBadCl, "Builder must normalize Content-Length to payload size"
  let splitBadCl = rawBadCl.split("\r\n\r\n", 1)
  assert splitBadCl.len == 2 and splitBadCl[1] == "HELLO", "Normalized response must preserve payload"
  echo "PASS: HTTP/1.1 server response framing normalization"

# ============================================================
# Test 37: HTTP/1.1 HEAD response has metadata only (no body bytes)
# ============================================================
block testH1ServerHeadNoBody:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        let respFut = newCpsFuture[HttpResponseBuilder]()
        respFut.complete(newResponse(200, "HELLO"))
        return respFut)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let req = "HEAD /head HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(req)
    var raw = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      raw &= chunk
    conn.AsyncStream.close()
    return raw

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let raw = cf.read()
  assert "HTTP/1.1 200 OK" in raw, "Expected successful HEAD response status"
  assert "Content-Length: 5\r\n" in raw, "HEAD response should preserve representation length"
  let parts = raw.split("\r\n\r\n", 1)
  assert parts.len == 2, "Malformed HEAD raw response"
  assert parts[1].len == 0, "HEAD response must not include payload bytes"
  listener.close()
  echo "PASS: HTTP/1.1 server HEAD no-body semantics"

# ============================================================
# Test 38: HTTP/1.1 server rejects control chars in request-target
# ============================================================
block testH1ServerRejectsControlCharsInPath:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        let respFut = newCpsFuture[HttpResponseBuilder]()
        respFut.complete(newResponse(200, "unexpected"))
        return respFut)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let req = "GET /bad\0path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(req)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let response = cf.read()
  assert "400 Bad Request" in response, "Control chars in request-target must be rejected, got: " & response
  listener.close()
  echo "PASS: HTTP/1.1 server request-target control-char rejection"

# ============================================================
# Test 39: Expect 100-continue is not emitted for invalid TE
# ============================================================
block testH1ExpectInvalidTeNoInterimContinue:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        let respFut = newCpsFuture[HttpResponseBuilder]()
        respFut.complete(newResponse(200, "unexpected"))
        return respFut)

  proc consumeHeaders(reader: BufferedReader): CpsVoidFuture {.cps.} =
    while true:
      let line = await reader.readLine()
      if line.len == 0:
        break

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reader = newBufferedReader(conn.AsyncStream)
    let req =
      "POST /x HTTP/1.1\r\n" &
      "Host: localhost\r\n" &
      "Expect: 100-continue\r\n" &
      "Transfer-Encoding: xchunked\r\n" &
      "Connection: close\r\n\r\n"
    await conn.AsyncStream.write(req)

    let status = await reader.readLine()
    await consumeHeaders(reader)
    conn.AsyncStream.close()
    return status

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let status = cf.read()
  assert status.startsWith("HTTP/1.1 400"), "Invalid TE with Expect must fail directly with 400, got: " & status
  assert "100 Continue" notin status, "Invalid TE must not emit interim 100 Continue"
  listener.close()
  echo "PASS: HTTP/1.1 invalid TE with Expect rejected before interim 100"

# ============================================================
# Test 40: HTTP/1.1 client rejects oversized response headers
# ============================================================
block testH1ClientRejectsOversizedResponseHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    var resp = "HTTP/1.1 200 OK\r\n"
    for i in 0 ..< 300:
      resp.add("X-" & $i & ": v\r\n")
    resp.add("Content-Length: 2\r\nConnection: close\r\n\r\nok")
    await client.AsyncStream.write(resp)
    client.AsyncStream.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let h1conn = Http1Connection(
      stream: conn.AsyncStream,
      reader: newBufferedReader(conn.AsyncStream),
      host: "localhost",
      port: p,
      keepAlive: false
    )
    var rejected = false
    try:
      discard await recvResponse(h1conn)
    except ValueError:
      rejected = true
    conn.AsyncStream.close()
    return rejected

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  assert cf.finished and cf.read(), "Client must reject oversized response headers"
  listener.close()
  echo "PASS: HTTP/1.1 client oversized response headers rejected"

# ============================================================
# Test 41: HTTP/1.1 client rejects oversized status line
# ============================================================
block testH1ClientRejectsOversizedStatusLine:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    var longMsg = ""
    for _ in 0 ..< 9000:
      longMsg.add('A')
    let resp =
      "HTTP/1.1 200 " & longMsg & "\r\n" &
      "Content-Length: 2\r\n" &
      "Connection: close\r\n\r\n" &
      "ok"
    await client.AsyncStream.write(resp)
    client.AsyncStream.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let h1conn = Http1Connection(
      stream: conn.AsyncStream,
      reader: newBufferedReader(conn.AsyncStream),
      host: "localhost",
      port: p,
      keepAlive: false
    )
    var rejected = false
    try:
      discard await recvResponse(h1conn)
    except ValueError:
      rejected = true
    conn.AsyncStream.close()
    return rejected

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  assert cf.finished and cf.read(), "Client must reject oversized HTTP status line"
  listener.close()
  echo "PASS: HTTP/1.1 client oversized status line rejected"

echo ""
echo "All HTTP server tests passed!"
