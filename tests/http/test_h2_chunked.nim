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

proc sendRawFrameHeader(s: AsyncStream, length: uint32, frameType: uint8,
                        flags: uint8, streamId: uint32): CpsVoidFuture {.cps.} =
  var raw = newString(9)
  raw[0] = char(byte((length shr 16) and 0xFF))
  raw[1] = char(byte((length shr 8) and 0xFF))
  raw[2] = char(byte(length and 0xFF))
  raw[3] = char(frameType)
  raw[4] = char(flags)
  raw[5] = char(byte((streamId shr 24) and 0x7F))
  raw[6] = char(byte((streamId shr 16) and 0xFF))
  raw[7] = char(byte((streamId shr 8) and 0xFF))
  raw[8] = char(byte(streamId and 0xFF))
  await s.write(raw)

proc encodeHeaders(headers: seq[(string, string)]): seq[byte] =
  var enc = initHpackEncoder()
  enc.encode(headers)

proc decodeHeaders(payload: seq[byte]): seq[(string, string)] =
  var dec = initHpackDecoder()
  dec.decode(payload)

proc settingsPayload(entries: seq[(uint16, uint32)]): seq[byte] =
  for (id, value) in entries:
    result.add byte((id shr 8) and 0xFF)
    result.add byte(id and 0xFF)
    result.add byte((value shr 24) and 0xFF)
    result.add byte((value shr 16) and 0xFF)
    result.add byte((value shr 8) and 0xFF)
    result.add byte(value and 0xFF)

proc windowUpdatePayload(increment: uint32): seq[byte] =
  @[
    byte((increment shr 24) and 0x7F),
    byte((increment shr 16) and 0xFF),
    byte((increment shr 8) and 0xFF),
    byte(increment and 0xFF)
  ]

proc goAwayPayload(lastStreamId: uint32, errorCode: uint32): seq[byte] =
  @[
    byte((lastStreamId shr 24) and 0x7F),
    byte((lastStreamId shr 16) and 0xFF),
    byte((lastStreamId shr 8) and 0xFF),
    byte(lastStreamId and 0xFF),
    byte((errorCode shr 24) and 0xFF),
    byte((errorCode shr 16) and 0xFF),
    byte((errorCode shr 8) and 0xFF),
    byte(errorCode and 0xFF)
  ]

proc goAwayErrorCode(frame: Http2Frame): uint32 =
  if frame.frameType != FrameGoAway or frame.payload.len < 8:
    return 0'u32
  (uint32(frame.payload[4]) shl 24) or
  (uint32(frame.payload[5]) shl 16) or
  (uint32(frame.payload[6]) shl 8) or
  uint32(frame.payload[7])

proc rstStreamErrorCode(frame: Http2Frame): uint32 =
  if frame.frameType != FrameRstStream or frame.payload.len < 4:
    return 0'u32
  (uint32(frame.payload[0]) shl 24) or
  (uint32(frame.payload[1]) shl 16) or
  (uint32(frame.payload[2]) shl 8) or
  uint32(frame.payload[3])

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

