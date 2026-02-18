## Python Interop Tests for Compression
##
## Validates that compression works correctly across language boundaries:
## 1. HTTP/1.1 + gzip compression ← Python urllib
## 2. SSE + gzip streaming over HTTP/1.1 ← Python urllib
## 3. WebSocket + permessage-deflate ← Python websockets
## 4. HTTP/2 + gzip compression ← Python h2 (h2c)
## 5. SSE + gzip over HTTP/2 ← Python h2 (h2c)
## 6. TLS + HTTP/1.1 + gzip compression ← Python urllib (HTTPS)
## 7. TLS + SSE + gzip ← Python urllib (HTTPS)
## 8. TLS + WSS + permessage-deflate ← Python websockets (WSS)
## 9. Python gzip HTTP/1.1 server → Nim HTTPS client (auto-decompress)
## 10. Python gzip SSE server → Nim SSE client (streaming decompress)
##
## Requires: python3 with websockets, h2, hpack packages installed.

import std/[strutils, nativesockets, osproc, os, streams as stdstreams, times]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/server/http2 as http2_server
import cps/http/server/sse
import cps/http/client/sse as sse_client
import cps/http/server/ws
import cps/tls/server as tls_server
import cps/http/client/client
import cps/http/server/router
import cps/http/shared/compression

# ============================================================
# Helpers
# ============================================================

proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = posix.getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

proc generateTestCert(): (string, string) =
  let certFile = getTempDir() / "test_compression_interop_cert.pem"
  let keyFile = getTempDir() / "test_compression_interop_key.pem"
  if not fileExists(certFile) or not fileExists(keyFile):
    let cmd = "openssl req -x509 -newkey rsa:2048 -keyout " & keyFile &
              " -out " & certFile &
              " -days 1 -nodes -subj '/CN=localhost' 2>/dev/null"
    let exitCode = execCmd(cmd)
    assert exitCode == 0, "Failed to generate test certificate"
  result = (certFile, keyFile)

proc waitForLine(p: Process, pattern: string, timeoutMs: int = 10000): string =
  let startTime = epochTime()
  var accumulated = ""
  while true:
    if epochTime() - startTime > timeoutMs.float / 1000.0:
      raise newException(system.IOError, "Timeout waiting for '" & pattern &
        "' from process. Output so far: " & accumulated)
    try:
      let line = stdstreams.readLine(p.outputStream)
      accumulated &= line & "\n"
      if pattern in line:
        return line
    except system.IOError:
      let exitCode = p.waitForExit()
      raise newException(system.IOError, "Process exited (code " & $exitCode &
        ") before '" & pattern & "'. Output: " & accumulated)

let (certFile, keyFile) = generateTestCert()

# The body text for HTTP compression tests (must be > 256 bytes for middleware)
let testBody = "Hello, World! " & repeat("This is compressed content. ", 50)

# ============================================================
# Shared Handlers
# ============================================================

proc httpHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## Simple handler returning a large text body.
  var body = "Hello, World! "
  for i in 0 ..< 50:
    body &= "This is compressed content. "
  return newResponse(200, body)

proc sseCompressHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## SSE handler with compression auto-detection via req parameter.
  let sse = await initSse(req.stream, req = req)
  await sse.sendEvent("event1", event = "msg", id = "1")
  await sse.sendEvent("event2", event = "msg", id = "2")
  await sse.sendEvent("event3", event = "msg", id = "3")
  sse.close()
  return sseResponse()

proc wsEchoHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## WebSocket echo handler (permessage-deflate negotiated via acceptWebSocket).
  let wsConn = await acceptWebSocket(req)
  while true:
    let msg = await wsConn.recvMessage()
    if msg.kind == opClose:
      break
    elif msg.kind == opText:
      await wsConn.sendText("echo:" & msg.data)
  return wsResponse()

proc combinedHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## Route to the right handler based on path.
  if req.path == "/events":
    return await sseCompressHandler(req)
  elif req.path == "/ws":
    return await wsEchoHandler(req)
  else:
    return await httpHandler(req)

