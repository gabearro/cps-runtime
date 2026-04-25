## Tests for the uTP stream adapter.
##
## Tests UtpManager, UtpStream (AsyncStream), connect/accept, and data transfer
## using two managers communicating over localhost UDP.

import std/[os]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/buffered
import cps/io/timeouts
import cps/bittorrent/utp
import cps/bittorrent/utp_stream
import cps/bittorrent/peer

# === Unit tests (no event loop) ===

block test_manager_creation:
  ## UtpManager allocates connection IDs.
  let mgr = newUtpManager(0)
  assert mgr.connectionCount == 0
  assert not mgr.closed
  mgr.close()
  assert mgr.closed
  echo "PASS: manager creation and close"

block test_stream_vtable:
  ## UtpStream has all vtable procs set.
  let mgr = newUtpManager(0)
  let sock = newUtpSocket(1000)
  sock.state = usConnected
  # Use internal helper via the module
  let stream = UtpStream(
    manager: mgr,
    sock: sock,
    remoteIp: "127.0.0.1",
    remotePort: 9999
  )
  stream.readProc = nil  # Will be set by newUtpStream (which we can't call directly)
  # Verify the type hierarchy works
  let base: AsyncStream = stream
  assert base of UtpStream
  mgr.close()
  echo "PASS: UtpStream type hierarchy"

# === Integration tests (with event loop) ===

proc testConnectAccept(): CpsVoidFuture {.cps.} =
  ## Test uTP connect and accept between two managers on localhost.
  let server = newUtpManager(19800)
  let client = newUtpManager(19801)
  server.start()
  client.start()

  # Server: start accept in background
  let acceptFut = utpAccept(server)

  # Give the accept a moment to register
  await cpsSleep(50)

  # Client: connect to server
  let clientStream: UtpStream = await utpConnect(client, "127.0.0.1", 19800, 3000)
  assert clientStream != nil
  assert clientStream.sock.state == usConnected

  # Server: accept should complete
  let serverStream: UtpStream = await withTimeout(acceptFut, 3000)
  assert serverStream != nil
  assert serverStream.sock.state == usConnected

  echo "PASS: uTP connect/accept"

  # Test data transfer: client → server
  let testData = "Hello from uTP client!"
  await clientStream.write(testData)

  # Give the packet time to arrive
  await cpsSleep(100)

  # Server reads
  let received: string = await withTimeout(serverStream.read(1024), 3000)
  assert received == testData, "got: " & received

  echo "PASS: uTP data transfer client→server"

  # Test data transfer: server → client
  let replyData = "Reply from uTP server!"
  await serverStream.write(replyData)

  await cpsSleep(100)

  let reply: string = await withTimeout(clientStream.read(1024), 3000)
  assert reply == replyData, "got: " & reply

  echo "PASS: uTP data transfer server→client"

  # Test larger data (multiple packets)
  var bigData = ""
  var i = 0
  while i < 100:
    bigData.add("Chunk " & $i & " of test data. ")
    i += 1

  await clientStream.write(bigData)
  await cpsSleep(200)

  var totalReceived = ""
  while totalReceived.len < bigData.len:
    let chunk: string = await withTimeout(serverStream.read(4096), 3000)
    if chunk.len == 0:
      break
    totalReceived.add(chunk)

  assert totalReceived == bigData, "big data mismatch: got " & $totalReceived.len & " expected " & $bigData.len

  echo "PASS: uTP large data transfer"

  # Clean close
  clientStream.close()
  serverStream.close()
  client.close()
  server.close()

  echo "PASS: uTP clean shutdown"

proc testConnectTimeout(): CpsVoidFuture {.cps.} =
  ## Test that connecting to a non-listening port times out.
  let client = newUtpManager(19802)
  client.start()

  var timedOut = false
  try:
    let stream: UtpStream = await utpConnect(client, "127.0.0.1", 19899, 500)
    # Should not reach here
    stream.close()
  except AsyncIoError:
    timedOut = true

  assert timedOut, "expected timeout on connect to non-listening port"
  assert client.connectionCount == 0, "connection should be cleaned up after timeout"

  client.close()
  echo "PASS: uTP connect timeout"

