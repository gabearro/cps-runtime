## WebSocket hardening regressions
##
## Focused protocol/compliance tests that target edge cases not covered by
## basic echo/interoperability tests.

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
import cps/http/server/ws
import cps/http/client/ws as client_ws

proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = posix.getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

proc readHttpResponseHeaders(s: AsyncStream): CpsFuture[string] {.cps.} =
  var response = ""
  while true:
    let chunk = await s.read(4096)
    if chunk.len == 0:
      break
    response &= chunk
    if "\r\n\r\n" in response:
      break
  return response

proc wsUpgradeRequest(path: string, key: string = "dGhlIHNhbXBsZSBub25jZQ=="): string =
  result = "GET " & path & " HTTP/1.1\r\n"
  result &= "Host: localhost\r\n"
  result &= "Upgrade: websocket\r\n"
  result &= "Connection: Upgrade\r\n"
  result &= "Sec-WebSocket-Key: " & key & "\r\n"
  result &= "Sec-WebSocket-Version: 13\r\n"
  result &= "\r\n"

proc buildWsFrame(opcode: byte, payload: string, masked: bool = true,
                  fin: bool = true): string =
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
    let maskKey = [0x11'u8, 0x22'u8, 0x33'u8, 0x44'u8]
    for i in 0 ..< 4:
      frame.add(maskKey[i])
    for i in 0 ..< payload.len:
      frame.add(uint8(payload[i].byte xor maskKey[i mod 4]))
  else:
    for i in 0 ..< payload.len:
      frame.add(payload[i].byte)

  result = newString(frame.len)
  for i in 0 ..< frame.len:
    result[i] = char(frame[i])

