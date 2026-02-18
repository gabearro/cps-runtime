## Tests for SSE streaming compression

import std/[strutils, nativesockets]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/server/sse
import cps/http/client/sse as sse_client
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
# Test 1: SSE server with compression - verify headers
# ============================================================

block testSseCompressionHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc sseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream, req = req)
    await sse.sendEvent("hello")
    sse.close()
    return sseResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, sseHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reqStr = "GET /events HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"
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

  let raw = cf.read()
  let ceHeader = extractHeader(raw, "Content-Encoding")
  assert ceHeader == "gzip", "Expected Content-Encoding: gzip, got: " & ceHeader
  # SSE streaming compression writes compressed data directly (no chunked encoding)
  let ctHeader = extractHeader(raw, "Content-Type")
  assert "text/event-stream" in ctHeader, "Expected Content-Type: text/event-stream"
  listener.close()
  echo "PASS: SSE server compression headers"

# ============================================================
# Test 2: SSE client with compression (full roundtrip)
# ============================================================

block testSseClientCompression:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc sseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream, req = req)
    await sse.sendEvent("event1", event = "msg")
    await sse.sendEvent("event2", event = "msg")
    await sse.sendEvent("event3", event = "msg")
    sse.close()
    return sseResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, sseHandler)

  proc clientTask(p: int): CpsFuture[seq[string]] {.cps.} =
    let client = await connectSse("127.0.0.1", p, "/events",
                                   enableCompression = true)
    var events: seq[string]
    for i in 0 ..< 3:
      let event = await client.readEvent()
      events.add event.data
    return events

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let events = cf.read()
  assert events.len == 3, "Expected 3 events, got " & $events.len
  assert events[0] == "event1", "Expected 'event1', got '" & events[0] & "'"
  assert events[1] == "event2", "Expected 'event2', got '" & events[1] & "'"
  assert events[2] == "event3", "Expected 'event3', got '" & events[2] & "'"
  listener.close()
  echo "PASS: SSE client with compression"

# ============================================================
# Test 3: SSE without compression (backward compatibility)
# ============================================================

block testSseNoCompression:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc sseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream, req = req)
    await sse.sendEvent("plain text event")
    sse.close()
    return sseResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, sseHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    # No Accept-Encoding header -> no compression
    let reqStr = "GET /events HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\nConnection: close\r\n\r\n"
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

  let raw = cf.read()
  let ceHeader = extractHeader(raw, "Content-Encoding")
  assert ceHeader == "", "Should not compress without Accept-Encoding, got: " & ceHeader
  assert "data: plain text event" in raw, "Expected uncompressed SSE event in response"
  listener.close()
  echo "PASS: SSE without compression (backward compatibility)"

# ============================================================
# Test 4: SSE client without compression (backward compatibility)
# ============================================================

block testSseClientNoCompression:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc sseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream, req = req)
    await sse.sendEvent("uncompressed event")
    sse.close()
    return sseResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, sseHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let client = await connectSse("127.0.0.1", p, "/events",
                                   enableCompression = false)
    let event = await client.readEvent()
    return event.data

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.read() == "uncompressed event"
  listener.close()
  echo "PASS: SSE client without compression"

echo "ALL SSE COMPRESSION TESTS PASSED"
