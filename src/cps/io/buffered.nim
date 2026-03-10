## CPS I/O Buffered
##
## Provides BufferedReader and BufferedWriter that wrap any AsyncStream
## with application-level buffering for efficient line-oriented and
## chunked I/O.

import ../runtime
import ../eventloop
import ./streams

# ============================================================
# BufferedReader
# ============================================================

type
  BufferedReader* = ref object
    stream*: AsyncStream
    buf: string
    pos: int       ## Current read position in buf
    cap: int       ## Valid data end in buf
    bufSize: int   ## Chunk size for reads
    eof: bool

proc newBufferedReader*(stream: AsyncStream, bufSize: int = 8192): BufferedReader =
  BufferedReader(
    stream: stream,
    buf: newString(bufSize),
    pos: 0,
    cap: 0,
    bufSize: bufSize,
    eof: false
  )

proc available(br: BufferedReader): int {.inline.} =
  br.cap - br.pos

proc atEof*(br: BufferedReader): bool {.inline.} =
  ## Returns true if the underlying stream has reached EOF and no buffered data remains.
  br.eof and br.available == 0

proc extract(br: BufferedReader, count: int): string {.inline.} =
  ## Extract `count` bytes from the buffer at the current position and advance.
  result = newString(count)
  if count > 0:
    copyMem(addr result[0], addr br.buf[br.pos], count)
  br.pos += count

proc extractRemaining(br: BufferedReader): string {.inline.} =
  ## Extract all remaining buffered data.
  let avail = br.available
  if avail > 0:
    result = newString(avail)
    copyMem(addr result[0], addr br.buf[br.pos], avail)
    br.pos = br.cap
  else:
    result = ""

proc drainBuffer*(br: BufferedReader): string =
  ## Return any unconsumed buffered data and reset the buffer.
  ## Useful when switching from buffered header reading to raw stream processing.
  br.extractRemaining()

proc compact(br: BufferedReader) {.inline.} =
  ## Shift unread data to the front of the buffer.
  if br.pos > 0:
    let avail = br.available
    if avail > 0:
      moveMem(addr br.buf[0], addr br.buf[br.pos], avail)
    br.pos = 0
    br.cap = avail

var gFillTrueFut {.global.}: CpsFuture[bool]
var gFillFalseFut {.global.}: CpsFuture[bool]

proc completedBoolTrue(): CpsFuture[bool] {.inline.} =
  if gFillTrueFut.isNil:
    gFillTrueFut = completedFuture(true)
  gFillTrueFut

proc completedBoolFalse(): CpsFuture[bool] {.inline.} =
  if gFillFalseFut.isNil:
    gFillFalseFut = completedFuture(false)
  gFillFalseFut

proc ensureSpace(br: BufferedReader) {.inline.} =
  ## Ensure buffer has room for at least bufSize bytes after cap.
  if br.buf.len - br.cap < br.bufSize:
    br.buf.setLen(br.cap + br.bufSize)

template fillAndRetry(fillFut: CpsFuture[bool], fut, retryCall: untyped) =
  ## Common pattern: chain on a fillBuffer future — sync fast path or async callback.
  if fillFut.finished():
    if fillFut.hasError():
      fut.fail(fillFut.getError())
    else:
      retryCall
  else:
    fillFut.addCallback(proc() =
      if fillFut.hasError():
        fut.fail(fillFut.getError())
      else:
        retryCall
    )

