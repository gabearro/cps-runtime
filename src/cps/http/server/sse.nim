## Server-Sent Events (SSE)
##
## Provides SSE streaming over HTTP/1.1 connections. The handler writes
## response headers directly via `initSse`, then streams events using
## `sendEvent` and `sendComment`. The handler returns `sseResponse()`
## (a sentinel with statusCode=0) so the HTTP/1.1 server knows the
## handler already wrote to the stream.
##
## Supports optional gzip streaming compression via zlib's Z_SYNC_FLUSH.
## Pass the HttpRequest to `initSse` to auto-detect Accept-Encoding.
##
## Usage:
##   proc handler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
##     let sse = await initSse(req.stream, req = req)
##     await sse.sendEvent("hello")
##     await sse.sendEvent("world", event="greeting")
##     return sseResponse()

import std/[strutils, atomics]
import ../../runtime
import ../../io/streams
import ./types
import ../shared/http2_stream_adapter
import ../shared/compression

type
  SseWriter* = ref object
    stream*: AsyncStream
    closed: Atomic[bool]
    compressor*: ZlibCompressor  ## nil if compression disabled

proc isClosed*(sse: SseWriter): bool =
  ## Check if the SSE writer has been closed. Thread-safe.
  sse.closed.load

proc sseResponse*(): HttpResponseBuilder =
  ## Sentinel control response. Tells handleHttp1Connection that
  ## the handler already wrote directly to the stream.
  handledResponse()

proc initSse*(stream: AsyncStream,
              extraHeaders: seq[(string, string)] = @[],
              req: HttpRequest = HttpRequest()): CpsFuture[SseWriter] =
  ## Write SSE response headers to the stream and return an SseWriter.
  ## If req is provided and client sends Accept-Encoding: gzip,
  ## enables streaming gzip compression with Z_SYNC_FLUSH per event.
  let fut = newCpsFuture[SseWriter]()

  # Check if client accepts gzip
  let aeHeader = req.getHeader("accept-encoding")
  let useCompression = "gzip" in aeHeader.toLowerAscii

  if stream of Http2StreamAdapter:
    # HTTP/2: send HEADERS frame with SSE headers (no END_STREAM)
    let adapter = Http2StreamAdapter(stream)
    var h2Headers: seq[(string, string)] = @[
      ("content-type", "text/event-stream"),
      ("cache-control", "no-cache")
    ]
    if useCompression:
      h2Headers.add ("content-encoding", "gzip")
    for (k, v) in extraHeaders:
      h2Headers.add (k.toLowerAscii, v)
    let writeFut = adapter.sendResponseHeaders(200, h2Headers)
    let capturedStream = stream
    let capturedUseComp = useCompression
    writeFut.addCallback(proc() =
      if writeFut.hasError():
        fut.fail(writeFut.getError())
      else:
        var comp: ZlibCompressor = nil
        if capturedUseComp:
          comp = newZlibCompressor(ceGzip)
        let writer = SseWriter(stream: capturedStream, compressor: comp)
        writer.closed.store(false)
        fut.complete(writer)
    )
  else:
    # HTTP/1.1: write raw response headers
    var headerStr = "HTTP/1.1 200 OK\r\n"
    headerStr &= "Content-Type: text/event-stream\r\n"
    headerStr &= "Cache-Control: no-cache\r\n"
    headerStr &= "Connection: keep-alive\r\n"
    if useCompression:
      headerStr &= "Content-Encoding: gzip\r\n"
    for (k, v) in extraHeaders:
      headerStr &= k & ": " & v & "\r\n"
    headerStr &= "\r\n"

    let writeFut = stream.write(headerStr)
    let capturedStream = stream
    let capturedUseComp = useCompression
    writeFut.addCallback(proc() =
      if writeFut.hasError():
        fut.fail(writeFut.getError())
      else:
        var comp: ZlibCompressor = nil
        if capturedUseComp:
          comp = newZlibCompressor(ceGzip)
        let writer = SseWriter(stream: capturedStream, compressor: comp)
        writer.closed.store(false)
        fut.complete(writer)
    )
  return fut

proc sendEvent*(writer: SseWriter, data: string, event: string = "",
                id: string = "", retry: int = -1): CpsVoidFuture =
  ## Format and send an SSE event. Multi-line data gets multiple `data:` prefixes.
  ## If compression is enabled, compresses with Z_SYNC_FLUSH for immediate delivery.
  var msg = ""
  if event.len > 0:
    msg &= "event: " & event & "\n"
  if id.len > 0:
    msg &= "id: " & id & "\n"
  if retry >= 0:
    msg &= "retry: " & $retry & "\n"
  let lines = data.split('\n')
  for line in lines:
    msg &= "data: " & line & "\n"
  msg &= "\n"

  if writer.compressor != nil:
    let compressed = writer.compressor.compressChunk(msg)
    return writer.stream.write(compressed)
  else:
    return writer.stream.write(msg)

proc sendComment*(writer: SseWriter, text: string): CpsVoidFuture =
  ## Send an SSE comment (`: text\n\n`). Returns the write future.
  let msg = ": " & text & "\n\n"
  if writer.compressor != nil:
    let compressed = writer.compressor.compressChunk(msg)
    return writer.stream.write(compressed)
  else:
    return writer.stream.write(msg)

proc close*(writer: SseWriter) =
  ## Mark the writer as closed. Finalize compressor if active.
  if writer.compressor != nil:
    let finalBytes = writer.compressor.finish()
    if finalBytes.len > 0:
      discard writer.stream.write(finalBytes)
    writer.compressor.destroy()
  writer.closed.store(true)
