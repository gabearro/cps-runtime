## Tests for Server-Sent Events (SSE)
##
## Tests SSE streaming over HTTP/1.1 connections using both the
## low-level SseWriter API and the DSL `sse` route type.

import std/[strutils, nativesockets, tables]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/server/router
import cps/http/server/dsl
import cps/http/server/sse

# ============================================================
# Helpers
# ============================================================

proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = posix.getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

proc sendRawRequest(p: int, reqStr: string): CpsFuture[string] {.cps.} =
  ## Send a raw HTTP/1.1 request and read the full response (until EOF).
  let conn = await tcpConnect("127.0.0.1", p)
  await conn.AsyncStream.write(reqStr)
  var response = ""
  while true:
    let chunk = await conn.AsyncStream.read(4096)
    if chunk.len == 0:
      break
    response &= chunk
  conn.AsyncStream.close()
  return response

proc runServerClient(listener: TcpListener, handler: HttpHandler,
                     reqStr: string): string =
  ## Spin up a server accepting one connection, send a request, return response.
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, h)

  let sf = serverTask(listener, config, handler)
  let cf = sendRawRequest(port, reqStr)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  result = cf.read()

proc extractHeaders(response: string): string =
  ## Extract the header section (before first \r\n\r\n).
  let idx = response.find("\r\n\r\n")
  if idx >= 0:
    return response[0 ..< idx]
  return response

proc extractSseBody(response: string): string =
  ## Extract the SSE body (after first \r\n\r\n).
  let idx = response.find("\r\n\r\n")
  if idx >= 0:
    return response[idx + 4 .. ^1]
  return ""

proc extractHeader(response: string, name: string): string =
  let headerEnd = response.find("\r\n\r\n")
  let headerSection = if headerEnd >= 0: response[0 ..< headerEnd] else: response
  for line in headerSection.split("\r\n"):
    let colonIdx = line.find(':')
    if colonIdx > 0:
      let key = line[0 ..< colonIdx].strip()
      if key.toLowerAscii == name.toLowerAscii:
        return line[colonIdx + 1 .. ^1].strip()
  return ""

# ============================================================
# Test 1: Basic SSE stream
# ============================================================
block testBasicSse:
  let listener = tcpListen("127.0.0.1", 0)

  proc sseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream)
    await sse.sendEvent("hello")
    await sse.sendEvent("world")
    await sse.sendEvent("done")
    return sseResponse()

  let response = runServerClient(listener, sseHandler,
    "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert "text/event-stream" in extractHeader(response, "Content-Type"),
    "Expected text/event-stream, got: " & extractHeader(response, "Content-Type")
  assert "no-cache" in extractHeader(response, "Cache-Control"),
    "Expected no-cache"

  let body = extractSseBody(response)
  assert "data: hello\n" in body, "Missing data: hello in body: " & body
  assert "data: world\n" in body, "Missing data: world"
  assert "data: done\n" in body, "Missing data: done"
  listener.close()
  echo "PASS: Basic SSE stream"

# ============================================================
# Test 2: Named events with IDs
# ============================================================
block testNamedEventsWithIds:
  let listener = tcpListen("127.0.0.1", 0)

  proc sseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream)
    await sse.sendEvent("user joined", event="join", id="1")
    await sse.sendEvent("message sent", event="msg", id="2")
    return sseResponse()

  let response = runServerClient(listener, sseHandler,
    "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  let body = extractSseBody(response)
  assert "event: join\n" in body, "Missing event: join"
  assert "id: 1\n" in body, "Missing id: 1"
  assert "data: user joined\n" in body, "Missing data: user joined"
  assert "event: msg\n" in body, "Missing event: msg"
  assert "id: 2\n" in body, "Missing id: 2"
  assert "data: message sent\n" in body, "Missing data: message sent"
  listener.close()
  echo "PASS: Named events with IDs"

# ============================================================
# Test 3: SSE comments
# ============================================================
block testSseComments:
  let listener = tcpListen("127.0.0.1", 0)

  proc sseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream)
    await sse.sendComment("keep-alive")
    await sse.sendEvent("data")
    return sseResponse()

  let response = runServerClient(listener, sseHandler,
    "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  let body = extractSseBody(response)
  assert ": keep-alive\n\n" in body, "Missing comment in body: " & repr(body)
  assert "data: data\n" in body, "Missing data"
  listener.close()
  echo "PASS: SSE comments"

# ============================================================
# Test 4: Retry field
# ============================================================
block testRetryField:
  let listener = tcpListen("127.0.0.1", 0)

  proc sseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream)
    await sse.sendEvent("reconnect", retry=5000)
    return sseResponse()

  let response = runServerClient(listener, sseHandler,
    "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  let body = extractSseBody(response)
  assert "retry: 5000\n" in body, "Missing retry: 5000 in body: " & repr(body)
  assert "data: reconnect\n" in body, "Missing data"
  listener.close()
  echo "PASS: Retry field"

# ============================================================
# Test 5: Multi-line data
# ============================================================
block testMultiLineData:
  let listener = tcpListen("127.0.0.1", 0)

  proc sseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream)
    await sse.sendEvent("line1\nline2\nline3")
    return sseResponse()

  let response = runServerClient(listener, sseHandler,
    "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  let body = extractSseBody(response)
  assert "data: line1\n" in body, "Missing data: line1"
  assert "data: line2\n" in body, "Missing data: line2"
  assert "data: line3\n" in body, "Missing data: line3"
  listener.close()
  echo "PASS: Multi-line data"

# ============================================================
# Test 6: DSL sse route
# ============================================================
block testDslSseRoute:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    sse "/events":
      await sendEvent("hello")
      await sendEvent("world", event="greeting")

  let response = runServerClient(listener, handler,
    "GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert "text/event-stream" in extractHeader(response, "Content-Type"),
    "Expected text/event-stream"
  let body = extractSseBody(response)
  assert "data: hello\n" in body, "Missing data: hello"
  assert "event: greeting\n" in body, "Missing event: greeting"
  assert "data: world\n" in body, "Missing data: world"
  listener.close()
  echo "PASS: DSL sse route"

# ============================================================
# Test 7: DSL lastEventId
# ============================================================
block testDslLastEventId:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    sse "/events":
      let lastId = lastEventId()
      await sendEvent("last-id:" & lastId)

  let response = runServerClient(listener, handler,
    "GET /events HTTP/1.1\r\nHost: localhost\r\nLast-Event-ID: 42\r\nConnection: close\r\n\r\n")

  let body = extractSseBody(response)
  assert "data: last-id:42\n" in body, "Missing data: last-id:42 in body: " & repr(body)
  listener.close()
  echo "PASS: DSL lastEventId"

# ============================================================
# Test 8: SSE with path params
# ============================================================
block testSseWithPathParams:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    sse "/events/{channel}":
      let ch = pathParams["channel"]
      await sendEvent("channel:" & ch)

  let response = runServerClient(listener, handler,
    "GET /events/news HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  let body = extractSseBody(response)
  assert "data: channel:news\n" in body, "Missing data: channel:news in body: " & repr(body)
  listener.close()
  echo "PASS: SSE with path params"

echo ""
echo "All SSE tests passed!"
