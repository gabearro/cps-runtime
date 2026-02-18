## HTTP/2 Stream Adapter
##
## An AsyncStream subtype that maps reads/writes to HTTP/2 DATA frames
## on a single stream. This allows SSE and WebSocket handlers to work
## transparently over HTTP/2 — the same handler code works for both
## HTTP/1.1 and HTTP/2.
##
## Write: data → serialized DATA frame → conn.stream.write()
## Read: internal buffer fed by processServerFrame via feedData()

import std/strutils
import ../../runtime
import ../../io/streams
import ./hpack
import ./http2

type
  AdapterWaiter = object
    size: int
    future: CpsFuture[string]

  Http2StreamAdapter* = ref object of AsyncStream
    connStream*: AsyncStream       ## The underlying TCP/TLS stream
    encoder*: ptr HpackEncoder     ## Pointer to connection's HPACK encoder
    streamId*: uint32
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

proc adapterWrite(s: AsyncStream, data: string): CpsVoidFuture =
  ## Wrap data in an HTTP/2 DATA frame and write to the connection stream.
  let a = Http2StreamAdapter(s)
  var payload = newSeq[byte](data.len)
  for i in 0 ..< data.len:
    payload[i] = byte(data[i])
  let frame = Http2Frame(
    frameType: FrameData,
    flags: 0,
    streamId: a.streamId,
    payload: payload
  )
  let serialized = serializeFrame(frame)
  var str = newString(serialized.len)
  for i, b in serialized:
    str[i] = char(b)
  a.connStream.write(str)

proc adapterClose(s: AsyncStream) =
  let a = Http2StreamAdapter(s)
  a.eofSignaled = true
  a.tryWakeWaiters()

proc newHttp2StreamAdapter*(connStream: AsyncStream, encoder: ptr HpackEncoder,
                             streamId: uint32): Http2StreamAdapter =
  result = Http2StreamAdapter(
    connStream: connStream,
    encoder: encoder,
    streamId: streamId,
    readBuffer: "",
    readWaiters: @[],
    eofSignaled: false
  )
  result.readProc = adapterRead
  result.writeProc = adapterWrite
  result.closeProc = adapterClose

proc sendResponseHeaders*(a: Http2StreamAdapter, statusCode: int,
                           headers: seq[(string, string)] = @[]): CpsVoidFuture =
  ## Send HTTP/2 HEADERS frame with the given status and headers.
  ## Does NOT set END_STREAM — the stream stays open for data.
  var allHeaders: seq[(string, string)] = @[
    (":status", $statusCode)
  ]
  for i in 0 ..< headers.len:
    allHeaders.add (headers[i][0].toLowerAscii, headers[i][1])
  let encoded = a.encoder[].encode(allHeaders)
  let frame = Http2Frame(
    frameType: FrameHeaders,
    flags: FlagEndHeaders,
    streamId: a.streamId,
    payload: encoded
  )
  let serialized = serializeFrame(frame)
  var str = newString(serialized.len)
  for i, b in serialized:
    str[i] = char(b)
  a.connStream.write(str)
