## Tests for chunked/streaming responses over HTTP/2
##
## Validates that the ChunkedWriter correctly detects Http2StreamAdapter
## and sends proper HEADERS + DATA frames instead of HTTP/1.1 chunked encoding.
## Uses plain TCP with HTTP/2 prior knowledge (no TLS).

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
import cps/http/server/chunked
import cps/http/server/http1 as http1_server

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
  let headerStr: string = await reader.readExact(9)
  var headerBytes = newSeq[byte](9)
  for i in 0 ..< 9:
    headerBytes[i] = byte(headerStr[i])
  var frame = parseFrame(headerBytes)
  if frame.length > 0:
    let payloadStr: string = await reader.readExact(int(frame.length))
    frame.payload = newSeq[byte](payloadStr.len)
    for i in 0 ..< payloadStr.len:
      frame.payload[i] = byte(payloadStr[i])
  else:
    frame.payload = @[]
  return frame

proc sendConnectionPreface(s: AsyncStream): CpsVoidFuture {.cps.} =
  await s.write(ConnectionPreface)
  let settingsFrame = Http2Frame(
    frameType: FrameSettings,
    flags: 0,
    streamId: 0,
    payload: @[]
  )
  await sendH2Frame(s, settingsFrame)

proc encodeHeaders(headers: seq[(string, string)]): seq[byte] =
  var enc = initHpackEncoder()
  enc.encode(headers)

proc decodeHeaders(payload: seq[byte]): seq[(string, string)] =
  var dec = initHpackDecoder()
  dec.decode(payload)

