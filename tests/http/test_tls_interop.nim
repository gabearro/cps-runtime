## TLS Interop Tests
##
## Validates TLS (HTTPS/WSS) interoperability between Nim and Python:
## 1. Nim TLS SSE server ← Python HTTPS client
## 2. Nim TLS WSS server ← Python WSS client
## 3. Python TLS SSE server → Nim SSE client
## 4. Python TLS WSS server → Nim WSS client
##
## Requires: python3 with websockets package installed.
## Uses self-signed certs (no verification on either side).

import std/[strutils, nativesockets, osproc, os, streams as stdstreams, times]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/server/sse
import cps/http/client/sse as sse_client
import cps/http/server/ws
import cps/http/client/ws as client_ws
import cps/tls/server as tls_server

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
  ## Generate a self-signed cert + key for testing. Returns (certFile, keyFile).
  let certFile = getTempDir() / "test_tls_interop_cert.pem"
  let keyFile = getTempDir() / "test_tls_interop_key.pem"
  if not fileExists(certFile) or not fileExists(keyFile):
    let cmd = "openssl req -x509 -newkey rsa:2048 -keyout " & keyFile &
              " -out " & certFile &
              " -days 1 -nodes -subj '/CN=localhost' 2>/dev/null"
    let exitCode = execCmd(cmd)
    assert exitCode == 0, "Failed to generate test certificate"
  result = (certFile, keyFile)

proc waitForLine(p: Process, pattern: string, timeoutMs: int = 10000): string =
  ## Read lines from process stdout until one contains `pattern`.
  ## Returns the matching line. Raises on timeout or process exit.
  let startTime = epochTime()
  var accumulated = ""
  while true:
    if epochTime() - startTime > timeoutMs.float / 1000.0:
      raise newException(system.IOError, "Timeout waiting for '" & pattern &
        "' from process. Output so far: " & accumulated)
    # Try to read a line; if the stream is at end, check exit code
    try:
      let line = stdstreams.readLine(p.outputStream)
      accumulated &= line & "\n"
      if pattern in line:
        return line
    except system.IOError:
      # Stream closed — process likely exited
      let exitCode = p.waitForExit()
      raise newException(system.IOError, "Process exited (code " & $exitCode &
        ") before '" & pattern & "'. Output: " & accumulated)

let (certFile, keyFile) = generateTestCert()

# ============================================================
# Test 1: Nim TLS SSE server ← Python HTTPS client
# ============================================================
block testNimTlsSseServer:
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
        proc inner(r: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
          let sseWriter = await initSse(r.stream)
          await sseWriter.sendEvent("hello", event = "greeting", id = "1")
          await sseWriter.sendEvent("world", event = "greeting", id = "2")
          await sseWriter.sendEvent("done", id = "3")
          return sseResponse()
        inner(req))

  let pyScript = """
import urllib.request
import ssl

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

url = "https://127.0.0.1:""" & $port & """/events"
req = urllib.request.Request(url, headers={"Accept": "text/event-stream", "Connection": "close"})
resp = urllib.request.urlopen(req, context=ctx, timeout=5)
data = resp.read().decode("utf-8")

assert "event: greeting" in data, f"Missing event: greeting in: {data!r}"
assert "id: 1" in data, f"Missing id: 1 in: {data!r}"
assert "data: hello" in data, f"Missing data: hello in: {data!r}"
assert "data: world" in data, f"Missing data: world in: {data!r}"
assert "data: done" in data, f"Missing data: done in: {data!r}"
print("PYTHON_TLS_SSE_OK")
"""
  let pyFile = "/tmp/test_tls_sse_client.py"
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
  assert pyExit == 0, "Python TLS SSE client failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_TLS_SSE_OK" in pyOutput, "Python TLS SSE client didn't complete: " & pyOutput
  echo "PASS: Nim TLS SSE server <- Python HTTPS client"

# ============================================================
# Test 2: Nim TLS WSS server ← Python WSS client
# ============================================================
block testNimTlsWssServer:
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
        proc inner(r: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
          let wsConn = await acceptWebSocket(r)
          while true:
            let msg = await wsConn.recvMessage()
            if msg.kind == opClose:
              break
            elif msg.kind == opText:
              await wsConn.sendText("echo:" & msg.data)
          return wsResponse()
        inner(req))

  let pyScript = """
import asyncio
import ssl
import websockets

async def main():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    uri = "wss://127.0.0.1:""" & $port & """/ws"
    async with websockets.connect(uri, ssl=ctx) as ws:
        await ws.send("hello from python tls")
        resp = await ws.recv()
        assert resp == "echo:hello from python tls", f"Got: {resp}"
        await ws.send("second tls")
        resp2 = await ws.recv()
        assert resp2 == "echo:second tls", f"Got: {resp2}"
        await ws.close()
    print("PYTHON_TLS_WS_OK")

asyncio.run(main())
"""
  let pyFile = "/tmp/test_tls_ws_client.py"
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
  assert pyExit == 0, "Python TLS WS client failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_TLS_WS_OK" in pyOutput, "Python TLS WS client didn't complete: " & pyOutput
  echo "PASS: Nim TLS WSS server <- Python WSS client"

