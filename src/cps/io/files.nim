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
  if size == 0:
    return completedFuture("")
  let fs = FileStream(s)
  let fut = newCpsFuture[string]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
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
  if data.len == 0:
    return completedVoidFuture()
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

  let fileSize = getFileSize(f)
  var resultData = newStringOfCap(if fileSize > 0: fileSize.int else: FileChunkSize)
  let loop = getEventLoop()

  proc readChunk() =
    let offset = resultData.len
    resultData.setLen(offset + FileChunkSize)
    let bytesRead = readBuffer(f, addr resultData[offset], FileChunkSize)
    if bytesRead < 0:
      resultData.setLen(offset)
      f.close()
      fut.fail(newException(streams.AsyncIoError, "File read failed"))
    elif bytesRead == 0:
      resultData.setLen(offset)
      f.close()
      fut.complete(resultData)
    else:
      resultData.setLen(offset + bytesRead)
      loop.scheduleCallback(readChunk)

  loop.scheduleCallback(readChunk)
  result = fut

proc asyncWriteToFile(path: string, data: string, mode: FileMode): CpsVoidFuture =
  ## Write data to a file in chunks, yielding to event loop between chunks.
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()

  var f: File
  if not open(f, path, mode):
    fut.fail(newException(streams.AsyncIoError, "Failed to open file: " & path))
    return fut

  if data.len == 0:
    f.close()
    fut.complete()
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
      loop.scheduleCallback(writeChunk)

  loop.scheduleCallback(writeChunk)
  result = fut

proc asyncWriteFile*(path: string, data: string): CpsVoidFuture =
  ## Write data to a file, yielding to event loop between chunks.
  asyncWriteToFile(path, data, fmWrite)

proc asyncAppendFile*(path: string, data: string): CpsVoidFuture =
  ## Append data to a file, yielding to event loop between chunks.
  asyncWriteToFile(path, data, fmAppend)