# ============================================================
# Test 4: HTTP/2 outbound flow control pauses DATA until WINDOW_UPDATE
# ============================================================
block testH2OutboundFlowControlPauseResume:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()
  let largeBody = 'Z'.repeat(512)

  proc flowHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, largeBody)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, h)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)

    await s.write(ConnectionPreface)
    await sendH2Frame(s, Http2Frame(
      frameType: FrameSettings,
      flags: 0,
      streamId: 0,
      payload: settingsPayload(@[(SettingsInitialWindowSize, 16'u32)])
    ))

    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(
      frameType: FrameSettings,
      flags: FlagAck,
      streamId: 0,
      payload: @[]
    ))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/flow"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var gotHeaders = false
    var firstDataLen = -1
    var firstDataEnd = false
    var body = ""

    while true:
      let frame = await recvH2Frame(reader)
      if frame.streamId != 1:
        continue
      if frame.frameType == FrameHeaders:
        gotHeaders = true
      elif frame.frameType == FrameData:
        firstDataLen = frame.payload.len
        firstDataEnd = (frame.flags and FlagEndStream) != 0
        for i in 0 ..< frame.payload.len:
          body &= char(frame.payload[i])
        break

    await sendH2Frame(s, Http2Frame(
      frameType: FrameWindowUpdate,
      flags: 0,
      streamId: 0,
      payload: windowUpdatePayload(2048'u32)
    ))
    await sendH2Frame(s, Http2Frame(
      frameType: FrameWindowUpdate,
      flags: 0,
      streamId: 1,
      payload: windowUpdatePayload(2048'u32)
    ))

    while not firstDataEnd and body.len < largeBody.len:
      let frame = await recvH2Frame(reader)
      if frame.frameType == FrameData and frame.streamId == 1:
        for i in 0 ..< frame.payload.len:
          body &= char(frame.payload[i])
        if (frame.flags and FlagEndStream) != 0:
          break

    s.close()
    if gotHeaders and firstDataLen > 0 and firstDataLen <= 16 and body == largeBody:
      return "ok"
    return "fail:" & $gotHeaders & ":" & $firstDataLen & ":" & $body.len

  let sf = serverTask(listener, config, flowHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "HTTP/2 flow-control client did not complete"
  let result = cf.read()
  assert result == "ok", "Flow-control assertion failed: " & result
  listener.close()
  echo "PASS: HTTP/2 outbound flow control pauses until WINDOW_UPDATE"

# ============================================================
# Test 5: HTTP/2 CONTINUATION header block assembly
# ============================================================
block testH2ContinuationHeaderAssembly:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc continuationHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok-continuation")

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
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let encoded = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/continuation"),
      (":scheme", "http"),
      (":authority", "localhost"),
      ("x-extra", 'a'.repeat(256))
    ])
    let splitAt = max(1, encoded.len div 2)
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndStream,
      streamId: 1,
      payload: encoded[0 ..< splitAt]
    ))
    await sendH2Frame(s, Http2Frame(
      frameType: FrameContinuation,
      flags: FlagEndHeaders,
      streamId: 1,
      payload: encoded[splitAt .. ^1]
    ))

    var statusCode = 0
    var body = ""
    while true:
      let frame = await recvH2Frame(reader)
      if frame.streamId != 1:
        continue
      if frame.frameType == FrameHeaders:
        let decoded = decodeHeaders(frame.payload)
        for (k, v) in decoded:
          if k == ":status":
            statusCode = parseInt(v)
        if (frame.flags and FlagEndStream) != 0:
          break
      elif frame.frameType == FrameData:
        for i in 0 ..< frame.payload.len:
          body &= char(frame.payload[i])
        if (frame.flags and FlagEndStream) != 0:
          break

    s.close()
    return $statusCode & "|" & body

  let sf = serverTask(listener, config, continuationHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "HTTP/2 continuation client did not complete"
  let result = cf.read()
  assert result == "200|ok-continuation", "Unexpected continuation response: " & result
  listener.close()
  echo "PASS: HTTP/2 CONTINUATION request header assembly"

# ============================================================
# Test 6: HTTP/2 ignores unknown CONTINUATION flags
# ============================================================
block testH2ContinuationIgnoresUnknownFlags:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc continuationHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok-continuation-flags")

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
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let encoded = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/continuation-extra-flags"),
      (":scheme", "http"),
      (":authority", "localhost"),
      ("x-extra", 'c'.repeat(256))
    ])
    let splitAt = max(1, encoded.len div 2)
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndStream,
      streamId: 1,
      payload: encoded[0 ..< splitAt]
    ))
    await sendH2Frame(s, Http2Frame(
      frameType: FrameContinuation,
      flags: FlagEndHeaders or FlagPadded,
      streamId: 1,
      payload: encoded[splitAt .. ^1]
    ))

    var statusCode = 0
    var body = ""
    while true:
      let frame = await recvH2Frame(reader)
      if frame.streamId != 1:
        continue
      if frame.frameType == FrameHeaders:
        let decoded = decodeHeaders(frame.payload)
        for (k, v) in decoded:
          if k == ":status":
            statusCode = parseInt(v)
        if (frame.flags and FlagEndStream) != 0:
          break
      elif frame.frameType == FrameData:
        for i in 0 ..< frame.payload.len:
          body &= char(frame.payload[i])
        if (frame.flags and FlagEndStream) != 0:
          break

    s.close()
    return $statusCode & "|" & body

  let sf = serverTask(listener, config, continuationHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "HTTP/2 continuation flag-compat client did not complete"
  let result = cf.read()
  assert result == "200|ok-continuation-flags", "Unexpected continuation response: " & result
  listener.close()
  echo "PASS: HTTP/2 ignores unknown CONTINUATION flags"

# ============================================================
# Test 7: HTTP/2 rejects non-CONTINUATION frame mid header block
# ============================================================
block testH2ContinuationProtocolViolation:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()
  
  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let encoded = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/bad-continuation"),
        (":scheme", "http"),
        (":authority", "localhost"),
        ("x-extra", 'b'.repeat(128))
      ])
      let splitAt = max(1, encoded.len div 2)
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndStream,
        streamId: 1,
        payload: encoded[0 ..< splitAt]
      ))
      await sendH2Frame(s, Http2Frame(
        frameType: FramePing,
        flags: 0,
        streamId: 0,
        payload: @[0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8]
      ))

      var attempts = 0
      var done = false
      while attempts < 6 and not done:
        var frame: Http2Frame
        var gotFrame = true
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          gotFrame = false
        if not gotFrame:
          done = true
        elif frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          done = true
        inc attempts
    except CatchableError:
      discard
    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "HTTP/2 continuation violation client did not complete"
  var errCode = 0'u32
  if cf.hasError():
    discard  # Peer may close immediately after protocol error.
  else:
    errCode = cf.read()
  assert errCode == 1'u32 or errCode == 0'u32,
    "Expected GOAWAY PROTOCOL_ERROR (1) or early close, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 CONTINUATION protocol violation yields GOAWAY"

