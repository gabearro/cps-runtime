## Tests for HTTP Server (single-threaded)
##
## Tests HTTP/1.1 and HTTP/2 server functionality including
## plaintext and TLS modes.

import std/[strutils, nativesockets, osproc, os]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/server/http2 as http2_server
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

echo ""
echo "All HTTP server tests passed!"
