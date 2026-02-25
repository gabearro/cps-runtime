## HTTP/2 Stream Adapter
##
## An AsyncStream subtype that maps reads/writes to HTTP/2 DATA frames
## on a single stream. This allows SSE and WebSocket handlers to work
## transparently over HTTP/2 — the same handler code works for both
## HTTP/1.1 and HTTP/2.
##
## Write: data → connection-scoped HTTP/2 writer callback
## Read: internal buffer fed by processServerFrame via feedData()

import ../../runtime
import ../../transform
import ../../io/streams

type
  AdapterSendHeadersProc* = proc(streamId: uint32, statusCode: int,
                                 headers: seq[(string, string)]): CpsVoidFuture {.closure.}
  AdapterSendDataProc* = proc(streamId: uint32, data: string): CpsVoidFuture {.closure.}
  AdapterCloseWriteProc* = proc(streamId: uint32): CpsVoidFuture {.closure.}

type
  AdapterWaiter = object
    size: int
    future: CpsFuture[string]

  Http2StreamAdapter* = ref object of AsyncStream
    streamId*: uint32
    sendHeadersProc*: AdapterSendHeadersProc
    sendDataProc*: AdapterSendDataProc
    closeWriteProc*: AdapterCloseWriteProc
    responseHeadersSent*: bool
    responseHeadersFuture: CpsVoidFuture
    readBuffer: string
    readWaiters: seq[AdapterWaiter]
    eofSignaled: bool

proc tryWakeWaiters(a: Http2StreamAdapter) =
  var i = 0
  while i < a.readWaiters.len:
    if a.eofSignaled and a.readBuffer.len == 0:
      let fut = a.readWaiters[i].future
      a.readWaiters.delete(i)
      fut.complete("")
    elif a.readBuffer.len > 0:
      let waiter = a.readWaiters[i]
      let toRead = min(waiter.size, a.readBuffer.len)
      let data = a.readBuffer[0 ..< toRead]
      a.readBuffer = a.readBuffer[toRead .. ^1]
      a.readWaiters.delete(i)
      waiter.future.complete(data)
    else:
      inc i

proc feedData*(a: Http2StreamAdapter, data: string) =
  ## Called by processServerFrame when a DATA frame arrives for this stream.
  a.readBuffer.add(data)
  a.tryWakeWaiters()

proc feedEof*(a: Http2StreamAdapter) =
  ## Called when END_STREAM or RST_STREAM is received.
  a.eofSignaled = true
  a.tryWakeWaiters()

proc adapterRead(s: AsyncStream, size: int): CpsFuture[string] =
  let a = Http2StreamAdapter(s)
  let fut = newCpsFuture[string]()
  if a.readBuffer.len > 0:
    let toRead = min(size, a.readBuffer.len)
    let data = a.readBuffer[0 ..< toRead]
    a.readBuffer = a.readBuffer[toRead .. ^1]
    fut.complete(data)
  elif a.eofSignaled:
    fut.complete("")
  else:
    a.readWaiters.add(AdapterWaiter(size: size, future: fut))
  result = fut

proc ensureAutoResponseHeaders(a: Http2StreamAdapter): CpsVoidFuture {.cps.} =
  if a.responseHeadersSent:
    return
  if a.sendHeadersProc == nil:
    raise newException(system.IOError, "HTTP/2 adapter has no sendHeaders callback")

  if a.responseHeadersFuture.isNil:
    a.responseHeadersFuture = a.sendHeadersProc(a.streamId, 200, @[])

  await a.responseHeadersFuture
  a.responseHeadersSent = true

proc adapterWrite(s: AsyncStream, data: string): CpsVoidFuture {.cps.} =
  ## Write stream data through the connection writer callback.
  let a = Http2StreamAdapter(s)
  if a.sendDataProc == nil:
    raise newException(system.IOError, "HTTP/2 adapter has no sendData callback")
  if not a.responseHeadersSent:
    await a.ensureAutoResponseHeaders()
  await a.sendDataProc(a.streamId, data)

proc adapterClose(s: AsyncStream) =
  let a = Http2StreamAdapter(s)
  a.eofSignaled = true
  if a.closeWriteProc != nil:
    discard a.closeWriteProc(a.streamId)
  a.tryWakeWaiters()

proc newHttp2StreamAdapter*(streamId: uint32,
                            sendHeadersProc: AdapterSendHeadersProc,
                            sendDataProc: AdapterSendDataProc,
                            closeWriteProc: AdapterCloseWriteProc = nil): Http2StreamAdapter =
  result = Http2StreamAdapter(
    streamId: streamId,
    sendHeadersProc: sendHeadersProc,
    sendDataProc: sendDataProc,
    closeWriteProc: closeWriteProc,
    responseHeadersSent: false,
    responseHeadersFuture: nil,
    readBuffer: "",
    readWaiters: @[],
    eofSignaled: false
  )
  result.readProc = adapterRead
  result.writeProc = adapterWrite
  result.closeProc = adapterClose

proc sendResponseHeaders*(a: Http2StreamAdapter, statusCode: int,
                           headers: seq[(string, string)] = @[]): CpsVoidFuture {.cps.} =
  ## Send response HEADERS through the connection writer callback.
  if a.sendHeadersProc == nil:
    raise newException(system.IOError, "HTTP/2 adapter has no sendHeaders callback")
  if a.responseHeadersSent:
    raise newException(system.IOError, "HTTP/2 response headers already sent")
  if not a.responseHeadersFuture.isNil:
    await a.responseHeadersFuture
    a.responseHeadersSent = true
    raise newException(system.IOError, "HTTP/2 response headers already sent")
  a.responseHeadersFuture = a.sendHeadersProc(a.streamId, statusCode, headers)
  await a.responseHeadersFuture
  a.responseHeadersSent = true

proc hasSentResponseHeaders*(a: Http2StreamAdapter): bool {.inline.} =
  if a.isNil:
    return false
  a.responseHeadersSent