# ============================================================
# Test 8: HTTP/2 emits GOAWAY on continuation protocol violation
# ============================================================
block testH2ContinuationProtocolViolationStrictGoAway:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let encoded = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/bad-continuation-strict"),
        (":scheme", "http"),
        (":authority", "localhost"),
        ("x-extra", 'x'.repeat(128))
      ])
      let splitAt = max(1, encoded.len div 2)
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndStream,
        streamId: 1,
        payload: encoded[0 ..< splitAt]
      ))
      await sendH2Frame(s, Http2Frame(
        frameType: FramePing,
        flags: 0,
        streamId: 0,
        payload: @[0'u8, 1'u8, 2'u8, 3'u8, 4'u8, 5'u8, 6'u8, 7'u8]
      ))

      var attempts = 0
      while attempts < 4:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard
    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "Strict GOAWAY client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR (1), got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 emits GOAWAY on protocol violation"

# ============================================================
# Test 8: HTTP/2 rejects reused client stream IDs
# ============================================================
block testH2RejectsReusedStreamIds:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok-" & req.path)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let firstHeaders = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/first"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders or FlagEndStream,
        streamId: 1,
        payload: firstHeaders
      ))

      var firstDone = false
      var attempts = 0
      while attempts < 8 and not firstDone:
        let frame = await recvH2Frame(reader)
        if frame.streamId != 1:
          inc attempts
          continue
        if frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          firstDone = true
        elif frame.frameType == FrameHeaders and (frame.flags and FlagEndStream) != 0:
          firstDone = true
        inc attempts

      let reusedHeaders = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/reused"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders or FlagEndStream,
        streamId: 1,
        payload: reusedHeaders
      ))
      await sendH2Frame(s, Http2Frame(
        frameType: FramePing,
        flags: 0,
        streamId: 0,
        payload: @[9'u8, 8'u8, 7'u8, 6'u8, 5'u8, 4'u8, 3'u8, 2'u8]
      ))

      attempts = 0
      while attempts < 8:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "Reused stream-id client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR on reused stream ID, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects reused stream IDs"

# ============================================================
# Test 9: HTTP/2 rejects RST_STREAM on stream 0
# ============================================================
block testH2RejectsRstStreamZero:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendH2Frame(s, Http2Frame(
        frameType: FrameRstStream,
        flags: 0,
        streamId: 0,
        payload: @[0'u8, 0'u8, 0'u8, 0'u8]
      ))
      await sendH2Frame(s, Http2Frame(
        frameType: FramePing,
        flags: 0,
        streamId: 0,
        payload: @[1'u8, 3'u8, 3'u8, 7'u8, 0'u8, 0'u8, 0'u8, 1'u8]
      ))

      var attempts = 0
      while attempts < 4:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "RST_STREAM zero client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR for RST_STREAM stream 0, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects RST_STREAM stream 0"

