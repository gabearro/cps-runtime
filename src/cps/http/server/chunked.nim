## Chunked Transfer Encoding / Streaming Writer
##
## Provides streaming response support for both HTTP/1.1 and HTTP/2.
##
## HTTP/1.1: Uses chunked transfer encoding (hex-size + CRLF + data + CRLF).
## HTTP/2: Writes data directly — the Http2StreamAdapter wraps it in DATA frames.
##
## The handler writes response headers via `initChunked`, streams data using
## `sendChunk`, and finalizes with `endChunked`. Returns `streamResponse()`
## (a sentinel with statusCode=0) so the server knows the handler already
## wrote to the stream.
##
## Usage:
##   proc handler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
##     let w = await initChunked(req.stream)
##     await w.sendChunk("Hello ")
##     await w.sendChunk("World\n")
##     await w.endChunked()
##     return streamResponse()

import std/strutils
import ../../runtime
import ../../io/streams
import ./types
import ../shared/http2_stream_adapter

type
  ChunkedWriter* = ref object
    stream*: AsyncStream
    closed*: bool
    isHttp2*: bool  ## true when writing to Http2StreamAdapter

proc streamResponse*(): HttpResponseBuilder =
  ## Sentinel control response. Tells the server that
  ## the handler already wrote directly to the stream.
  handledResponse()

proc initChunked*(stream: AsyncStream, statusCode: int = 200,
                  extraHeaders: seq[(string, string)] = @[]): CpsFuture[ChunkedWriter] =
  ## Write HTTP response headers and return a ChunkedWriter for streaming data.
  ## Detects HTTP/2 (Http2StreamAdapter) and uses proper HEADERS frames.
  ## For HTTP/1.1, uses Transfer-Encoding: chunked.
  let fut = newCpsFuture[ChunkedWriter]()

  if stream of Http2StreamAdapter:
    # HTTP/2: send HEADERS frame (no END_STREAM) via the adapter
    let adapter = Http2StreamAdapter(stream)
    var h2Headers: seq[(string, string)] = @[]
    for (k, v) in extraHeaders:
      h2Headers.add (k.toLowerAscii, v)
    let writeFut = adapter.sendResponseHeaders(statusCode, h2Headers)
    let capturedStream = stream
    writeFut.addCallback(proc() =
      if writeFut.hasError():
        fut.fail(writeFut.getError())
      else:
        fut.complete(ChunkedWriter(stream: capturedStream, closed: false, isHttp2: true))
    )
  else:
    # HTTP/1.1: write raw response headers with chunked encoding
    var headerStr = "HTTP/1.1 " & $statusCode & " " & statusMessage(statusCode) & "\r\n"
    headerStr.add "Transfer-Encoding: chunked\r\n"
    for (k, v) in extraHeaders:
      headerStr.add k & ": " & v & "\r\n"
    headerStr.add "\r\n"

    let writeFut = stream.write(headerStr)
    let capturedStream = stream
    writeFut.addCallback(proc() =
      if writeFut.hasError():
        fut.fail(writeFut.getError())
      else:
        fut.complete(ChunkedWriter(stream: capturedStream, closed: false, isHttp2: false))
    )
  return fut

proc sendChunk*(writer: ChunkedWriter, data: string): CpsVoidFuture =
  ## Send a chunk of data.
  ## HTTP/1.1: uses chunked transfer encoding (hex-size CRLF data CRLF).
  ## HTTP/2: writes raw data (adapter wraps in DATA frames).
  ## Empty data is ignored (use endChunked to finalize).
  if writer.closed or data.len == 0:
    let fut = newCpsVoidFuture()
    fut.complete()
    return fut

  if writer.isHttp2:
    # HTTP/2: write raw data — the adapter wraps it in DATA frames
    return writer.stream.write(data)
  else:
    # HTTP/1.1: chunked transfer encoding format
    var hex = toHex(data.len).toLowerAscii
    # Strip leading zeros, keeping at least one digit
    var start = 0
    while start < hex.len - 1 and hex[start] == '0':
      inc start
    hex = hex[start .. ^1]
    let chunk = hex & "\r\n" & data & "\r\n"
    return writer.stream.write(chunk)

proc endChunked*(writer: ChunkedWriter): CpsVoidFuture =
  ## Finalize the streaming response.
  ## HTTP/1.1: sends the terminal zero-length chunk.
  ## HTTP/2: no-op (END_STREAM is sent by dispatchHttp2Handler after handler returns).
  if not writer.closed:
    writer.closed = true
    if not writer.isHttp2:
      return writer.stream.write("0\r\n\r\n")
  # HTTP/2 or already closed: return completed future
  let fut = newCpsVoidFuture()
  fut.complete()
  return fut