proc fillBuffer*(br: BufferedReader): CpsFuture[bool] =
  ## Read a chunk from the underlying stream into the buffer.
  ## Returns true if data was read, false on EOF.
  if br.eof:
    return completedBoolFalse()

  br.compact()

  # Zero-copy fast path: read directly into buffer via readInto vtable.
  if br.stream.readIntoProc != nil:
    br.ensureSpace()
    let n = br.stream.readIntoProc(br.stream, addr br.buf[br.cap], br.bufSize)
    if n > 0:
      br.cap += n
      return completedBoolTrue()
    elif n == 0:
      br.eof = true
      return completedBoolFalse()
    elif n == -1:
      # EAGAIN: wait for readability, then retry
      if br.stream.waitReadableProc != nil:
        let waitFut = br.stream.waitReadableProc(br.stream)
        let fut = newCpsFuture[bool]()
        let brLocal = br
        waitFut.addCallback(proc() =
          if waitFut.hasError():
            fut.fail(waitFut.getError())
          else:
            brLocal.ensureSpace()
            let n2 = brLocal.stream.readIntoProc(brLocal.stream,
              addr brLocal.buf[brLocal.cap], brLocal.bufSize)
            if n2 > 0:
              brLocal.cap += n2
              fut.complete(true)
            elif n2 == 0:
              brLocal.eof = true
              fut.complete(false)
            elif n2 == -1:
              fut.complete(false)
            else:
              fut.fail(newException(streams.AsyncIoError, "Read failed"))
        )
        return fut
      # No waitReadable — fall through to allocating read() path
    else:
      return failedFuture[bool](newException(streams.AsyncIoError, "Read failed"))

  # Allocating fallback: use stream.read() (creates temp string + CpsFuture)
  let streamFut = br.stream.read(br.bufSize)

  proc copyInto(br: BufferedReader, data: string) {.inline.} =
    let needed = br.cap + data.len
    if needed > br.buf.len:
      br.buf.setLen(needed)
    copyMem(addr br.buf[br.cap], unsafeAddr data[0], data.len)
    br.cap += data.len

  if streamFut.finished():
    if streamFut.hasError():
      return failedFuture[bool](streamFut.getError())
    let data = streamFut.read()
    if data.len == 0:
      br.eof = true
      return completedBoolFalse()
    br.copyInto(data)
    return completedBoolTrue()

  let fut = newCpsFuture[bool]()
  streamFut.addCallback(proc() =
    if streamFut.hasError():
      fut.fail(streamFut.getError())
    else:
      let data = streamFut.read()
      if data.len == 0:
        br.eof = true
        fut.complete(false)
      else:
        br.copyInto(data)
        fut.complete(true)
  )
  result = fut

proc readLine*(br: BufferedReader, delimiter: string = "\r\n",
               maxLen: int = 65536): CpsFuture[string] =
  ## Read until `delimiter` is found. Returns the line without the delimiter.
  ## Returns "" on EOF (with no data remaining).

  proc findDelimiter(br: BufferedReader, delimiter: string): int {.inline.} =
    ## Returns the buffer index where delimiter starts, or -1.
    let avail = br.available
    if avail <= 0 or delimiter.len <= 0: return -1
    let searchEnd = br.pos + avail - delimiter.len
    for i in br.pos .. searchEnd:
      var found = true
      for j in 0 ..< delimiter.len:
        if br.buf[i + j] != delimiter[j]:
          found = false
          break
      if found: return i
    return -1

  # Fast path: delimiter already in buffer
  let idx = br.findDelimiter(delimiter)
  if idx >= 0:
    let lineLen = idx - br.pos
    let line = br.extract(lineLen)
    br.pos += delimiter.len  # skip delimiter
    return completedFuture(line)

  let avail = br.available
  if avail >= maxLen:
    return completedFuture(br.extract(avail))
  if br.eof:
    return completedFuture(br.extractRemaining())

  # Need more data — allocate future and retry loop
  let fut = newCpsFuture[string]()

  proc tryReadLine() =
    let idx = br.findDelimiter(delimiter)
    if idx >= 0:
      let lineLen = idx - br.pos
      let line = br.extract(lineLen)
      br.pos += delimiter.len
      fut.complete(line)
      return

    let avail = br.available
    if avail >= maxLen:
      fut.complete(br.extract(avail))
      return
    if br.eof:
      fut.complete(br.extractRemaining())
      return

    let fillFut = br.fillBuffer()
    fillAndRetry(fillFut, fut, tryReadLine())

  let fillFut = br.fillBuffer()
  fillAndRetry(fillFut, fut, tryReadLine())
  result = fut

proc searchHeaderEnd*(br: BufferedReader): int {.inline.} =
  ## Search for \r\n\r\n in buffered data. Returns the index of the first \r,
  ## or -1 if not found.
  let avail = br.available
  if avail < 4: return -1
  let last = br.pos + avail - 4
  var i = br.pos
  while i <= last:
    if br.buf[i] == '\r':
      if br.buf[i+1] == '\n' and br.buf[i+2] == '\r' and br.buf[i+3] == '\n':
        return i
    i += 1
  return -1

proc extractHeaderBlock*(br: BufferedReader, endIdx: int): string {.inline.} =
  ## Extract header block from buffer up to endIdx, advance past \r\n\r\n.
  let blockLen = endIdx - br.pos
  result = br.extract(blockLen)
  br.pos += 4  # skip \r\n\r\n (extract already advanced by blockLen)