proc readSingleWsFrame(reader: BufferedReader): CpsFuture[(byte, string)] {.cps.} =
  let hdr = await reader.readExact(2)
  let b0 = hdr[0].byte
  let b1 = hdr[1].byte
  let opcode = b0 and 0x0F
  let masked = (b1 and 0x80'u8) != 0
  var payloadLen = (b1 and 0x7F'u8).int
  if payloadLen == 126:
    let extLen = await reader.readExact(2)
    payloadLen = (extLen[0].byte.int shl 8) or extLen[1].byte.int
  elif payloadLen == 127:
    let extLen = await reader.readExact(8)
    payloadLen = 0
    for i in 0 ..< 8:
      payloadLen = (payloadLen shl 8) or extLen[i].byte.int

  var maskKey: array[4, byte]
  if masked:
    let maskData = await reader.readExact(4)
    for i in 0 ..< 4:
      maskKey[i] = maskData[i].byte

  var payload = ""
  if payloadLen > 0:
    payload = await reader.readExact(payloadLen)
    if masked:
      var unmasked = newString(payloadLen)
      for i in 0 ..< payloadLen:
        unmasked[i] = char(payload[i].byte xor maskKey[i mod 4])
      payload = unmasked

  return (opcode, payload)

proc closeCode(payload: string): uint16 =
  if payload.len >= 2:
    return (payload[0].byte.uint16 shl 8) or payload[1].byte.uint16
  0'u16

proc echoWsHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  let wsConn = await acceptWebSocket(req)
  while true:
    let msg = await wsConn.recvMessage()
    if msg.kind == opClose:
      break
    elif msg.kind == opText:
      await wsConn.sendText(msg.data)
    elif msg.kind == opBinary:
      await wsConn.sendBinary(msg.data)
  return wsResponse()

proc readRequestAndGetKey(reader: BufferedReader): CpsFuture[string] {.cps.} =
  discard await reader.readLine() # Request line
  var key = ""
  while true:
    let line = await reader.readLine()
    if line.len == 0:
      break
    let colonPos = line.find(':')
    if colonPos > 0:
      let name = line[0 ..< colonPos].strip().toLowerAscii
      let value = line[colonPos + 1 .. ^1].strip()
      if name == "sec-websocket-key":
        key = value
  return key

block testRejectMalformedSecWebSocketKey:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    var req = wsUpgradeRequest("/ws", "not-base64")
    await s.write(req)
    let resp = await readHttpResponseHeaders(s)
    s.close()
    return resp

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let resp = cf.read()
  assert "101 Switching Protocols" notin resp,
    "Server accepted malformed Sec-WebSocket-Key: " & resp
  listener.close()
  echo "PASS: reject malformed Sec-WebSocket-Key"

block testRejectDuplicateSecWebSocketKey:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    var req = "GET /ws HTTP/1.1\r\n"
    req &= "Host: localhost\r\n"
    req &= "Upgrade: websocket\r\n"
    req &= "Connection: Upgrade\r\n"
    req &= "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    req &= "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    req &= "Sec-WebSocket-Version: 13\r\n"
    req &= "\r\n"
    await s.write(req)
    let resp = await readHttpResponseHeaders(s)
    s.close()
    return resp

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let resp = cf.read()
  assert "101 Switching Protocols" notin resp,
    "Server accepted duplicate Sec-WebSocket-Key: " & resp
  listener.close()
  echo "PASS: reject duplicate Sec-WebSocket-Key"

block testRejectInvalidConnectionToken:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    var req = "GET /ws HTTP/1.1\r\n"
    req &= "Host: localhost\r\n"
    req &= "Upgrade: websocket\r\n"
    req &= "Connection: keep-alive, notupgrade\r\n"
    req &= "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    req &= "Sec-WebSocket-Version: 13\r\n"
    req &= "\r\n"
    await s.write(req)
    let resp = await readHttpResponseHeaders(s)
    s.close()
    return resp

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let resp = cf.read()
  assert "101 Switching Protocols" notin resp,
    "Server accepted invalid Connection token list: " & resp
  listener.close()
  echo "PASS: reject invalid Connection token list"

block testRejectHttp10WebSocketUpgrade:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    var req = "GET /ws HTTP/1.0\r\n"
    req &= "Host: localhost\r\n"
    req &= "Upgrade: websocket\r\n"
    req &= "Connection: Upgrade\r\n"
    req &= "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    req &= "Sec-WebSocket-Version: 13\r\n"
    req &= "\r\n"
    await s.write(req)
    let resp = await readHttpResponseHeaders(s)
    s.close()
    return resp

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let resp = cf.read()
  assert "101 Switching Protocols" notin resp,
    "Server accepted HTTP/1.0 WebSocket upgrade: " & resp
  listener.close()
  echo "PASS: reject HTTP/1.0 WebSocket upgrade"

block testRejectNonMinimalLen126FrameEncoding:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    await s.write(wsUpgradeRequest("/ws"))
    let reader = newBufferedReader(s)
    while true:
      let line = await reader.readLine()
      if line.len == 0:
        break

    # Text payload length 1 encoded as 126 extended length (non-minimal).
    var frame = newString(2 + 2 + 4 + 1)
    frame[0] = char(0x81) # FIN text
    frame[1] = char(0x80 or 126) # masked + 126
    frame[2] = char(0x00)
    frame[3] = char(0x01)
    frame[4] = char(0x11)
    frame[5] = char(0x22)
    frame[6] = char(0x33)
    frame[7] = char(0x44)
    frame[8] = char('A'.byte xor 0x11'u8)
    await s.write(frame)

    try:
      let resp = await readSingleWsFrame(reader)
      s.close()
      # Rejection passes when server does not echo the malformed text.
      return not (resp[0] == 0x1'u8 and resp[1] == "A")
    except CatchableError:
      s.close()
      return true

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let rejected = cf.read()
  assert rejected, "Server accepted non-minimal 126-length frame encoding"
  listener.close()
  echo "PASS: reject non-minimal 126-length frame encoding"

block testRejectNonMinimalLen127FrameEncoding:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    await s.write(wsUpgradeRequest("/ws"))
    let reader = newBufferedReader(s)
    while true:
      let line = await reader.readLine()
      if line.len == 0:
        break

    # Text payload length 126 encoded as 127 extended length (non-minimal).
    let payloadLen = 126
    let payload = "A".repeat(payloadLen)
    var frame = newString(2 + 8 + 4 + payloadLen)
    frame[0] = char(0x81) # FIN text
    frame[1] = char(0x80 or 127) # masked + 127
    frame[2] = char(0x00)
    frame[3] = char(0x00)
    frame[4] = char(0x00)
    frame[5] = char(0x00)
    frame[6] = char(0x00)
    frame[7] = char(0x00)
    frame[8] = char(0x00)
    frame[9] = char(0x7E) # 126
    let m0 = 0x11'u8
    let m1 = 0x22'u8
    let m2 = 0x33'u8
    let m3 = 0x44'u8
    frame[10] = char(m0)
    frame[11] = char(m1)
    frame[12] = char(m2)
    frame[13] = char(m3)
    for i in 0 ..< payloadLen:
      let mb = [m0, m1, m2, m3][i mod 4]
      frame[14 + i] = char(payload[i].byte xor mb)
    await s.write(frame)

    try:
      let resp = await readSingleWsFrame(reader)
      s.close()
      return not (resp[0] == 0x1'u8 and resp[1] == payload)
    except CatchableError:
      s.close()
      return true

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let rejected = cf.read()
  assert rejected, "Server accepted non-minimal 127-length frame encoding"
  listener.close()
  echo "PASS: reject non-minimal 127-length frame encoding"

block testClientRejects101WithoutUpgradeHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc fakeServerTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)
    let wsKey = await readRequestAndGetKey(reader)
    let acceptKey = computeAcceptKey(wsKey)
    var resp = "HTTP/1.1 101 Switching Protocols\r\n"
    resp &= "Sec-WebSocket-Accept: " & acceptKey & "\r\n"
    resp &= "\r\n"
    await s.write(resp)
    s.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    try:
      let ws = await wsConnect("127.0.0.1", p, "/ws")
      ws.close()
      return true
    except CatchableError:
      return false

  let sf = fakeServerTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let accepted = cf.read()
  assert not accepted, "Client accepted 101 response without Upgrade/Connection headers"
  listener.close()
  echo "PASS: client rejects incomplete 101 upgrade response"

block testClientRejectsMalformedStatusLine:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc fakeServerTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)
    let wsKey = await readRequestAndGetKey(reader)
    let acceptKey = computeAcceptKey(wsKey)
    var resp = "HTTP/1.1 1010 Not Switching\r\n"
    resp &= "Upgrade: websocket\r\n"
    resp &= "Connection: Upgrade\r\n"
    resp &= "Sec-WebSocket-Accept: " & acceptKey & "\r\n"
    resp &= "\r\n"
    await s.write(resp)
    s.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    try:
      let ws = await wsConnect("127.0.0.1", p, "/ws")
      ws.close()
      return true
    except CatchableError:
      return false

  let sf = fakeServerTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let accepted = cf.read()
  assert not accepted, "Client accepted malformed HTTP status line for upgrade response"
  listener.close()
  echo "PASS: client rejects malformed upgrade status line"

block testClientRejectsDuplicateAcceptHeader:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc fakeServerTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)
    let wsKey = await readRequestAndGetKey(reader)
    let acceptKey = computeAcceptKey(wsKey)
    var resp = "HTTP/1.1 101 Switching Protocols\r\n"
    resp &= "Upgrade: websocket\r\n"
    resp &= "Connection: Upgrade\r\n"
    resp &= "Sec-WebSocket-Accept: " & acceptKey & "\r\n"
    resp &= "Sec-WebSocket-Accept: " & acceptKey & "\r\n"
    resp &= "\r\n"
    await s.write(resp)
    s.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    try:
      let ws = await wsConnect("127.0.0.1", p, "/ws")
      ws.close()
      return true
    except CatchableError:
      return false

  let sf = fakeServerTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let accepted = cf.read()
  assert not accepted, "Client accepted duplicate Sec-WebSocket-Accept header"
  listener.close()
  echo "PASS: client rejects duplicate Sec-WebSocket-Accept header"

block testClientAcceptsSplitConnectionHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc fakeServerTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)
    let wsKey = await readRequestAndGetKey(reader)
    let acceptKey = computeAcceptKey(wsKey)
    var resp = "HTTP/1.1 101 Switching Protocols\r\n"
    resp &= "Upgrade: websocket\r\n"
    resp &= "Connection: keep-alive\r\n"
    resp &= "Connection: Upgrade\r\n"
    resp &= "Sec-WebSocket-Accept: " & acceptKey & "\r\n"
    resp &= "\r\n"
    await s.write(resp)
    s.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    try:
      let ws = await wsConnect("127.0.0.1", p, "/ws")
      ws.close()
      return true
    except CatchableError:
      return false

  let sf = fakeServerTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let accepted = cf.read()
  assert accepted, "Client failed valid split Connection header handshake"
  listener.close()
  echo "PASS: client accepts split Connection headers"

block testClientRejectsUnsolicitedCompressionExtension:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc fakeServerTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)
    let wsKey = await readRequestAndGetKey(reader)
    let acceptKey = computeAcceptKey(wsKey)
    var resp = "HTTP/1.1 101 Switching Protocols\r\n"
    resp &= "Upgrade: websocket\r\n"
    resp &= "Connection: Upgrade\r\n"
    resp &= "Sec-WebSocket-Accept: " & acceptKey & "\r\n"
    resp &= "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\r\n"
    resp &= "\r\n"
    await s.write(resp)
    s.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    try:
      let ws = await wsConnect("127.0.0.1", p, "/ws", enableCompression = false)
      ws.close()
      return true
    except CatchableError:
      return false

  let sf = fakeServerTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let accepted = cf.read()
  assert not accepted, "Client accepted unsolicited permessage-deflate negotiation"
  listener.close()
  echo "PASS: client rejects unsolicited compression extension"