# ============================================================
# Test 3: Python TLS SSE server → Nim SSE client
# ============================================================
block testPythonTlsSseServer:
  let pyScript = """
import http.server
import ssl
import sys
import socket

class SSEHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(b"event: greeting\ndata: hello\nid: 1\n\n")
        self.wfile.write(b"event: greeting\ndata: world\nid: 2\n\n")
        self.wfile.write(b"data: done\nid: 3\n\n")
        self.wfile.flush()

    def log_message(self, format, *args):
        pass  # Suppress access logs

# Bind to random port, then create server with bind_and_activate=False
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.listen(1)

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('""" & certFile & """', '""" & keyFile & """')
ssock = ctx.wrap_socket(sock, server_side=True)

server = http.server.HTTPServer(("127.0.0.1", port), SSEHandler, bind_and_activate=False)
server.socket = ssock

print(f"PORT:{port}", flush=True)
server.handle_request()
server.server_close()
"""
  let pyFile = "/tmp/test_tls_sse_server.py"
  writeFile(pyFile, pyScript)

  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  # Wait for Python to print port
  let portLine = waitForLine(pyProcess, "PORT:")
  let port = parseInt(portLine.split("PORT:")[1].strip())

  proc clientTask(p: int): CpsFuture[seq[SseEvent]] {.cps.} =
    let client = await connectSse("127.0.0.1", p, "/events", useTls = true)
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
  assert events[0].eventType == "greeting", "Event 0 type: " & events[0].eventType
  assert events[0].data == "hello", "Event 0 data: " & events[0].data
  assert events[0].id == "1", "Event 0 id: " & events[0].id
  assert events[1].eventType == "greeting", "Event 1 type: " & events[1].eventType
  assert events[1].data == "world", "Event 1 data: " & events[1].data
  assert events[1].id == "2", "Event 1 id: " & events[1].id
  assert events[2].data == "done", "Event 2 data: " & events[2].data
  assert events[2].id == "3", "Event 2 id: " & events[2].id
  echo "PASS: Python TLS SSE server -> Nim SSE client"

# ============================================================
# Test 4: Python TLS WSS server → Nim WSS client
# ============================================================
block testPythonTlsWssServer:
  let pyScript = """
import asyncio
import ssl
import websockets
import sys
import socket

async def handler(ws):
    async for msg in ws:
        await ws.send("echo:" + msg)

async def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain('""" & certFile & """', '""" & keyFile & """')

    # Bind to random port
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()

    async with websockets.serve(handler, "127.0.0.1", port, ssl=ctx) as server:
        print(f"PORT:{port}", flush=True)
        # Serve until stdin is closed or timeout
        await asyncio.sleep(10)

asyncio.run(main())
"""
  let pyFile = "/tmp/test_tls_wss_server.py"
  writeFile(pyFile, pyScript)

  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  # Wait for Python to print port
  let portLine = waitForLine(pyProcess, "PORT:")
  let port = parseInt(portLine.split("PORT:")[1].strip())

  proc clientTask(p: int): CpsFuture[seq[string]] {.cps.} =
    let ws = await wssConnect("127.0.0.1", p, "/")
    var responses: seq[string]

    await ws.sendText("hello from nim tls")
    let msg1 = await ws.recvMessage()
    responses.add msg1.data

    await ws.sendText("second msg")
    let msg2 = await ws.recvMessage()
    responses.add msg2.data

    await ws.sendClose()
    return responses

  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  pyProcess.kill()
  discard pyProcess.waitForExit()
  pyProcess.close()

  assert not cf.hasError(), "Nim WSS client failed: " & (if cf.hasError(): cf.getError().msg else: "")
  let responses = cf.read()
  assert responses.len == 2, "Expected 2 responses, got " & $responses.len
  assert responses[0] == "echo:hello from nim tls", "Response 0: " & responses[0]
  assert responses[1] == "echo:second msg", "Response 1: " & responses[1]
  echo "PASS: Python TLS WSS server -> Nim WSS client"

echo ""
echo "All TLS interop tests passed!"