# ============================================================
# Test 10: HTTP/2 rejects connection window overflow
# ============================================================
block testH2RejectsConnectionWindowOverflow:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendH2Frame(s, Http2Frame(
        frameType: FrameWindowUpdate,
        flags: 0,
        streamId: 0,
        payload: windowUpdatePayload(0x7FFF_FFFF'u32)
      ))

      var attempts = 0
      while attempts < 4:
        await sendH2Frame(s, Http2Frame(
          frameType: FramePing,
          flags: 0,
          streamId: 0,
          payload: @[
            byte(9 + attempts), byte(9 + attempts), byte(9 + attempts), byte(9 + attempts),
            byte(9 + attempts), byte(9 + attempts), byte(9 + attempts), byte(9 + attempts)
          ]
        ))
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "Connection overflow client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 3'u32,
    "Expected GOAWAY FLOW_CONTROL_ERROR (3), got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects connection window overflow"

# ============================================================
# Test 11: HTTP/2 rejects stream window overflow with RST_STREAM
# ============================================================
block testH2RejectsStreamWindowOverflow:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc slowHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    await cpsSleep(30)
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, slowHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/stream-overflow"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders or FlagEndStream,
        streamId: 1,
        payload: reqHeaders
      ))
      await sendH2Frame(s, Http2Frame(
        frameType: FrameWindowUpdate,
        flags: 0,
        streamId: 1,
        payload: windowUpdatePayload(0x7FFF_FFFF'u32)
      ))

      var attempts = 0
      while attempts < 6:
        await sendH2Frame(s, Http2Frame(
          frameType: FramePing,
          flags: 0,
          streamId: 0,
          payload: @[
            byte(17 + attempts), byte(17 + attempts), byte(17 + attempts), byte(17 + attempts),
            byte(17 + attempts), byte(17 + attempts), byte(17 + attempts), byte(17 + attempts)
          ]
        ))
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameRstStream and frame.streamId == 1:
          rstErr = rstStreamErrorCode(frame)
          break
        elif frame.frameType == FrameGoAway:
          rstErr = 0'u32
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return rstErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "Stream overflow client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 3'u32,
    "Expected RST_STREAM FLOW_CONTROL_ERROR (3), got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects stream window overflow"

# ============================================================
# Test 12: HTTP/2 rejects DATA on idle stream (connection error)
# ============================================================
block testH2RejectsDataOnIdleStream:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendH2Frame(s, Http2Frame(
        frameType: FrameData,
        flags: FlagEndStream,
        streamId: 3,
        payload: @[byte('x')]
      ))

      var attempts = 0
      while attempts < 5:
        await sendH2Frame(s, Http2Frame(
          frameType: FramePing,
          flags: 0,
          streamId: 0,
          payload: @[
            byte(33 + attempts), byte(33 + attempts), byte(33 + attempts), byte(33 + attempts),
            byte(33 + attempts), byte(33 + attempts), byte(33 + attempts), byte(33 + attempts)
          ]
        ))
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "Idle DATA client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR (1) for DATA on idle stream, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects DATA on idle stream"

# ============================================================
# Test 13: HTTP/2 rejects RST_STREAM on idle stream
# ============================================================
block testH2RejectsRstOnIdleStream:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendH2Frame(s, Http2Frame(
        frameType: FrameRstStream,
        flags: 0,
        streamId: 3,
        payload: @[0'u8, 0'u8, 0'u8, 0'u8]
      ))

      var attempts = 0
      while attempts < 5:
        await sendH2Frame(s, Http2Frame(
          frameType: FramePing,
          flags: 0,
          streamId: 0,
          payload: @[
            byte(49 + attempts), byte(49 + attempts), byte(49 + attempts), byte(49 + attempts),
            byte(49 + attempts), byte(49 + attempts), byte(49 + attempts), byte(49 + attempts)
          ]
        ))
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "Idle RST_STREAM client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR (1) for RST_STREAM on idle stream, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects RST_STREAM on idle stream"

# ============================================================
# Test 14: HTTP/2 rejects PRIORITY on stream 0
# ============================================================
block testH2RejectsPriorityStreamZero:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendH2Frame(s, Http2Frame(
        frameType: FramePriority,
        flags: 0,
        streamId: 0,
        payload: @[0'u8, 0'u8, 0'u8, 0'u8, 0'u8]
      ))

      var attempts = 0
      while attempts < 4:
        await sendH2Frame(s, Http2Frame(
          frameType: FramePing,
          flags: 0,
          streamId: 0,
          payload: @[
            byte(65 + attempts), byte(65 + attempts), byte(65 + attempts), byte(65 + attempts),
            byte(65 + attempts), byte(65 + attempts), byte(65 + attempts), byte(65 + attempts)
          ]
        ))
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "PRIORITY stream-0 client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR (1) for PRIORITY stream 0, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects PRIORITY stream 0"

# ============================================================
# Test 15: HTTP/2 emits GOAWAY on oversized inbound frame length
# ============================================================
block testH2OversizedFrameLengthGoAway:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendRawFrameHeader(s, uint32(DefaultMaxFrameSize + 1), FrameData, 0'u8, 1'u32)

      var attempts = 0
      while attempts < 3:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert cf.finished, "Oversized-frame client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 6'u32,
    "Expected GOAWAY FRAME_SIZE_ERROR (6) for oversized frame length, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 emits GOAWAY on oversized frame length"

# ============================================================
# Test 16: HTTP/2 rejects SETTINGS initial-window overflow on active stream
# ============================================================
block testH2RejectsSettingsWindowOverflow:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "POST"),
        (":path", "/overflow"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders, # keep stream open (no END_STREAM)
        streamId: 1,
        payload: reqHeaders
      ))

      let toMaxIncrement = 0x7FFF_FFFF'u32 - DefaultWindowSize.uint32
      await sendH2Frame(s, Http2Frame(
        frameType: FrameWindowUpdate,
        flags: 0,
        streamId: 1,
        payload: windowUpdatePayload(toMaxIncrement)
      ))

      await sendH2Frame(s, Http2Frame(
        frameType: FrameSettings,
        flags: 0,
        streamId: 0,
        payload: settingsPayload(@[
          (SettingsInitialWindowSize, 0x7FFF_FFFF'u32)
        ])
      ))

      var attempts = 0
      while attempts < 1:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "SETTINGS-overflow client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 3'u32,
    "Expected GOAWAY FLOW_CONTROL_ERROR (3) for SETTINGS window overflow, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects SETTINGS initial-window overflow on active stream"

# ============================================================
# Test 17: HTTP/2 rejects HEADERS priority self-dependency
# ============================================================
block testH2RejectsHeadersPrioritySelfDependency:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/priority-self"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      var payload: seq[byte] = @[
        0x00'u8, 0x00'u8, 0x00'u8, 0x01'u8, # stream dependency = stream 1 (self)
        0x10'u8 # weight
      ]
      payload.add reqHeaders

      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagPriority or FlagEndHeaders or FlagEndStream,
        streamId: 1,
        payload: payload
      ))

      var attempts = 0
      while attempts < 1:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameRstStream and frame.streamId == 1:
          rstErr = rstStreamErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return rstErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "PRIORITY self-dependency client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected RST_STREAM PROTOCOL_ERROR (1) for HEADERS self-dependency, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects HEADERS priority self-dependency"

