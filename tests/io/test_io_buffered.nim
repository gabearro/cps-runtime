## Tests for CPS I/O BufferedReader/Writer with BufferStream (no real I/O)

import cps/eventloop
import cps/io/streams
import cps/io/buffered

# Test 1: BufferedReader readLine with \r\n
block testReadLine:
  let bs = newBufferStream()
  let wf = bs.AsyncStream.write("hello\r\nworld\r\n")
  runCps(wf)
  bs.signalEof()

  let br = newBufferedReader(bs.AsyncStream, bufSize = 64)

  let line1 = runCps(br.readLine())
  assert line1 == "hello", "Expected 'hello', got '" & line1 & "'"

  let line2 = runCps(br.readLine())
  assert line2 == "world", "Expected 'world', got '" & line2 & "'"

  let line3 = runCps(br.readLine())
  assert line3 == "", "Expected empty on EOF, got '" & line3 & "'"
  echo "PASS: BufferedReader readLine"

# Test 2: readLine with custom delimiter
block testReadLineCustomDelim:
  let bs = newBufferStream()
  let wf = bs.AsyncStream.write("a|b|c|")
  runCps(wf)
  bs.signalEof()

  let br = newBufferedReader(bs.AsyncStream, bufSize = 32)

  let l1 = runCps(br.readLine(delimiter = "|"))
  assert l1 == "a", "Expected 'a', got '" & l1 & "'"

  let l2 = runCps(br.readLine(delimiter = "|"))
  assert l2 == "b", "Expected 'b', got '" & l2 & "'"

  let l3 = runCps(br.readLine(delimiter = "|"))
  assert l3 == "c", "Expected 'c', got '" & l3 & "'"
  echo "PASS: BufferedReader readLine custom delimiter"

# Test 3: readExact
block testReadExact:
  let bs = newBufferStream()
  let wf = bs.AsyncStream.write("exactly10!")
  runCps(wf)
  bs.signalEof()

  let br = newBufferedReader(bs.AsyncStream, bufSize = 16)

  let data = runCps(br.readExact(10))
  assert data == "exactly10!", "Expected 'exactly10!', got '" & data & "'"
  echo "PASS: BufferedReader readExact"

# Test 4: readExact short read fails
block testReadExactShort:
  let bs = newBufferStream()
  let wf = bs.AsyncStream.write("short")
  runCps(wf)
  bs.signalEof()

  let br = newBufferedReader(bs.AsyncStream, bufSize = 16)

  let fut = br.readExact(100)
  let loop = getEventLoop()
  while not fut.finished:
    loop.tick()
    if not fut.finished and not loop.hasWork:
      break
  assert fut.hasError(), "readExact should fail on short read"
  assert fut.getError() of ConnectionClosedError, "Should be ConnectionClosedError"
  echo "PASS: BufferedReader readExact short read fails"

# Test 5: BufferedReader read
block testRead:
  let bs = newBufferStream()
  let wf = bs.AsyncStream.write("some data here")
  runCps(wf)
  bs.signalEof()

  let br = newBufferedReader(bs.AsyncStream, bufSize = 32)

  let d1 = runCps(br.read(4))
  assert d1 == "some", "Expected 'some', got '" & d1 & "'"

  let d2 = runCps(br.read(100))
  assert d2 == " data here", "Expected ' data here', got '" & d2 & "'"

  let d3 = runCps(br.read(10))
  assert d3 == "", "Expected empty on EOF"
  echo "PASS: BufferedReader read"

# Test 6: Partial fills — data arrives in chunks
block testPartialFills:
  let bs = newBufferStream()

  let br = newBufferedReader(bs.AsyncStream, bufSize = 8)

  # Start a readLine before full line is available
  let lineFut = br.readLine()
  assert not lineFut.finished, "Should be waiting for data"

  # Write partial data
  let wf1 = bs.AsyncStream.write("hel")
  runCps(wf1)

  # Still waiting — no delimiter yet
  # (need to drive event loop to process the fill callback)
  let loop = getEventLoop()
  loop.tick()
  # The readLine chains callbacks internally, may need more ticks
  for i in 0 ..< 5:
    loop.tick()

  # Write the rest with delimiter
  let wf2 = bs.AsyncStream.write("lo\r\n")
  runCps(wf2)

  # Now drive until finished
  while not lineFut.finished:
    loop.tick()

  let line = lineFut.read()
  assert line == "hello", "Expected 'hello', got '" & line & "'"
  echo "PASS: BufferedReader partial fills"

# Test 7: BufferedWriter flush
block testBufferedWriter:
  let bs = newBufferStream()
  let bw = newBufferedWriter(bs.AsyncStream, bufSize = 100)

  runCps(bw.write("hello "))
  runCps(bw.write("world"))
  runCps(bw.flush())

  let data = runCps(bs.AsyncStream.read(100))
  assert data == "hello world", "Expected 'hello world', got '" & data & "'"
  echo "PASS: BufferedWriter flush"

# Test 8: BufferedWriter writeLine
block testBufferedWriterLine:
  let bs = newBufferStream()
  let bw = newBufferedWriter(bs.AsyncStream, bufSize = 100)

  runCps(bw.writeLine("line1"))
  let data = runCps(bs.AsyncStream.read(100))
  assert data == "line1\r\n", "Expected 'line1\\r\\n', got '" & data & "'"
  echo "PASS: BufferedWriter writeLine"

# Test 9: BufferedWriter auto-flush
block testAutoFlush:
  let bs = newBufferStream()
  let bw = newBufferedWriter(bs.AsyncStream, bufSize = 5)

  # Write more than bufSize — should auto-flush
  runCps(bw.write("hello world"))  # 11 bytes > 5

  let data = runCps(bs.AsyncStream.read(100))
  assert data == "hello world", "Expected 'hello world' after auto-flush"
  echo "PASS: BufferedWriter auto-flush"

echo "All buffered I/O tests passed!"
