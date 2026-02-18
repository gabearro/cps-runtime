## WebSocket Tests
##
## Tests the WebSocket server and client implementation using:
## 1. Internal Nim tests (raw TCP client + server)
## 2. Python websockets library interop (validates RFC 6455 compliance)

import std/[strutils, nativesockets, tables, sysrand, base64, osproc, os]
from std/streams import readAll, readLine
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/server/router
import cps/http/server/dsl
import cps/http/server/ws
import cps/http/client/ws as client_ws

# ============================================================
# Helpers
# ============================================================

proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = posix.getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

proc buildWsFrame(opcode: byte, payload: string, masked: bool = true,
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

proc wsUpgradeRequest(path: string, key: string = ""): string =
  ## Build a raw HTTP/1.1 WebSocket upgrade request.
  let wsKey = if key == "": base64.encode(urandom(16)) else: key
  result = "GET " & path & " HTTP/1.1\r\n"
  result &= "Host: localhost\r\n"
  result &= "Upgrade: websocket\r\n"
  result &= "Connection: Upgrade\r\n"
  result &= "Sec-WebSocket-Key: " & wsKey & "\r\n"
  result &= "Sec-WebSocket-Version: 13\r\n"
  result &= "\r\n"

proc parseWsFrame(data: string): (byte, string) =
  ## Parse a raw WebSocket frame, return (opcode, payload).
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

proc echoWsHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  ## WebSocket echo handler: echoes back text messages.
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

# ============================================================
# Test 1: Server handshake
# ============================================================
block testServerHandshake:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let key = "dGhlIHNhbXBsZSBub25jZQ=="
    await s.write(wsUpgradeRequest("/ws", key))
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
  assert "101 Switching Protocols" in resp, "Expected 101, got: " & resp
  assert "Upgrade: websocket" in resp, "Missing Upgrade header"
  assert "Connection: Upgrade" in resp, "Missing Connection header"
  assert "Sec-WebSocket-Accept:" in resp, "Missing Accept header"

  let expectedAccept = computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==")
  assert expectedAccept in resp, "Wrong accept key, expected " & expectedAccept & " in: " & resp
  listener.close()
  echo "PASS: Server handshake"

# ============================================================
# Test 2: Reject bad upgrade
# ============================================================
block testRejectBadUpgrade:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    # Send request without Upgrade header
    await s.write("GET /ws HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    var response = ""
    while true:
      let chunk = await s.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    s.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  # Server should fail the upgrade (no 101), connection closes
  let resp = cf.read()
  assert "101" notin resp, "Should not get 101 without Upgrade header: " & resp
  listener.close()
  echo "PASS: Reject bad upgrade"

# ============================================================
# Test 3: Text echo
# ============================================================
block testTextEcho:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    await s.write(wsUpgradeRequest("/ws"))
    # Read 101 response
    let reader = newBufferedReader(s)
    while true:
      let line = await reader.readLine()
      if line == "":
        break
    # Send text frame
    await s.write(buildWsFrame(0x1, "hello world"))
    # Read echo response
    let respData = await reader.readExact(2 + len("hello world"))
    let parsed = parseWsFrame(respData)
    let op = parsed[0]
    let payload = parsed[1]
    # Send close frame
    await s.write(buildWsFrame(0x8, "\x03\xe8"))  # code 1000
    s.close()
    return payload

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "hello world", "Expected 'hello world', got: '" & result & "'"
  listener.close()
  echo "PASS: Text echo"

# ============================================================
# Test 4: Binary message
# ============================================================
block testBinaryMessage:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    await s.write(wsUpgradeRequest("/ws"))
    let reader = newBufferedReader(s)
    while true:
      let line = await reader.readLine()
      if line == "":
        break
    # Send binary frame (opcode 0x2)
    let binaryData = "\x00\x01\x02\x03\x04"
    await s.write(buildWsFrame(0x2, binaryData))
    let respData = await reader.readExact(2 + binaryData.len)
    let parsed = parseWsFrame(respData)
    let op = parsed[0]
    let payload = parsed[1]
    await s.write(buildWsFrame(0x8, "\x03\xe8"))
    s.close()
    return $op & ":" & $payload.len

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "2:5", "Expected '2:5' (binary opcode + 5 bytes), got: '" & result & "'"
  listener.close()
  echo "PASS: Binary message"

# ============================================================
# Test 5: Ping/pong auto-response
# ============================================================
block testPingPong:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  # Handler that just waits for messages
  proc pingHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let wsConn = await acceptWebSocket(req)
    let msg = await wsConn.recvMessage()
    # After ping auto-response, we should get the text message
    if msg.kind == opText:
      await wsConn.sendText("after-ping:" & msg.data)
    return wsResponse()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, h)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    await s.write(wsUpgradeRequest("/ws"))
    let reader = newBufferedReader(s)
    while true:
      let line = await reader.readLine()
      if line == "":
        break
    # Send ping
    await s.write(buildWsFrame(0x9, "ping-data"))
    # Read pong response (auto-sent by recvMessage)
    let pongHeader = await reader.readExact(2)
    let pongOp = pongHeader[0].byte and 0x0F
    let pongLen = pongHeader[1].byte and 0x7F
    let pongPayload = await reader.readExact(pongLen.int)
    # Now send a text message
    await s.write(buildWsFrame(0x1, "test"))
    # Read server response
    let textHeader = await reader.readExact(2)
    let textLen = (textHeader[1].byte and 0x7F).int
    let textPayload = await reader.readExact(textLen)
    await s.write(buildWsFrame(0x8, "\x03\xe8"))
    s.close()
    return $pongOp & ":" & pongPayload & "|" & textPayload

  let sf = serverTask(listener, config, pingHandler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result.startsWith("10:ping-data|"), "Expected pong with same payload, got: '" & result & "'"
  assert "after-ping:test" in result, "Expected echo after ping, got: '" & result & "'"
  listener.close()
  echo "PASS: Ping/pong auto-response"

# ============================================================
# Test 6: Close handshake
# ============================================================
block testCloseHandshake:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    await s.write(wsUpgradeRequest("/ws"))
    let reader = newBufferedReader(s)
    while true:
      let line = await reader.readLine()
      if line == "":
        break
    # Send close with code 1000
    await s.write(buildWsFrame(0x8, "\x03\xe8goodbye"))
    # Read close response
    let closeHeader = await reader.readExact(2)
    let closeOp = closeHeader[0].byte and 0x0F
    let closeLen = (closeHeader[1].byte and 0x7F).int
    let closePayload = await reader.readExact(closeLen)
    let closeCode = (closePayload[0].byte.int shl 8) or closePayload[1].byte.int
    s.close()
    return $closeOp & ":" & $closeCode

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "8:1000", "Expected close frame with code 1000, got: '" & result & "'"
  listener.close()
  echo "PASS: Close handshake"

# ============================================================
# Test 7: Multi-line text
# ============================================================
block testMultiLineText:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    await s.write(wsUpgradeRequest("/ws"))
    let reader = newBufferedReader(s)
    while true:
      let line = await reader.readLine()
      if line == "":
        break
    let multiLine = "line1\nline2\nline3\nend"
    await s.write(buildWsFrame(0x1, multiLine))
    let respData = await reader.readExact(2 + multiLine.len)
    let parsed = parseWsFrame(respData)
    let op = parsed[0]
    let payload = parsed[1]
    await s.write(buildWsFrame(0x8, "\x03\xe8"))
    s.close()
    return payload

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "line1\nline2\nline3\nend", "Multi-line text not preserved: '" & result & "'"
  listener.close()
  echo "PASS: Multi-line text"

# ============================================================
# Test 8: Fragmented message
# ============================================================
block testFragmentedMessage:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    await s.write(wsUpgradeRequest("/ws"))
    let reader = newBufferedReader(s)
    while true:
      let line = await reader.readLine()
      if line == "":
        break
    # Send fragmented text: 3 frames
    await s.write(buildWsFrame(0x1, "Hello ", fin = false))  # text, not fin
    await s.write(buildWsFrame(0x0, "frag ", fin = false))   # continuation, not fin
    await s.write(buildWsFrame(0x0, "world", fin = true))    # continuation, fin
    # Read assembled echo
    let assembledMsg = "Hello frag world"
    let respData = await reader.readExact(2 + assembledMsg.len)
    let parsed = parseWsFrame(respData)
    let op = parsed[0]
    let payload = parsed[1]
    await s.write(buildWsFrame(0x8, "\x03\xe8"))
    s.close()
    return payload

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "Hello frag world", "Fragmented message not assembled: '" & result & "'"
  listener.close()
  echo "PASS: Fragmented message"

# ============================================================
# Test 9: Client wsConnect
# ============================================================
block testWsConnect:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws")
    await wsConn.sendText("hello from client")
    let msg = await wsConn.recvMessage()
    await wsConn.sendClose(1000)
    return msg.data

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "hello from client", "wsConnect echo failed: '" & result & "'"
  listener.close()
  echo "PASS: Client wsConnect"

# ============================================================
# Test 10: DSL ws route
# ============================================================
block testDslWsRoute:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  let handler = router:
    ws "/echo":
      while true:
        let msg = await recvMessage()
        if msg.kind == opClose:
          break
        await sendText("dsl:" & msg.data)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, h)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/echo")
    await wsConn.sendText("test")
    let msg = await wsConn.recvMessage()
    await wsConn.sendClose(1000)
    return msg.data

  let sf = serverTask(listener, config, handler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "dsl:test", "DSL ws route failed: '" & result & "'"
  listener.close()
  echo "PASS: DSL ws route"

# ============================================================
# Test 11: DSL path params
# ============================================================
block testDslPathParams:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  let handler = router:
    ws "/chat/{room}":
      let room = pathParams["room"]
      await sendText("joined:" & room)

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, h)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/chat/general")
    let msg = await wsConn.recvMessage()
    await wsConn.sendClose(1000)
    return msg.data

  let sf = serverTask(listener, config, handler)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "joined:general", "Path params failed: '" & result & "'"
  listener.close()
  echo "PASS: DSL path params"

# ============================================================
# Test 12: Large payload (100KB)
# ============================================================
block testLargePayload:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  let largeData = repeat('X', 100_000)

  proc clientTask(p: int, expected: string): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/ws")
    await wsConn.sendText(expected)
    let msg = await wsConn.recvMessage()
    await wsConn.sendClose(1000)
    return $msg.data.len

  let sf = serverTask(listener, config)
  let cf = clientTask(port, largeData)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "100000", "Large payload failed, got len: " & result
  listener.close()
  echo "PASS: Large payload (100KB)"

# ============================================================
# Test 13: Python WebSocket client → Nim server
# ============================================================
block testPythonClientNimServer:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  # Write Python client script first (before starting server to avoid race)
  let pyScript = """
import asyncio
import websockets

async def main():
    uri = "ws://127.0.0.1:""" & $port & """/ws"
    async with websockets.connect(uri) as ws:
        await ws.send("hello from python")
        resp = await ws.recv()
        assert resp == "hello from python", f"Got: {resp}"
        await ws.send("second message")
        resp2 = await ws.recv()
        assert resp2 == "second message", f"Got: {resp2}"
        await ws.close()
    print("PYTHON_OK")

asyncio.run(main())
"""
  let pyFile = "/tmp/test_ws_client.py"
  writeFile(pyFile, pyScript)

  # Server accepts one connection, closes listener, handles WebSocket
  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    l.close()  # Close listener so selector becomes empty when done
    await handleHttp1Connection(client.AsyncStream, cfg, echoWsHandler)

  let sf = serverTask(listener, config)

  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  # Run event loop until the server finishes handling the connection
  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = readAll(pyProcess.outputStream)
  pyProcess.close()

  assert pyExit == 0, "Python client failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_OK" in pyOutput, "Python client didn't complete: " & pyOutput
  echo "PASS: Python client → Nim server"

# ============================================================
# Test 14: Nim client → Python server
# ============================================================
block testNimClientPythonServer:
  # Start Python WebSocket server
  let pyScript = """
import asyncio
import websockets
import sys

async def echo_handler(websocket):
    async for message in websocket:
        await websocket.send("py:" + message)

async def main():
    server = await websockets.serve(echo_handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    print(f"PORT:{port}", flush=True)
    await server.serve_forever()

asyncio.run(main())
"""
  let pyFile = "/tmp/test_ws_server.py"
  writeFile(pyFile, pyScript)

  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poUsePath})

  # Read the port from Python's stdout
  var pyPort = 0
  for i in 0 ..< 50:
    sleep(100)
    let line = pyProcess.outputStream.readLine()
    if line.startsWith("PORT:"):
      pyPort = parseInt(line[5..^1])
      break

  assert pyPort > 0, "Failed to get Python server port"

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let wsConn = await wsConnect("127.0.0.1", p, "/")
    await wsConn.sendText("hello from nim")
    let msg = await wsConn.recvMessage()
    await wsConn.sendClose(1000)
    return msg.data

  let cf = clientTask(pyPort)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let result = cf.read()
  assert result == "py:hello from nim", "Nim→Python echo failed: '" & result & "'"

  pyProcess.kill()
  pyProcess.close()
  echo "PASS: Nim client → Python server"

echo ""
echo "All WebSocket tests passed!"
