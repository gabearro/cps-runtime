## Tests for CPS I/O Unix Domain Sockets

import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/unix
import cps/io/buffered
import std/posix

const TestSocket = "/tmp/cps_test_unix.sock"
const TestSocket2 = "/tmp/cps_test_unix2.sock"
const TestSocket3 = "/tmp/cps_test_unix3.sock"
const TestSocket4 = "/tmp/cps_test_unix4.sock"
const TestSocket5 = "/tmp/cps_test_unix5.sock"
const TestSocket6 = "/tmp/cps_test_unix6.sock"
const TestSocket7 = "/tmp/cps_test_unix7.sock"

# ============================================================
# Test 1: Listen + connect + send/recv basic data
# ============================================================
block testBasicEcho:
  let listener = unixListen(TestSocket)

  proc serverTask(l: UnixListener): CpsFuture[string] {.cps.} =
    let client = await l.accept()
    let data = await client.AsyncStream.read(1024)
    await client.AsyncStream.write(data)
    client.AsyncStream.close()
    return data

  proc clientTask(path: string): CpsFuture[string] {.cps.} =
    let conn = await unixConnect(path)
    await conn.AsyncStream.write("hello unix")
    let reply = await conn.AsyncStream.read(1024)
    conn.AsyncStream.close()
    return reply

  let sf = serverTask(listener)
  let cf = clientTask(TestSocket)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let serverGot = sf.read()
  let clientGot = cf.read()
  assert serverGot == "hello unix", "Server should have received 'hello unix', got '" & serverGot & "'"
  assert clientGot == "hello unix", "Client should have received echo, got '" & clientGot & "'"
  listener.close()
  echo "PASS: Unix socket basic echo"

# ============================================================
# Test 2: Multiple clients connecting to same server
# ============================================================
block testMultipleClients:
  let listener = unixListen(TestSocket2)

  proc serverTask(l: UnixListener, count: int): CpsFuture[seq[string]] {.cps.} =
    var messages: seq[string]
    for i in 0 ..< count:
      let client = await l.accept()
      let data = await client.AsyncStream.read(1024)
      messages.add(data)
      await client.AsyncStream.write("ack" & $i)
      client.AsyncStream.close()
    return messages

  proc clientTask(path: string, msg: string): CpsFuture[string] {.cps.} =
    let conn = await unixConnect(path)
    await conn.AsyncStream.write(msg)
    let reply = await conn.AsyncStream.read(1024)
    conn.AsyncStream.close()
    return reply

  let sf = serverTask(listener, 3)
  let c1 = clientTask(TestSocket2, "client1")
  let c2 = clientTask(TestSocket2, "client2")
  let c3 = clientTask(TestSocket2, "client3")

  let loop = getEventLoop()
  while not sf.finished or not c1.finished or not c2.finished or not c3.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let serverMessages = sf.read()
  assert serverMessages.len == 3, "Expected 3 messages, got " & $serverMessages.len
  # Clients connected sequentially (server accepts one at a time)
  let r1 = c1.read()
  let r2 = c2.read()
  let r3 = c3.read()
  assert r1 == "ack0", "Client 1 got: " & r1
  assert r2 == "ack1", "Client 2 got: " & r2
  assert r3 == "ack2", "Client 3 got: " & r3
  listener.close()
  echo "PASS: Unix socket multiple clients"

# ============================================================
# Test 3: Bidirectional communication
# ============================================================
block testBidirectional:
  let listener = unixListen(TestSocket3)

  proc serverTask(l: UnixListener): CpsFuture[string] {.cps.} =
    let client = await l.accept()
    # Server sends first
    await client.AsyncStream.write("server-hello")
    # Then reads
    let data = await client.AsyncStream.read(1024)
    # Then sends reply
    await client.AsyncStream.write("server-got:" & data)
    client.AsyncStream.close()
    return data

  proc clientTask(path: string): CpsFuture[string] {.cps.} =
    let conn = await unixConnect(path)
    # Client reads server greeting first
    let greeting = await conn.AsyncStream.read(1024)
    # Then sends
    await conn.AsyncStream.write("client-hello")
    # Then reads reply
    let reply = await conn.AsyncStream.read(1024)
    conn.AsyncStream.close()
    return greeting & "|" & reply

  let sf = serverTask(listener)
  let cf = clientTask(TestSocket3)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let serverGot = sf.read()
  let clientGot = cf.read()
  assert serverGot == "client-hello", "Server got: " & serverGot
  assert clientGot == "server-hello|server-got:client-hello", "Client got: " & clientGot
  listener.close()
  echo "PASS: Unix socket bidirectional communication"

