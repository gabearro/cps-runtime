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

proc bufferPtr*(br: BufferedReader): ptr string {.inline.} =
  ## Direct access to the internal buffer (for zero-copy parsing).
  addr br.buf

proc bufferPos*(br: BufferedReader): int {.inline.} =
  ## Current read position in the buffer.
  br.pos

proc bufferCap*(br: BufferedReader): int {.inline.} =
  ## End of valid data in the buffer.
  br.cap

proc advancePos*(br: BufferedReader, n: int) {.inline.} =
  ## Advance the read position by n bytes (after parsing from buffer directly).
  br.pos += n

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

proc fillBuffer*(br: BufferedReader): CpsFuture[bool] =
  ## Read a chunk from the underlying stream into the buffer.
  ## Returns true if data was read, false on EOF.
  if br.eof:
    return completedBoolFalse()

  br.compact()

  # Zero-copy fast path: read directly into buffer via readInto vtable.
  # Avoids: newString(size), completedFuture(buf), copyMem from temp string.
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
              # Still EAGAIN after select — shouldn't happen, treat as temporary
              fut.complete(false)
            else:
              fut.fail(newException(streams.AsyncIoError, "Read failed"))
        )
        return fut
      # No waitReadable — fall through to allocating read() path
    else:
      let fut = newCpsFuture[bool]()
      fut.fail(newException(streams.AsyncIoError, "Read failed"))
      return fut

  # Allocating fallback: use stream.read() (creates temp string + CpsFuture)
  let readSize = br.bufSize
  let streamFut = br.stream.read(readSize)

  if streamFut.finished():
    if streamFut.hasError():
      let fut = newCpsFuture[bool]()
      fut.fail(streamFut.getError())
      return fut
    let data = streamFut.read()
    if data.len == 0:
      br.eof = true
      return completedBoolFalse()
    let needed = br.cap + data.len
    if needed > br.buf.len:
      br.buf.setLen(needed)
    copyMem(addr br.buf[br.cap], unsafeAddr data[0], data.len)
    br.cap += data.len
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
    if fillFut.finished():
      if fillFut.hasError():
        fut.fail(fillFut.getError())
      else:
        tryReadLine()
    else:
      fillFut.addCallback(proc() =
        if fillFut.hasError():
          fut.fail(fillFut.getError())
        else:
          tryReadLine()
      )

  tryReadLine()
  result = fut

proc searchHeaderEnd*(br: BufferedReader): int {.inline.} =
  ## Search for \r\n\r\n in buffered data. Returns the index of the first \r,
  ## or -1 if not found.
  let avail = br.available
  if avail < 4: return -1
  let searchEnd = br.pos + avail - 3
  for i in br.pos ..< searchEnd:
    if br.buf[i] == '\r' and br.buf[i+1] == '\n' and
       br.buf[i+2] == '\r' and br.buf[i+3] == '\n':
      return i
  return -1

proc extractHeaderBlock*(br: BufferedReader, endIdx: int): string {.inline.} =
  ## Extract header block from buffer up to endIdx, advance past \r\n\r\n.
  let blockLen = endIdx - br.pos
  result = newString(blockLen)
  if blockLen > 0:
    copyMem(addr result[0], addr br.buf[br.pos], blockLen)
  br.pos = endIdx + 4

proc readUntilHeaderEnd*(br: BufferedReader,
                         maxLen: int = 65536): CpsFuture[string] =
  ## Read until \r\n\r\n is found. Returns the complete header block WITHOUT
  ## the trailing \r\n\r\n delimiter. On EOF, returns "" (empty headers).
  ## This is a fast path for HTTP/1.1 header parsing — a single read gets
  ## the entire header block, avoiding multiple readLine calls and futures.

  # Ultra-fast path: headers already in buffer (no future/closure allocation)
  var idx = br.searchHeaderEnd()
  if idx >= 0:
    return completedFuture(br.extractHeaderBlock(idx))

  # Try one sync fill, then check again (common for keep-alive)
  if not br.eof and br.available < maxLen:
    let fillFut = br.fillBuffer()
    if fillFut.finished():
      if not fillFut.hasError():
        idx = br.searchHeaderEnd()
        if idx >= 0:
          return completedFuture(br.extractHeaderBlock(idx))
        # EOF after fill?
        if br.eof:
          let avail = br.available
          if avail > 0:
            var hdrBlock = newString(avail)
            copyMem(addr hdrBlock[0], addr br.buf[br.pos], avail)
            br.pos = br.cap
            return completedFuture(hdrBlock)
          else:
            return completedFuture("")
        # Not enough data yet, fall through to slow path
      else:
        let fut = newCpsFuture[string]()
        fut.fail(fillFut.getError())
        return fut
    else:
      # fillBuffer is pending (EAGAIN) — set up callback chain, do NOT call tryRead
      let fut = newCpsFuture[string]()

      proc tryRead() =
        let foundIdx = br.searchHeaderEnd()
        if foundIdx >= 0:
          fut.complete(br.extractHeaderBlock(foundIdx))
          return
        let avail = br.available
        if avail >= maxLen:
          var hdrBlock = newString(avail)
          copyMem(addr hdrBlock[0], addr br.buf[br.pos], avail)
          br.pos = br.cap
          fut.complete(hdrBlock)
          return
        if br.eof:
          if avail > 0:
            var hdrBlock = newString(avail)
            copyMem(addr hdrBlock[0], addr br.buf[br.pos], avail)
            br.pos = br.cap
            fut.complete(hdrBlock)
          else:
            fut.complete("")
          return
        let innerFillFut = br.fillBuffer()
        if innerFillFut.finished():
          if innerFillFut.hasError():
            fut.fail(innerFillFut.getError())
          else:
            tryRead()
        else:
          innerFillFut.addCallback(proc() =
            if innerFillFut.hasError():
              fut.fail(innerFillFut.getError())
            else:
              tryRead()
          )

      fillFut.addCallback(proc() =
        if fillFut.hasError():
          fut.fail(fillFut.getError())
        else:
          tryRead()
      )
      return fut

  # Slow path: need async I/O — allocate future and closure
  let fut = newCpsFuture[string]()

  proc tryRead() =
    let foundIdx = br.searchHeaderEnd()
    if foundIdx >= 0:
      fut.complete(br.extractHeaderBlock(foundIdx))
      return

    let avail = br.available
    if avail >= maxLen:
      var hdrBlock = newString(avail)
      copyMem(addr hdrBlock[0], addr br.buf[br.pos], avail)
      br.pos = br.cap
      fut.complete(hdrBlock)
      return

    if br.eof:
      if avail > 0:
        var hdrBlock = newString(avail)
        copyMem(addr hdrBlock[0], addr br.buf[br.pos], avail)
        br.pos = br.cap
        fut.complete(hdrBlock)
      else:
        fut.complete("")
      return

    let fillFut = br.fillBuffer()
    if fillFut.finished():
      if fillFut.hasError():
        fut.fail(fillFut.getError())
      else:
        tryRead()
    else:
      fillFut.addCallback(proc() =
        if fillFut.hasError():
          fut.fail(fillFut.getError())
        else:
          tryRead()
      )

  tryRead()
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
    if fillFut.finished():
      if fillFut.hasError():
        fut.fail(fillFut.getError())
      else:
        tryRead()
    else:
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
    if fillFut.finished():
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
    else:
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
