## Tests for HTTP/2 HEAD response semantics

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
import cps/http/shared/http2_stream_adapter

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
  await s.write(ConnectionPreface)
  await sendH2Frame(s, Http2Frame(
    frameType: FrameSettings,
    flags: 0,
    streamId: 0,
    payload: @[]
  ))

proc encodeHeaders(headers: seq[(string, string)]): seq[byte] =
  var enc = initHpackEncoder()
  enc.encode(headers)

proc decodeHeaders(payload: seq[byte]): seq[(string, string)] =
  var dec = initHpackDecoder()
  dec.decode(payload)

proc rstStreamErrorCode(frame: Http2Frame): uint32 =
  if frame.payload.len < 4:
    return 0'u32
  (uint32(frame.payload[0]) shl 24) or
  (uint32(frame.payload[1]) shl 16) or
  (uint32(frame.payload[2]) shl 8) or
  uint32(frame.payload[3])

proc goAwayErrorCode(frame: Http2Frame): uint32 =
  if frame.payload.len < 8:
    return 0'u32
  (uint32(frame.payload[4]) shl 24) or
  (uint32(frame.payload[5]) shl 16) or
  (uint32(frame.payload[6]) shl 8) or
  uint32(frame.payload[7])

block testH2ServerHeadDoesNotSendData:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()
  let body = "hello-head"

  proc headHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, body)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, headHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)

    await sendConnectionPreface(s)
    var sentServerSettingsAck = false
    var sawPeerSettingsAck = false
    var handshakeReads = 0
    while handshakeReads < 6 and not (sentServerSettingsAck and sawPeerSettingsAck):
      let frame = await recvH2Frame(reader)
      assert frame.frameType == FrameSettings
      if (frame.flags and FlagAck) != 0:
        sawPeerSettingsAck = true
      else:
        await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
        sentServerSettingsAck = true
      inc handshakeReads
    assert sentServerSettingsAck, "did not observe peer SETTINGS to ACK"
    assert sawPeerSettingsAck, "did not observe peer ACK of client SETTINGS"

    let reqHeaders = encodeHeaders(@[
      (":method", "HEAD"),
      (":path", "/head"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var statusCode = 0
    var contentLength = ""
    var sawData = false

    var attempts = 0
    var done = false
    while attempts < 10 and not done:
      var frame: Http2Frame
      try:
        frame = await recvH2Frame(reader)
      except CatchableError:
        done = true

      if frame.streamId != 1:
        inc attempts
        continue

      if frame.frameType == FrameHeaders:
        let decoded = decodeHeaders(frame.payload)
        for i in 0 ..< decoded.len:
          if decoded[i][0] == ":status":
            statusCode = parseInt(decoded[i][1])
          elif decoded[i][0] == "content-length":
            contentLength = decoded[i][1]
        if (frame.flags and FlagEndStream) != 0:
          done = true
      elif frame.frameType == FrameData:
        sawData = true
        if (frame.flags and FlagEndStream) != 0:
          done = true
      inc attempts

    s.close()
    return $statusCode & "|" & contentLength & "|" & (if sawData: "1" else: "0")

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "200|" & $body.len & "|0",
    "HEAD response must include metadata content-length and no DATA, got: " & result
  listener.close()
  echo "PASS: HTTP/2 server HEAD response sends no DATA"

block testH2Server205DoesNotSendData:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()
  let body = "reset-content"

  proc resetHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(205, body)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, resetHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)

    await sendConnectionPreface(s)
    var sentServerSettingsAck = false
    var sawPeerSettingsAck = false
    var handshakeReads = 0
    while handshakeReads < 6 and not (sentServerSettingsAck and sawPeerSettingsAck):
      let frame = await recvH2Frame(reader)
      assert frame.frameType == FrameSettings
      if (frame.flags and FlagAck) != 0:
        sawPeerSettingsAck = true
      else:
        await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
        sentServerSettingsAck = true
      inc handshakeReads
    assert sentServerSettingsAck, "did not observe peer SETTINGS to ACK"
    assert sawPeerSettingsAck, "did not observe peer ACK of client SETTINGS"

    let reqHeaders = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/reset"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var statusCode = 0
    var sawData = false
    var attempts = 0
    var done = false
    while attempts < 10 and not done:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              statusCode = parseInt(decoded[i][1])
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData:
          sawData = sawData or frame.payload.len > 0
          if (frame.flags and FlagEndStream) != 0:
            done = true
      inc attempts

    s.close()
    return $statusCode & "|" & (if sawData: "1" else: "0")

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "205|0",
    "205 response must not carry DATA payload, got: " & result
  listener.close()
  echo "PASS: HTTP/2 server 205 response sends no DATA"

block testH2ServerRejectsMissingAuthorityAndHost:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(204, "")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32
    var statusCode = 0

    await sendConnectionPreface(s)
    var sentServerSettingsAck = false
    var sawPeerSettingsAck = false
    var handshakeReads = 0
    while handshakeReads < 6 and not (sentServerSettingsAck and sawPeerSettingsAck):
      let frame = await recvH2Frame(reader)
      assert frame.frameType == FrameSettings
      if (frame.flags and FlagAck) != 0:
        sawPeerSettingsAck = true
      else:
        await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
        sentServerSettingsAck = true
      inc handshakeReads
    assert sentServerSettingsAck, "did not observe peer SETTINGS to ACK"
    assert sawPeerSettingsAck, "did not observe peer ACK of client SETTINGS"

    let reqHeaders = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/missing-authority"),
      (":scheme", "http")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var attempts = 0
    var done = false
    while attempts < 10 and not done:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameRstStream:
          rstErr = rstStreamErrorCode(frame)
          done = true
        elif frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              statusCode = parseInt(decoded[i][1])
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          done = true

      inc attempts

    s.close()
    return $rstErr & "|" & $statusCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "1|0",
    "missing authority+host should trigger PROTOCOL_ERROR RST_STREAM, got: " & result
  listener.close()
  echo "PASS: HTTP/2 rejects request missing both :authority and host"

block testH2ServerRejectsEmptyHostWhenAuthorityMissing:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(204, "")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32
    var statusCode = 0

    await sendConnectionPreface(s)
    var sentServerSettingsAck = false
    var sawPeerSettingsAck = false
    var handshakeReads = 0
    while handshakeReads < 6 and not (sentServerSettingsAck and sawPeerSettingsAck):
      let frame = await recvH2Frame(reader)
      assert frame.frameType == FrameSettings
      if (frame.flags and FlagAck) != 0:
        sawPeerSettingsAck = true
      else:
        await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
        sentServerSettingsAck = true
      inc handshakeReads
    assert sentServerSettingsAck, "did not observe peer SETTINGS to ACK"
    assert sawPeerSettingsAck, "did not observe peer ACK of client SETTINGS"

    let reqHeaders = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/empty-host"),
      (":scheme", "http"),
      ("host", "")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var attempts = 0
    var done = false
    while attempts < 10 and not done:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameRstStream:
          rstErr = rstStreamErrorCode(frame)
          done = true
        elif frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              statusCode = parseInt(decoded[i][1])
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          done = true

      inc attempts

    s.close()
    return $rstErr & "|" & $statusCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "1|0",
    "empty host without :authority should trigger PROTOCOL_ERROR RST_STREAM, got: " & result
  listener.close()
  echo "PASS: HTTP/2 rejects empty host when :authority is missing"

block testH2ServerRejectsInvalidPathWithSpace:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(204, "")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32
    var statusCode = 0

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/bad path"),
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
    var done = false
    while attempts < 10 and not done:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameRstStream:
          rstErr = rstStreamErrorCode(frame)
          done = true
        elif frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              statusCode = parseInt(decoded[i][1])
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          done = true

      inc attempts

    s.close()
    return $rstErr & "|" & $statusCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "1|0",
    "invalid :path with space should trigger PROTOCOL_ERROR RST_STREAM, got: " & result
  listener.close()
  echo "PASS: HTTP/2 rejects invalid :path containing spaces"

block testH2ServerRejectsPathContainingFragment:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(204, "")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32
    var statusCode = 0

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/bad#fragment"),
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
    var done = false
    while attempts < 10 and not done:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameRstStream:
          rstErr = rstStreamErrorCode(frame)
          done = true
        elif frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              statusCode = parseInt(decoded[i][1])
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          done = true

      inc attempts

    s.close()
    return $rstErr & "|" & $statusCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "1|0",
    "invalid :path containing fragment should trigger PROTOCOL_ERROR RST_STREAM, got: " & result
  listener.close()
  echo "PASS: HTTP/2 rejects invalid :path containing fragment"

block testH2ServerRejectsInvalidAuthorityWithSpace:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(204, "")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32
    var statusCode = 0

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/bad-authority"),
      (":scheme", "http"),
      (":authority", "bad host")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var attempts = 0
    var done = false
    while attempts < 10 and not done:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameRstStream:
          rstErr = rstStreamErrorCode(frame)
          done = true
        elif frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              statusCode = parseInt(decoded[i][1])
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          done = true

      inc attempts

    s.close()
    return $rstErr & "|" & $statusCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "1|0",
    "invalid :authority with space should trigger PROTOCOL_ERROR RST_STREAM, got: " & result
  listener.close()
  echo "PASS: HTTP/2 rejects invalid :authority containing spaces"

block testH2HostHeaderFallbackPopulatesRequestAuthority:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc echoAuthorityHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, req.authority)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, echoAuthorityHandler)

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
      (":method", "GET"),
      (":path", "/authority-fallback"),
      (":scheme", "http"),
      ("host", "example.com")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var body = ""
    var done = false
    var attempts = 0
    while attempts < 16 and not done:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameData:
          for i in 0 ..< frame.payload.len:
            body.add char(frame.payload[i])
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameHeaders and (frame.flags and FlagEndStream) != 0:
          done = true

      inc attempts

    s.close()
    return body

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "example.com",
    "host fallback should populate req.authority, got: " & result
  listener.close()
  echo "PASS: HTTP/2 host fallback populates request authority"