# ============================================================
# Test 1: HTTP/1.1 + gzip compression ← Python urllib
# ============================================================
block testHttpGzipH1:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  # Wrap with compression middleware
  let mw = compressionMiddleware()
  let compHandler: HttpHandler = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
    mw(req, httpHandler)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    l.close()
    await handleHttp1Connection(client.AsyncStream, cfg, h)

  let pyScript = """
import urllib.request
import zlib

url = "http://127.0.0.1:""" & $port & """/"
req = urllib.request.Request(url, headers={
    "Accept-Encoding": "gzip",
    "Connection": "close"
})
resp = urllib.request.urlopen(req, timeout=5)
encoding = resp.headers.get("Content-Encoding", "")
assert encoding == "gzip", f"Expected Content-Encoding: gzip, got: {encoding!r}"

raw = resp.read()
# Manually decompress gzip
decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
data = decompressor.decompress(raw).decode("utf-8")
assert "Hello, World!" in data, f"Missing expected text in: {data[:100]}"
assert len(data) > 200, f"Response too short: {len(data)}"
assert len(raw) < len(data), f"Compressed ({len(raw)}) should be smaller than original ({len(data)})"
print("PYTHON_HTTP_GZIP_H1_OK")
"""
  let pyFile = "/tmp/test_http_gzip_h1.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, config, compHandler)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  assert pyExit == 0, "Python HTTP gzip/H1 failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_HTTP_GZIP_H1_OK" in pyOutput, "Python HTTP gzip/H1 didn't complete: " & pyOutput
  echo "PASS: HTTP/1.1 + gzip compression <- Python urllib"

# ============================================================
# Test 2: SSE + gzip streaming over HTTP/1.1 ← Python urllib
# ============================================================
block testSseGzipH1:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    l.close()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        sseCompressHandler(req))

  let pyScript = """
import urllib.request
import zlib

url = "http://127.0.0.1:""" & $port & """/events"
req = urllib.request.Request(url, headers={
    "Accept-Encoding": "gzip",
    "Connection": "close"
})
resp = urllib.request.urlopen(req, timeout=5)
encoding = resp.headers.get("Content-Encoding", "")
assert encoding == "gzip", f"Expected Content-Encoding: gzip, got: {encoding!r}"

raw = resp.read()
assert len(raw) > 0, "No data received"

# Decompress gzip stream
decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
data = decompressor.decompress(raw).decode("utf-8")

# Verify SSE events
assert "event: msg" in data, f"Missing event: msg in: {data!r}"
assert "data: event1" in data, f"Missing data: event1 in: {data!r}"
assert "data: event2" in data, f"Missing data: event2 in: {data!r}"
assert "data: event3" in data, f"Missing data: event3 in: {data!r}"
assert "id: 1" in data, f"Missing id: 1 in: {data!r}"
assert "id: 2" in data, f"Missing id: 2 in: {data!r}"
assert "id: 3" in data, f"Missing id: 3 in: {data!r}"
print("PYTHON_SSE_GZIP_H1_OK")
"""
  let pyFile = "/tmp/test_sse_gzip_h1.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, config)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  assert pyExit == 0, "Python SSE gzip/H1 failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_SSE_GZIP_H1_OK" in pyOutput, "Python SSE gzip/H1 didn't complete: " & pyOutput
  echo "PASS: SSE + gzip streaming over HTTP/1.1 <- Python urllib"

# ============================================================
# Test 3: WebSocket + permessage-deflate ← Python websockets
# ============================================================
block testWsDeflateH1:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    l.close()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        wsEchoHandler(req))

  let pyScript = """
import asyncio
import websockets

async def main():
    uri = "ws://127.0.0.1:""" & $port & """/ws"
    # websockets enables permessage-deflate by default
    async with websockets.connect(uri, compression="deflate") as ws:
        await ws.send("hello compressed")
        resp = await ws.recv()
        assert resp == "echo:hello compressed", f"Got: {resp}"

        await ws.send("second compressed")
        resp2 = await ws.recv()
        assert resp2 == "echo:second compressed", f"Got: {resp2}"

        # Send a larger message to verify compression works on bigger payloads
        big_msg = "x" * 1000
        await ws.send(big_msg)
        resp3 = await ws.recv()
        assert resp3 == "echo:" + big_msg, f"Large msg mismatch, len={len(resp3)}"

        await ws.close()
    print("PYTHON_WS_DEFLATE_H1_OK")

asyncio.run(main())
"""
  let pyFile = "/tmp/test_ws_deflate_h1.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, config)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  assert pyExit == 0, "Python WS deflate/H1 failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_WS_DEFLATE_H1_OK" in pyOutput, "Python WS deflate/H1 didn't complete: " & pyOutput
  echo "PASS: WebSocket + permessage-deflate <- Python websockets"

