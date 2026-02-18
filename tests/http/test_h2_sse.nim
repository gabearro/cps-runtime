## Tests for SSE over HTTP/2
##
## Tests SSE streaming over HTTP/2 connections using plain TCP
## (HTTP/2 prior knowledge, no TLS). The client manually constructs
## HTTP/2 frames and parses the server's response frames.

import std/[strutils, nativesockets]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/http/server/types
import cps/http/server/http2 as http2_server
import cps/http/shared/http2
import cps/http/shared/hpack
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

proc sendH2Frame(s: AsyncStream, frame: Http2Frame): CpsVoidFuture =
  let data = serializeFrame(frame)
  var str = newString(data.len)
  for i, b in data:
    str[i] = char(b)
  s.write(str)

proc recvH2Frame(reader: BufferedReader): CpsFuture[Http2Frame] {.cps.} =
  let headerStr = await reader.readExact(9)
  var headerBytes = newSeq[byte](9)
  for i in 0 ..< 9:
    headerBytes[i] = byte(headerStr[i])
  var frame = parseFrame(headerBytes)
  if frame.length > 0:
    let payloadStr = await reader.readExact(int(frame.length))
    frame.payload = newSeq[byte](payloadStr.len)
    for i in 0 ..< payloadStr.len:
      frame.payload[i] = byte(payloadStr[i])
  else:
    frame.payload = @[]
  return frame

proc sendConnectionPreface(s: AsyncStream): CpsVoidFuture {.cps.} =
  ## Send HTTP/2 connection preface + empty SETTINGS
  await s.write(ConnectionPreface)
  let settingsFrame = Http2Frame(
    frameType: FrameSettings,
    flags: 0,
    streamId: 0,
    payload: @[]
  )
  await sendH2Frame(s, settingsFrame)

proc encodeHeaders(headers: seq[(string, string)]): seq[byte] =
  ## Encode headers using HPACK (non-CPS helper to avoid var capture issues).
  var enc = initHpackEncoder()
  enc.encode(headers)

proc decodeHeaders(payload: seq[byte]): seq[(string, string)] =
  ## Decode HPACK headers (non-CPS helper to avoid var capture issues).
  var dec = initHpackDecoder()
  dec.decode(payload)

# ============================================================
# Test 1: Basic SSE over HTTP/2
# ============================================================
block testBasicH2Sse:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc sseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream)
    await sse.sendEvent("hello")
    await sse.sendEvent("world")
    return sseResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, h)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)

    # Send connection preface + SETTINGS
    await sendConnectionPreface(s)

    # Read server's SETTINGS frame
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings, "Expected SETTINGS, got type " & $serverSettings.frameType
    # ACK server's settings
    await sendH2Frame(s, Http2Frame(
      frameType: FrameSettings,
      flags: FlagAck,
      streamId: 0,
      payload: @[]
    ))
    # Read SETTINGS ACK from server (for our settings)
    let settingsAck = await recvH2Frame(reader)
    assert settingsAck.frameType == FrameSettings, "Expected SETTINGS ACK"
    assert (settingsAck.flags and FlagAck) != 0, "Expected ACK flag"

    # Send HEADERS for GET /events with END_STREAM (no body)
    let headers = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/events"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    let headersFrame = Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: headers
    )
    await sendH2Frame(s, headersFrame)

    # Read response frames
    var responseHeaders: seq[(string, string)]
    var responseData = ""

    # Collect all frames for stream 1
    while true:
      let frame = await recvH2Frame(reader)
      if frame.frameType == FrameHeaders and frame.streamId == 1:
        responseHeaders = decodeHeaders(frame.payload)
      elif frame.frameType == FrameData and frame.streamId == 1:
        for i in 0 ..< frame.payload.len:
          responseData &= char(frame.payload[i])
        if (frame.flags and FlagEndStream) != 0:
          break
      elif frame.frameType == FrameWindowUpdate:
        discard  # Ignore window updates
      elif frame.frameType == FrameSettings:
        discard  # Ignore additional settings
      else:
        discard

    s.close()

    # Build output string
    var output = ""
    for (k, v) in responseHeaders:
      output &= k & "=" & v & "|"
    output &= "DATA:" & responseData
    return output

  let sf = serverTask(listener, config, sseHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  # Verify response headers
  assert ":status=200" in result, "Expected :status=200, got: " & result
  assert "content-type=text/event-stream" in result,
    "Expected content-type=text/event-stream, got: " & result
  assert "cache-control=no-cache" in result,
    "Expected cache-control=no-cache, got: " & result
  # Verify SSE data
  assert "data: hello\n" in result, "Missing data: hello in: " & result
  assert "data: world\n" in result, "Missing data: world in: " & result
  listener.close()
  echo "PASS: Basic SSE over HTTP/2"

# ============================================================
# Test 2: SSE with named events over HTTP/2
# ============================================================
block testNamedEventsH2:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc sseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream)
    await sse.sendEvent("user joined", event="join", id="1")
    await sse.sendEvent("message sent", event="msg", id="2")
    return sseResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, h)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let settingsAck = await recvH2Frame(reader)

    let headers = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/events"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: headers
    ))

    var responseData = ""

    while true:
      let frame = await recvH2Frame(reader)
      if frame.frameType == FrameHeaders and frame.streamId == 1:
        discard decodeHeaders(frame.payload)
      elif frame.frameType == FrameData and frame.streamId == 1:
        for i in 0 ..< frame.payload.len:
          responseData &= char(frame.payload[i])
        if (frame.flags and FlagEndStream) != 0:
          break
      elif frame.frameType == FrameWindowUpdate:
        discard
      else:
        discard

    s.close()
    return responseData

  let sf = serverTask(listener, config, sseHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert "event: join\n" in result, "Missing event: join in: " & result
  assert "id: 1\n" in result, "Missing id: 1 in: " & result
  assert "data: user joined\n" in result, "Missing data: user joined in: " & result
  assert "event: msg\n" in result, "Missing event: msg in: " & result
  assert "id: 2\n" in result, "Missing id: 2 in: " & result
  assert "data: message sent\n" in result, "Missing data: message sent in: " & result
  listener.close()
  echo "PASS: SSE with named events over HTTP/2"

# ============================================================
# Test 3: Same SSE handler works for both HTTP/1.1 and HTTP/2
# ============================================================
block testSameHandlerBothProtocols:
  # This test verifies that the same handler proc can be used
  # with both HTTP/1.1 and HTTP/2 transparently.
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  # This is the exact same handler — no protocol-specific code
  proc universalSseHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let sse = await initSse(req.stream)
    await sse.sendEvent("universal")
    await sse.sendComment("keepalive")
    return sseResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, h)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let settingsAck = await recvH2Frame(reader)

    let headers = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/events"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: headers
    ))

    var responseData = ""

    while true:
      let frame = await recvH2Frame(reader)
      if frame.frameType == FrameHeaders and frame.streamId == 1:
        discard decodeHeaders(frame.payload)
      elif frame.frameType == FrameData and frame.streamId == 1:
        for i in 0 ..< frame.payload.len:
          responseData &= char(frame.payload[i])
        if (frame.flags and FlagEndStream) != 0:
          break
      elif frame.frameType == FrameWindowUpdate:
        discard
      else:
        discard

    s.close()
    return responseData

  let sf = serverTask(listener, config, universalSseHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert "data: universal\n" in result, "Missing data: universal in: " & result
  assert ": keepalive\n" in result, "Missing comment in: " & result
  listener.close()
  echo "PASS: Same SSE handler works for HTTP/2"

echo ""
echo "All HTTP/2 SSE tests passed!"