block testH2ServerRejectsRstOnIdleGapStream:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/gap-stream"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders,
      streamId: 5,
      payload: reqHeaders
    ))

    await sendH2Frame(s, Http2Frame(
      frameType: FrameRstStream,
      flags: 0,
      streamId: 3,
      payload: @[0'u8, 0'u8, 0'u8, 0'u8]
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

    s.close()
    var frameType = -1
    if gotFrame:
      frameType = int(frame.frameType)
    return $frameType & "|" & $goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "7|1",
    "RST_STREAM on idle gap stream should trigger GOAWAY PROTOCOL_ERROR (1), got: " & result
  listener.close()
  echo "PASS: HTTP/2 rejects RST_STREAM on idle gap stream IDs"

block testH2ServerRejectsWindowUpdateOnIdleGapStream:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(204, "")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/gap-window"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders,
      streamId: 5,
      payload: reqHeaders
    ))

    await sendH2Frame(s, Http2Frame(
      frameType: FrameWindowUpdate,
      flags: 0,
      streamId: 3,
      payload: @[0'u8, 0'u8, 0'u8, 1'u8]
    ))

    await sendH2Frame(s, Http2Frame(
      frameType: FramePing,
      flags: 0,
      streamId: 0,
      payload: @[8'u8, 7'u8, 6'u8, 5'u8, 4'u8, 3'u8, 2'u8, 1'u8]
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

    var frameType = -1
    if gotFrame:
      frameType = int(frame.frameType)
    s.close()
    return $frameType & "|" & $goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "7|1",
    "WINDOW_UPDATE on idle gap stream should trigger GOAWAY PROTOCOL_ERROR (1), got: " & result
  listener.close()
  echo "PASS: HTTP/2 rejects WINDOW_UPDATE on idle gap stream IDs"

block testH2ServerRejectsDataOnIdleGapStream:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(204, "")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/gap-data"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders,
      streamId: 5,
      payload: reqHeaders
    ))

    await sendH2Frame(s, Http2Frame(
      frameType: FrameData,
      flags: FlagEndStream,
      streamId: 3,
      payload: @[byte('x')]
    ))

    await sendH2Frame(s, Http2Frame(
      frameType: FramePing,
      flags: 0,
      streamId: 0,
      payload: @[9'u8, 9'u8, 9'u8, 9'u8, 9'u8, 9'u8, 9'u8, 9'u8]
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

    var frameType = -1
    if gotFrame:
      frameType = int(frame.frameType)
    s.close()
    return $frameType & "|" & $goAwayErr

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "7|1",
    "DATA on idle gap stream should trigger GOAWAY PROTOCOL_ERROR (1), got: " & result
  listener.close()
  echo "PASS: HTTP/2 rejects DATA on idle gap stream IDs"

block testH2HandledResponseWithoutWriteStillStartsWithHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc handledOnly(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    discard req
    return handledResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, handledOnly)

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
      (":method", "GET"),
      (":path", "/handled-only"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var frame: Http2Frame
    var got = false
    try:
      frame = await recvH2Frame(reader)
      got = true
    except CatchableError:
      discard
    s.close()
    if not got:
      return "-1|0"
    return $int(frame.frameType) & "|" & $int(frame.streamId)

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "1|1",
    "handledResponse without direct write should still start with HEADERS, got: " & result
  listener.close()
  echo "PASS: HTTP/2 handledResponse fallback begins with HEADERS"

block testH2MixedStreamWriteAndNormalResponseAvoidsDuplicateHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc mixedHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    await req.stream.write("streamed")
    return newResponse(200, "normal")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, mixedHandler)

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
      (":method", "GET"),
      (":path", "/mixed-write"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var headerCount = 0
    var endStreamSeen = false
    var attempts = 0
    while attempts < 16 and not endStreamSeen:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        endStreamSeen = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          var hasStatus = false
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              hasStatus = true
          if hasStatus:
            inc headerCount
          if (frame.flags and FlagEndStream) != 0:
            endStreamSeen = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          endStreamSeen = true
      inc attempts

    s.close()
    return $headerCount

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "1",
    "mixed req.stream.write + normal response must not emit duplicate status HEADERS, got: " & result
  listener.close()
  echo "PASS: HTTP/2 prevents duplicate status HEADERS on mixed stream writes"

block testH2PlainConnectDispatchesBeforeEndStream:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()
  var handlerInvoked = false

  proc connectHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    if req.meth == "CONNECT":
      handlerInvoked = true
    return handledResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, connectHandler)

  proc clientTask(p: int): CpsVoidFuture {.cps.} =
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
      (":method", "CONNECT"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders, # no END_STREAM
      streamId: 1,
      payload: reqHeaders
    ))

    await cpsSleep(30)
    s.close()

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "client task did not complete"
  assert handlerInvoked, "plain CONNECT should dispatch handler before END_STREAM"
  listener.close()
  echo "PASS: HTTP/2 plain CONNECT dispatches before END_STREAM"

block testH2ServerRejectsPlainConnectWithEmptyPathPseudo:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(204, "")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32
    var statusCode = 0

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "CONNECT"),
      (":authority", "localhost"),
      (":path", "")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var attempts = 0
    var done = false
    while attempts < 10 and not done:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameRstStream:
          rstErr = rstStreamErrorCode(frame)
          done = true
        elif frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              statusCode = parseInt(decoded[i][1])
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          done = true

      inc attempts

    s.close()
    return $rstErr & "|" & $statusCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "1|0",
    "plain CONNECT with empty :path pseudo-header should trigger PROTOCOL_ERROR RST_STREAM, got: " & result
  listener.close()
  echo "PASS: HTTP/2 rejects plain CONNECT with empty :path pseudo-header"

