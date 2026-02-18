## Tests for WebSocket over HTTP/2
##
## Tests WebSocket (RFC 8441 Extended CONNECT) over HTTP/2 connections
## using plain TCP (HTTP/2 prior knowledge, no TLS). The client
## manually constructs HTTP/2 frames containing WebSocket frames
## as DATA payloads.

import std/[strutils, nativesockets, sysrand, base64]
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
import cps/http/server/ws

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

proc buildWsFrame(opcode: byte, payload: string, masked: bool = false,
                  fin: bool = true): string =
  ## Build a raw WebSocket frame as a string.
  var frame: seq[byte]
  let b0 = (if fin: 0x80'u8 else: 0x00'u8) or opcode
  frame.add(b0)
  let maskBit = if masked: 0x80'u8 else: 0x00'u8
  if payload.len < 126:
    frame.add(maskBit or payload.len.uint8)
  elif payload.len <= 0xFFFF:
    frame.add(maskBit or 126'u8)
    frame.add(uint8(payload.len shr 8))
    frame.add(uint8(payload.len and 0xFF))
  else:
    frame.add(maskBit or 127'u8)
    for i in countdown(7, 0):
      frame.add(uint8((payload.len shr (i * 8)) and 0xFF))
  if masked:
    let rnd = urandom(4)
    for i in 0 ..< 4:
      frame.add(rnd[i])
    for i in 0 ..< payload.len:
      frame.add(uint8(payload[i].byte xor rnd[i mod 4]))
  else:
    for i in 0 ..< payload.len:
      frame.add(payload[i].byte)
  result = newString(frame.len)
  for i in 0 ..< frame.len:
    result[i] = char(frame[i])

proc sendWsFrameOverH2(s: AsyncStream, streamId: uint32,
                        opcode: byte, payload: string,
                        masked: bool = false): CpsVoidFuture {.cps.} =
  ## Send a WebSocket frame embedded in an HTTP/2 DATA frame.
  let wsFrame = buildWsFrame(opcode, payload, masked)
  var wsBytes = newSeq[byte](wsFrame.len)
  for i in 0 ..< wsFrame.len:
    wsBytes[i] = byte(wsFrame[i])
  let h2Frame = Http2Frame(
    frameType: FrameData,
    flags: 0,
    streamId: streamId,
    payload: wsBytes
  )
  await sendH2Frame(s, h2Frame)

proc parseWsFrame(data: string): (byte, string) =
  let b0 = data[0].byte
  let b1 = data[1].byte
  let opcode = b0 and 0x0F
  let masked = (b1 and 0x80) != 0
  var payloadLen = (b1 and 0x7F).int
  var pos = 2
  if payloadLen == 126:
    payloadLen = (data[2].byte.int shl 8) or data[3].byte.int
    pos = 4
  elif payloadLen == 127:
    payloadLen = 0
    for i in 0 ..< 8:
      payloadLen = (payloadLen shl 8) or data[pos + i].byte.int
    pos += 8
  var maskKey: array[4, byte]
  if masked:
    for i in 0 ..< 4:
      maskKey[i] = data[pos + i].byte
    pos += 4
  var payload = newString(payloadLen)
  for i in 0 ..< payloadLen:
    if masked:
      payload[i] = char(data[pos + i].byte xor maskKey[i mod 4])
    else:
      payload[i] = data[pos + i]
  return (opcode, payload)

# ============================================================
# Test 1: WebSocket echo over HTTP/2 Extended CONNECT
# ============================================================
block testWsEchoH2:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc wsEchoHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let wsConn = await acceptWebSocket(req)
    while true:
      let msg = await wsConn.recvMessage()
      if msg.kind == opClose:
        break
      elif msg.kind == opText:
        await wsConn.sendText(msg.data)
    return wsResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, h)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)

    # HTTP/2 connection setup
    await sendConnectionPreface(s)
    let serverSettings = await recvH2Frame(reader)
    await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
    let settingsAck = await recvH2Frame(reader)

    # Send Extended CONNECT for WebSocket (RFC 8441)
    # Note: no END_STREAM flag — stream stays open for data
    let headers = encodeHeaders(@[
      (":method", "CONNECT"),
      (":protocol", "websocket"),
      (":path", "/ws"),
      (":scheme", "http"),
      (":authority", "localhost"),
      ("sec-websocket-version", "13")
    ])
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders,  # No FlagEndStream
      streamId: 1,
      payload: headers
    ))

    # Read response HEADERS (should be :status=200)
    var gotResponseHeaders = false
    var statusCode = ""
    while not gotResponseHeaders:
      let frame = await recvH2Frame(reader)
      if frame.frameType == FrameHeaders and frame.streamId == 1:
        let respHeaders = decodeHeaders(frame.payload)
        for (k, v) in respHeaders:
          if k == ":status":
            statusCode = v
        gotResponseHeaders = true
      elif frame.frameType == FrameWindowUpdate:
        discard
      elif frame.frameType == FrameSettings:
        discard

    # Now send a WebSocket text frame inside an HTTP/2 DATA frame
    await sendWsFrameOverH2(s, 1, 0x1, "hello h2 ws")

    # Read response: expect a DATA frame containing a WebSocket text frame
    var responsePayload = ""
    while true:
      let frame = await recvH2Frame(reader)
      if frame.frameType == FrameData and frame.streamId == 1:
        var dataStr = newString(frame.payload.len)
        for i in 0 ..< frame.payload.len:
          dataStr[i] = char(frame.payload[i])
        let parsed = parseWsFrame(dataStr)
        let op = parsed[0]
        responsePayload = parsed[1]
        break
      elif frame.frameType == FrameWindowUpdate:
        discard

    # Send WebSocket close frame
    await sendWsFrameOverH2(s, 1, 0x8, "\x03\xe8")

    s.close()
    return statusCode & ":" & responsePayload

  let sf = serverTask(listener, config, wsEchoHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "200:hello h2 ws", "Expected '200:hello h2 ws', got: '" & result & "'"
  listener.close()
  echo "PASS: WebSocket echo over HTTP/2"

# ============================================================
# Test 2: Multiple WebSocket messages over HTTP/2
# ============================================================
block testMultipleWsMsgsH2:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc wsEchoHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let wsConn = await acceptWebSocket(req)
    while true:
      let msg = await wsConn.recvMessage()
      if msg.kind == opClose:
        break
      elif msg.kind == opText:
        await wsConn.sendText("echo:" & msg.data)
    return wsResponse()

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
      payload: headers
    ))

    # Wait for response headers
    while true:
      let frame = await recvH2Frame(reader)
      if frame.frameType == FrameHeaders and frame.streamId == 1:
        break
      elif frame.frameType == FrameWindowUpdate or frame.frameType == FrameSettings:
        discard

    # Send and receive 3 messages
    var responses: seq[string]
    for i in 0 ..< 3:
      await sendWsFrameOverH2(s, 1, 0x1, "msg" & $i)
      # Read response
      while true:
        let frame = await recvH2Frame(reader)
        if frame.frameType == FrameData and frame.streamId == 1:
          var dataStr = newString(frame.payload.len)
          for j in 0 ..< frame.payload.len:
            dataStr[j] = char(frame.payload[j])
          let parsed = parseWsFrame(dataStr)
          responses.add parsed[1]
          break
        elif frame.frameType == FrameWindowUpdate:
          discard

    # Close
    await sendWsFrameOverH2(s, 1, 0x8, "\x03\xe8")
    s.close()
    return responses[0] & "|" & responses[1] & "|" & responses[2]

  let sf = serverTask(listener, config, wsEchoHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "echo:msg0|echo:msg1|echo:msg2",
    "Expected 'echo:msg0|echo:msg1|echo:msg2', got: '" & result & "'"
  listener.close()
  echo "PASS: Multiple WebSocket messages over HTTP/2"

# ============================================================
# Test 3: Same WS handler works for both HTTP/1.1 and HTTP/2
# ============================================================
block testSameHandlerBothProtocols:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  # This is the exact same handler — no protocol-specific code
  proc universalWsHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let wsConn = await acceptWebSocket(req)
    let msg = await wsConn.recvMessage()
    if msg.kind == opText:
      await wsConn.sendText("universal:" & msg.data)
    return wsResponse()

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
      payload: headers
    ))

    while true:
      let frame = await recvH2Frame(reader)
      if frame.frameType == FrameHeaders and frame.streamId == 1:
        break
      elif frame.frameType == FrameWindowUpdate or frame.frameType == FrameSettings:
        discard

    await sendWsFrameOverH2(s, 1, 0x1, "test")

    var responsePayload = ""
    while true:
      let frame = await recvH2Frame(reader)
      if frame.frameType == FrameData and frame.streamId == 1:
        var dataStr = newString(frame.payload.len)
        for i in 0 ..< frame.payload.len:
          dataStr[i] = char(frame.payload[i])
        let parsed = parseWsFrame(dataStr)
        responsePayload = parsed[1]
        break
      elif frame.frameType == FrameWindowUpdate:
        discard

    await sendWsFrameOverH2(s, 1, 0x8, "\x03\xe8")
    s.close()
    return responsePayload

  let sf = serverTask(listener, config, universalWsHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "universal:test", "Expected 'universal:test', got: '" & result & "'"
  listener.close()
  echo "PASS: Same WS handler works for HTTP/2"

echo ""
echo "All HTTP/2 WebSocket tests passed!"
