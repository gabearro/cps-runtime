## CPS I/O Streams
##
## Provides the base stream abstraction and error types for the CPS I/O library.
## AsyncStream uses proc-field vtable dispatch (matching the Continuation.fn pattern).
## BufferStream is an in-memory stream for testing and piping.

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
  assert s.readProc != nil, "Stream does not support reading"
  s.readProc(s, size)

proc write*(s: AsyncStream, data: string): CpsVoidFuture =
  ## Write `data` to the stream.
  assert s.writeProc != nil, "Stream does not support writing"
  s.writeProc(s, data)

proc close*(s: AsyncStream) =
  ## Close the stream.
  if not s.closed:
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
    waiters: seq[BufferWaiter]
    eofSignaled: bool

proc tryWakeWaiters(bs: BufferStream) =
  ## Try to fulfill pending read waiters from the buffer.
  var i = 0
  while i < bs.waiters.len:
    if bs.eofSignaled and bs.buffer.len == 0:
      # EOF: complete all waiters with empty string
      let fut = bs.waiters[i].future
      bs.waiters.delete(i)
      fut.complete("")
    elif bs.buffer.len > 0:
      let waiter = bs.waiters[i]
      let toRead = min(waiter.size, bs.buffer.len)
      let data = bs.buffer[0 ..< toRead]
      bs.buffer = bs.buffer[toRead .. ^1]
      bs.waiters.delete(i)
      waiter.future.complete(data)
    else:
      inc i

proc bufferStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let bs = BufferStream(s)
  let fut = newCpsFuture[string]()
  if bs.buffer.len > 0:
    let toRead = min(size, bs.buffer.len)
    let data = bs.buffer[0 ..< toRead]
    bs.buffer = bs.buffer[toRead .. ^1]
    fut.complete(data)
  elif bs.eofSignaled:
    fut.complete("")
  else:
    bs.waiters.add(BufferWaiter(size: size, future: fut))
  result = fut

proc bufferStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let bs = BufferStream(s)
  let fut = newCpsVoidFuture()
  if bs.closed or bs.eofSignaled:
    fut.fail(newException(AsyncIoError, "Cannot write to closed/EOF stream"))
    return fut
  bs.buffer.add(data)
  bs.tryWakeWaiters()
  fut.complete()
  result = fut

proc bufferStreamClose(s: AsyncStream) =
  let bs = BufferStream(s)
  bs.eofSignaled = true
  bs.tryWakeWaiters()

proc newBufferStream*(): BufferStream =
  ## Create an in-memory stream for testing and piping.
  result = BufferStream(
    closed: false,
    buffer: "",
    waiters: @[],
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
    let fut = newCpsFuture[string]()
    fut.complete(data)
    return fut
  return ps.inner.read(size)

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