# ============================================================
# Test 4: HTTP/2 + gzip compression ← Python h2 (h2c)
# ============================================================
block testHttpGzipH2:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  # Wrap with compression middleware
  let mw = compressionMiddleware()
  let compHandler: HttpHandler = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
    mw(req, httpHandler)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    l.close()
    await handleHttp2Connection(client.AsyncStream, cfg, h)

  let pyScript = """
import socket
import zlib
import h2.connection
import h2.config
import h2.events

def test_http_gzip_h2():
    sock = socket.create_connection(("127.0.0.1", """ & $port & """))

    config = h2.config.H2Configuration(client_side=True, header_encoding='utf-8')
    conn = h2.connection.H2Connection(config=config)
    conn.initiate_connection()
    sock.sendall(conn.data_to_send())

    conn.send_headers(
        stream_id=1,
        headers=[
            (":method", "GET"),
            (":path", "/"),
            (":scheme", "http"),
            (":authority", "localhost"),
            ("accept-encoding", "gzip"),
        ],
        end_stream=True,
    )
    sock.sendall(conn.data_to_send())

    response_headers = None
    response_data = b""
    stream_ended = False

    while not stream_ended:
        data = sock.recv(65535)
        if not data:
            break
        events = conn.receive_data(data)
        for event in events:
            if isinstance(event, h2.events.ResponseReceived):
                response_headers = {k: v for k, v in event.headers}
            elif isinstance(event, h2.events.DataReceived):
                response_data += event.data
                conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
            elif isinstance(event, h2.events.StreamEnded):
                stream_ended = True
        sock.sendall(conn.data_to_send())

    sock.close()

    assert response_headers is not None, "No response headers"
    status = response_headers.get(":status", "")
    assert status == "200", f"Expected 200, got {status}"

    ce = response_headers.get("content-encoding", "")
    assert ce == "gzip", f"Expected content-encoding: gzip, got: {ce}"

    # Decompress
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    body = decompressor.decompress(response_data).decode("utf-8")
    assert "Hello, World!" in body, f"Missing text in: {body[:100]}"
    assert len(response_data) < len(body), f"Compressed ({len(response_data)}) should be smaller than original ({len(body)})"
    print("PYTHON_HTTP_GZIP_H2_OK")

test_http_gzip_h2()
"""
  let pyFile = "/tmp/test_http_gzip_h2.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, config, compHandler)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  assert pyExit == 0, "Python HTTP gzip/H2 failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_HTTP_GZIP_H2_OK" in pyOutput, "Python HTTP gzip/H2 didn't complete: " & pyOutput
  echo "PASS: HTTP/2 + gzip compression <- Python h2 (h2c)"

