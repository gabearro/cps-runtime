## Tests for I/O operations on the MT event loop
##
## Verifies that existing TCP/UDP I/O works correctly when
## the MT runtime is active.
##
## NOTE: Must be compiled with --mm:arc (ORC is not thread-safe).

import cps/mt
import cps/transform
import cps/io/streams
import cps/io/tcp
import cps/io/udp
import std/[nativesockets, strutils]
import std/posix as posix
from std/posix import Sockaddr_in, getsockname, SockLen

let loop = initMtRuntime(numWorkers = 2)

# Test 1: TCP echo on MT event loop
block testMtTcpEcho:
  let listener = tcpListen("127.0.0.1", 0)
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  let port = nativesockets.ntohs(localAddr.sin_port).int

  proc serverTask(l: TcpListener): CpsFuture[string] {.cps.} =
    let client = await l.accept()
    let data = await client.AsyncStream.read(1024)
    await client.AsyncStream.write(data)
    client.AsyncStream.close()
    return data

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    await conn.AsyncStream.write("hello mt-tcp")
    let reply = await conn.AsyncStream.read(1024)
    conn.AsyncStream.close()
    return reply

  let sf = serverTask(listener)
  let cf = clientTask(port)
  while not sf.finished or not cf.finished:
    loop.tick()
  let serverData = sf.read()
  let clientReply = cf.read()
  assert serverData == "hello mt-tcp", "Server got: " & serverData
  assert clientReply == "hello mt-tcp", "Client got: " & clientReply
  listener.close()
  echo "PASS: TCP echo on MT event loop"

# Test 2: UDP on MT event loop
block testMtUdp:
  let recvSock = newUdpSocket()
  recvSock.bindAddr("127.0.0.1", 0)
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = getsockname(recvSock.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  let port = nativesockets.ntohs(localAddr.sin_port).int

  let sendSock = newUdpSocket()

  proc sender(sock: UdpSocket, p: int): CpsVoidFuture {.cps.} =
    await cpsYield()  # Let receiver register first
    await sock.sendTo("udp mt test", "127.0.0.1", p)

  proc receiver(sock: UdpSocket): CpsFuture[string] {.cps.} =
    let pkt = await sock.recvFrom(1024)
    return pkt.data

  let rf = receiver(recvSock)
  let sf = sender(sendSock, port)
  while not rf.finished or not sf.finished:
    loop.tick()
  let data = rf.read()
  assert data == "udp mt test", "Expected 'udp mt test', got: " & data
  recvSock.close()
  sendSock.close()
  echo "PASS: UDP on MT event loop"

# Test 3: TCP + spawnBlocking mixed
block testMtTcpBlocking:
  let listener = tcpListen("127.0.0.1", 0)
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  let port = nativesockets.ntohs(localAddr.sin_port).int

  proc uppercaseBlocking(input: string): CpsFuture[string] =
    ## Non-CPS helper: offloads toUpperAscii to a worker thread.
    let inputCopy = input  # Copy for the gcsafe closure
    spawnBlocking(proc(): string {.gcsafe.} =
      var s = ""
      for c in inputCopy:
        s.add c.toUpperAscii()
      return s
    )

  proc server(l: TcpListener): CpsFuture[string] {.cps.} =
    let client = await l.accept()
    let data = await client.AsyncStream.read(1024)
    let processed = await uppercaseBlocking(data)
    await client.AsyncStream.write(processed)
    client.AsyncStream.close()
    return processed

  proc client(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    await conn.AsyncStream.write("hello")
    let reply = await conn.AsyncStream.read(1024)
    conn.AsyncStream.close()
    return reply

  let sf = server(listener)
  let cf = client(port)
  while not sf.finished or not cf.finished:
    loop.tick()
  let serverResult = sf.read()
  let clientReply = cf.read()
  assert serverResult == "HELLO", "Server processed: " & serverResult
  assert clientReply == "HELLO", "Client got: " & clientReply
  listener.close()
  echo "PASS: TCP + spawnBlocking mixed"

# Test 4: Deferred registerRead from non-reactor thread must fire
# for pre-existing data on kqueue.
block testMtDeferredRegisterReadPreexisting:
  var iter = 0
  while iter < 64:
    var fds: array[0..1, cint]
    doAssert posix.pipe(fds) == 0, "pipe failed"
    let readFd = SocketHandle(fds[0])

    var marker: array[1, byte]
    marker[0] = byte(iter and 0xFF)
    doAssert posix.write(fds[1], addr marker[0], 1) == 1, "write to pipe failed"

    let fired = newCpsVoidFuture()
    fired.pinFutureRuntime()
    let regFut = spawnBlocking(proc(): int {.gcsafe.} =
      {.cast(gcsafe).}:
        let ev = getEventLoop()
        ev.registerRead(readFd, proc() =
          var buf: array[8, byte]
          discard posix.read(cint(int(readFd)), addr buf[0], buf.len)
          ev.unregister(readFd)
          if not fired.finished:
            fired.complete()
        )
      return 1
    )

    var ticks = 0
    while (not regFut.finished or not fired.finished) and ticks < 5000:
      loop.tick()
      inc ticks

    if not fired.finished:
      try:
        loop.unregister(readFd)
      except Exception:
        discard

    discard posix.close(fds[0])
    discard posix.close(fds[1])

    doAssert regFut.finished, "blocking registration did not complete"
    doAssert not regFut.hasError(), "blocking registration failed"
    doAssert fired.finished,
      "deferred registerRead missed pre-existing data (iter " & $iter & ")"
    inc iter
  echo "PASS: MT deferred registerRead handles pre-existing readability"

# Test 5: Deferred registerWrite from non-reactor thread must fire
# for pre-existing writability on kqueue.
block testMtDeferredRegisterWritePreexisting:
  var iter = 0
  while iter < 64:
    var fds: array[0..1, cint]
    doAssert posix.pipe(fds) == 0, "pipe failed"
    let writeFd = SocketHandle(fds[1])

    let fired = newCpsVoidFuture()
    fired.pinFutureRuntime()
    let regFut = spawnBlocking(proc(): int {.gcsafe.} =
      {.cast(gcsafe).}:
        let ev = getEventLoop()
        ev.registerWrite(writeFd, proc() =
          ev.unregister(writeFd)
          if not fired.finished:
            fired.complete()
        )
      return 1
    )

    var ticks = 0
    while (not regFut.finished or not fired.finished) and ticks < 5000:
      loop.tick()
      inc ticks

    if not fired.finished:
      try:
        loop.unregister(writeFd)
      except Exception:
        discard

    discard posix.close(fds[0])
    discard posix.close(fds[1])

    doAssert regFut.finished, "blocking registration did not complete"
    doAssert not regFut.hasError(), "blocking registration failed"
    doAssert fired.finished,
      "deferred registerWrite missed pre-existing writability (iter " & $iter & ")"
    inc iter
  echo "PASS: MT deferred registerWrite handles pre-existing writability"

loop.shutdownMtRuntime()

echo ""
echo "All MT I/O tests passed!"