# ============================================================
# Test 4: Large data transfer (1MB+)
# ============================================================
block testLargeData:
  let listener = unixListen(TestSocket4)
  let dataSize = 1024 * 1024 + 37  # 1MB + 37 bytes to be unaligned

  # Build test data
  var testData = newString(dataSize)
  for i in 0 ..< dataSize:
    testData[i] = chr(i mod 256)

  proc serverTask(l: UnixListener, expectedSize: int): CpsFuture[int] {.cps.} =
    let client = await l.accept()
    var received = ""
    while received.len < expectedSize:
      let chunk = await client.AsyncStream.read(65536)
      if chunk.len == 0:
        break
      received.add(chunk)
    # Echo back the length
    await client.AsyncStream.write($received.len)
    client.AsyncStream.close()
    return received.len

  proc clientTask(path: string, data: string): CpsFuture[string] {.cps.} =
    let conn = await unixConnect(path)
    await conn.AsyncStream.write(data)
    let reply = await conn.AsyncStream.read(1024)
    conn.AsyncStream.close()
    return reply

  let sf = serverTask(listener, dataSize)
  let cf = clientTask(TestSocket4, testData)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let serverReceivedLen = sf.read()
  let clientReply = cf.read()
  assert serverReceivedLen == dataSize, "Server received " & $serverReceivedLen & " bytes, expected " & $dataSize
  assert clientReply == $dataSize, "Client reply: " & clientReply
  listener.close()
  echo "PASS: Unix socket large data transfer (" & $dataSize & " bytes)"

# ============================================================
# Test 5: Connection refused (no listener)
# ============================================================
block testConnectionRefused:
  # Try to connect to a socket path that doesn't exist
  let fut = unixConnect("/tmp/cps_test_unix_nonexistent_" & $posix.getpid() & ".sock")
  let loop = getEventLoop()
  while not fut.finished:
    loop.tick()
    if not fut.finished and not loop.hasWork:
      break
  assert fut.hasError(), "Connection to nonexistent socket should fail"
  echo "PASS: Unix socket connection refused"

# ============================================================
# Test 6: Close listener and verify cleanup (socket file removed)
# ============================================================
proc pathExists(path: string): bool =
  ## Check if any filesystem entry exists at path (works for socket files too).
  var s: Stat
  posix.stat(path.cstring, s) == 0

block testCleanup:
  let listener = unixListen(TestSocket6)
  assert pathExists(TestSocket6), "Socket file should exist after listen"
  listener.close()
  assert not pathExists(TestSocket6), "Socket file should be removed after close"
  echo "PASS: Unix socket cleanup (file removed on close)"

# ============================================================
# Test 7: BufferedReader/BufferedWriter over UnixStream
# ============================================================
block testBuffered:
  let listener = unixListen(TestSocket7)

  proc serverTask(l: UnixListener): CpsFuture[seq[string]] {.cps.} =
    let client = await l.accept()
    let reader = newBufferedReader(client.AsyncStream)
    var lines: seq[string]
    let line1 = await reader.readLine("\n")
    lines.add(line1)
    let line2 = await reader.readLine("\n")
    lines.add(line2)
    let line3 = await reader.readLine("\n")
    lines.add(line3)
    client.AsyncStream.close()
    return lines

  proc clientTask(path: string): CpsVoidFuture {.cps.} =
    let conn = await unixConnect(path)
    let writer = newBufferedWriter(conn.AsyncStream)
    await writer.writeLine("line one", "\n")
    await writer.writeLine("line two", "\n")
    await writer.writeLine("line three", "\n")
    let flushFut = writer.flush()
    await flushFut
    conn.AsyncStream.close()

  let sf = serverTask(listener)
  let cf = clientTask(TestSocket7)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let lines = sf.read()
  assert lines.len == 3, "Expected 3 lines, got " & $lines.len
  assert lines[0] == "line one", "Line 1: " & lines[0]
  assert lines[1] == "line two", "Line 2: " & lines[1]
  assert lines[2] == "line three", "Line 3: " & lines[2]
  listener.close()
  echo "PASS: Unix socket buffered reader/writer"

echo "All Unix socket tests passed!"