block testH2ServerRejectsEmptyProtocolPseudoOnNonConnect:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(204, "")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32
    var statusCode = 0

    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/bad-empty-proto"),
      (":scheme", "http"),
      (":authority", "localhost"),
      (":protocol", "")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var attempts = 0
    var done = false
    while attempts < 10 and not done:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameRstStream:
          rstErr = rstStreamErrorCode(frame)
          done = true
        elif frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              statusCode = parseInt(decoded[i][1])
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          done = true

      inc attempts

    s.close()
    return $rstErr & "|" & $statusCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "1|0",
    "non-CONNECT with empty :protocol pseudo-header should trigger PROTOCOL_ERROR RST_STREAM, got: " & result
  listener.close()
  echo "PASS: HTTP/2 rejects non-CONNECT empty :protocol pseudo-header"

block testH2ConcurrentDirectWritesDoNotDuplicateHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc concurrentWriteHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let w1 = req.stream.write("one")
    let w2 = req.stream.write("two")
    await w1
    await w2
    return handledResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, concurrentWriteHandler)

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
      (":method", "GET"),
      (":path", "/concurrent-direct-writes"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqHeaders
    ))

    var statusHeaderCount = 0
    var body = ""
    var done = false
    var attempts = 0
    while attempts < 24 and not done:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              inc statusHeaderCount
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData:
          for i in 0 ..< frame.payload.len:
            body.add char(frame.payload[i])
          if (frame.flags and FlagEndStream) != 0:
            done = true
      inc attempts

    s.close()
    return $statusHeaderCount & "|" & body

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "1|onetwo",
    "concurrent direct writes should emit one status HEADERS and body 'onetwo', got: " & result
  listener.close()
  echo "PASS: HTTP/2 concurrent direct writes emit single status HEADERS"