# ============================================================
# Test 5: SSE + gzip over HTTP/2 ← Python h2 (h2c)
# ============================================================
block testSseGzipH2:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    l.close()
    await handleHttp2Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        sseCompressHandler(req))

  let pyScript = """
import socket
import zlib
import h2.connection
import h2.config
import h2.events

def test_sse_gzip_h2():
    sock = socket.create_connection(("127.0.0.1", """ & $port & """))

    config = h2.config.H2Configuration(client_side=True, header_encoding='utf-8')
    conn = h2.connection.H2Connection(config=config)
    conn.initiate_connection()
    sock.sendall(conn.data_to_send())

    conn.send_headers(
        stream_id=1,
        headers=[
            (":method", "GET"),
            (":path", "/events"),
            (":scheme", "http"),
            (":authority", "localhost"),
            ("accept-encoding", "gzip"),
        ],
        end_stream=True,
    )
    sock.sendall(conn.data_to_send())

    response_headers = None
    response_data = b""
    stream_ended = False

    while not stream_ended:
        data = sock.recv(65535)
        if not data:
            break
        events = conn.receive_data(data)
        for event in events:
            if isinstance(event, h2.events.ResponseReceived):
                response_headers = {k: v for k, v in event.headers}
            elif isinstance(event, h2.events.DataReceived):
                response_data += event.data
                conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
            elif isinstance(event, h2.events.StreamEnded):
                stream_ended = True
        sock.sendall(conn.data_to_send())

    sock.close()

    assert response_headers is not None, "No response headers"
    status = response_headers.get(":status", "")
    assert status == "200", f"Expected 200, got {status}"

    ct = response_headers.get("content-type", "")
    assert "text/event-stream" in ct, f"Expected text/event-stream, got: {ct}"

    ce = response_headers.get("content-encoding", "")
    assert ce == "gzip", f"Expected content-encoding: gzip, got: {ce}"

    # Decompress
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    body = decompressor.decompress(response_data).decode("utf-8")
    assert "event: msg" in body, f"Missing event: msg in: {body!r}"
    assert "data: event1" in body, f"Missing data: event1 in: {body!r}"
    assert "data: event2" in body, f"Missing data: event2 in: {body!r}"
    assert "data: event3" in body, f"Missing data: event3 in: {body!r}"
    print("PYTHON_SSE_GZIP_H2_OK")

test_sse_gzip_h2()
"""
  let pyFile = "/tmp/test_sse_gzip_h2.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, config)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  assert pyExit == 0, "Python SSE gzip/H2 failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_SSE_GZIP_H2_OK" in pyOutput, "Python SSE gzip/H2 didn't complete: " & pyOutput
  echo "PASS: SSE + gzip over HTTP/2 <- Python h2 (h2c)"

# ============================================================
# Test 6: TLS + HTTP/1.1 + gzip compression ← Python urllib
# ============================================================
block testHttpGzipTls:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig(useTls: true, certFile: certFile, keyFile: keyFile)
  let tlsCtx = newTlsServerContext(certFile, keyFile, @["http/1.1"])

  let mw = compressionMiddleware()
  let compHandler: HttpHandler = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
    mw(req, httpHandler)

  proc serverTask(l: TcpListener, ctx: TlsServerContext,
                  cfg: HttpServerConfig, h: HttpHandler): CpsVoidFuture {.cps.} =
    let tcpClient = await l.accept()
    l.close()
    let tlsStream = await tlsAccept(ctx, tcpClient)
    await handleHttp1Connection(tlsStream.AsyncStream, cfg, h)

  let pyScript = """
import urllib.request
import ssl
import zlib

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

url = "https://127.0.0.1:""" & $port & """/"
req = urllib.request.Request(url, headers={
    "Accept-Encoding": "gzip",
    "Connection": "close"
})
resp = urllib.request.urlopen(req, context=ctx, timeout=5)
encoding = resp.headers.get("Content-Encoding", "")
assert encoding == "gzip", f"Expected Content-Encoding: gzip, got: {encoding!r}"

raw = resp.read()
decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
data = decompressor.decompress(raw).decode("utf-8")
assert "Hello, World!" in data, f"Missing expected text"
assert len(raw) < len(data), f"Compression didn't work: {len(raw)} >= {len(data)}"
print("PYTHON_HTTP_GZIP_TLS_OK")
"""
  let pyFile = "/tmp/test_http_gzip_tls.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, tlsCtx, config, compHandler)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  closeTlsServerContext(tlsCtx)
  assert pyExit == 0, "Python HTTP gzip/TLS failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_HTTP_GZIP_TLS_OK" in pyOutput, "Python HTTP gzip/TLS didn't complete: " & pyOutput
  echo "PASS: TLS + HTTP/1.1 + gzip compression <- Python urllib"