proc readUntilHeaderEnd*(br: BufferedReader,
                         maxLen: int = 65536): CpsFuture[string] =
  ## Read until \r\n\r\n is found. Returns the complete header block WITHOUT
  ## the trailing \r\n\r\n delimiter. On EOF, returns "" (empty headers).

  # Ultra-fast path: headers already in buffer
  var idx = br.searchHeaderEnd()
  if idx >= 0:
    return completedFuture(br.extractHeaderBlock(idx))

  if br.eof:
    return completedFuture(br.extractRemaining())

  # Shared retry closure for both sync-fill and async-fill paths
  let fut = newCpsFuture[string]()

  proc tryRead() =
    let foundIdx = br.searchHeaderEnd()
    if foundIdx >= 0:
      fut.complete(br.extractHeaderBlock(foundIdx))
      return
    if br.available >= maxLen:
      fut.complete(br.extractRemaining())
      return
    if br.eof:
      fut.complete(br.extractRemaining())
      return
    let fillFut = br.fillBuffer()
    fillAndRetry(fillFut, fut, tryRead())

  # Try one sync fill first (common for keep-alive)
  let fillFut = br.fillBuffer()
  if fillFut.finished():
    if fillFut.hasError():
      fut.fail(fillFut.getError())
    else:
      idx = br.searchHeaderEnd()
      if idx >= 0:
        # Don't use fut — return pre-completed directly
        return completedFuture(br.extractHeaderBlock(idx))
      if br.eof:
        return completedFuture(br.extractRemaining())
      # Still need more data, fall through to tryRead loop
      let fillFut2 = br.fillBuffer()
      fillAndRetry(fillFut2, fut, tryRead())
  else:
    fillFut.addCallback(proc() =
      if fillFut.hasError():
        fut.fail(fillFut.getError())
      else:
        tryRead()
    )
  result = fut

proc readExact*(br: BufferedReader, size: int): CpsFuture[string] =
  ## Read exactly `size` bytes. Fails with ConnectionClosedError on short read.

  # Fast path: already buffered
  if br.available >= size:
    return completedFuture(br.extract(size))

  let fut = newCpsFuture[string]()

  proc tryRead() =
    if br.available >= size:
      fut.complete(br.extract(size))
      return
    if br.eof:
      fut.fail(newException(ConnectionClosedError,
        "Connection closed before receiving all data (got " & $br.available & " of " & $size & " bytes)"))
      return
    let fillFut = br.fillBuffer()
    fillAndRetry(fillFut, fut, tryRead())

  let fillFut = br.fillBuffer()
  fillAndRetry(fillFut, fut, tryRead())
  result = fut

proc read*(br: BufferedReader, size: int): CpsFuture[string] =
  ## Read up to `size` bytes. Returns "" on EOF.

  # Fast path: data already buffered
  if br.available > 0:
    return completedFuture(br.extract(min(size, br.available)))
  if br.eof:
    return completedFuture("")

  let fut = newCpsFuture[string]()

  proc tryRead() =
    if br.available > 0:
      fut.complete(br.extract(min(size, br.available)))
      return
    if br.eof:
      fut.complete("")
      return
    let fillFut = br.fillBuffer()
    fillAndRetry(fillFut, fut, tryRead())

  let fillFut = br.fillBuffer()
  fillAndRetry(fillFut, fut, tryRead())
  result = fut

# ============================================================
# BufferedWriter
# ============================================================

type
  BufferedWriter* = ref object
    stream*: AsyncStream
    buf: string
    bufSize: int

proc newBufferedWriter*(stream: AsyncStream, bufSize: int = 8192): BufferedWriter =
  BufferedWriter(
    stream: stream,
    buf: "",
    bufSize: bufSize
  )

proc flush*(bw: BufferedWriter): CpsVoidFuture =
  ## Flush the internal buffer to the underlying stream.
  if bw.buf.len == 0:
    return completedVoidFuture()
  let data = move bw.buf
  bw.buf = newStringOfCap(bw.bufSize)
  bw.stream.write(data)

proc write*(bw: BufferedWriter, data: string): CpsVoidFuture =
  ## Write data to the buffer. Auto-flushes when buffer exceeds bufSize.
  bw.buf.add(data)
  if bw.buf.len >= bw.bufSize:
    return bw.flush()
  return completedVoidFuture()

proc writeLine*(bw: BufferedWriter, line: string,
                delimiter: string = "\r\n"): CpsVoidFuture =
  ## Write a line followed by delimiter, then flush.
  bw.buf.add(line)
  bw.buf.add(delimiter)
  return bw.flush()

proc close*(bw: BufferedWriter): CpsVoidFuture =
  ## Flush remaining data and close the underlying stream.
  let flushFut = bw.flush()
  if flushFut.finished():
    if flushFut.hasError():
      return failedVoidFuture(flushFut.getError())
    bw.stream.close()
    return completedVoidFuture()
  let fut = newCpsVoidFuture()
  flushFut.addCallback(proc() =
    if flushFut.hasError():
      fut.fail(flushFut.getError())
    else:
      bw.stream.close()
      fut.complete()
  )
  result = fut