block testClientRejectsUnsupportedDeflateParams:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc fakeServerTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)
    let wsKey = await readRequestAndGetKey(reader)
    let acceptKey = computeAcceptKey(wsKey)
    var resp = "HTTP/1.1 101 Switching Protocols\r\n"
    resp &= "Upgrade: websocket\r\n"
    resp &= "Connection: Upgrade\r\n"
    resp &= "Sec-WebSocket-Accept: " & acceptKey & "\r\n"
    resp &= "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits=8\r\n"
    resp &= "\r\n"
    await s.write(resp)
    s.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    try:
      let ws = await wsConnect("127.0.0.1", p, "/ws", enableCompression = true)
      ws.close()
      return true
    except CatchableError:
      return false

  let sf = fakeServerTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let accepted = cf.read()
  assert not accepted, "Client accepted unsupported permessage-deflate parameters"
  listener.close()
  echo "PASS: client rejects unsupported permessage-deflate params"

block testClientRejectsUnknownExtensionWithDeflate:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc fakeServerTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)
    let wsKey = await readRequestAndGetKey(reader)
    let acceptKey = computeAcceptKey(wsKey)
    var resp = "HTTP/1.1 101 Switching Protocols\r\n"
    resp &= "Upgrade: websocket\r\n"
    resp &= "Connection: Upgrade\r\n"
    resp &= "Sec-WebSocket-Accept: " & acceptKey & "\r\n"
    resp &= "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover, x-foo\r\n"
    resp &= "\r\n"
    await s.write(resp)
    s.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    try:
      let ws = await wsConnect("127.0.0.1", p, "/ws", enableCompression = true)
      ws.close()
      return true
    except CatchableError:
      return false

  let sf = fakeServerTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let accepted = cf.read()
  assert not accepted, "Client accepted unknown extension alongside permessage-deflate"
  listener.close()
  echo "PASS: client rejects unknown extension alongside permessage-deflate"

