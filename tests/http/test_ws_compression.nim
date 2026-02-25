## Tests for WebSocket permessage-deflate compression

import std/[strutils, nativesockets, sysrand, base64]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/server/ws
import cps/http/client/ws as client_ws
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

proc pseudoRandomBytes(n: int): string =
  ## Deterministic pseudo-random byte sequence for stable tests.
  var state = 0x1234ABCD'u32
  result = newString(n)
  for i in 0 ..< n:
    state = state * 1664525'u32 + 1013904223'u32
    result[i] = char((state shr 24).int and 0xFF)

# ============================================================
# Test 1: permessage-deflate negotiation
# ============================================================

block testDeflateNegotiation:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  # Use raw client to check the extension header
  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let wsKey = base64.encode(urandom(16))
    var reqStr = "GET /ws HTTP/1.1\r\n"
    reqStr &= "Host: localhost\r\n"
    reqStr &= "Upgrade: websocket\r\n"
    reqStr &= "Connection: Upgrade\r\n"
    reqStr &= "Sec-WebSocket-Key: " & wsKey & "\r\n"
    reqStr &= "Sec-WebSocket-Version: 13\r\n"
    reqStr &= "Sec-WebSocket-Extensions: permessage-deflate\r\n"
    reqStr &= "\r\n"
    await s.write(reqStr)
    var response = ""
    while true:
      let chunk = await s.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
      if "\r\n\r\n" in response:
        break
    s.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let resp = cf.read()
  assert "101 Switching Protocols" in resp
  assert "Sec-WebSocket-Extensions: permessage-deflate" in resp,
    "Expected permessage-deflate in response, got: " & resp
  listener.close()
  echo "PASS: permessage-deflate negotiation"

# ============================================================
# Test 2: Compressed text message echo roundtrip
# ============================================================

block testCompressedTextEcho:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws", enableCompression = true)
    assert wsConn.compressEnabled, "Expected compression to be enabled"

    # Send a text message (will be compressed by sendFrame)
    let testMsg = "Hello, compressed WebSocket! ".repeat(10)
    await wsConn.sendText(testMsg)

    # Receive echo (will be decompressed by recvMessage)
    let msg = await wsConn.recvMessage()
    assert msg.kind == opText
    assert msg.data == testMsg, "Echo mismatch: expected '" & testMsg & "', got '" & msg.data & "'"

    # Close
    await wsConn.sendClose()
    let closeMsg = await wsConn.recvMessage()
    assert closeMsg.kind == opClose

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
  echo "PASS: compressed text message echo roundtrip"

# ============================================================
# Test 3: Compressed binary message roundtrip
# ============================================================

block testCompressedBinaryEcho:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws", enableCompression = true)

    # Build binary payload
    var binaryData = ""
    for i in 0 ..< 256:
      binaryData.add char(i mod 256)
    binaryData = binaryData.repeat(4)  # 1024 bytes

    await wsConn.sendBinary(binaryData)

    let msg = await wsConn.recvMessage()
    assert msg.kind == opBinary
    assert msg.data == binaryData, "Binary echo mismatch"

    await wsConn.sendClose()
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
  echo "PASS: compressed binary message echo roundtrip"

# ============================================================
# Test 4: Control frames (ping/pong) not compressed
# ============================================================

block testControlFramesNotCompressed:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  # Handler that sends a ping first, then echoes
  proc pingHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let wsConn = await acceptWebSocket(req)
    # Send a ping - should NOT be compressed even with permessage-deflate
    await wsConn.sendPing("hello")
    # Wait for text message and echo it
    let msg = await wsConn.recvMessage()
    if msg.kind == opText:
      await wsConn.sendText(msg.data)
    let closeMsg = await wsConn.recvMessage()
    return wsResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, pingHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws", enableCompression = true)
    assert wsConn.compressEnabled

    # Send text message (will trigger server to respond after ping/pong)
    await wsConn.sendText("test")

    # recvMessage auto-responds to ping with pong, then returns the text echo
    let msg = await wsConn.recvMessage()
    assert msg.kind == opText
    assert msg.data == "test"

    await wsConn.sendClose()
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
  echo "PASS: control frames (ping/pong) not compressed"

# ============================================================
# Test 5: No compression when client doesn't request it
# ============================================================

block testNoCompressionWithout:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws", enableCompression = false)
    assert not wsConn.compressEnabled, "Expected compression to be disabled"

    let testMsg = "no compression here"
    await wsConn.sendText(testMsg)
    let msg = await wsConn.recvMessage()
    assert msg.kind == opText
    assert msg.data == testMsg

    await wsConn.sendClose()
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
  echo "PASS: no compression when client doesn't request it"

# ============================================================
# Test 6: Large payload compression
# ============================================================

block testLargePayloadCompression:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws", enableCompression = true)

    # Large repetitive payload should compress well
    let largeMsg = "This is a test message for WebSocket compression. ".repeat(200)
    await wsConn.sendText(largeMsg)

    let msg = await wsConn.recvMessage()
    assert msg.kind == opText
    assert msg.data == largeMsg, "Large message echo mismatch (len: " & $msg.data.len & " vs " & $largeMsg.len & ")"

    await wsConn.sendClose()
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
  echo "PASS: large payload compression"

# ============================================================
# Test 7: Large incompressible payload roundtrip
# ============================================================

block testLargeIncompressiblePayloadCompression:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig(
    maxWsFrameBytes: 4 * 1024 * 1024,
    maxWsMessageBytes: 8 * 1024 * 1024
  )

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws", enableCompression = true)
    let payload = pseudoRandomBytes(2 * 1024 * 1024) # 2 MiB incompressible-ish payload

    await wsConn.sendBinary(payload)
    let msg = await wsConn.recvMessage()
    assert msg.kind == opBinary
    assert msg.data == payload, "Incompressible binary payload mismatch"

    await wsConn.sendClose()
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
  echo "PASS: large incompressible payload compression"

# ============================================================
# Test 8: Decompressed size limit enforced (compression bomb guard)
# ============================================================

block testCompressedPayloadRespectsMessageLimit:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig(maxWsFrameBytes: 1024 * 1024, maxWsMessageBytes: 1024)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[uint16] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws", enableCompression = true)

    # Highly compressible payload: compressed frame is small, decompressed message is large.
    await wsConn.sendText("A".repeat(16 * 1024))
    let msg = await wsConn.recvMessage()
    if msg.kind == opClose:
      return msg.closeCode
    return 0'u16

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let closeCode = cf.read()
  assert closeCode == 1009'u16, "Expected close code 1009 for oversized decompressed message, got: " & $closeCode
  listener.close()
  echo "PASS: decompressed payload size limit enforced"

echo "ALL WEBSOCKET COMPRESSION TESTS PASSED"