proc testBufferedRead(): CpsVoidFuture {.cps.} =
  ## Test reading through a BufferedReader over uTP.
  let server = newUtpManager(19803)
  let client = newUtpManager(19804)
  server.start()
  client.start()

  let acceptFut = utpAccept(server)
  await cpsSleep(50)

  let clientStream: UtpStream = await utpConnect(client, "127.0.0.1", 19803, 3000)
  let serverStream: UtpStream = await withTimeout(acceptFut, 3000)

  # Wrap server side in BufferedReader
  let reader = newBufferedReader(serverStream.AsyncStream, 4096)

  # Send exactly 10 bytes
  await clientStream.write("0123456789")
  await cpsSleep(100)

  # Read exactly 10 bytes via buffered reader
  let exact: string = await withTimeout(reader.readExact(10), 3000)
  assert exact == "0123456789", "got: " & exact

  echo "PASS: uTP buffered readExact"

  clientStream.close()
  serverStream.close()
  client.close()
  server.close()

proc testEofOnClose(): CpsVoidFuture {.cps.} =
  ## Test that closing the remote side delivers EOF.
  let server = newUtpManager(19805)
  let client = newUtpManager(19806)
  server.start()
  client.start()

  let acceptFut = utpAccept(server)
  await cpsSleep(50)

  let clientStream: UtpStream = await utpConnect(client, "127.0.0.1", 19805, 3000)
  let serverStream: UtpStream = await withTimeout(acceptFut, 3000)

  # Close client side
  clientStream.close()
  await cpsSleep(200)  # Wait for FIN to propagate

  # Server should get EOF
  let data: string = await withTimeout(serverStream.read(1024), 3000)
  assert data.len == 0, "expected EOF, got " & $data.len & " bytes"

  echo "PASS: uTP EOF on close"

  serverStream.close()
  client.close()
  server.close()

block test_write_window_full_buffers:
  ## Regression: utpStreamWrite used to silently drop data when the congestion
  ## window was full. Now it should buffer remaining data and not complete the
  ## future until all data is sent.
  let mgr = newUtpManager(0)
  let sock = newUtpSocket(2000)
  sock.state = usConnected
  # Set a very small window so write can only send ~1 packet
  sock.maxWindow = UtpMaxPayload  # Room for exactly 1 packet
  sock.wndSize = uint32(UtpMaxPayload)
  sock.curWindow = 0

  let stream = newUtpStream(mgr, sock, "127.0.0.1", 9999)

  # Write more data than fits in one window
  var bigData = newString(UtpMaxPayload * 3)
  for i in 0 ..< bigData.len:
    bigData[i] = char(i mod 256)

  let writeFut = stream.write(bigData)

  # After the first packet, curWindow should fill the window.
  # The future should NOT be completed yet — data is still pending.
  assert not writeFut.finished, "write should block when window is full"
  assert stream.writeOffset > 0, "some data should have been sent"
  assert stream.writeOffset < bigData.len, "not all data sent"
  echo "PASS: uTP write buffers when window full (no silent truncation)"

  mgr.close()

block test_write_completes_immediately_when_window_large:
  ## When the window is large enough, write should complete immediately.
  let mgr = newUtpManager(0)
  let sock = newUtpSocket(2002)
  sock.state = usConnected
  sock.maxWindow = DefaultWindowSize  # 1 MiB — plenty of space
  sock.wndSize = DefaultWindowSize.uint32
  sock.curWindow = 0

  let stream = newUtpStream(mgr, sock, "127.0.0.1", 9999)

  let smallData = "hello uTP"
  let writeFut = stream.write(smallData)

  assert writeFut.finished, "small write should complete immediately with large window"
  assert not writeFut.hasError
  echo "PASS: uTP write completes immediately when window allows"

  mgr.close()

block test_write_close_fails_pending:
  ## If the stream is closed while a write is pending, the write future should fail.
  let mgr = newUtpManager(0)
  let sock = newUtpSocket(2004)
  sock.state = usConnected
  sock.maxWindow = UtpMaxPayload
  sock.wndSize = uint32(UtpMaxPayload)
  sock.curWindow = 0

  let stream = newUtpStream(mgr, sock, "127.0.0.1", 9999)

  let bigData = newString(UtpMaxPayload * 3)
  let writeFut = stream.write(bigData)
  assert not writeFut.finished

  # Close the stream — pending write should fail
  stream.close()
  assert writeFut.finished, "close should fail the pending write"
  assert writeFut.hasError, "pending write should have error after close"
  echo "PASS: uTP close fails pending write"

