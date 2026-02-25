## Python Interop Tests for SSE and WebSocket over HTTP/1.1 and HTTP/2
##
## Validates that Python clients can connect to Nim servers using:
## 1. SSE over HTTP/1.1 (urllib)
## 2. WebSocket over HTTP/1.1 (websockets library)
## 3. SSE over HTTP/2 (h2 library)
## 4. WebSocket over HTTP/2 Extended CONNECT (h2 library)
##
## Requires: python3 with websockets, h2, hpack packages installed.

import std/[strutils, nativesockets, osproc, streams as stdstreams]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/server/http2 as http2_server
import cps/http/server/sse
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

# ============================================================
# Shared handler: SSE + WS on the same server
# ============================================================

proc sseWsHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  if req.path == "/events":
    let sse = await initSse(req.stream)
    await sse.sendEvent("hello", event="greeting", id="1")
    await sse.sendEvent("world", event="greeting", id="2")
    await sse.sendComment("keepalive")
    await sse.sendEvent("done", id="3")
    return sseResponse()
  elif req.path == "/ws":
    let wsConn = await acceptWebSocket(req)
    while true:
      let msg = await wsConn.recvMessage()
      if msg.kind == opClose:
        break
      elif msg.kind == opText:
        await wsConn.sendText("echo:" & msg.data)
    return wsResponse()
  else:
    return newResponse(200, "ok")

# ============================================================
# Test 1: SSE over HTTP/1.1 (Python urllib client)
# ============================================================
block testPythonSseH1:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    l.close()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        sseWsHandler(req))

  let pyScript = """
import urllib.request
import ssl

url = "http://127.0.0.1:""" & $port & """/events"
req = urllib.request.Request(url, headers={"Connection": "close"})
resp = urllib.request.urlopen(req, timeout=5)
data = resp.read().decode("utf-8")

# Verify SSE format
assert "event: greeting" in data, f"Missing event: greeting in: {data!r}"
assert "id: 1" in data, f"Missing id: 1 in: {data!r}"
assert "data: hello" in data, f"Missing data: hello in: {data!r}"
assert "data: world" in data, f"Missing data: world in: {data!r}"
assert ": keepalive" in data, f"Missing comment in: {data!r}"
assert "data: done" in data, f"Missing data: done in: {data!r}"
assert "id: 3" in data, f"Missing id: 3 in: {data!r}"
print("PYTHON_SSE_H1_OK")
"""
  let pyFile = "/tmp/test_sse_h1_client.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, config)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  assert pyExit == 0, "Python SSE/H1 client failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_SSE_H1_OK" in pyOutput, "Python SSE/H1 client didn't complete: " & pyOutput
  echo "PASS: Python SSE over HTTP/1.1"

# ============================================================
# Test 2: WebSocket over HTTP/1.1 (Python websockets client)
# ============================================================
block testPythonWsH1:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    l.close()
    await handleHttp1Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        sseWsHandler(req))

  let pyScript = """
import asyncio
import websockets

async def main():
    uri = "ws://127.0.0.1:""" & $port & """/ws"
    async with websockets.connect(uri) as ws:
        await ws.send("hello from python h1")
        resp = await ws.recv()
        assert resp == "echo:hello from python h1", f"Got: {resp}"
        await ws.send("second")
        resp2 = await ws.recv()
        assert resp2 == "echo:second", f"Got: {resp2}"
        await ws.close()
    print("PYTHON_WS_H1_OK")

asyncio.run(main())
"""
  let pyFile = "/tmp/test_ws_h1_client.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, config)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  assert pyExit == 0, "Python WS/H1 client failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_WS_H1_OK" in pyOutput, "Python WS/H1 client didn't complete: " & pyOutput
  echo "PASS: Python WebSocket over HTTP/1.1"

