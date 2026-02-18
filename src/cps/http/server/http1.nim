## HTTP/1.1 Server Implementation
##
## Parses HTTP/1.1 requests and writes responses over an AsyncStream.
## Supports keep-alive connections and chunked/fixed-length bodies.

import std/[strutils, tables]
import ../../runtime
import ../../transform
import ../../io/streams
import ../../io/buffered
import ../../io/timeouts
import ./types

type
  Http1RequestError = object of CatchableError
    statusCode: int

  ParseRequestResult = object
    ok: bool
    req: HttpRequest
    statusCode: int
    errBody: string
    closeConn: bool

  Http1ServerConnection* = object
    stream*: AsyncStream
    reader*: BufferedReader
    config*: HttpServerConfig

proc raiseRequestError(statusCode: int, msg: string) =
  var err = newException(Http1RequestError, msg)
  err.statusCode = statusCode
  raise err

proc applyReadTimeout[T](fut: CpsFuture[T], timeoutMs: int): CpsFuture[T] =
  if timeoutMs > 0:
    return withTimeout(fut, timeoutMs)
  fut

proc parseRequestResult(stream: AsyncStream, reader: BufferedReader,
                        config: HttpServerConfig): CpsFuture[ParseRequestResult] {.cps.} =
  ## Parse an HTTP/1.1 request from the stream, returning status metadata
  ## instead of throwing parse exceptions.
  var meth = ""
  var path = ""
  var httpVersion = "HTTP/1.1"
  var headers: seq[(string, string)]
  var body = ""

  # Parse request line: METHOD /path HTTP/1.1
  var requestLine = ""
  try:
    requestLine = await applyReadTimeout(reader.readLine(), config.readTimeoutMs)
  except TimeoutError:
    return ParseRequestResult(statusCode: 408, errBody: "Request Timeout")
  except CatchableError:
    return ParseRequestResult(closeConn: true)
  if requestLine == "":
    return ParseRequestResult(closeConn: true)
  if config.maxRequestLineSize > 0 and requestLine.len > config.maxRequestLineSize:
    return ParseRequestResult(statusCode: 414, errBody: "URI Too Long")

  let parts = requestLine.split(' ', 2)
  if parts.len < 3:
    return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
  meth = parts[0]
  path = parts[1]
  httpVersion = parts[2]

  # Read headers until blank line
  var headerCount = 0
  var totalHeaderBytes = 0
  while true:
    var line = ""
    try:
      line = await applyReadTimeout(reader.readLine(), config.readTimeoutMs)
    except TimeoutError:
      return ParseRequestResult(statusCode: 408, errBody: "Request Timeout")
    except CatchableError:
      return ParseRequestResult(closeConn: true)
    if line == "":
      break
    inc headerCount
    totalHeaderBytes += line.len
    if config.maxHeaderCount > 0 and headerCount > config.maxHeaderCount:
      return ParseRequestResult(statusCode: 431, errBody: "Request Header Fields Too Large")
    if config.maxHeaderLineSize > 0 and line.len > config.maxHeaderLineSize:
      return ParseRequestResult(statusCode: 431, errBody: "Request Header Fields Too Large")
    if config.maxHeaderBytes > 0 and totalHeaderBytes > config.maxHeaderBytes:
      return ParseRequestResult(statusCode: 431, errBody: "Request Header Fields Too Large")
    let colonPos = line.find(':')
    if colonPos <= 0:
      return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
    let key = line[0 ..< colonPos].strip()
    let val = line[colonPos + 1 .. ^1].strip()
    headers.add (key, val)

  # Find content-length and transfer-encoding from headers
  var contentLength = ""
  var transferEncoding = ""
  for i in 0 ..< headers.len:
    if headers[i][0].toLowerAscii == "content-length":
      contentLength = headers[i][1]
    if headers[i][0].toLowerAscii == "transfer-encoding":
      transferEncoding = headers[i][1]

  # Read body based on Content-Length or chunked encoding
  if transferEncoding.toLowerAscii == "chunked":
    var bodyParts: seq[string]
    var totalBodyBytes = 0
    while true:
      var sizeLine = ""
      try:
        sizeLine = await applyReadTimeout(reader.readLine(), config.readTimeoutMs)
      except TimeoutError:
        return ParseRequestResult(statusCode: 408, errBody: "Request Timeout")
      except CatchableError:
        return ParseRequestResult(closeConn: true)
      let sizeStr = sizeLine.strip().split(';')[0].strip()
      var chunkSize = 0
      try:
        chunkSize = parseHexInt(sizeStr)
      except ValueError:
        return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
      if chunkSize < 0:
        return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
      if chunkSize == 0:
        var trailing = ""
        try:
          trailing = await applyReadTimeout(reader.readLine(), config.readTimeoutMs)
        except TimeoutError:
          return ParseRequestResult(statusCode: 408, errBody: "Request Timeout")
        except CatchableError:
          return ParseRequestResult(closeConn: true)
        discard trailing
        break
      totalBodyBytes += chunkSize
      if config.maxRequestBodySize > 0 and totalBodyBytes > config.maxRequestBodySize:
        return ParseRequestResult(statusCode: 413, errBody: "Payload Too Large")
      var data = ""
      try:
        data = await applyReadTimeout(reader.readExact(chunkSize), config.readTimeoutMs)
      except TimeoutError:
        return ParseRequestResult(statusCode: 408, errBody: "Request Timeout")
      except CatchableError:
        return ParseRequestResult(closeConn: true)
      bodyParts.add data
      var chunkTrailing = ""
      try:
        chunkTrailing = await applyReadTimeout(reader.readLine(), config.readTimeoutMs)
      except TimeoutError:
        return ParseRequestResult(statusCode: 408, errBody: "Request Timeout")
      except CatchableError:
        return ParseRequestResult(closeConn: true)
      discard chunkTrailing
    body = bodyParts.join("")
  elif contentLength != "":
    var cl = 0
    try:
      cl = parseInt(contentLength)
    except ValueError:
      return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
    if cl < 0:
      return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
    if config.maxRequestBodySize > 0 and cl > config.maxRequestBodySize:
      return ParseRequestResult(statusCode: 413, errBody: "Payload Too Large")
    if cl > 0:
      var bodyData = ""
      try:
        bodyData = await applyReadTimeout(reader.readExact(cl), config.readTimeoutMs)
      except TimeoutError:
        return ParseRequestResult(statusCode: 408, errBody: "Request Timeout")
      except CatchableError:
        return ParseRequestResult(closeConn: true)
      body = bodyData

  var req = HttpRequest(
    meth: meth,
    path: path,
    httpVersion: httpVersion,
    headers: headers,
    body: body,
    stream: stream,
    reader: reader,
    context: newTable[string, string]()
  )
  return ParseRequestResult(ok: true, req: req)