block testH2ResponseContinuationBlocksAreNotInterleaved:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()
  let hugeHeaderValue = "abcdefghijklmnop".repeat(4096)

  proc bigHeaderHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    if req.path == "/one":
      return newResponse(200, "one", @[("x-big", hugeHeaderValue)])
    return newResponse(200, "two")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, bigHeaderHandler)

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

    let reqOne = encodeHeaders(@[
      (":method", "GET"),
      (":path", "/one"),
      (":scheme", "http"),
      (":authority", "localhost")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 1,
      payload: reqOne
    ))

    var sentSecondRequest = false
    var sawFragmentedHeader = false
    var awaitingContinuation = false
    var interleaved = false
    var stream1Ended = false
    var stream3Ended = false
    var attempts = 0

    while attempts < 128 and not (stream1Ended and stream3Ended):
      let frame = await recvH2Frame(reader)

      if not sentSecondRequest and frame.streamId == 1 and frame.frameType == FrameHeaders and
          (frame.flags and FlagEndHeaders) == 0:
        sawFragmentedHeader = true
        awaitingContinuation = true
        let reqTwo = encodeHeaders(@[
          (":method", "GET"),
          (":path", "/two"),
          (":scheme", "http"),
          (":authority", "localhost")
        ])
        await sendH2Frame(s, Http2Frame(
          frameType: FrameHeaders,
          flags: FlagEndHeaders or FlagEndStream,
          streamId: 3,
          payload: reqTwo
        ))
        sentSecondRequest = true
      elif awaitingContinuation:
        if frame.streamId != 1 or frame.frameType != FrameContinuation:
          interleaved = true
          break
        if (frame.flags and FlagEndHeaders) != 0:
          awaitingContinuation = false

      if frame.streamId == 1 and (frame.flags and FlagEndStream) != 0:
        stream1Ended = true
      if frame.streamId == 3 and (frame.flags and FlagEndStream) != 0:
        stream3Ended = true

      inc attempts

    s.close()
    return $(if sawFragmentedHeader: 1 else: 0) & "|" &
           $(if interleaved: 1 else: 0) & "|" &
           $(if stream1Ended: 1 else: 0) & "|" &
           $(if stream3Ended: 1 else: 0)

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 80_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result.startsWith("1|"), "test must observe a fragmented response header block, got: " & result
  assert result.startsWith("1|0|"), "response continuation blocks were interleaved across streams, got: " & result
  listener.close()
  echo "PASS: HTTP/2 response CONTINUATION blocks are not interleaved"