# ============================================================
# Test 18: HTTP/2 rejects PRIORITY self-dependency
# ============================================================
block testH2RejectsPrioritySelfDependency:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "POST"),
        (":path", "/priority-self"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders, # keep stream open
        streamId: 1,
        payload: reqHeaders
      ))

      await sendH2Frame(s, Http2Frame(
        frameType: FramePriority,
        flags: 0,
        streamId: 1,
        payload: @[
          0x00'u8, 0x00'u8, 0x00'u8, 0x01'u8, # dependency=self
          0x20'u8
        ]
      ))

      var attempts = 0
      while attempts < 1:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameRstStream and frame.streamId == 1:
          rstErr = rstStreamErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return rstErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "PRIORITY self-dependency client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected RST_STREAM PROTOCOL_ERROR (1) for PRIORITY self-dependency, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects PRIORITY self-dependency"

# ============================================================
# Test 19: HTTP/2 strips request DATA padding from body
# ============================================================
block testH2StripsRequestDataPadding:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc lenHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, $req.body.len)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, lenHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "POST"),
      (":path", "/padded"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders,
      streamId: 1,
      payload: reqHeaders
    ))

    await sendH2Frame(s, Http2Frame(
      frameType: FrameData,
      flags: FlagPadded or FlagEndStream,
      streamId: 1,
      payload: @[
        3'u8,
        byte('o'),
        byte('k'),
        0'u8, 0'u8, 0'u8
      ]
    ))

    var body = ""
    var done = false
    while not done:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameData:
        for i in 0 ..< frame.payload.len:
          body.add char(frame.payload[i])
        if (frame.flags and FlagEndStream) != 0:
          done = true
      else:
        discard

    s.close()
    return body

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Padded-request client did not complete"
  assert not cf.hasError(), "Padded-request client failed unexpectedly"
  assert cf.read() == "2",
    "Expected request body length 2 after stripping DATA padding, got: " & cf.read()
  listener.close()
  echo "PASS: HTTP/2 strips request DATA padding from body"

# ============================================================
# Test 20: HTTP/2 rejects malformed padded request DATA
# ============================================================
block testH2RejectsMalformedPaddedRequestData:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "POST"),
        (":path", "/bad-padding"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders,
        streamId: 1,
        payload: reqHeaders
      ))

      # Invalid: pad length (5) exceeds payload bytes after pad-length field.
      await sendH2Frame(s, Http2Frame(
        frameType: FrameData,
        flags: FlagPadded or FlagEndStream,
        streamId: 1,
        payload: @[
          5'u8,
          byte('x')
        ]
      ))

      var attempts = 0
      while attempts < 2:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Malformed-padded DATA client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR (1) for malformed padded DATA, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects malformed padded request DATA"

