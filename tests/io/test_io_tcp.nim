## Tests for CPS I/O TCP (client + server)

import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import std/nativesockets
from std/posix import Sockaddr_in, getsockname, SockLen

# Test 1: TCP echo server via loopback
block testTcpEcho:
  let listener = tcpListen("127.0.0.1", 0)  # OS-assigned port

  # Get the port the OS assigned
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  let port = ntohs(localAddr.sin_port).int

  # Server: accept, read, echo back, close
  proc serverTask(l: TcpListener): CpsFuture[string] {.cps.} =
    let client = await l.accept()
    let data = await client.AsyncStream.read(1024)
    await client.AsyncStream.write(data)
    client.AsyncStream.close()
    return data

  # Client: connect, send, read reply
  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    await conn.AsyncStream.write("hello tcp")
    let reply = await conn.AsyncStream.read(1024)
    conn.AsyncStream.close()
    return reply

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let serverGot = sf.read()
  let clientGot = cf.read()
  assert serverGot == "hello tcp", "Server should have received 'hello tcp', got '" & serverGot & "'"
  assert clientGot == "hello tcp", "Client should have received echo, got '" & clientGot & "'"
  listener.close()
  echo "PASS: TCP echo server"

# Test 2: Multiple messages
block testTcpMultiMessage:
  let listener = tcpListen("127.0.0.1", 0)

  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  discard getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  let port = ntohs(localAddr.sin_port).int

  proc serverTask(l: TcpListener): CpsFuture[seq[string]] {.cps.} =
    var messages: seq[string]
    let client = await l.accept()
    # Read 3 fixed-size messages
    for i in 0 ..< 3:
      let data = await client.AsyncStream.read(4)
      messages.add(data)
    await client.AsyncStream.write("done")
    client.AsyncStream.close()
    return messages

  proc clientTask(p: int): CpsVoidFuture {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    await conn.AsyncStream.write("msg1")
    await conn.AsyncStream.write("msg2")
    await conn.AsyncStream.write("msg3")
    let reply = await conn.AsyncStream.read(1024)
    assert reply == "done", "Expected 'done'"
    conn.AsyncStream.close()

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let serverMessages = sf.read()
  assert serverMessages.len == 3, "Expected 3 messages, got " & $serverMessages.len
  listener.close()
  echo "PASS: TCP multiple messages"

# Test 3: Connect error (connection refused)
block testConnectError:
  # Try to connect to a port that's definitely not listening
  let fut = tcpConnect("127.0.0.1", 1)  # Port 1 — should be refused
  let loop = getEventLoop()
  while not fut.finished:
    loop.tick()
    if not fut.finished and not loop.hasWork:
      break
  assert fut.hasError(), "Connection to port 1 should fail"
  echo "PASS: TCP connect error handling"

echo "All TCP tests passed!"
