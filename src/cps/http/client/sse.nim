## SSE Client
##
## Consumes Server-Sent Events streams over HTTP/1.1 (with optional TLS).
## Uses CPS procs for clean, sequential async code.
## Supports automatic gzip decompression of compressed SSE streams.
##
## Usage:
##   let client = await connectSse("example.com", 443, "/events", useTls = true)
##   while not client.reader.atEof:
##     let event = await client.readEvent()
##     echo event.eventType, ": ", event.data

import std/strutils
import ../../runtime
import ../../transform
import ../../io/streams
import ../../io/buffered
import ../../io/tcp
import ../../tls/client as tls
import ../shared/compression
import ../../tls/fingerprint

type
  SseEvent* = object
    eventType*: string  ## "event:" field (empty for unnamed events)
    data*: string       ## "data:" field (multi-line joined with \n)
    id*: string         ## "id:" field
    retry*: int         ## "retry:" field (-1 if not set)

  SseClient* = ref object
    stream*: AsyncStream
    reader*: BufferedReader
    lastEventId*: string
    closed*: bool

proc connectSse*(host: string, port: int, path: string = "/events",
                 useTls: bool = false,
                 extraHeaders: seq[(string, string)] = @[],
                 enableCompression: bool = true,
                 tlsFingerprint: TlsFingerprint = nil): CpsFuture[SseClient] {.cps.} =
  ## Connect to an SSE server. If useTls, wraps TCP with TLS (no cert verification).
  ## Sends GET with Accept: text/event-stream, validates 200 response.
  ## If enableCompression, sends Accept-Encoding: gzip and auto-decompresses.
  ## When `tlsFingerprint` is provided, applies the TLS fingerprint profile.
  var stream: AsyncStream

  if useTls:
    let tcpConn = await tcpConnect(host, port)
    let tlsStream = newTlsStream(tcpConn, host, @[], tlsFingerprint)  # No ALPN for SSE
    await tlsConnect(tlsStream)
    stream = tlsStream.AsyncStream
  else:
    let tcpConn = await tcpConnect(host, port)
    stream = tcpConn.AsyncStream

  # Build and send GET request with SSE headers (CRLF line endings)
  var reqStr = "GET " & path & " HTTP/1.1\r\n"
  reqStr &= "Host: " & host & ":" & $port & "\r\n"
  reqStr &= "Accept: text/event-stream\r\n"
  reqStr &= "Cache-Control: no-cache\r\n"
  reqStr &= "Connection: keep-alive\r\n"
  if enableCompression:
    reqStr &= "Accept-Encoding: gzip\r\n"
  for (k, v) in extraHeaders:
    reqStr &= k & ": " & v & "\r\n"
  reqStr &= "\r\n"

  await stream.write(reqStr)

  # Read response headers (CRLF-terminated)
  let reader = newBufferedReader(stream)
  let statusLine = await reader.readLine()  # default delimiter is \r\n
  if not statusLine.contains("200"):
    raise newException(streams.AsyncIoError, "SSE connection failed: " & statusLine)

  # Parse headers for Content-Encoding and Transfer-Encoding
  var isCompressed = false
  var isChunked = false
  while true:
    let line = await reader.readLine()
    if line == "":
      break
    let colonPos = line.find(':')
    if colonPos > 0:
      let hdrKey = line[0 ..< colonPos].strip().toLowerAscii
      let hdrVal = line[colonPos + 1 .. ^1].strip().toLowerAscii
      if hdrKey == "content-encoding" and "gzip" in hdrVal:
        isCompressed = true
      elif hdrKey == "transfer-encoding" and "chunked" in hdrVal:
        isChunked = true

  # If compressed, wrap stream with DecompressedStream
  # The reader may have buffered data beyond the headers, so drain it
  # and re-inject via PrefixedStream before decompression.
  var finalReader = reader
  if isCompressed:
    let remaining = reader.drainBuffer()
    var rawStream: AsyncStream
    if remaining.len > 0:
      rawStream = newPrefixedStream(remaining, stream).AsyncStream
    else:
      rawStream = stream
    if isChunked:
      rawStream = newChunkedDecompressedStream(rawStream, ceGzip).AsyncStream
    else:
      rawStream = newDecompressedStream(rawStream, ceGzip).AsyncStream
    finalReader = newBufferedReader(rawStream)

  return SseClient(
    stream: stream,
    reader: finalReader,
    lastEventId: "",
    closed: false
  )

proc readEvent*(client: SseClient): CpsFuture[SseEvent] {.cps.} =
  ## Read the next SSE event from the stream.
  ## Accumulates fields until a blank line (event boundary).
  ## Returns on blank line or EOF.
  var event = SseEvent(retry: -1)
  var dataLines: seq[string]

  while true:
    let rawLine = await client.reader.readLine(delimiter = "\n")

    # Strip trailing \r for servers that send CRLF
    var line = rawLine
    if line.len > 0 and line[^1] == '\r':
      line = line[0 ..< ^1]

    # Blank line = event boundary
    if line.len == 0:
      # If we accumulated any data, return the event
      if dataLines.len > 0 or event.eventType.len > 0 or event.id.len > 0:
        event.data = dataLines.join("\n")
        if event.id.len > 0:
          client.lastEventId = event.id
        return event
      # If nothing accumulated and at EOF, return empty event
      if client.reader.atEof:
        event.data = dataLines.join("\n")
        return event
      # Otherwise skip consecutive blank lines
      continue

    # Comment line (starts with ':')
    if line[0] == ':':
      continue

    # Parse field
    let colonPos = line.find(':')
    if colonPos > 0:
      let field = line[0 ..< colonPos]
      # Value starts after colon, skip optional leading space
      var value = line[colonPos + 1 .. ^1]
      if value.len > 0 and value[0] == ' ':
        value = value[1 .. ^1]

      case field
      of "event":
        event.eventType = value
      of "data":
        dataLines.add value
      of "id":
        event.id = value
      of "retry":
        try:
          event.retry = parseInt(value)
        except ValueError:
          discard
    elif colonPos == -1:
      # Field name with no colon — treat as field with empty value
      case line
      of "data":
        dataLines.add ""
      else:
        discard