# ============================================================
# Test 1: Basic chunked streaming over HTTP/2
# ============================================================
block testBasicH2Chunked:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc streamHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let w = await initChunked(req.stream)
    await w.sendChunk("Hello ")
    await w.sendChunk("World")
    await w.endChunked()
    return streamResponse()

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

    # Read server's SETTINGS
    let serverSettings: Http2Frame = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    # ACK server's settings
    await sendH2Frame(s, Http2Frame(
      frameType: FrameSettings,
      flags: FlagAck,
      streamId: 0,
      payload: @[]
    ))
    # Read SETTINGS ACK
    let settingsAck: Http2Frame = await recvH2Frame(reader)
    assert settingsAck.frameType == FrameSettings
    assert (settingsAck.flags and FlagAck) != 0

    # Send HEADERS for GET /stream with END_STREAM (no body)
    let headers = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/stream"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: headers
    ))

    # Read response frames
    var responseHeaders: seq[(string, string)]
    var responseData = ""

    while true:
      let frame: Http2Frame = await recvH2Frame(reader)
      if frame.frameType == FrameHeaders and frame.streamId == 1:
        responseHeaders = decodeHeaders(frame.payload)
      elif frame.frameType == FrameData and frame.streamId == 1:
        for i in 0 ..< frame.payload.len:
          responseData &= char(frame.payload[i])
        if (frame.flags and FlagEndStream) != 0:
          break
      elif frame.frameType == FrameWindowUpdate:
        discard
      elif frame.frameType == FrameSettings:
        discard
      else:
        discard

    s.close()

    # Build result: headers then data
    var resultStr = ""
    for (k, v) in responseHeaders:
      resultStr &= k & "=" & v & "|"
    resultStr &= "DATA:" & responseData
    return resultStr

  let sf = serverTask(listener, config, streamHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "Client task did not complete"
  let result = cf.read()

  # Verify response headers — should have :status=200, no Transfer-Encoding
  assert ":status=200" in result, "Expected :status=200, got: " & result
  assert "transfer-encoding" notin result.toLowerAscii,
    "HTTP/2 should NOT have Transfer-Encoding header, got: " & result

  # Verify data — should be raw "Hello World" (no hex chunk encoding)
  let dataIdx = result.find("DATA:")
  assert dataIdx >= 0
  let data = result[dataIdx + 5 .. ^1]
  assert data == "Hello World", "Expected raw 'Hello World', got: '" & data & "'"

  listener.close()
  echo "PASS: Basic chunked streaming over HTTP/2"

# ============================================================
# Test 2: Chunked streaming with custom status and headers over HTTP/2
# ============================================================
block testH2ChunkedWithHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc streamHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let w = await initChunked(req.stream, 201, @[
      ("X-Custom", "streaming"),
      ("Content-Type", "text/plain")
    ])
    await w.sendChunk("chunk1")
    await w.sendChunk("chunk2")
    await w.sendChunk("chunk3")
    await w.endChunked()
    return streamResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, h)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)

    await sendConnectionPreface(s)
    let serverSettings: Http2Frame = await recvH2Frame(reader)
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let settingsAck: Http2Frame = await recvH2Frame(reader)

    let headers = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/stream"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: headers
    ))

    var responseHeaders: seq[(string, string)]
    var responseData = ""

    while true:
      let frame: Http2Frame = await recvH2Frame(reader)
      if frame.frameType == FrameHeaders and frame.streamId == 1:
        responseHeaders = decodeHeaders(frame.payload)
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

    var resultStr = ""
    for (k, v) in responseHeaders:
      resultStr &= k & "=" & v & "|"
    resultStr &= "DATA:" & responseData
    return resultStr

  let sf = serverTask(listener, config, streamHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "Client task did not complete"
  let result = cf.read()

  # Verify status 201
  assert ":status=201" in result, "Expected :status=201, got: " & result
  # Verify custom headers (lowercased by HTTP/2)
  assert "x-custom=streaming" in result, "Expected x-custom header, got: " & result
  assert "content-type=text/plain" in result, "Expected content-type header, got: " & result
  # Verify data is raw concatenation (no chunked encoding artifacts)
  let dataIdx = result.find("DATA:")
  let data = result[dataIdx + 5 .. ^1]
  assert data == "chunk1chunk2chunk3",
    "Expected raw 'chunk1chunk2chunk3', got: '" & data & "'"

  listener.close()
  echo "PASS: Chunked streaming with custom headers over HTTP/2"

# ============================================================
# Test 3: Same handler works for both HTTP/1.1 and HTTP/2
# ============================================================
block testSameHandlerBothProtocols:
  # Define ONE handler — it should work transparently for both protocols
  proc universalStreamHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let w = await initChunked(req.stream)
    await w.sendChunk("part1|")
    await w.sendChunk("part2")
    await w.endChunked()
    return streamResponse()

  # --- HTTP/2 path ---
  block h2Path:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                    h: HttpHandler): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp2Connection(client.AsyncStream, cfg, h)

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let s = conn.AsyncStream
      let reader = newBufferedReader(s)

      await sendConnectionPreface(s)
      let serverSettings: Http2Frame = await recvH2Frame(reader)
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let settingsAck: Http2Frame = await recvH2Frame(reader)

      let headers = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/stream"),
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
        let frame: Http2Frame = await recvH2Frame(reader)
        if frame.frameType == FrameData and frame.streamId == 1:
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

    let sf = serverTask(listener, config, universalStreamHandler)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break

    assert cf.finished, "HTTP/2 client did not complete"
    let h2Data = cf.read()
    assert h2Data == "part1|part2", "HTTP/2 data mismatch: '" & h2Data & "'"
    listener.close()

  # --- HTTP/1.1 path ---
  block h1Path:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let config = HttpServerConfig()

    proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                    h: HttpHandler): CpsVoidFuture {.cps.} =
      let client = await l.accept()
      await handleHttp1Connection(client.AsyncStream, cfg, h)

    proc clientTask(p: int): CpsFuture[string] {.cps.} =
      let conn = await tcpConnect("127.0.0.1", p)
      let s = conn.AsyncStream
      await s.write("GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      var data = ""
      while true:
        let chunk: string = await s.read(4096)
        if chunk.len == 0:
          break
        data &= chunk
      s.close()
      return data

    let sf = serverTask(listener, config, universalStreamHandler)
    let cf = clientTask(port)
    let loop = getEventLoop()
    while not cf.finished:
      loop.tick()
      if not loop.hasWork:
        break

    assert cf.finished, "HTTP/1.1 client did not complete"
    let h1Raw = cf.read()
    # HTTP/1.1 should have Transfer-Encoding: chunked
    assert "Transfer-Encoding: chunked" in h1Raw,
      "HTTP/1.1 should use chunked encoding: " & h1Raw
    # Should contain the data (in chunked format)
    assert "part1|" in h1Raw, "Missing part1| in HTTP/1.1 response"
    assert "part2" in h1Raw, "Missing part2 in HTTP/1.1 response"
    # Should have terminal chunk
    assert "\r\n0\r\n" in h1Raw, "Missing terminal chunk in HTTP/1.1 response"
    listener.close()

  echo "PASS: Same streaming handler works for both HTTP/1.1 and HTTP/2"

echo ""
echo "All HTTP/2 chunked streaming tests passed!"
