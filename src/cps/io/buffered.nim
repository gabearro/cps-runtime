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

proc drainBuffer*(br: BufferedReader): string =
  ## Return any unconsumed buffered data and reset the buffer.
  ## Useful when switching from buffered header reading to raw stream processing.
  let avail = br.available
  if avail > 0:
    result = newString(avail)
    copyMem(addr result[0], addr br.buf[br.pos], avail)
    br.pos = br.cap
  else:
    result = ""

proc compact(br: BufferedReader) =
  ## Shift unread data to the front of the buffer.
  if br.pos > 0:
    let avail = br.available
    if avail > 0:
      moveMem(addr br.buf[0], addr br.buf[br.pos], avail)
    br.pos = 0
    br.cap = avail

proc fillBuffer(br: BufferedReader): CpsFuture[bool] =
  ## Read a chunk from the underlying stream into the buffer.
  ## Returns true if data was read, false on EOF.
  let fut = newCpsFuture[bool]()
  if br.eof:
    fut.complete(false)
    return fut

  br.compact()

  let readSize = br.bufSize
  let streamFut = br.stream.read(readSize)

  streamFut.addCallback(proc() =
    if streamFut.hasError():
      fut.fail(streamFut.getError())
    else:
      let data = streamFut.read()
      if data.len == 0:
        br.eof = true
        fut.complete(false)
      else:
        # Grow buffer if needed
        let needed = br.cap + data.len
        if needed > br.buf.len:
          br.buf.setLen(needed)
        copyMem(addr br.buf[br.cap], unsafeAddr data[0], data.len)
        br.cap += data.len
        fut.complete(true)
  )
  result = fut

proc readLine*(br: BufferedReader, delimiter: string = "\r\n",
               maxLen: int = 65536): CpsFuture[string] =
  ## Read until `delimiter` is found. Returns the line without the delimiter.
  ## Returns "" on EOF (with no data remaining).
  let fut = newCpsFuture[string]()

  proc tryReadLine() =
    # Search for delimiter in buffered data
    let avail = br.available
    if avail > 0 and delimiter.len > 0:
      let searchEnd = br.pos + avail - delimiter.len
      for i in br.pos .. searchEnd:
        var found = true
        for j in 0 ..< delimiter.len:
          if br.buf[i + j] != delimiter[j]:
            found = false
            break
        if found:
          let lineLen = i - br.pos
          var line = newString(lineLen)
          if lineLen > 0:
            copyMem(addr line[0], addr br.buf[br.pos], lineLen)
          br.pos = i + delimiter.len
          fut.complete(line)
          return

    if avail >= maxLen:
      # Max length reached without delimiter — return what we have
      var line = newString(avail)
      copyMem(addr line[0], addr br.buf[br.pos], avail)
      br.pos = br.cap
      fut.complete(line)
      return

    if br.eof:
      # EOF — return whatever is left
      if avail > 0:
        var line = newString(avail)
        copyMem(addr line[0], addr br.buf[br.pos], avail)
        br.pos = br.cap
        fut.complete(line)
      else:
        fut.complete("")
      return

    # Need more data
    let fillFut = br.fillBuffer()
    fillFut.addCallback(proc() =
      if fillFut.hasError():
        fut.fail(fillFut.getError())
      else:
        tryReadLine()
    )

  tryReadLine()
  result = fut

proc readExact*(br: BufferedReader, size: int): CpsFuture[string] =
  ## Read exactly `size` bytes. Fails with ConnectionClosedError on short read.
  let fut = newCpsFuture[string]()

  proc tryRead() =
    if br.available >= size:
      var data = newString(size)
      copyMem(addr data[0], addr br.buf[br.pos], size)
      br.pos += size
      fut.complete(data)
      return

    if br.eof:
      fut.fail(newException(ConnectionClosedError,
        "Connection closed before receiving all data (got " & $br.available & " of " & $size & " bytes)"))
      return

    let fillFut = br.fillBuffer()
    fillFut.addCallback(proc() =
      if fillFut.hasError():
        fut.fail(fillFut.getError())
      else:
        tryRead()
    )

  tryRead()
  result = fut

proc read*(br: BufferedReader, size: int): CpsFuture[string] =
  ## Read up to `size` bytes. Returns "" on EOF.
  let fut = newCpsFuture[string]()

  proc tryRead() =
    if br.available > 0:
      let toRead = min(size, br.available)
      var data = newString(toRead)
      copyMem(addr data[0], addr br.buf[br.pos], toRead)
      br.pos += toRead
      fut.complete(data)
      return

    if br.eof:
      fut.complete("")
      return

    let fillFut = br.fillBuffer()
    fillFut.addCallback(proc() =
      if fillFut.hasError():
        fut.fail(fillFut.getError())
      else:
        if br.available > 0:
          let toRead = min(size, br.available)
          var data = newString(toRead)
          copyMem(addr data[0], addr br.buf[br.pos], toRead)
          br.pos += toRead
          fut.complete(data)
        else:
          fut.complete("")  # EOF
    )

  tryRead()
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
    let fut = newCpsVoidFuture()
    fut.complete()
    return fut
  let data = bw.buf
  bw.buf = ""
  bw.stream.write(data)

proc write*(bw: BufferedWriter, data: string): CpsVoidFuture =
  ## Write data to the buffer. Auto-flushes when buffer exceeds bufSize.
  bw.buf.add(data)
  if bw.buf.len >= bw.bufSize:
    return bw.flush()
  else:
    let fut = newCpsVoidFuture()
    fut.complete()
    return fut

proc writeLine*(bw: BufferedWriter, line: string,
                delimiter: string = "\r\n"): CpsVoidFuture =
  ## Write a line followed by delimiter, then flush.
  bw.buf.add(line)
  bw.buf.add(delimiter)
  bw.flush()

proc close*(bw: BufferedWriter): CpsVoidFuture =
  ## Flush remaining data and close the underlying stream.
  let fut = newCpsVoidFuture()
  let flushFut = bw.flush()
  flushFut.addCallback(proc() =
    if flushFut.hasError():
      fut.fail(flushFut.getError())
    else:
      bw.stream.close()
      fut.complete()
  )
  result = fut