# ============================================================
# Test 7: TLS + SSE + gzip ← Python urllib (HTTPS)
# ============================================================
block testSseGzipTls:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig(useTls: true, certFile: certFile, keyFile: keyFile)
  let tlsCtx = newTlsServerContext(certFile, keyFile, @["http/1.1"])

  proc serverTask(l: TcpListener, ctx: TlsServerContext,
                  cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let tcpClient = await l.accept()
    l.close()
    let tlsStream = await tlsAccept(ctx, tcpClient)
    await handleHttp1Connection(tlsStream.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        sseCompressHandler(req))

  let pyScript = """
import urllib.request
import ssl
import zlib

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

url = "https://127.0.0.1:""" & $port & """/events"
req = urllib.request.Request(url, headers={
    "Accept-Encoding": "gzip",
    "Accept": "text/event-stream",
    "Connection": "close"
})
resp = urllib.request.urlopen(req, context=ctx, timeout=5)
encoding = resp.headers.get("Content-Encoding", "")
assert encoding == "gzip", f"Expected Content-Encoding: gzip, got: {encoding!r}"

raw = resp.read()
decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
data = decompressor.decompress(raw).decode("utf-8")

assert "event: msg" in data, f"Missing event: msg in: {data!r}"
assert "data: event1" in data, f"Missing data: event1 in: {data!r}"
assert "data: event2" in data, f"Missing data: event2"
assert "data: event3" in data, f"Missing data: event3"
assert "id: 1" in data, f"Missing id: 1"
print("PYTHON_SSE_GZIP_TLS_OK")
"""
  let pyFile = "/tmp/test_sse_gzip_tls.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, tlsCtx, config)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  closeTlsServerContext(tlsCtx)
  assert pyExit == 0, "Python SSE gzip/TLS failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_SSE_GZIP_TLS_OK" in pyOutput, "Python SSE gzip/TLS didn't complete: " & pyOutput
  echo "PASS: TLS + SSE + gzip <- Python urllib"

# ============================================================
# Test 8: TLS + WSS + permessage-deflate ← Python websockets
# ============================================================
block testWssDeflateTls:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig(useTls: true, certFile: certFile, keyFile: keyFile)
  let tlsCtx = newTlsServerContext(certFile, keyFile, @["http/1.1"])

  proc serverTask(l: TcpListener, ctx: TlsServerContext,
                  cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let tcpClient = await l.accept()
    l.close()
    let tlsStream = await tlsAccept(ctx, tcpClient)
    await handleHttp1Connection(tlsStream.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        wsEchoHandler(req))

  let pyScript = """
import asyncio
import ssl
import websockets

async def main():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    uri = "wss://127.0.0.1:""" & $port & """/ws"
    async with websockets.connect(uri, ssl=ctx, compression="deflate") as ws:
        await ws.send("hello tls compressed")
        resp = await ws.recv()
        assert resp == "echo:hello tls compressed", f"Got: {resp}"

        await ws.send("second tls compressed")
        resp2 = await ws.recv()
        assert resp2 == "echo:second tls compressed", f"Got: {resp2}"

        await ws.close()
    print("PYTHON_WSS_DEFLATE_TLS_OK")

asyncio.run(main())
"""
  let pyFile = "/tmp/test_wss_deflate_tls.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, tlsCtx, config)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  closeTlsServerContext(tlsCtx)
  assert pyExit == 0, "Python WSS deflate/TLS failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_WSS_DEFLATE_TLS_OK" in pyOutput, "Python WSS deflate/TLS didn't complete: " & pyOutput
  echo "PASS: TLS + WSS + permessage-deflate <- Python websockets"

# ============================================================
# Test 9: Python gzip HTTP/1.1 server → Nim HTTPS client
# ============================================================
block testNimClientAutoDecompress:
  let pyScript = """
import http.server
import ssl
import sys
import socket
import gzip

class GzipHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ae = self.headers.get("Accept-Encoding", "")
        body_text = "Hello from Python! " + "Compressed content. " * 50
        if "gzip" in ae:
            compressed = gzip.compress(body_text.encode("utf-8"))
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(compressed)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(compressed)
        else:
            encoded = body_text.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(encoded)

    def log_message(self, format, *args):
        pass

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.listen(1)

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('""" & certFile & """', '""" & keyFile & """')
ssock = ctx.wrap_socket(sock, server_side=True)

server = http.server.HTTPServer(("127.0.0.1", port), GzipHandler, bind_and_activate=False)
server.socket = ssock

print(f"PORT:{port}", flush=True)
server.handle_request()
server.server_close()
"""
  let pyFile = "/tmp/test_gzip_http_server.py"
  writeFile(pyFile, pyScript)

  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let portLine = waitForLine(pyProcess, "PORT:")
  let port = parseInt(portLine.split("PORT:")[1].strip())

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let httpsClient = newHttpsClient()
    let resp = await httpsClient.get("https://127.0.0.1:" & $p & "/")
    return resp.body

  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  discard pyProcess.waitForExit()
  pyProcess.close()

  assert not cf.hasError(), "Nim HTTPS client failed: " & (if cf.hasError(): cf.getError().msg else: "")
  let body = cf.read()
  assert "Hello from Python!" in body, "Missing expected text in: " & body[0 .. min(body.len - 1, 100)]
  assert body.len > 200, "Response too short: " & $body.len
  echo "PASS: Python gzip HTTP/1.1 server -> Nim HTTPS client (auto-decompress)"

# ============================================================
# Test 10: Python gzip SSE server → Nim SSE client
# ============================================================
block testNimSseClientDecompress:
  let pyScript = """
import http.server
import socket
import zlib
import struct

class GzipSSEHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ae = self.headers.get("Accept-Encoding", "")
        if "gzip" not in ae:
            # Plain SSE
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"event: msg\ndata: event1\nid: 1\n\n")
            self.wfile.write(b"event: msg\ndata: event2\nid: 2\n\n")
            self.wfile.write(b"event: msg\ndata: event3\nid: 3\n\n")
            self.wfile.flush()
            return

        # Compressed SSE: use zlib with Z_SYNC_FLUSH per event
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Encoding", "gzip")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        compressor = zlib.compressobj(zlib.Z_DEFAULT_COMPRESSION,
                                       zlib.DEFLATED,
                                       16 + zlib.MAX_WBITS)  # gzip

        events = [
            b"event: msg\ndata: event1\nid: 1\n\n",
            b"event: msg\ndata: event2\nid: 2\n\n",
            b"event: msg\ndata: event3\nid: 3\n\n",
        ]
        for evt in events:
            chunk = compressor.compress(evt)
            chunk += compressor.flush(zlib.Z_SYNC_FLUSH)
            self.wfile.write(chunk)
            self.wfile.flush()

        # Finalize
        final = compressor.flush(zlib.Z_FINISH)
        self.wfile.write(final)
        self.wfile.flush()

    def log_message(self, format, *args):
        pass

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.listen(1)

server = http.server.HTTPServer(("127.0.0.1", port), GzipSSEHandler, bind_and_activate=False)
server.socket = sock

print(f"PORT:{port}", flush=True)
server.handle_request()
server.server_close()
"""
  let pyFile = "/tmp/test_gzip_sse_server.py"
  writeFile(pyFile, pyScript)

  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let portLine = waitForLine(pyProcess, "PORT:")
  let port = parseInt(portLine.split("PORT:")[1].strip())

  proc clientTask(p: int): CpsFuture[seq[SseEvent]] {.cps.} =
    let client = await connectSse("127.0.0.1", p, "/events",
                                   enableCompression = true)
    var events: seq[SseEvent]
    for i in 0 ..< 3:
      let ev = await client.readEvent()
      events.add ev
    return events

  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  discard pyProcess.waitForExit()
  pyProcess.close()

  assert not cf.hasError(), "Nim SSE client failed: " & (if cf.hasError(): cf.getError().msg else: "")
  let events = cf.read()
  assert events.len == 3, "Expected 3 events, got " & $events.len
  assert events[0].eventType == "msg", "Event 0 type: " & events[0].eventType
  assert events[0].data == "event1", "Event 0 data: " & events[0].data
  assert events[0].id == "1", "Event 0 id: " & events[0].id
  assert events[1].data == "event2", "Event 1 data: " & events[1].data
  assert events[2].data == "event3", "Event 2 data: " & events[2].data
  echo "PASS: Python gzip SSE server -> Nim SSE client (streaming decompress)"

echo ""
echo "All Python compression interop tests passed!"