# ============================================================
# Test 21: HTTP/2 rejects invalid SETTINGS_ENABLE_PUSH value
# ============================================================
block testH2RejectsInvalidEnablePushSetting:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendH2Frame(s, Http2Frame(
        frameType: FrameSettings,
        flags: 0,
        streamId: 0,
        payload: settingsPayload(@[(SettingsEnablePush, 2'u32)])
      ))

      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        discard
      if gotFrame and frame.frameType == FrameGoAway:
        goAwayErr = goAwayErrorCode(frame)
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Invalid-SETTINGS client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR (1) for invalid SETTINGS_ENABLE_PUSH, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects invalid SETTINGS_ENABLE_PUSH value"

# ============================================================
# Test 22: HTTP/2 rejects PING on non-zero stream as PROTOCOL_ERROR
# ============================================================
block testH2RejectsPingOnStream:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendH2Frame(s, Http2Frame(
        frameType: FramePing,
        flags: 0,
        streamId: 1,
        payload: @[1'u8, 2'u8, 3'u8, 4'u8, 5'u8, 6'u8, 7'u8, 8'u8]
      ))

      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        discard
      if gotFrame and frame.frameType == FrameGoAway:
        goAwayErr = goAwayErrorCode(frame)
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "PING-on-stream client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR (1) for PING on stream 1, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects PING on non-zero stream as PROTOCOL_ERROR"

# ============================================================
# Test 23: HTTP/2 treats stream WINDOW_UPDATE increment 0 as stream error
# ============================================================
block testH2RejectsZeroIncrementStreamWindowUpdate:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[int] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var outcome = 0

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "POST"),
        (":path", "/zero-window-inc"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders,
        streamId: 1,
        payload: reqHeaders
      ))

      await sendH2Frame(s, Http2Frame(
        frameType: FrameWindowUpdate,
        flags: 0,
        streamId: 1,
        payload: windowUpdatePayload(0'u32)
      ))

      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        discard
      if gotFrame:
        if frame.frameType == FrameRstStream and frame.streamId == 1:
          outcome = int(rstStreamErrorCode(frame))
        elif frame.frameType == FrameGoAway:
          outcome = -int(goAwayErrorCode(frame))
    except CatchableError:
      discard

    s.close()
    return outcome

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Zero-increment WINDOW_UPDATE client did not complete"
  var outcome = 0
  if not cf.hasError():
    outcome = cf.read()
  assert outcome == 1,
    "Expected RST_STREAM PROTOCOL_ERROR (1) for zero-increment stream WINDOW_UPDATE; got outcome " & $outcome
  listener.close()
  echo "PASS: HTTP/2 treats stream WINDOW_UPDATE increment 0 as stream error"

# ============================================================
# Test 24: HTTP/2 rejects invalid SETTINGS_ENABLE_CONNECT_PROTOCOL value
# ============================================================
block testH2RejectsInvalidEnableConnectProtocolSetting:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendH2Frame(s, Http2Frame(
        frameType: FrameSettings,
        flags: 0,
        streamId: 0,
        payload: settingsPayload(@[(SettingsEnableConnectProtocol, 2'u32)])
      ))

      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        discard
      if gotFrame and frame.frameType == FrameGoAway:
        goAwayErr = goAwayErrorCode(frame)
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Invalid-SETTINGS ENABLE_CONNECT_PROTOCOL client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR (1) for invalid SETTINGS_ENABLE_CONNECT_PROTOCOL, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects invalid SETTINGS_ENABLE_CONNECT_PROTOCOL value"

# ============================================================
# Test 25: HTTP/2 accepts valid request trailers
# ============================================================
block testH2AcceptsRequestTrailers:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc trailerHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, req.getHeader("x-trailer") & "|" & req.body)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, trailerHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "POST"),
      (":path", "/trailers"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders,
      streamId: 1,
      payload: reqHeaders
    ))

    let trailerHeaders = encodeHeaders(@[
      ("x-trailer", "t")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: trailerHeaders
    ))

    var status = 0
    var body = ""
    var rstErr = 0'u32
    var done = false
    var attempts = 0
    while not done and attempts < 6:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if not gotFrame:
        break

      case frame.frameType
      of FrameHeaders:
        let hdrs = decodeHeaders(frame.payload)
        for i in 0 ..< hdrs.len:
          if hdrs[i][0] == ":status":
            status = parseInt(hdrs[i][1])
      of FrameData:
        for i in 0 ..< frame.payload.len:
          body.add char(frame.payload[i])
        if (frame.flags and FlagEndStream) != 0:
          done = true
      of FrameRstStream:
        if frame.streamId == 1:
          rstErr = rstStreamErrorCode(frame)
          done = true
      else:
        discard
      inc attempts

    s.close()
    return $status & "|" & body & "|" & $rstErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Request-trailers client did not complete"
  assert not cf.hasError(), "Request-trailers client failed unexpectedly"
  assert cf.read() == "200|t||0",
    "Expected 200 with trailer visible to handler and no reset, got: " & cf.read()
  listener.close()
  echo "PASS: HTTP/2 accepts valid request trailers"

# ============================================================
# Test 26: HTTP/2 rejects :protocol on non-CONNECT requests
# ============================================================
block testH2RejectsProtocolPseudoHeaderOnNonConnect:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/bad-proto"),
        (":scheme", "http"),
        (":authority", "localhost"),
        (":protocol", "websocket")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders or FlagEndStream,
        streamId: 1,
        payload: reqHeaders
      ))

      var attempts = 0
      while attempts < 3:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameRstStream and frame.streamId == 1:
          rstErr = rstStreamErrorCode(frame)
          break
        if frame.streamId == 1 and frame.frameType == FrameHeaders and
            (frame.flags and FlagEndStream) != 0:
          break
        if frame.streamId == 1 and frame.frameType == FrameData and
            (frame.flags and FlagEndStream) != 0:
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return rstErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Non-CONNECT :protocol client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected RST_STREAM PROTOCOL_ERROR (1) for :protocol on non-CONNECT, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects :protocol on non-CONNECT requests"

# ============================================================
# Test 27: HTTP/2 rejects WINDOW_UPDATE on idle stream
# ============================================================
block testH2RejectsWindowUpdateOnIdleStream:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      # Stream 1 is idle (not opened with HEADERS) here.
      await sendH2Frame(s, Http2Frame(
        frameType: FrameWindowUpdate,
        flags: 0,
        streamId: 1,
        payload: windowUpdatePayload(1'u32)
      ))
      await sendH2Frame(s, Http2Frame(
        frameType: FramePing,
        flags: 0,
        streamId: 0,
        payload: @[1'u8, 2'u8, 3'u8, 4'u8, 5'u8, 6'u8, 7'u8, 8'u8]
      ))

      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        discard
      if gotFrame and frame.frameType == FrameGoAway:
        goAwayErr = goAwayErrorCode(frame)
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "WINDOW_UPDATE idle-stream client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR (1) for WINDOW_UPDATE on idle stream, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects WINDOW_UPDATE on idle stream"

# ============================================================
# Test 28: HTTP/2 rejects requests with host/:authority mismatch
# ============================================================
block testH2RejectsHostAuthorityMismatch:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/host-authority-mismatch"),
        (":scheme", "http"),
        (":authority", "good.example"),
        ("host", "evil.example")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders or FlagEndStream,
        streamId: 1,
        payload: reqHeaders
      ))

      var attempts = 0
      while attempts < 3:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameRstStream and frame.streamId == 1:
          rstErr = rstStreamErrorCode(frame)
          break
        if frame.streamId == 1 and frame.frameType == FrameHeaders and
            (frame.flags and FlagEndStream) != 0:
          break
        if frame.streamId == 1 and frame.frameType == FrameData and
            (frame.flags and FlagEndStream) != 0:
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return rstErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Host/:authority mismatch client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected RST_STREAM PROTOCOL_ERROR (1) for host/:authority mismatch, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects requests with host/:authority mismatch"