# ============================================================
# Test 3: SSE over HTTP/2 (Python h2 library, plain TCP h2c)
# ============================================================
block testPythonSseH2:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    l.close()
    await handleHttp2Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        sseWsHandler(req))

  let pyScript = """
import socket
import h2.connection
import h2.config
import h2.events

def test_sse_h2():
    sock = socket.create_connection(("127.0.0.1", """ & $port & """))

    config = h2.config.H2Configuration(client_side=True, header_encoding='utf-8')
    conn = h2.connection.H2Connection(config=config)
    conn.initiate_connection()
    sock.sendall(conn.data_to_send())

    # Send GET /events request
    conn.send_headers(
        stream_id=1,
        headers=[
            (":method", "GET"),
            (":path", "/events"),
            (":scheme", "http"),
            (":authority", "localhost"),
        ],
        end_stream=True,
    )
    sock.sendall(conn.data_to_send())

    # Read response
    response_headers = None
    response_data = b""
    stream_ended = False

    while not stream_ended:
        data = sock.recv(65535)
        if not data:
            break
        events = conn.receive_data(data)
        for event in events:
            if isinstance(event, h2.events.ResponseReceived):
                response_headers = {k: v for k, v in event.headers}
            elif isinstance(event, h2.events.DataReceived):
                response_data += event.data
                conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
            elif isinstance(event, h2.events.StreamEnded):
                stream_ended = True
            elif isinstance(event, h2.events.WindowUpdated):
                pass
            elif isinstance(event, h2.events.SettingsAcknowledged):
                pass
            elif isinstance(event, h2.events.RemoteSettingsChanged):
                pass
        sock.sendall(conn.data_to_send())

    sock.close()

    # Verify response
    assert response_headers is not None, "No response headers received"
    status = response_headers.get(":status", "")
    assert status == "200", f"Expected status 200, got {status}"

    content_type = response_headers.get("content-type", "")
    assert "text/event-stream" in content_type, f"Expected text/event-stream, got {content_type}"

    body = response_data.decode("utf-8")
    assert "event: greeting" in body, f"Missing event: greeting in: {body!r}"
    assert "data: hello" in body, f"Missing data: hello in: {body!r}"
    assert "data: world" in body, f"Missing data: world in: {body!r}"
    assert ": keepalive" in body, f"Missing comment in: {body!r}"
    assert "data: done" in body, f"Missing data: done in: {body!r}"
    print("PYTHON_SSE_H2_OK")

test_sse_h2()
"""
  let pyFile = "/tmp/test_sse_h2_client.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, config)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  assert pyExit == 0, "Python SSE/H2 client failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_SSE_H2_OK" in pyOutput, "Python SSE/H2 client didn't complete: " & pyOutput
  echo "PASS: Python SSE over HTTP/2"

