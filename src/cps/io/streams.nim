## CPS I/O Streams
##
## Provides the base stream abstraction and error types for the CPS I/O library.
## AsyncStream uses proc-field vtable dispatch (matching the Continuation.fn pattern).
## BufferStream is an in-memory stream for testing and piping.

import std/deques
import ../runtime
import ../eventloop

type
  AsyncIoError* = object of CatchableError
  IoError* {.deprecated: "Use AsyncIoError instead".} = AsyncIoError
  ConnectionClosedError* = object of AsyncIoError
  TimeoutError* = object of AsyncIoError

  AsyncStream* = ref object of RootObj
    ## Base stream type with proc-field vtable dispatch.
    closed*: bool
    readProc*: proc(s: AsyncStream, size: int): CpsFuture[string]
    writeProc*: proc(s: AsyncStream, data: string): CpsVoidFuture
    closeProc*: proc(s: AsyncStream)
    ## Optional zero-copy read API for buffered consumers.
    ## readIntoProc: read up to `size` bytes directly into `buf`.
    ##   Returns >0 = bytes read, 0 = EOF, -1 = EAGAIN, < -1 = error.
    ## waitReadableProc: register for readability, complete when data available.
    ## If nil, BufferedReader falls back to the allocating read() path.
    readIntoProc*: proc(s: AsyncStream, buf: pointer, size: int): int
    waitReadableProc*: proc(s: AsyncStream): CpsVoidFuture

# ============================================================
# Stream dispatch procs
# ============================================================

proc read*(s: AsyncStream, size: int): CpsFuture[string] =
  ## Read up to `size` bytes from the stream. Returns "" on EOF.
  if s == nil:
    return failedFuture[string](newException(AsyncIoError, "Cannot read from nil stream"))
  if s.closed:
    return failedFuture[string](newException(AsyncIoError, "Cannot read from closed stream"))
  if s.readProc == nil:
    return failedFuture[string](newException(AsyncIoError, "Stream does not support reading"))
  s.readProc(s, size)

proc write*(s: AsyncStream, data: string): CpsVoidFuture =
  ## Write `data` to the stream.
  if s == nil:
    return failedVoidFuture(newException(AsyncIoError, "Cannot write to nil stream"))
  if s.closed:
    return failedVoidFuture(newException(AsyncIoError, "Cannot write to closed stream"))
  if s.writeProc == nil:
    return failedVoidFuture(newException(AsyncIoError, "Stream does not support writing"))
  s.writeProc(s, data)

proc close*(s: AsyncStream) =
  ## Close the stream.
  if s != nil and not s.closed:
    s.closed = true
    if s.closeProc != nil:
      s.closeProc(s)

# ============================================================
# BufferStream - in-memory stream for testing and piping
# ============================================================

type
  BufferWaiter = object
    size: int
    future: CpsFuture[string]

  BufferStream* = ref object of AsyncStream
    buffer: string
    pos: int
    waiters: Deque[BufferWaiter]
    eofSignaled: bool

proc bufferAvail(bs: BufferStream): int {.inline.} =
  bs.buffer.len - bs.pos

proc consumeBuffer(bs: BufferStream, size: int): string =
  ## Consume up to `size` bytes from the buffer. Compacts when half consumed.
  let avail = bs.bufferAvail
  let toRead = min(size, avail)
  result = bs.buffer[bs.pos ..< bs.pos + toRead]
  bs.pos += toRead
  if bs.pos > 0 and bs.pos >= bs.buffer.len div 2:
    bs.buffer = bs.buffer[bs.pos .. ^1]
    bs.pos = 0

proc tryWakeWaiters(bs: BufferStream) =
  ## Try to fulfill pending read waiters from the buffer.
  while bs.waiters.len > 0:
    if bs.eofSignaled and bs.bufferAvail == 0:
      bs.waiters.popFirst().future.complete("")
    elif bs.bufferAvail > 0:
      let waiter = bs.waiters.popFirst()
      waiter.future.complete(bs.consumeBuffer(waiter.size))
    else:
      break

proc bufferStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let bs = BufferStream(s)
  if bs.bufferAvail > 0:
    return completedFuture(bs.consumeBuffer(size))
  if bs.eofSignaled:
    return completedFuture("")
  let fut = newCpsFuture[string]()
  bs.waiters.addLast(BufferWaiter(size: size, future: fut))
  fut

proc bufferStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let bs = BufferStream(s)
  if bs.closed or bs.eofSignaled:
    return failedVoidFuture(newException(AsyncIoError, "Cannot write to closed/EOF stream"))
  bs.buffer.add(data)
  bs.tryWakeWaiters()
  completedVoidFuture()

proc bufferStreamClose(s: AsyncStream) =
  let bs = BufferStream(s)
  bs.eofSignaled = true
  bs.tryWakeWaiters()

proc newBufferStream*(): BufferStream =
  ## Create an in-memory stream for testing and piping.
  result = BufferStream(
    closed: false,
    buffer: "",
    pos: 0,
    eofSignaled: false
  )
  result.readProc = bufferStreamRead
  result.writeProc = bufferStreamWrite
  result.closeProc = bufferStreamClose

proc signalEof*(bs: BufferStream) =
  ## Signal that no more data will be written.
  ## Completes all waiting readers with "".
  bs.eofSignaled = true
  bs.tryWakeWaiters()

# ============================================================
# PrefixedStream - replays prefix data before inner stream
# ============================================================

type
  PrefixedStream* = ref object of AsyncStream
    inner*: AsyncStream
    prefix: string
    prefixPos: int

proc prefixedStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let ps = PrefixedStream(s)
  let remaining = ps.prefix.len - ps.prefixPos
  if remaining > 0:
    let n = min(size, remaining)
    let data = ps.prefix[ps.prefixPos ..< ps.prefixPos + n]
    ps.prefixPos += n
    return completedFuture(data)
  ps.inner.read(size)

proc prefixedStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  PrefixedStream(s).inner.write(data)

proc prefixedStreamClose(s: AsyncStream) =
  PrefixedStream(s).inner.close()

proc newPrefixedStream*(inner: AsyncStream, prefix: string): PrefixedStream =
  ## Wrap a stream with prefix data that is read first.
  ## After the prefix is consumed, reads pass through to the inner stream.
  result = PrefixedStream(inner: inner, prefix: prefix, prefixPos: 0)
  result.readProc = prefixedStreamRead
  result.writeProc = prefixedStreamWrite
  result.closeProc = prefixedStreamClose