block testClientRejectsMaskedServerFrames:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc fakeServerTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)
    let wsKey = await readRequestAndGetKey(reader)
    let acceptKey = computeAcceptKey(wsKey)
    var resp = "HTTP/1.1 101 Switching Protocols\r\n"
    resp &= "Upgrade: websocket\r\n"
    resp &= "Connection: Upgrade\r\n"
    resp &= "Sec-WebSocket-Accept: " & acceptKey & "\r\n"
    resp &= "\r\n"
    await s.write(resp)
    await s.write(buildWsFrame(0x1'u8, "masked-from-server", masked = true))
    s.close()

  proc clientTask(p: int): CpsFuture[uint16] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws")
    try:
      let msg = await wsConn.recvMessage()
      if msg.kind != opClose:
        return 0'u16
      return msg.closeCode
    except WsProtocolError as err:
      return err.closeCode
    except CatchableError:
      return 0'u16

  let sf = fakeServerTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let code = cf.read()
  assert code == 1002'u16, "Expected close code 1002 for masked server frame, got: " & $code
  listener.close()
  echo "PASS: client rejects masked server frames"

block testCloseWithoutStatusCodeGetsEmptyCloseResponse:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[int] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    await s.write(wsUpgradeRequest("/ws"))
    let reader = newBufferedReader(s)
    while true:
      let line = await reader.readLine()
      if line.len == 0:
        break
    await s.write(buildWsFrame(0x8'u8, "", masked = true))
    var frame: (byte, string)
    try:
      frame = await readSingleWsFrame(reader)
    except CatchableError:
      s.close()
      return -1
    s.close()
    if frame[0] != 0x8'u8:
      return -1
    return frame[1].len

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let payloadLen = cf.read()
  assert payloadLen == 0, "Expected empty close payload response, got length: " & $payloadLen
  listener.close()
  echo "PASS: close without status code gets empty close response"

block testRejectInvalidUtf8TextFrame:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[uint16] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    await s.write(wsUpgradeRequest("/ws"))
    let reader = newBufferedReader(s)
    while true:
      let line = await reader.readLine()
      if line.len == 0:
        break

    # Invalid UTF-8 sequence: C3 28
    await s.write(buildWsFrame(0x1, "\xC3\x28", masked = true))
    var frame: (byte, string)
    try:
      frame = await readSingleWsFrame(reader)
    except CatchableError:
      s.close()
      return 0'u16
    s.close()
    if frame[0] != 0x8'u8:
      return 0'u16
    return closeCode(frame[1])

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let code = cf.read()
  assert code == 1007'u16, "Expected close code 1007 for invalid UTF-8 text, got: " & $code
  listener.close()
  echo "PASS: reject invalid UTF-8 text frame"

block testRejectInvalidUtf8CloseReason:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[uint16] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    await s.write(wsUpgradeRequest("/ws"))
    let reader = newBufferedReader(s)
    while true:
      let line = await reader.readLine()
      if line.len == 0:
        break

    # Close code 1000 + invalid UTF-8 reason bytes
    var payload = "\x03\xe8"
    payload &= "\xC3\x28"
    await s.write(buildWsFrame(0x8, payload, masked = true))
    var frame: (byte, string)
    try:
      frame = await readSingleWsFrame(reader)
    except CatchableError:
      s.close()
      return 0'u16
    s.close()
    if frame[0] != 0x8'u8:
      return 0'u16
    return closeCode(frame[1])

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let code = cf.read()
  assert code == 1007'u16, "Expected close code 1007 for invalid UTF-8 close reason, got: " & $code
  listener.close()
  echo "PASS: reject invalid UTF-8 close reason"

block testLocalSendTextRejectsInvalidUtf8:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws")
    var rejected = false
    try:
      await wsConn.sendText("\xC3\x28")
    except WsProtocolError as err:
      rejected = err.closeCode == 1007'u16
    except CatchableError:
      rejected = false
    await wsConn.sendClose(1000)
    discard await wsConn.recvMessage()
    return rejected

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let rejected = cf.read()
  assert rejected, "sendText accepted invalid UTF-8 payload"
  listener.close()
  echo "PASS: local sendText rejects invalid UTF-8"

block testLocalSendCloseRejectsInvalidUtf8Reason:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws")
    var rejected = false
    try:
      await wsConn.sendClose(1000, "\xC3\x28")
    except WsProtocolError as err:
      rejected = err.closeCode == 1007'u16
    except CatchableError:
      rejected = false
    await wsConn.sendClose(1000)
    discard await wsConn.recvMessage()
    return rejected

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let rejected = cf.read()
  assert rejected, "sendClose accepted invalid UTF-8 reason"
  listener.close()
  echo "PASS: local sendClose rejects invalid UTF-8 reason"

block testLocalSendCloseRejectsInvalidCloseCode:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws")
    var rejected = false
    try:
      await wsConn.sendClose(1005'u16)
    except WsProtocolError as err:
      rejected = err.closeCode == 1002'u16
    except CatchableError:
      rejected = false
    await wsConn.sendClose(1000)
    discard await wsConn.recvMessage()
    return rejected

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let rejected = cf.read()
  assert rejected, "sendClose accepted invalid close code"
  listener.close()
  echo "PASS: local sendClose rejects invalid close code"

block testFragmentedSendWithCompressionRemainsValid:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws", enableCompression = true)
    await wsConn.sendFrame(opText, "hello ", fin = false)
    await wsConn.sendFrame(opContinuation, "world", fin = true)
    let msg = await wsConn.recvMessage()
    assert msg.kind == opText, "Expected text echo for fragmented send"
    assert msg.data == "hello world", "Fragmented message echo mismatch: " & msg.data
    await wsConn.sendClose(1000)
    discard await wsConn.recvMessage()
    return "OK"

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  assert cf.read() == "OK"
  listener.close()
  echo "PASS: fragmented send with compression remains protocol-valid"

block testRejectDataSendAfterCloseStarted:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws")
    await wsConn.sendClose(1000)
    var rejected = false
    try:
      await wsConn.sendText("after-close")
    except WsError:
      rejected = true
    except CatchableError:
      rejected = false
    discard await wsConn.recvMessage()
    return rejected

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  let rejected = cf.read()
  assert rejected, "sendText was accepted after close started"
  listener.close()
  echo "PASS: reject data send after close started"

echo ""
echo "All WebSocket hardening tests passed!"
