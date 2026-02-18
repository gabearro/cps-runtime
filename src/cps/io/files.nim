## CPS I/O Files
##
## Provides async-friendly file I/O. Since Unix selectors cannot async-wait
## on regular files, this uses synchronous reads/writes with scheduleCallback
## to yield to the event loop between chunks.

import ../runtime
import ../eventloop
import ./streams

const FileChunkSize = 32768  # 32KB chunks

# ============================================================
# FileStream - file wrapped as AsyncStream
# ============================================================

type
  FileStream* = ref object of AsyncStream
    file: File
    path: string

proc fileStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let fs = FileStream(s)
  let fut = newCpsFuture[string]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  # Schedule the synchronous read to yield to event loop first
  loop.scheduleCallback(proc() =
    if fs.file.isNil:
      fut.fail(newException(streams.AsyncIoError, "File is not open"))
      return
    var buf = newString(size)
    let bytesRead = readBuffer(fs.file, addr buf[0], size)
    if bytesRead < 0:
      fut.fail(newException(streams.AsyncIoError, "File read failed"))
    elif bytesRead == 0:
      fut.complete("")  # EOF
    else:
      buf.setLen(bytesRead)
      fut.complete(buf)
  )
  result = fut

proc fileStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let fs = FileStream(s)
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  loop.scheduleCallback(proc() =
    if fs.file.isNil:
      fut.fail(newException(streams.AsyncIoError, "File is not open"))
      return
    let written = writeBuffer(fs.file, unsafeAddr data[0], data.len)
    if written != data.len:
      fut.fail(newException(streams.AsyncIoError, "File write incomplete"))
    else:
      fut.complete()
  )
  result = fut

proc fileStreamClose(s: AsyncStream) =
  let fs = FileStream(s)
  if not fs.file.isNil:
    fs.file.close()
    fs.file = nil

proc newFileStream*(path: string, mode: FileMode = fmRead): FileStream =
  ## Open a file as an AsyncStream.
  var f: File
  if not open(f, path, mode):
    raise newException(streams.AsyncIoError, "Failed to open file: " & path)
  result = FileStream(
    file: f,
    path: path,
    closed: false
  )
  result.readProc = fileStreamRead
  result.writeProc = fileStreamWrite
  result.closeProc = fileStreamClose

# ============================================================
# Convenience procs
# ============================================================

proc asyncReadFile*(path: string): CpsFuture[string] =
  ## Read an entire file, yielding to event loop between chunks.
  let fut = newCpsFuture[string]()
  fut.pinFutureRuntime()

  var f: File
  if not open(f, path, fmRead):
    fut.fail(newException(streams.AsyncIoError, "Failed to open file: " & path))
    return fut

  var result_data = ""
  let loop = getEventLoop()

  proc readChunk() =
    var buf = newString(FileChunkSize)
    let bytesRead = readBuffer(f, addr buf[0], FileChunkSize)
    if bytesRead < 0:
      f.close()
      fut.fail(newException(streams.AsyncIoError, "File read failed"))
    elif bytesRead == 0:
      f.close()
      fut.complete(result_data)
    else:
      buf.setLen(bytesRead)
      result_data.add(buf)
      # Yield to event loop before next chunk
      loop.scheduleCallback(proc() =
        readChunk()
      )

  loop.scheduleCallback(proc() =
    readChunk()
  )
  result = fut

proc asyncWriteFile*(path: string, data: string): CpsVoidFuture =
  ## Write data to a file, yielding to event loop between chunks.
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()

  var f: File
  if not open(f, path, fmWrite):
    fut.fail(newException(streams.AsyncIoError, "Failed to open file: " & path))
    return fut

  var offset = 0
  let loop = getEventLoop()

  proc writeChunk() =
    let remaining = data.len - offset
    if remaining <= 0:
      f.close()
      fut.complete()
      return
    let chunkSize = min(remaining, FileChunkSize)
    let written = writeBuffer(f, unsafeAddr data[offset], chunkSize)
    if written != chunkSize:
      f.close()
      fut.fail(newException(streams.AsyncIoError, "File write incomplete"))
    else:
      offset += chunkSize
      loop.scheduleCallback(proc() =
        writeChunk()
      )

  loop.scheduleCallback(proc() =
    writeChunk()
  )
  result = fut
