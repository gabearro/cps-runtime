## Tests for CPS I/O TCP (client + server)

import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import std/nativesockets
when defined(linux):
  from std/posix import Sockaddr_in, getsockname, SockLen, fcntl, F_GETFL,
    O_NONBLOCK, getsockopt, TCP_NODELAY
else:
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

when defined(linux):
  block testDeferredAcceptOption:
    let listener = tcpListen("127.0.0.1", 0, deferAcceptSeconds = 1)
    var configured: cint
    var configuredLen = sizeof(configured).SockLen
    let rc = getsockopt(listener.fd, cint(toInt(IPPROTO_TCP)), 9.cint,
                        addr configured, addr configuredLen)
    assert rc == 0 and configured > 0,
      "TCP_DEFER_ACCEPT must be active when explicitly requested"
    listener.close()
    echo "PASS: TCP deferred accept option"

  block testAcceptedSocketIsNonBlocking:
    let listener = tcpListen("127.0.0.1", 0)
    let accepted = listener.accept()
    let connected = tcpConnect("127.0.0.1", listener.localPort())
    runCps(waitAll(accepted, connected))
    let serverSide = accepted.read()
    let clientSide = connected.read()
    let flags = fcntl(cint(int(serverSide.fd)), F_GETFL)
    assert flags >= 0 and (flags and O_NONBLOCK) != 0,
      "accept4 must set O_NONBLOCK on every accepted socket"
    serverSide.closeImmediately()
    clientSide.closeImmediately()
    listener.close()
    echo "PASS: accepted TCP socket is non-blocking"

  block testAcceptedSocketInheritsNoDelay:
    let listener = tcpListen("127.0.0.1", 0, noDelay = true)
    let accepted = listener.accept()
    let connected = tcpConnect("127.0.0.1", listener.localPort())
    runCps(waitAll(accepted, connected))
    let serverSide = accepted.read()
    let clientSide = connected.read()
    var configured: cint
    var configuredLen = sizeof(configured).SockLen
    let rc = getsockopt(serverSide.fd, cint(toInt(IPPROTO_TCP)), TCP_NODELAY,
                        addr configured, addr configuredLen)
    assert rc == 0 and configured == 1,
      "accepted sockets must inherit listener TCP_NODELAY"
    serverSide.closeImmediately()
    clientSide.closeImmediately()
    listener.close()
    echo "PASS: accepted TCP socket inherits TCP_NODELAY"

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

block testReusePortListeners:
  let first = tcpListen("127.0.0.1", 0, reusePort = true)
  let port = first.localPort()
  let second = tcpListen("127.0.0.1", port, reusePort = true)
  assert second.localPort() == port
  second.close()
  first.close()
  echo "PASS: TCP SO_REUSEPORT listener sharding"

# Test 5: A large concurrent backlog stays live, including multiple
# request/response rounds on every accepted stream.
block testConcurrentAcceptLiveness:
  const ClientCount = 96
  const Rounds = 3
  let listener = tcpListen("127.0.0.1", 0, backlog = ClientCount)
  let port = listener.localPort()

  proc serveClient(client: TcpStream): CpsVoidFuture {.cps.} =
    for _ in 0 ..< Rounds:
      let data = await client.AsyncStream.read(1)
      assert data == "x"
      await client.AsyncStream.write("y")
    client.closeImmediately()

  proc serveBatch(l: TcpListener): CpsVoidFuture {.cps.} =
    var clients: seq[CpsVoidFuture]
    for _ in 0 ..< ClientCount:
      let client = await l.accept()
      clients.add serveClient(client)
    await waitAll(clients)

  proc runClient(p: int): CpsVoidFuture {.cps.} =
    let client = await tcpConnect("127.0.0.1", p)
    for _ in 0 ..< Rounds:
      await client.AsyncStream.write("x")
      let data = await client.AsyncStream.read(1)
      assert data == "y"
    client.closeImmediately()

  let serverFut = serveBatch(listener)
  var clientFuts: seq[CpsVoidFuture]
  for _ in 0 ..< ClientCount:
    clientFuts.add runClient(port)
  let clientsDone = waitAll(clientFuts)
  let allDone = waitAll(serverFut, clientsDone)
  runCps(allDone)
  assert serverFut.finished and not serverFut.hasError()
  assert clientsDone.finished and not clientsDone.hasError()
  listener.close()
  echo "PASS: TCP concurrent accept liveness"

block testPersistentAcceptCallback:
  const ClientCount = 48
  let listener = tcpListen("127.0.0.1", 0, backlog = ClientCount)
  let port = listener.localPort()
  var accepted = 0
  var serverFutures: seq[CpsVoidFuture]

  proc serveOne(client: TcpStream): CpsVoidFuture {.cps.} =
    let value = await client.AsyncStream.read(1)
    await client.AsyncStream.write(value)
    client.closeImmediately()

  listener.acceptEach(proc(client: TcpStream) =
    inc accepted
    serverFutures.add serveOne(client)
  , maxBatch = 8)

  proc roundTrip(p: int): CpsVoidFuture {.cps.} =
    let client = await tcpConnect("127.0.0.1", p)
    await client.AsyncStream.write("z")
    let echoed = await client.AsyncStream.read(1)
    assert echoed == "z"
    client.closeImmediately()

  var clients: seq[CpsVoidFuture]
  for _ in 0 ..< ClientCount:
    clients.add roundTrip(port)
  runCps(waitAll(clients))
  assert accepted == ClientCount
  for fut in serverFutures:
    assert fut.finished and not fut.hasError()
  listener.close()
  echo "PASS: persistent TCP accept callback"

echo "All TCP tests passed!"