block testH2AdapterConcurrentFirstWriteSendsHeadersOnce:
  var headersSent = 0
  var dataWrites = 0

  proc sendHeaders(streamId: uint32, statusCode: int,
                   headers: seq[(string, string)]): CpsVoidFuture {.cps.} =
    discard streamId
    discard statusCode
    discard headers
    inc headersSent
    await cpsSleep(1)

  proc sendData(streamId: uint32, data: string): CpsVoidFuture {.cps.} =
    discard streamId
    discard data
    inc dataWrites
    await cpsSleep(1)

  let adapter = newHttp2StreamAdapter(1, sendHeaders, sendData)
  let w1 = adapter.write("first")
  let w2 = adapter.write("second")

  let loop = getEventLoop()
  var ticks = 0
  while (not w1.finished or not w2.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert w1.finished and w2.finished, "adapter concurrent writes did not complete"
  assert not w1.hasError(), "first write unexpectedly failed"
  assert not w2.hasError(), "second write unexpectedly failed"
  assert dataWrites == 2, "expected two DATA writes, got: " & $dataWrites
  assert headersSent == 1, "adapter must send response HEADERS exactly once, got: " & $headersSent
  echo "PASS: HTTP/2 adapter concurrent first write sends headers once"

block testH2RejectsExtendedConnectWithoutEnableConnectSetting:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var rstErr = 0'u32
    var statusCode = 0

    await sendConnectionPreface(s) # Sends empty SETTINGS; no ENABLE_CONNECT_PROTOCOL
    let serverSettings = await recvH2Frame(reader)
    assert serverSettings.frameType == FrameSettings
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let serverAck = await recvH2Frame(reader)
    assert serverAck.frameType == FrameSettings
    assert (serverAck.flags and FlagAck) != 0

    let reqHeaders = encodeHeaders(@[
      (":method", "CONNECT"),
      (":protocol", "websocket"),
      (":path", "/ws"),
      (":scheme", "http"),
      (":authority", "localhost"),
      ("sec-websocket-version", "13")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders,
      streamId: 1,
      payload: reqHeaders
    ))

    var done = false
    var attempts = 0
    while attempts < 10 and not done:
      var frame: Http2Frame
      var gotFrame = false
      try:
        frame = await recvH2Frame(reader)
        gotFrame = true
      except CatchableError:
        done = true

      if gotFrame and frame.streamId == 1:
        if frame.frameType == FrameRstStream:
          rstErr = rstStreamErrorCode(frame)
          done = true
        elif frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              statusCode = parseInt(decoded[i][1])
          if (frame.flags and FlagEndStream) != 0:
            done = true
        elif frame.frameType == FrameData and (frame.flags and FlagEndStream) != 0:
          done = true
      inc attempts

    s.close()
    return $rstErr & "|" & $statusCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while (not sf.finished or not cf.finished) and ticks < 50_000:
    loop.tick()
    inc ticks

  assert sf.finished, "server task did not complete"
  assert cf.finished, "client task did not complete"
  let result = cf.read()
  assert result == "1|0",
    "extended CONNECT without ENABLE_CONNECT_PROTOCOL should be RST_STREAM PROTOCOL_ERROR, got: " & result
  listener.close()
  echo "PASS: HTTP/2 rejects extended CONNECT without ENABLE_CONNECT_PROTOCOL"

echo ""
echo "All HTTP/2 HEAD semantic tests passed!"
