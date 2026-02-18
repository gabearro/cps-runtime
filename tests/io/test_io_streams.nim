## Tests for CPS I/O streams (BufferStream)

import cps/eventloop
import cps/io/streams

# Test 1: BufferStream write then read
block testWriteRead:
  let bs = newBufferStream()
  let wf = bs.AsyncStream.write("hello")
  runCps(wf)

  let rf = bs.AsyncStream.read(5)
  let data = runCps(rf)
  assert data == "hello", "Expected 'hello', got '" & data & "'"
  echo "PASS: BufferStream write+read"

# Test 2: Partial read
block testPartialRead:
  let bs = newBufferStream()
  let wf = bs.AsyncStream.write("hello world")
  runCps(wf)

  let rf1 = bs.AsyncStream.read(5)
  let d1 = runCps(rf1)
  assert d1 == "hello", "Expected 'hello', got '" & d1 & "'"

  let rf2 = bs.AsyncStream.read(10)
  let d2 = runCps(rf2)
  assert d2 == " world", "Expected ' world', got '" & d2 & "'"
  echo "PASS: BufferStream partial read"

# Test 3: EOF signaling
block testEof:
  let bs = newBufferStream()
  bs.signalEof()

  let rf = bs.AsyncStream.read(100)
  let data = runCps(rf)
  assert data == "", "Expected empty string on EOF, got '" & data & "'"
  echo "PASS: BufferStream EOF signaling"

# Test 4: Read waiter wakeup
block testReadWaiter:
  let bs = newBufferStream()

  # Start a read before any data is written — it will wait
  let rf = bs.AsyncStream.read(5)
  assert not rf.finished, "Should not be finished yet"

  # Now write data — should wake the waiter
  let wf = bs.AsyncStream.write("data!")
  runCps(wf)

  assert rf.finished, "Should be finished after write"
  let data = rf.read()
  assert data == "data!", "Expected 'data!', got '" & data & "'"
  echo "PASS: BufferStream read waiter wakeup"

# Test 5: EOF wakes waiting reader
block testEofWakesReader:
  let bs = newBufferStream()

  let rf = bs.AsyncStream.read(100)
  assert not rf.finished, "Should not be finished yet"

  bs.signalEof()
  assert rf.finished, "Should be finished after EOF"
  let data = rf.read()
  assert data == "", "Expected empty string, got '" & data & "'"
  echo "PASS: BufferStream EOF wakes waiting reader"

# Test 6: Stream dispatch (polymorphism via proc fields)
block testStreamDispatch:
  let bs = newBufferStream()
  let s: AsyncStream = bs  # Use as base type

  let wf = s.write("polymorphic")
  runCps(wf)

  let rf = s.read(20)
  let data = runCps(rf)
  assert data == "polymorphic", "Expected 'polymorphic', got '" & data & "'"
  echo "PASS: Stream dispatch polymorphism"

# Test 7: Close stream
block testClose:
  let bs = newBufferStream()
  bs.AsyncStream.close()
  assert bs.closed, "Stream should be closed"

  # Writing to closed stream should fail
  let wf = bs.AsyncStream.write("fail")
  runCps(wf)
  assert wf.hasError(), "Write to closed stream should fail"
  echo "PASS: BufferStream close"

echo "All stream tests passed!"