# ============================================================
# Test 29: HTTP/2 rejects requests with invalid :method token
# ============================================================
block testH2RejectsInvalidMethodToken:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "G ET"),
        (":path", "/bad-method"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders or FlagEndStream,
        streamId: 1,
        payload: reqHeaders
      ))

      var attempts = 0
      while attempts < 3:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameRstStream and frame.streamId == 1:
          rstErr = rstStreamErrorCode(frame)
          break
        if frame.streamId == 1 and frame.frameType == FrameHeaders and
            (frame.flags and FlagEndStream) != 0:
          break
        if frame.streamId == 1 and frame.frameType == FrameData and
            (frame.flags and FlagEndStream) != 0:
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return rstErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Invalid :method token client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected RST_STREAM PROTOCOL_ERROR (1) for invalid :method token, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects requests with invalid :method token"

# ============================================================
# Test 30: HTTP/2 rejects forbidden response headers from handlers
# ============================================================
block testH2RejectsForbiddenResponseHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc badHeaderHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok", @[("connection", "keep-alive")])

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, badHeaderHandler)

  proc clientTask(p: int): CpsFuture[int] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var statusCode = 0

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/bad-response-headers"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders or FlagEndStream,
        streamId: 1,
        payload: reqHeaders
      ))

      var done = false
      while not done:
        let frame = await recvH2Frame(reader)
        if frame.streamId != 1:
          continue
        if frame.frameType == FrameHeaders:
          var headerBlock = frame.payload
          var endHeaders = (frame.flags and FlagEndHeaders) != 0
          while not endHeaders:
            let cont = await recvH2Frame(reader)
            assert cont.frameType == FrameContinuation and cont.streamId == 1
            headerBlock.add cont.payload
            endHeaders = (cont.flags and FlagEndHeaders) != 0
          let hdrs = decodeHeaders(headerBlock)
          for i in 0 ..< hdrs.len:
            if hdrs[i][0] == ":status":
              statusCode = parseInt(hdrs[i][1])
              break
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          done = true
    except CatchableError:
      discard

    s.close()
    return statusCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Forbidden-response-headers client did not complete"
  var status = 0
  if not cf.hasError():
    status = cf.read()
  assert status == 500,
    "Expected HTTP 500 fallback when handler returns forbidden HTTP/2 response headers, got: " & $status
  listener.close()
  echo "PASS: HTTP/2 rejects forbidden response headers from handlers"

# ============================================================
# Test 31: HTTP/2 rejects GOAWAY on non-zero stream
# ============================================================
block testH2RejectsGoAwayOnNonZeroStream:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendH2Frame(s, Http2Frame(
        frameType: FrameGoAway,
        flags: 0,
        streamId: 1,
        payload: goAwayPayload(0'u32, 0'u32)
      ))

      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        discard
      if gotFrame and frame.frameType == FrameGoAway:
        goAwayErr = goAwayErrorCode(frame)
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "GOAWAY non-zero stream client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected GOAWAY PROTOCOL_ERROR (1) for GOAWAY on stream 1, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects GOAWAY on non-zero stream"

# ============================================================
# Test 32: HTTP/2 rejects malformed GOAWAY payload length
# ============================================================
block testH2RejectsMalformedGoAwayPayload:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendH2Frame(s, Http2Frame(
        frameType: FrameGoAway,
        flags: 0,
        streamId: 0,
        payload: @[0'u8, 0'u8, 0'u8, 0'u8]
      ))

      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        discard
      if gotFrame and frame.frameType == FrameGoAway:
        goAwayErr = goAwayErrorCode(frame)
    except CatchableError:
      discard

    s.close()
    return goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Malformed GOAWAY payload client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 6'u32,
    "Expected GOAWAY FRAME_SIZE_ERROR (6) for malformed GOAWAY payload, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects malformed GOAWAY payload length"

# ============================================================
# Test 33: HTTP/2 rejects invalid request content-length
# ============================================================
block testH2RejectsInvalidRequestContentLength:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "POST"),
        (":path", "/invalid-content-length"),
        (":scheme", "http"),
        (":authority", "localhost"),
        ("content-length", "abc")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders or FlagEndStream,
        streamId: 1,
        payload: reqHeaders
      ))

      var attempts = 0
      while attempts < 3:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameRstStream and frame.streamId == 1:
          rstErr = rstStreamErrorCode(frame)
          break
        if frame.streamId == 1 and frame.frameType == FrameHeaders and
            (frame.flags and FlagEndStream) != 0:
          break
        if frame.streamId == 1 and frame.frameType == FrameData and
            (frame.flags and FlagEndStream) != 0:
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return rstErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Invalid request content-length client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected RST_STREAM PROTOCOL_ERROR (1) for invalid request content-length, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects invalid request content-length"