proc parseRequest*(stream: AsyncStream, reader: BufferedReader,
                   config: HttpServerConfig): CpsFuture[HttpRequest] {.cps.} =
  ## Parse an HTTP/1.1 request from the stream.
  let parsed = await parseRequestResult(stream, reader, config)
  if parsed.ok:
    return parsed.req
  if parsed.statusCode != 0:
    raiseRequestError(parsed.statusCode, parsed.errBody)
  raise newException(streams.AsyncIoError, "Connection closed")

proc buildResponseString*(resp: HttpResponseBuilder): string =
  ## Build the HTTP/1.1 response string from a response builder.
  result = "HTTP/1.1 " & $resp.statusCode & " " & statusMessage(resp.statusCode) & "\r\n"

  var hasContentLength = false
  var hasConnection = false
  for (k, v) in resp.headers:
    result &= k & ": " & v & "\r\n"
    if k.toLowerAscii == "content-length":
      hasContentLength = true
    if k.toLowerAscii == "connection":
      hasConnection = true

  if not hasContentLength:
    result &= "Content-Length: " & $resp.body.len & "\r\n"

  if not hasConnection:
    result &= "Connection: keep-alive\r\n"

  result &= "\r\n"
  result &= resp.body

proc writeResponse*(stream: AsyncStream, resp: HttpResponseBuilder): CpsVoidFuture =
  ## Write an HTTP/1.1 response to the stream.
  let respStr = buildResponseString(resp)
  stream.write(respStr)

proc handleHttp1Connection*(stream: AsyncStream, config: HttpServerConfig,
                            handler: HttpHandler): CpsVoidFuture {.cps.} =
  ## Handle an HTTP/1.1 connection: parse requests in a loop, call the
  ## handler, and write responses. Honors Connection: close.
  let reader = newBufferedReader(stream)
  while true:
    var req: HttpRequest
    var hasRequest = false
    var closeConn = false
    var parseErrStatus = 0
    var parseErrBody = ""
    let parsed = await parseRequestResult(stream, reader, config)
    if parsed.ok:
      req = parsed.req
      hasRequest = true
    elif parsed.statusCode != 0:
      parseErrStatus = parsed.statusCode
      parseErrBody = parsed.errBody
    else:
      closeConn = parsed.closeConn

    if parseErrStatus != 0:
      try:
        await writeResponse(stream, newResponse(parseErrStatus, parseErrBody, @[("Connection", "close")]))
      except CatchableError:
        discard
      break

    if closeConn or not hasRequest:
      break

    var resp: HttpResponseBuilder
    try:
      resp = await handler(req)
    except CatchableError:
      resp = newResponse(500, "Internal Server Error", @[("Connection", "close")])

    if resp.control == rcHandled or resp.statusCode == 0:
      break  # SSE/WS/chunked handler already wrote to stream

    var writeFailed = false
    try:
      await writeResponse(stream, resp)
    except CatchableError:
      writeFailed = true
    if writeFailed:
      break

    # Check if client requested connection close
    let connHeader = req.getHeader("connection")
    if connHeader.toLowerAscii == "close":
      break

    # Respect explicit close from response
    let respConnHeader = resp.getResponseHeader("connection")
    if respConnHeader.toLowerAscii == "close":
      break

    # Also close if HTTP/1.0 without keep-alive
    if req.httpVersion == "HTTP/1.0" and connHeader.toLowerAscii != "keep-alive":
      break
  stream.close()
