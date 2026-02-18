## Tests for CPS I/O UDP

import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/udp
import std/nativesockets
from std/posix import Sockaddr_in, Sockaddr_storage, getsockname, SockLen

# Helper: get the port assigned to a bound UDP socket
proc getBoundPort(sock: UdpSocket): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = getsockname(sock.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

# Test 1: UDP loopback send/recv
block testUdpLoopback:
  let receiver = newUdpSocket()
  receiver.bindAddr("127.0.0.1", 0)
  let port = receiver.getBoundPort()

  let sender = newUdpSocket()

  proc recvTask(recv: UdpSocket): CpsFuture[Datagram] {.cps.} =
    let dg = await recv.recvFrom(1024)
    return dg

  proc sendTask(send: UdpSocket, p: int): CpsVoidFuture {.cps.} =
    await cpsYield()  # Let receiver register first
    await send.sendTo("hello udp", "127.0.0.1", p)

  let rf = recvTask(receiver)
  let sf = sendTask(sender, port)
  # Drive both: wait for send to complete, then recv should have data
  let loop = getEventLoop()
  while not rf.finished or not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert rf.finished, "recv should be finished"
  assert sf.finished, "send should be finished"
  let receivedDatagram = rf.read()
  assert receivedDatagram.data == "hello udp",
    "Expected 'hello udp', got '" & receivedDatagram.data & "'"
  assert receivedDatagram.address == "127.0.0.1",
    "Expected sender address 127.0.0.1, got '" & receivedDatagram.address & "'"
  assert receivedDatagram.port > 0, "Expected valid sender port"

  receiver.close()
  sender.close()
  echo "PASS: UDP loopback send/recv"

# Test 2: Multiple datagrams
block testUdpMultiple:
  let receiver = newUdpSocket()
  receiver.bindAddr("127.0.0.1", 0)
  let port = receiver.getBoundPort()

  let sender = newUdpSocket()

  proc recvTask(recv: UdpSocket): CpsFuture[seq[string]] {.cps.} =
    var received: seq[string]
    for i in 0 ..< 3:
      let dg = await recv.recvFrom(1024)
      received.add(dg.data)
    return received

  proc sendTask(send: UdpSocket, p: int): CpsVoidFuture {.cps.} =
    await cpsYield()
    await send.sendTo("one", "127.0.0.1", p)
    await send.sendTo("two", "127.0.0.1", p)
    await send.sendTo("three", "127.0.0.1", p)

  let rf = recvTask(receiver)
  let sf = sendTask(sender, port)
  let loop = getEventLoop()
  while not rf.finished or not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert rf.finished, "recv should be finished"
  let received = rf.read()
  assert received.len == 3, "Expected 3 datagrams, got " & $received.len
  assert "one" in received
  assert "two" in received
  assert "three" in received

  receiver.close()
  sender.close()
  echo "PASS: UDP multiple datagrams"

# Test 3: Close UDP socket
block testUdpClose:
  let sock = newUdpSocket()
  assert not sock.closed
  sock.close()
  assert sock.closed
  echo "PASS: UDP close"

# Test 4: trySendToAddr fire-and-forget + recvFrom
block testTrySendToAddr:
  let receiver = newUdpSocket()
  receiver.bindAddr("127.0.0.1", 0)
  let port = receiver.getBoundPort()

  let sender = newUdpSocket()

  proc recvTask(recv: UdpSocket): CpsFuture[Datagram] {.cps.} =
    let dg = await recv.recvFrom(1024)
    return dg

  let rf = recvTask(receiver)

  # Fire-and-forget send
  let ok = sender.trySendToAddr("fire-and-forget", "127.0.0.1", port)
  assert ok, "trySendToAddr should succeed on loopback"

  let loop = getEventLoop()
  while not rf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert rf.finished, "recv should be finished"
  let dg = rf.read()
  assert dg.data == "fire-and-forget",
    "Expected 'fire-and-forget', got '" & dg.data & "'"

  receiver.close()
  sender.close()
  echo "PASS: trySendToAddr fire-and-forget"

# Test 5: sendToAddr async with write-readiness
block testSendToAddr:
  let receiver = newUdpSocket()
  receiver.bindAddr("127.0.0.1", 0)
  let port = receiver.getBoundPort()

  let sender = newUdpSocket()

  proc recvTask(recv: UdpSocket): CpsFuture[Datagram] {.cps.} =
    let dg = await recv.recvFrom(1024)
    return dg

  proc sendTask(send: UdpSocket, p: int): CpsVoidFuture {.cps.} =
    await cpsYield()
    await send.sendToAddr("async-addr-send", "127.0.0.1", p)

  let rf = recvTask(receiver)
  let sf = sendTask(sender, port)
  let loop = getEventLoop()
  while not rf.finished or not sf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  assert rf.finished, "recv should be finished"
  assert sf.finished, "send should be finished"
  let dg = rf.read()
  assert dg.data == "async-addr-send",
    "Expected 'async-addr-send', got '" & dg.data & "'"

  receiver.close()
  sender.close()
  echo "PASS: sendToAddr async"

# Test 6: onRecv persistent callback receives multiple datagrams
block testOnRecv:
  let receiver = newUdpSocket()
  receiver.bindAddr("127.0.0.1", 0)
  let port = receiver.getBoundPort()

  let sender = newUdpSocket()

  var received: seq[string]

  receiver.onRecv(1024, proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
    received.add(data)
  )

  # Send 3 datagrams with a short delay between each to allow drain+reregister
  proc sendTask(send: UdpSocket, p: int): CpsVoidFuture {.cps.} =
    discard send.trySendToAddr("msg1", "127.0.0.1", p)
    await cpsYield()
    discard send.trySendToAddr("msg2", "127.0.0.1", p)
    await cpsYield()
    discard send.trySendToAddr("msg3", "127.0.0.1", p)

  let sf = sendTask(sender, port)
  let loop = getEventLoop()

  # Run enough ticks to process all 3 messages
  var ticks = 0
  while ticks < 30 and (received.len < 3 or not sf.finished):
    loop.tick()
    ticks += 1

  assert received.len == 3, "Expected 3 datagrams via onRecv, got " & $received.len
  assert "msg1" in received
  assert "msg2" in received
  assert "msg3" in received

  # Now cancelOnRecv and verify no more datagrams are received
  receiver.cancelOnRecv()
  discard sender.trySendToAddr("msg4", "127.0.0.1", port)

  # Run a few ticks
  for i in 0 ..< 5:
    loop.tick()

  assert received.len == 3, "Expected still 3 after cancelOnRecv, got " & $received.len

  receiver.close()
  sender.close()
  echo "PASS: onRecv persistent callback"

# Test 7: parseSenderAddress extracts correct IP and port
block testParseSenderAddress:
  let receiver = newUdpSocket()
  receiver.bindAddr("127.0.0.1", 0)
  let port = receiver.getBoundPort()

  let sender = newUdpSocket()
  sender.bindAddr("127.0.0.1", 0)
  let senderPort = sender.getBoundPort()

  var rawDg: RawDatagram
  var gotDatagram = false

  receiver.onRecv(1024, proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
    rawDg = RawDatagram(data: data, srcAddr: srcAddr, addrLen: addrLen)
    gotDatagram = true
  )

  discard sender.trySendToAddr("addr-test", "127.0.0.1", port)

  let loop = getEventLoop()
  var ticks = 0
  while not gotDatagram and ticks < 20:
    loop.tick()
    ticks += 1

  assert gotDatagram, "Should have received datagram"
  assert rawDg.data == "addr-test"

  let (ip, srcPort) = parseSenderAddress(rawDg)
  assert ip == "127.0.0.1", "Expected sender IP 127.0.0.1, got '" & ip & "'"
  assert srcPort == senderPort, "Expected sender port " & $senderPort & ", got " & $srcPort

  receiver.cancelOnRecv()
  receiver.close()
  sender.close()
  echo "PASS: parseSenderAddress"

# Test 8: fillSockaddrIp rejects invalid IP
block testFillSockaddrIpInvalid:
  var sa: Sockaddr_storage
  var gotError = false
  try:
    discard fillSockaddrIp("not-an-ip", 53, AF_INET, sa)
  except streams.AsyncIoError:
    gotError = true
  assert gotError, "fillSockaddrIp should raise on invalid IP"
  echo "PASS: fillSockaddrIp rejects invalid IP"

echo "All UDP tests passed!"