# ============================================================
# Test 34: HTTP/2 rejects request body exceeding content-length
# ============================================================
block testH2RejectsRequestBodyExceedingContentLength:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[uint32] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "POST"),
        (":path", "/content-length-exceeded"),
        (":scheme", "http"),
        (":authority", "localhost"),
        ("content-length", "2")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders,
        streamId: 1,
        payload: reqHeaders
      ))
      await sendH2Frame(s, Http2Frame(
        frameType: FrameData,
        flags: FlagEndStream,
        streamId: 1,
        payload: @[byte('a'), byte('b'), byte('c')]
      ))

      var attempts = 0
      while attempts < 4:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break
        if frame.frameType == FrameRstStream and frame.streamId == 1:
          rstErr = rstStreamErrorCode(frame)
          break
        if frame.streamId == 1 and frame.frameType == FrameHeaders and
            (frame.flags and FlagEndStream) != 0:
          break
        if frame.streamId == 1 and frame.frameType == FrameData and
            (frame.flags and FlagEndStream) != 0:
          break
        inc attempts
    except CatchableError:
      discard

    s.close()
    return rstErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Request content-length exceeded client did not complete"
  var errCode = 0'u32
  if not cf.hasError():
    errCode = cf.read()
  assert errCode == 1'u32,
    "Expected RST_STREAM PROTOCOL_ERROR (1) for request body exceeding content-length, got: " & $errCode
  listener.close()
  echo "PASS: HTTP/2 rejects request body exceeding content-length"

# ============================================================
# Test 35: HTTP/2 rejects invalid response content-length from handlers
# ============================================================
block testH2RejectsInvalidResponseContentLength:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc badHeaderHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok", @[("content-length", "abc")])

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, badHeaderHandler)

  proc clientTask(p: int): CpsFuture[int] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var statusCode = 0

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/bad-response-content-length"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders or FlagEndStream,
        streamId: 1,
        payload: reqHeaders
      ))

      var done = false
      while not done:
        let frame = await recvH2Frame(reader)
        if frame.streamId != 1:
          continue
        if frame.frameType == FrameHeaders:
          var headerBlock = frame.payload
          var endHeaders = (frame.flags and FlagEndHeaders) != 0
          while not endHeaders:
            let cont = await recvH2Frame(reader)
            assert cont.frameType == FrameContinuation and cont.streamId == 1
            headerBlock.add cont.payload
            endHeaders = (cont.flags and FlagEndHeaders) != 0
          let hdrs = decodeHeaders(headerBlock)
          for i in 0 ..< hdrs.len:
            if hdrs[i][0] == ":status":
              statusCode = parseInt(hdrs[i][1])
              break
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          done = true
    except CatchableError:
      discard

    s.close()
    return statusCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Invalid response content-length client did not complete"
  var status = 0
  if not cf.hasError():
    status = cf.read()
  assert status == 500,
    "Expected HTTP 500 fallback for invalid response content-length, got: " & $status
  listener.close()
  echo "PASS: HTTP/2 rejects invalid response content-length from handlers"

# ============================================================
# Test 36: HTTP/2 rejects mismatched response content-length from handlers
# ============================================================
block testH2RejectsMismatchedResponseContentLength:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc badHeaderHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok", @[("content-length", "5")])

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, badHeaderHandler)

  proc clientTask(p: int): CpsFuture[int] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var statusCode = 0

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      let reqHeaders = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/mismatched-response-content-length"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders or FlagEndStream,
        streamId: 1,
        payload: reqHeaders
      ))

      var done = false
      while not done:
        let frame = await recvH2Frame(reader)
        if frame.streamId != 1:
          continue
        if frame.frameType == FrameHeaders:
          var headerBlock = frame.payload
          var endHeaders = (frame.flags and FlagEndHeaders) != 0
          while not endHeaders:
            let cont = await recvH2Frame(reader)
            assert cont.frameType == FrameContinuation and cont.streamId == 1
            headerBlock.add cont.payload
            endHeaders = (cont.flags and FlagEndHeaders) != 0
          let hdrs = decodeHeaders(headerBlock)
          for i in 0 ..< hdrs.len:
            if hdrs[i][0] == ":status":
              statusCode = parseInt(hdrs[i][1])
              break
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          done = true
    except CatchableError:
      discard

    s.close()
    return statusCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Mismatched response content-length client did not complete"
  var status = 0
  if not cf.hasError():
    status = cf.read()
  assert status == 500,
    "Expected HTTP 500 fallback for mismatched response content-length, got: " & $status
  listener.close()
  echo "PASS: HTTP/2 rejects mismatched response content-length from handlers"

echo ""
echo "All HTTP/2 chunked streaming tests passed!"