# ============================================================
# Test 4: WebSocket over HTTP/2 Extended CONNECT (Python h2 library, plain TCP h2c)
# ============================================================
block testPythonWsH2:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    l.close()
    await handleHttp2Connection(client.AsyncStream, cfg,
      proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
        sseWsHandler(req))

  let pyScript = """
import socket
import struct
import os
import h2.connection
import h2.config
import h2.events
import h2.settings

def build_ws_frame(opcode, payload, masked=False, fin=True):
    '''Build a WebSocket frame.'''
    frame = bytearray()
    b0 = (0x80 if fin else 0x00) | opcode
    frame.append(b0)
    mask_bit = 0x80 if masked else 0x00
    if len(payload) < 126:
        frame.append(mask_bit | len(payload))
    elif len(payload) <= 0xFFFF:
        frame.append(mask_bit | 126)
        frame.extend(struct.pack("!H", len(payload)))
    else:
        frame.append(mask_bit | 127)
        frame.extend(struct.pack("!Q", len(payload)))
    if masked:
        mask_key = os.urandom(4)
        frame.extend(mask_key)
        for i, b in enumerate(payload):
            frame.append(b ^ mask_key[i % 4])
    else:
        frame.extend(payload)
    return bytes(frame)

def parse_ws_frame(data):
    '''Parse a WebSocket frame, return (opcode, payload, total_consumed).'''
    b0 = data[0]
    b1 = data[1]
    opcode = b0 & 0x0F
    masked = (b1 & 0x80) != 0
    payload_len = b1 & 0x7F
    pos = 2
    if payload_len == 126:
        payload_len = struct.unpack("!H", data[2:4])[0]
        pos = 4
    elif payload_len == 127:
        payload_len = struct.unpack("!Q", data[2:10])[0]
        pos = 10
    mask_key = None
    if masked:
        mask_key = data[pos:pos+4]
        pos += 4
    payload = data[pos:pos+payload_len]
    if masked:
        payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
    return opcode, payload, pos + payload_len

def test_ws_h2():
    sock = socket.create_connection(("127.0.0.1", """ & $port & """))
    sock.settimeout(5.0)

    config = h2.config.H2Configuration(client_side=True, header_encoding='utf-8')
    conn = h2.connection.H2Connection(config=config)
    conn.initiate_connection()
    conn.update_settings({
        h2.settings.SettingCodes.ENABLE_CONNECT_PROTOCOL: 1,
    })
    sock.sendall(conn.data_to_send())

    # Send Extended CONNECT for WebSocket (RFC 8441)
    conn.send_headers(
        stream_id=1,
        headers=[
            (":method", "CONNECT"),
            (":protocol", "websocket"),
            (":path", "/ws"),
            (":scheme", "http"),
            (":authority", "localhost"),
            ("sec-websocket-version", "13"),
        ],
        end_stream=False,  # Stream stays open for data
    )
    sock.sendall(conn.data_to_send())

    # Read until we get response headers
    response_headers = None
    while response_headers is None:
        data = sock.recv(65535)
        events = conn.receive_data(data)
        for event in events:
            if isinstance(event, h2.events.ResponseReceived):
                response_headers = {k: v for k, v in event.headers}
            elif isinstance(event, h2.events.StreamReset):
                raise AssertionError(f"Extended CONNECT stream reset before response headers: {event.error_code}")
        sock.sendall(conn.data_to_send())

    status = response_headers.get(":status", "")
    assert status == "200", f"Expected 200, got {status}"

    # Send a WebSocket text frame inside HTTP/2 DATA
    ws_frame = build_ws_frame(0x1, b"hello from python h2", masked=True)
    conn.send_data(stream_id=1, data=ws_frame)
    sock.sendall(conn.data_to_send())

    # Read response: expect DATA frame containing a WebSocket frame
    ws_response_data = b""
    got_response = False
    while not got_response:
        data = sock.recv(65535)
        events = conn.receive_data(data)
        for event in events:
            if isinstance(event, h2.events.DataReceived):
                ws_response_data += event.data
                conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                # Try to parse WebSocket frame
                if len(ws_response_data) >= 2:
                    opcode, payload, consumed = parse_ws_frame(ws_response_data)
                    if consumed <= len(ws_response_data):
                        got_response = True
            elif isinstance(event, h2.events.StreamReset):
                raise AssertionError(f"Extended CONNECT stream reset while waiting for first message: {event.error_code}")
            elif isinstance(event, h2.events.WindowUpdated):
                pass
        sock.sendall(conn.data_to_send())

    opcode, payload, _ = parse_ws_frame(ws_response_data)
    assert opcode == 0x1, f"Expected text opcode (1), got {opcode}"
    assert payload == b"echo:hello from python h2", f"Got: {payload}"

    # Send another message
    ws_frame2 = build_ws_frame(0x1, b"second msg", masked=True)
    conn.send_data(stream_id=1, data=ws_frame2)
    sock.sendall(conn.data_to_send())

    ws_response_data2 = b""
    got_response2 = False
    while not got_response2:
        data = sock.recv(65535)
        events = conn.receive_data(data)
        for event in events:
            if isinstance(event, h2.events.DataReceived):
                ws_response_data2 += event.data
                conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                if len(ws_response_data2) >= 2:
                    opcode2, payload2, consumed2 = parse_ws_frame(ws_response_data2)
                    if consumed2 <= len(ws_response_data2):
                        got_response2 = True
            elif isinstance(event, h2.events.StreamReset):
                raise AssertionError(f"Extended CONNECT stream reset while waiting for second message: {event.error_code}")
            elif isinstance(event, h2.events.WindowUpdated):
                pass
        sock.sendall(conn.data_to_send())

    opcode2, payload2, _ = parse_ws_frame(ws_response_data2)
    assert opcode2 == 0x1, f"Expected text opcode, got {opcode2}"
    assert payload2 == b"echo:second msg", f"Got: {payload2}"

    # Send WebSocket close frame
    ws_close = build_ws_frame(0x8, struct.pack("!H", 1000), masked=True)
    conn.send_data(stream_id=1, data=ws_close)
    sock.sendall(conn.data_to_send())

    sock.close()
    print("PYTHON_WS_H2_OK")

test_ws_h2()
"""
  let pyFile = "/tmp/test_ws_h2_client.py"
  writeFile(pyFile, pyScript)

  let sf = serverTask(listener, config)
  let pyProcess = startProcess("python3", args = [pyFile],
                               options = {poStdErrToStdOut, poUsePath})

  let loop = getEventLoop()
  while not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  assert pyExit == 0, "Python WS/H2 client failed (exit " & $pyExit & "): " & pyOutput
  assert "PYTHON_WS_H2_OK" in pyOutput, "Python WS/H2 client didn't complete: " & pyOutput
  echo "PASS: Python WebSocket over HTTP/2 (Extended CONNECT)"

echo ""
echo "All Python interop tests passed!"