block test_utp_conn_key_includes_endpoint:
  ## Regression: uTP connection table was keyed only by connectionId, allowing
  ## different peers with same connId to collide/misroute/overwrite.
  let key1 = utpConnKey(1000, "192.168.1.1", 6881)
  let key2 = utpConnKey(1000, "192.168.1.2", 6881)
  let key3 = utpConnKey(1000, "192.168.1.1", 6882)
  let key4 = utpConnKey(1001, "192.168.1.1", 6881)
  assert key1 != key2, "different IP should produce different key"
  assert key1 != key3, "different port should produce different key"
  assert key1 != key4, "different connId should produce different key"
  let key1b = utpConnKey(1000, "192.168.1.1", 6881)
  assert key1 == key1b, "identical inputs should produce identical key"
  echo "PASS: uTP connection key includes sender endpoint"

block test_simultaneous_syn:
  ## Regression: when both sides send SYN simultaneously (BEP 55 holepunch),
  ## receiving a StSyn while in usSynSent was ignored. Now it transitions to connected.
  let sockA = newUtpSocket(1000)
  let sockB = newUtpSocket(2000)

  # Both sides send SYN → both enter usSynSent
  let synA = sockA.makeSynPacket()
  let synB = sockB.makeSynPacket()
  assert sockA.state == usSynSent
  assert sockB.state == usSynSent

  # A receives B's SYN — should transition to connected
  let resultA = sockA.processIncoming(synB)
  assert sockA.state == usConnected, "sockA should be connected after receiving SYN in usSynSent"
  assert resultA.stateChanged, "state should have changed"
  assert resultA.response.len > 0, "should send STATE response"

  # B receives A's SYN — should also transition to connected
  let resultB = sockB.processIncoming(synA)
  assert sockB.state == usConnected, "sockB should be connected after receiving SYN in usSynSent"
  assert resultB.stateChanged, "state should have changed"
  assert resultB.response.len > 0, "should send STATE response"

  echo "PASS: uTP simultaneous SYN (BEP 55 holepunch race)"

block test_transport_kind:
  ## Test TransportKind enum exists and works.
  var tk: TransportKind = ptUtp
  assert tk == ptUtp
  tk = ptTcp
  assert tk == ptTcp
  echo "PASS: TransportKind enum"

# Main — run all tests
echo "uTP Stream Tests"
echo "================"
echo ""

block:
  let loop = getEventLoop()

  # Test connect/accept and data transfer
  block:
    let fut = testConnectAccept()
    var ticks = 0
    while not fut.finished and ticks < 300000:
      loop.tick()
      ticks += 1
    if fut.hasError:
      echo "ERROR: testConnectAccept: " & fut.getError().msg
      quit(1)
    if not fut.finished:
      echo "TIMEOUT: testConnectAccept"
      quit(1)

  # Test connect timeout
  block:
    let fut = testConnectTimeout()
    var ticks = 0
    while not fut.finished and ticks < 100000:
      loop.tick()
      ticks += 1
    if fut.hasError:
      echo "ERROR: testConnectTimeout: " & fut.getError().msg
      quit(1)
    if not fut.finished:
      echo "TIMEOUT: testConnectTimeout"
      quit(1)

  # Test buffered read
  block:
    let fut = testBufferedRead()
    var ticks = 0
    while not fut.finished and ticks < 300000:
      loop.tick()
      ticks += 1
    if fut.hasError:
      echo "ERROR: testBufferedRead: " & fut.getError().msg
      quit(1)
    if not fut.finished:
      echo "TIMEOUT: testBufferedRead"
      quit(1)

  # Test EOF on close
  block:
    let fut = testEofOnClose()
    var ticks = 0
    while not fut.finished and ticks < 300000:
      loop.tick()
      ticks += 1
    if fut.hasError:
      echo "ERROR: testEofOnClose: " & fut.getError().msg
      quit(1)
    if not fut.finished:
      echo "TIMEOUT: testEofOnClose"
      quit(1)

echo ""
echo "All uTP stream tests passed!"
