## Tests for HTTP Server (multi-threaded)
##
## Verifies that the HTTP server works correctly on the MT runtime
## with work-stealing scheduler and blocking pool.
##
## NOTE: Must be compiled with --mm:atomicArc

import std/[strutils, nativesockets, osproc, os]
from std/posix import Sockaddr_in, SockLen
import cps/mt
import cps/transform
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
  return newResponse(200, req.body, @[("X-Method", req.meth)])

proc helloHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  return newResponse(200, "Hello, MT World!")

proc generateTestCert(): (string, string) =
  let certFile = getTempDir() / "test_server_cert.pem"
  let keyFile = getTempDir() / "test_server_key.pem"
  if not fileExists(certFile) or not fileExists(keyFile):
    let cmd = "openssl req -x509 -newkey rsa:2048 -keyout " & keyFile &
              " -out " & certFile &
              " -days 1 -nodes -subj '/CN=localhost' 2>/dev/null"
    let exitCode = execCmd(cmd)
    assert exitCode == 0, "Failed to generate test certificate"
  result = (certFile, keyFile)

# Initialize OpenSSL before creating worker threads.
# This avoids potential thread-safety issues during SSL init.
import std/openssl
SSL_library_init()
SSL_load_error_strings()

let loop = initMtRuntime(numWorkers = 2)

# ============================================================
# Test 1: MT HTTP/1.1 plaintext
# ============================================================
block testMtH1Plaintext:
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
    let reqStr = "GET /mt-test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
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
  while not cf.finished:
    loop.tick()

  let response = cf.read()
  assert "200 OK" in response, "Expected 200 OK, got: " & response
  assert "Hello, MT World!" in response
  listener.close()
  echo "PASS: MT HTTP/1.1 plaintext"

# ============================================================
# Test 2: MT TLS HTTP/1.1
# ============================================================
block testMtTlsH1:
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
    await sendRequest(h1conn, "GET", "/mt-tls",
                      @[("Connection", "close")])
    let resp = await recvResponse(h1conn)
    tlsStream.AsyncStream.close()
    return $resp.statusCode & ":" & resp.body

  let sf = serverTask(listener, tlsCtx, config)
  let cf = clientTask(port)
  while not cf.finished or not sf.finished:
    loop.tick()

  assert not cf.hasError(), "Client TLS failed: " & cf.getError().msg
  let result = cf.read()
  assert result.startsWith("200:"), "Expected 200, got: " & result
  assert "Hello, MT World!" in result
  listener.close()
  closeTlsServerContext(tlsCtx)
  echo "PASS: MT TLS HTTP/1.1"

# ============================================================
# Test 3: MT TLS HTTP/2
# ============================================================
block testMtTlsH2:
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

    if tlsStream.alpnProto != "h2":
      return "ALPN: " & tlsStream.alpnProto

    let h2conn = newHttp2Connection(tlsStream.AsyncStream)
    await initConnection(h2conn)
    discard runReceiveLoop(h2conn)
    let resp = await http2.request(h2conn, "GET", "/mt-h2", "localhost")
    return $resp.statusCode & ":" & resp.body

  let sf = serverTask(listener, tlsCtx, config)
  let cf = clientTask(port)
  while not cf.finished:
    loop.tick()

  let result = cf.read()
  assert result.startsWith("200:"), "Expected 200, got: " & result
  assert "Hello, MT World!" in result
  listener.close()
  closeTlsServerContext(tlsCtx)
  echo "PASS: MT TLS HTTP/2"

# ============================================================
# Test 4: MT handler with spawnBlocking
# ============================================================
block testMtSpawnBlocking:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc blockingUppercase(input: string): CpsFuture[string] =
    let inputCopy = input
    spawnBlocking(proc(): string {.gcsafe.} =
      var s = ""
      for c in inputCopy:
        s.add c.toUpperAscii()
      return s
    )

  proc blockingHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let upper = await blockingUppercase(req.body)
    return newResponse(200, upper)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        blockingHandler(req))

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let body = "hello blocking"
    let reqStr = "POST /blocking HTTP/1.1\r\nHost: localhost\r\nContent-Length: " &
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
  while not cf.finished:
    loop.tick()

  let response = cf.read()
  assert "200 OK" in response, "Expected 200 OK"
  assert "HELLO BLOCKING" in response, "Expected uppercase body, got: " & response
  listener.close()
  echo "PASS: MT handler with spawnBlocking"

# ============================================================
# Test 5: MT concurrent clients
# ============================================================
block testMtConcurrent:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()
  let numClients = 5

  proc acceptLoop(l: TcpListener, cfg: HttpServerConfig, n: int): CpsVoidFuture {.cps.} =
    for i in 0 ..< n:
      let client = await l.accept()
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

  var allDone = false
  var ticks = 0
  while not allDone and ticks < 2000:
    loop.tick()
    inc ticks
    allDone = true
    for i in 0 ..< clientFuts.len:
      if not clientFuts[i].finished:
        allDone = false
        break

  var successCount = 0
  for i in 0 ..< clientFuts.len:
    if clientFuts[i].finished and not clientFuts[i].hasError():
      let resp = clientFuts[i].read()
      if "200 OK" in resp and "Hello, MT World!" in resp:
        inc successCount

  assert successCount == numClients, "Expected " & $numClients & " successful, got " & $successCount
  listener.close()
  echo "PASS: MT concurrent clients (" & $numClients & " clients)"

loop.shutdownMtRuntime()

echo ""
echo "All MT HTTP server tests passed!"
