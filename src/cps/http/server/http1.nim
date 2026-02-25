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
    hasConnectionClose: bool
    hasConnectionKeepAlive: bool

  Http1ServerConnection* = object
    stream*: AsyncStream
    reader*: BufferedReader
    config*: HttpServerConfig

proc raiseRequestError(statusCode: int, msg: string) =
  var err = newException(Http1RequestError, msg)
  err.statusCode = statusCode
  raise err

proc applyReadTimeout[T](fut: CpsFuture[T], timeoutMs: int): CpsFuture[T] {.inline.} =
  if timeoutMs > 0:
    # Fast path: if data is already buffered, the future completes synchronously.
    # Skip the expensive timeout wrapper (timer + atomic flag + closures).
    if fut.finished():
      return fut
    return withTimeout(fut, timeoutMs)
  fut

proc headerHasToken(value, token: string): bool =
  ## Zero-allocation comma-separated token search (case-insensitive).
  var i = 0
  while i < value.len:
    # Skip leading whitespace
    while i < value.len and (value[i] == ' ' or value[i] == '\t'): inc i
    let start = i
    # Find end of token (next comma or end)
    while i < value.len and value[i] != ',': inc i
    # Trim trailing whitespace
    var tokenEnd = i - 1
    while tokenEnd >= start and (value[tokenEnd] == ' ' or value[tokenEnd] == '\t'): dec tokenEnd
    let tokenLen = tokenEnd - start + 1
    if tokenLen == token.len:
      var match = true
      for j in 0 ..< tokenLen:
        if toLowerAscii(value[start + j]) != toLowerAscii(token[j]):
          match = false
          break
      if match: return true
    if i < value.len: inc i  # skip comma
  false

proc headersHaveToken(headers: openArray[(string, string)],
                      name, token: string): bool =
  for (k, v) in headers:
    if eqCaseInsensitive(k, name) and headerHasToken(v, token):
      return true
  false

proc headersContainName(headers: openArray[(string, string)], name: string): bool =
  for (k, _) in headers:
    if eqCaseInsensitive(k, name):
      return true
  false

proc removeHeadersByName(headers: var seq[(string, string)], name: string) =
  var i = 0
  while i < headers.len:
    if eqCaseInsensitive(headers[i][0], name):
      headers.delete(i)
    else:
      inc i

proc parseContentLengthValue(value: string, parsed: var int): bool =
  if value.len == 0:
    return false
  for ch in value:
    if ch notin Digits:
      return false
  let n =
    try:
      parseBiggestInt(value)
    except ValueError:
      return false
  if n < 0 or n > BiggestInt(high(int)):
    return false
  parsed = int(n)
  true

proc parseTransferEncodingTokens(value: string, tokens: var seq[string]): bool =
  tokens.setLen(0)
  if value.len == 0:
    return false
  for part in value.split(','):
    let token = part.strip().toLowerAscii
    if token.len == 0:
      return false
    if not isValidHeaderName(token):
      return false
    tokens.add token
  # This implementation only supports pure chunked transfer-coding.
  tokens.len == 1 and tokens[0] == "chunked"

proc parseCommaTokens(value: string, tokens: var seq[string]): bool =
  tokens.setLen(0)
  if value.len == 0:
    return false
  for part in value.split(','):
    let token = part.strip().toLowerAscii
    if token.len == 0:
      return false
    if not isValidHeaderName(token):
      return false
    tokens.add token
  tokens.len > 0

proc parseHexChunkSize(token: string, parsed: var int): bool =
  if token.len == 0:
    return false
  var n: uint64 = 0
  for ch in token:
    var v = 0'u64
    if ch in {'0' .. '9'}:
      v = uint64(ord(ch) - ord('0'))
    elif ch in {'a' .. 'f'}:
      v = uint64(ord(ch) - ord('a') + 10)
    elif ch in {'A' .. 'F'}:
      v = uint64(ord(ch) - ord('A') + 10)
    else:
      return false
    if n > (uint64(high(int)) shr 4):
      return false
    n = (n shl 4) or v
  if n > uint64(high(int)):
    return false
  parsed = int(n)
  true

type
  HeaderParseResult = object
    ok: bool
    statusCode: int
    errBody: string
    meth: string
    path: string
    httpVersion: string
    headers: seq[(string, string)]
    hasConnectionClose: bool
    hasConnectionKeepAlive: bool
    parsedContentLength: int
    sawContentLength: bool
    transferEncoding: string
    hasExpect100Continue: bool

proc parseHeaderBlock(headerBlock: string, config: HttpServerConfig): HeaderParseResult =
  ## Parse a complete header block (request line + headers) synchronously.
  ## The headerBlock does NOT include the trailing \r\n\r\n.
  if headerBlock.len == 0:
    return HeaderParseResult(statusCode: 0)  # signals close

  # Find the first \r\n to separate request line from headers
  var lineEnd = 0
  while lineEnd < headerBlock.len - 1:
    if headerBlock[lineEnd] == '\r' and headerBlock[lineEnd + 1] == '\n':
      break
    inc lineEnd
  if lineEnd >= headerBlock.len - 1:
    # No \r\n found — whole block is request line with no headers
    lineEnd = headerBlock.len

  let requestLineLen = lineEnd
  if config.maxRequestLineSize > 0 and requestLineLen > config.maxRequestLineSize:
    return HeaderParseResult(ok: false, statusCode: 414, errBody: "URI Too Long")

  # Parse request line: METHOD SP path SP version
  let sp1 = headerBlock.find(' ')
  if sp1 <= 0 or sp1 >= lineEnd:
    return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")
  let sp2 = headerBlock.find(' ', sp1 + 1)
  if sp2 < 0 or sp2 >= lineEnd or sp2 == sp1 + 1:
    return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")

  result.meth = headerBlock[0 ..< sp1]
  result.path = headerBlock[sp1 + 1 ..< sp2]
  result.httpVersion = headerBlock[sp2 + 1 ..< lineEnd]

  if result.meth.len == 0 or not isValidHeaderName(result.meth):
    return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")
  if result.path.len == 0:
    return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")
  for c in result.path:
    if ord(c) < 0x21 or ord(c) == 0x7F:
      return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")
  if result.httpVersion.len == 0 or result.httpVersion.find(' ') >= 0:
    return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")
  if result.httpVersion != "HTTP/1.1" and result.httpVersion != "HTTP/1.0":
    if result.httpVersion.startsWith("HTTP/"):
      return HeaderParseResult(ok: false, statusCode: 505, errBody: "HTTP Version Not Supported")
    return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")

  # Parse headers from the remaining lines
  var headerCount = 0
  var totalHeaderBytes = 0
  var hostHeaderCount = 0
  var pos = lineEnd + 2  # skip past \r\n of request line
  var expectHeader = ""
  result.headers = newSeqOfCap[(string, string)](8)

  while pos < headerBlock.len:
    # Find end of this header line
    var hEnd = pos
    while hEnd < headerBlock.len - 1:
      if headerBlock[hEnd] == '\r' and headerBlock[hEnd + 1] == '\n':
        break
      inc hEnd
    if hEnd >= headerBlock.len - 1:
      hEnd = headerBlock.len  # last line without trailing \r\n

    let lineLen = hEnd - pos
    if lineLen == 0:
      # Empty line — end of headers (shouldn't happen since readUntilHeaderEnd
      # stops at \r\n\r\n, but handle gracefully)
      break

    inc headerCount
    totalHeaderBytes += lineLen
    if config.maxHeaderCount > 0 and headerCount > config.maxHeaderCount:
      return HeaderParseResult(ok: false, statusCode: 431, errBody: "Request Header Fields Too Large")
    if config.maxHeaderLineSize > 0 and lineLen > config.maxHeaderLineSize:
      return HeaderParseResult(ok: false, statusCode: 431, errBody: "Request Header Fields Too Large")
    if config.maxHeaderBytes > 0 and totalHeaderBytes > config.maxHeaderBytes:
      return HeaderParseResult(ok: false, statusCode: 431, errBody: "Request Header Fields Too Large")

    if headerBlock[pos] == ' ' or headerBlock[pos] == '\t':
      return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")

    # Find colon
    var colonPos = pos
    while colonPos < hEnd and headerBlock[colonPos] != ':':
      inc colonPos
    if colonPos >= hEnd or colonPos == pos:
      return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")

    let rawKey = headerBlock[pos ..< colonPos]
    # Check no trailing whitespace in key
    if rawKey[^1] == ' ' or rawKey[^1] == '\t':
      return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")

    # Extract and strip value
    var valStart = colonPos + 1
    while valStart < hEnd and (headerBlock[valStart] == ' ' or headerBlock[valStart] == '\t'):
      inc valStart
    var valEnd = hEnd - 1
    while valEnd >= valStart and (headerBlock[valEnd] == ' ' or headerBlock[valEnd] == '\t'):
      dec valEnd
    let val = if valStart <= valEnd: headerBlock[valStart .. valEnd] else: ""

    if not validateHeaderPair(rawKey, val):
      return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")

    if eqCaseInsensitive(rawKey, "host"):
      if val.len == 0:
        return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")
      inc hostHeaderCount
    elif eqCaseInsensitive(rawKey, "content-length"):
      var parsedLen = 0
      if not parseContentLengthValue(val, parsedLen):
        return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")
      if result.sawContentLength and parsedLen != result.parsedContentLength:
        return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")
      result.sawContentLength = true
      result.parsedContentLength = parsedLen
    elif eqCaseInsensitive(rawKey, "transfer-encoding"):
      if result.transferEncoding.len > 0:
        result.transferEncoding.add(",")
      result.transferEncoding.add(val)
    elif eqCaseInsensitive(rawKey, "expect"):
      if expectHeader.len > 0:
        expectHeader.add(",")
      expectHeader.add(val)
    elif eqCaseInsensitive(rawKey, "connection"):
      if headerHasToken(val, "close"):
        result.hasConnectionClose = true
      if headerHasToken(val, "keep-alive"):
        result.hasConnectionKeepAlive = true
    result.headers.add (rawKey, val)

    pos = hEnd + 2  # skip \r\n

  if result.httpVersion == "HTTP/1.1" and hostHeaderCount != 1:
    return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")
  if result.httpVersion == "HTTP/1.0" and hostHeaderCount > 1:
    return HeaderParseResult(ok: false, statusCode: 400, errBody: "Bad Request")

  # Process expect header
  if expectHeader.len > 0:
    var expectTokens: seq[string]
    if not parseCommaTokens(expectHeader, expectTokens):
      return HeaderParseResult(ok: false, statusCode: 417, errBody: "Expectation Failed")
    for token in expectTokens:
      if token == "100-continue":
        result.hasExpect100Continue = true
      else:
        return HeaderParseResult(ok: false, statusCode: 417, errBody: "Expectation Failed")
    if result.hasExpect100Continue and
       result.sawContentLength and
       config.maxRequestBodySize > 0 and
       result.parsedContentLength > config.maxRequestBodySize:
      return HeaderParseResult(ok: false, statusCode: 413, errBody: "Payload Too Large")

  result.ok = true

proc parseRequestResultWithBody(stream: AsyncStream, reader: BufferedReader,
                                config: HttpServerConfig,
                                remoteAddr: string,
                                hdr: HeaderParseResult): CpsFuture[ParseRequestResult] {.cps.} =
  ## CPS proc for parsing requests WITH bodies (Content-Length or chunked).
  ## Only called when the request has a body to read.
  var body = ""
  var headerCount = hdr.headers.len
  var totalHeaderBytes = 0  # approximate

  if hdr.transferEncoding.len > 0 and hdr.sawContentLength:
    return ParseRequestResult(statusCode: 400, errBody: "Bad Request")

  var hasChunkedTransfer = false
  if hdr.transferEncoding.len > 0:
    var teTokens: seq[string]
    if not parseTransferEncodingTokens(hdr.transferEncoding, teTokens):
      return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
    hasChunkedTransfer = true

  if hdr.hasExpect100Continue and (hasChunkedTransfer or (hdr.sawContentLength and hdr.parsedContentLength > 0)):
    try:
      await stream.write("HTTP/1.1 100 Continue\r\n\r\n")
    except CatchableError:
      return ParseRequestResult(closeConn: true)

  if hasChunkedTransfer:
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
      let semi = sizeLine.find(';')
      var sizeStr = sizeLine
      if semi >= 0:
        sizeStr = sizeLine[0 ..< semi]
      let sizeToken = sizeStr.strip()
      if sizeToken.len == 0:
        return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
      var chunkSize = 0
      if not parseHexChunkSize(sizeToken, chunkSize):
        return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
      if chunkSize == 0:
        while true:
          var trailerLine = ""
          try:
            trailerLine = await applyReadTimeout(reader.readLine(), config.readTimeoutMs)
          except TimeoutError:
            return ParseRequestResult(statusCode: 408, errBody: "Request Timeout")
          except CatchableError:
            return ParseRequestResult(closeConn: true)
          if trailerLine.len == 0:
            break
          if trailerLine[0] == ' ' or trailerLine[0] == '\t':
            return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
          let trailerColon = trailerLine.find(':')
          if trailerColon <= 0:
            return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
          let trailerKeyRaw = trailerLine.substr(0, trailerColon - 1)
          if trailerKeyRaw != trailerKeyRaw.strip():
            return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
          let trailerVal = trailerLine[trailerColon + 1 .. ^1].strip()
          if not validateHeaderPair(trailerKeyRaw, trailerVal):
            return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
          inc headerCount
          totalHeaderBytes += trailerLine.len
          if config.maxHeaderCount > 0 and headerCount > config.maxHeaderCount:
            return ParseRequestResult(statusCode: 431, errBody: "Request Header Fields Too Large")
          if config.maxHeaderLineSize > 0 and trailerLine.len > config.maxHeaderLineSize:
            return ParseRequestResult(statusCode: 431, errBody: "Request Header Fields Too Large")
          if config.maxHeaderBytes > 0 and totalHeaderBytes > config.maxHeaderBytes:
            return ParseRequestResult(statusCode: 431, errBody: "Request Header Fields Too Large")
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
        chunkTrailing = await applyReadTimeout(reader.readExact(2), config.readTimeoutMs)
      except TimeoutError:
        return ParseRequestResult(statusCode: 408, errBody: "Request Timeout")
      except CatchableError:
        return ParseRequestResult(closeConn: true)
      if chunkTrailing != "\r\n":
        return ParseRequestResult(statusCode: 400, errBody: "Bad Request")
    body = bodyParts.join("")
  elif hdr.sawContentLength:
    let cl = hdr.parsedContentLength
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
    meth: hdr.meth,
    path: hdr.path,
    httpVersion: hdr.httpVersion,
    headers: hdr.headers,
    body: body,
    remoteAddr: remoteAddr,
    stream: stream,
    reader: reader,
    context: nil
  )
  return ParseRequestResult(ok: true, req: req,
    hasConnectionClose: hdr.hasConnectionClose,
    hasConnectionKeepAlive: hdr.hasConnectionKeepAlive)

proc processHeaderBlock(headerBlock: string, config: HttpServerConfig,
                        stream: AsyncStream, reader: BufferedReader,
                        remoteAddr: string): CpsFuture[ParseRequestResult] =
  ## Process a complete header block into a ParseRequestResult.
  ## For no-body requests: returns a pre-completed future (no CPS overhead).
  ## For body requests: delegates to CPS proc.
  if headerBlock.len == 0:
    return completedFuture(ParseRequestResult(closeConn: true))

  let hdr = parseHeaderBlock(headerBlock, config)
  if not hdr.ok:
    if hdr.statusCode == 0:
      return completedFuture(ParseRequestResult(closeConn: true))
    return completedFuture(ParseRequestResult(statusCode: hdr.statusCode, errBody: hdr.errBody))

  # Check if body reading is needed
  let needsBody = hdr.transferEncoding.len > 0 or
                  (hdr.sawContentLength and hdr.parsedContentLength > 0) or
                  hdr.hasExpect100Continue
  if needsBody:
    return parseRequestResultWithBody(stream, reader, config, remoteAddr, hdr)

  # No body — fast path: return pre-completed future
  let req = HttpRequest(
    meth: hdr.meth,
    path: hdr.path,
    httpVersion: hdr.httpVersion,
    headers: hdr.headers,
    body: "",
    remoteAddr: remoteAddr,
    stream: stream,
    reader: reader,
    context: nil
  )
  return completedFuture(ParseRequestResult(ok: true, req: req,
    hasConnectionClose: hdr.hasConnectionClose,
    hasConnectionKeepAlive: hdr.hasConnectionKeepAlive))

proc parseRequestResult(stream: AsyncStream, reader: BufferedReader,
                        config: HttpServerConfig,
                        remoteAddr: string = ""): CpsFuture[ParseRequestResult] =
  ## Parse an HTTP/1.1 request. Avoids CPS env allocation for the common case
  ## (no-body requests with headers already in the buffer).
  let maxHeaderSize = if config.maxHeaderBytes > 0: config.maxHeaderBytes else: 65536

  # Ultra-fast path: search buffer directly, bypass readUntilHeaderEnd's CpsFuture
  var idx = reader.searchHeaderEnd()
  if idx >= 0:
    return processHeaderBlock(reader.extractHeaderBlock(idx), config, stream, reader, remoteAddr)

  # Try one sync fill, then check again (common for keep-alive)
  if not reader.atEof():
    let fillFut = reader.fillBuffer()
    if fillFut.finished():
      if not fillFut.hasError():
        idx = reader.searchHeaderEnd()
        if idx >= 0:
          return processHeaderBlock(reader.extractHeaderBlock(idx), config, stream, reader, remoteAddr)
        if reader.atEof():
          return completedFuture(ParseRequestResult(closeConn: true))
      else:
        return completedFuture(ParseRequestResult(closeConn: true))
    else:
      # fillBuffer is pending (EAGAIN) — wait for data, then use readUntilHeaderEnd
      let resultFut = newCpsFuture[ParseRequestResult]()
      fillFut.addCallback(proc() =
        if fillFut.hasError():
          resultFut.complete(ParseRequestResult(closeConn: true))
          return
        # Now try readUntilHeaderEnd (data should be available or more will come)
        let headerFut = applyReadTimeout(reader.readUntilHeaderEnd(maxHeaderSize), config.readTimeoutMs)
        if headerFut.finished():
          if headerFut.hasError():
            let err = headerFut.getError()
            if err of TimeoutError:
              resultFut.complete(ParseRequestResult(statusCode: 408, errBody: "Request Timeout"))
            else:
              resultFut.complete(ParseRequestResult(closeConn: true))
          else:
            let innerFut = processHeaderBlock(headerFut.read(), config, stream, reader, remoteAddr)
            if innerFut.finished():
              if innerFut.hasError():
                resultFut.fail(innerFut.getError())
              else:
                resultFut.complete(innerFut.read())
            else:
              innerFut.addCallback(proc() =
                if innerFut.hasError():
                  resultFut.fail(innerFut.getError())
                else:
                  resultFut.complete(innerFut.read())
              )
        else:
          headerFut.addCallback(proc() =
            if headerFut.hasError():
              let err = headerFut.getError()
              if err of TimeoutError:
                resultFut.complete(ParseRequestResult(statusCode: 408, errBody: "Request Timeout"))
              else:
                resultFut.complete(ParseRequestResult(closeConn: true))
            else:
              let innerFut = processHeaderBlock(headerFut.read(), config, stream, reader, remoteAddr)
              if innerFut.finished():
                if innerFut.hasError():
                  resultFut.fail(innerFut.getError())
                else:
                  resultFut.complete(innerFut.read())
              else:
                innerFut.addCallback(proc() =
                  if innerFut.hasError():
                    resultFut.fail(innerFut.getError())
                  else:
                    resultFut.complete(innerFut.read())
                )
          )
      )
      return resultFut

  # EOF with no data
  if reader.atEof():
    return completedFuture(ParseRequestResult(closeConn: true))

  # Fall back to full readUntilHeaderEnd (for edge cases)
  let headerFut = applyReadTimeout(reader.readUntilHeaderEnd(maxHeaderSize), config.readTimeoutMs)
  if headerFut.finished():
    if headerFut.hasError():
      let err = headerFut.getError()
      if err of TimeoutError:
        return completedFuture(ParseRequestResult(statusCode: 408, errBody: "Request Timeout"))
      return completedFuture(ParseRequestResult(closeConn: true))
    return processHeaderBlock(headerFut.read(), config, stream, reader, remoteAddr)

  let resultFut = newCpsFuture[ParseRequestResult]()
  headerFut.addCallback(proc() =
    if headerFut.hasError():
      let err = headerFut.getError()
      if err of TimeoutError:
        resultFut.complete(ParseRequestResult(statusCode: 408, errBody: "Request Timeout"))
      else:
        resultFut.complete(ParseRequestResult(closeConn: true))
    else:
      let innerFut = processHeaderBlock(headerFut.read(), config, stream, reader, remoteAddr)
      if innerFut.finished():
        if innerFut.hasError():
          resultFut.fail(innerFut.getError())
        else:
          resultFut.complete(innerFut.read())
      else:
        innerFut.addCallback(proc() =
          if innerFut.hasError():
            resultFut.fail(innerFut.getError())
          else:
            resultFut.complete(innerFut.read())
        )
  )
  return resultFut

proc parseRequest*(stream: AsyncStream, reader: BufferedReader,
                   config: HttpServerConfig,
                   remoteAddr: string = ""): CpsFuture[HttpRequest] {.cps.} =
  ## Parse an HTTP/1.1 request from the stream.
  let parsed = await parseRequestResult(stream, reader, config, remoteAddr)
  if parsed.ok:
    return parsed.req
  if parsed.statusCode != 0:
    raiseRequestError(parsed.statusCode, parsed.errBody)
  raise newException(streams.AsyncIoError, "Connection closed")

proc statusProhibitsBody(statusCode: int): bool {.inline.} =
  (statusCode >= 100 and statusCode < 200) or statusCode == 204 or statusCode == 304

proc addInt(s: var string, n: int) {.inline.} =
  ## Append integer to string without allocating a temporary `$n`.
  if n == 0:
    s.add '0'
    return
  var val = n
  let start = s.len
  while val > 0:
    s.add char(ord('0') + val mod 10)
    val = val div 10
  # Reverse the appended digits in-place
  var lo = start
  var hi = s.len - 1
  while lo < hi:
    swap(s[lo], s[hi])
    inc lo
    dec hi

proc statusLine(code: int): string {.inline.} =
  ## Return pre-computed status line prefix for common codes.
  case code
  of 200: "HTTP/1.1 200 OK\r\n"
  of 201: "HTTP/1.1 201 Created\r\n"
  of 204: "HTTP/1.1 204 No Content\r\n"
  of 301: "HTTP/1.1 301 Moved Permanently\r\n"
  of 302: "HTTP/1.1 302 Found\r\n"
  of 304: "HTTP/1.1 304 Not Modified\r\n"
  of 400: "HTTP/1.1 400 Bad Request\r\n"
  of 404: "HTTP/1.1 404 Not Found\r\n"
  of 405: "HTTP/1.1 405 Method Not Allowed\r\n"
  of 500: "HTTP/1.1 500 Internal Server Error\r\n"
  else:
    var s = "HTTP/1.1 "
    s.addInt(code)
    s.add ' '
    s.add statusMessage(code)
    s.add "\r\n"
    s

proc buildResponseStringImpl(resp: HttpResponseBuilder,
                             sendBody: bool,
                             bodyLengthHint: int): string =
  if not validateResponseHeaders(resp.headers):
    let body = "Internal Server Error"
    result = newStringOfCap(128)
    result.add "HTTP/1.1 500 Internal Server Error\r\nContent-Length: "
    result.addInt(body.len)
    result.add "\r\nConnection: close\r\n\r\n"
    if sendBody:
      result.add body
    return

  let noBody = statusProhibitsBody(resp.statusCode)
  let resetContentNoPayload = resp.statusCode == 205
  let representationLen =
    if bodyLengthHint >= 0: bodyLengthHint
    else: resp.body.len
  let bodyStr =
    if noBody or resetContentNoPayload or not sendBody: ""
    else: resp.body

  # Pre-allocate: status line + headers + body
  result = newStringOfCap(256 + bodyStr.len)
  result.add statusLine(resp.statusCode)

  var hasConnection = false
  for (k, v) in resp.headers:
    if eqCaseInsensitive(k, "content-length") or eqCaseInsensitive(k, "transfer-encoding"):
      continue
    result.add k
    result.add ": "
    result.add v
    result.add "\r\n"
    if eqCaseInsensitive(k, "connection"):
      hasConnection = true

  if resetContentNoPayload:
    result.add "Content-Length: 0\r\n"
  elif not noBody:
    result.add "Content-Length: "
    result.addInt(representationLen)
    result.add "\r\n"

  if not hasConnection:
    result.add "Connection: keep-alive\r\n"

  result.add "\r\n"
  result.add bodyStr

proc buildResponseString*(resp: HttpResponseBuilder): string =
  ## Build the HTTP/1.1 response string from a response builder.
  buildResponseStringImpl(resp, sendBody = true, bodyLengthHint = -1)

proc writeResponse*(stream: AsyncStream, resp: HttpResponseBuilder,
                    sendBody: bool = true,
                    bodyLengthHint: int = -1): CpsVoidFuture =
  ## Write an HTTP/1.1 response to the stream.
  let respStr = buildResponseStringImpl(resp, sendBody, bodyLengthHint)
  stream.write(respStr)

proc headBodyLengthHint(resp: HttpResponseBuilder): int =
  ## For HEAD requests, extract Content-Length from headers if present
  ## (e.g. set by router HEAD auto-gen), else fall back to body length.
  let clVal = resp.getResponseHeader("content-length")
  if clVal.len > 0:
    var parsed = 0
    if parseContentLengthValue(clVal, parsed):
      return parsed
  resp.body.len

proc handleHttp1Connection*(stream: AsyncStream, config: HttpServerConfig,
                            handler: HttpHandler,
                            remoteAddr: string = ""): CpsVoidFuture {.cps.} =
  ## Handle an HTTP/1.1 connection: parse requests in a loop, call the
  ## handler, and write responses. Honors Connection: close.
  let reader = newBufferedReader(stream)
  while true:
    var req: HttpRequest
    var hasRequest = false
    var closeConn = false
    var parseErrStatus = 0
    var parseErrBody = ""
    let parsed = await parseRequestResult(stream, reader, config, remoteAddr)
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
    var wsHandlerFailure = false
    try:
      resp = await handler(req)
    except CatchableError:
      if not req.context.isNil and req.context.getOrDefault("ws_upgraded") == "1":
        wsHandlerFailure = true
      else:
        resp = newResponse(500, "Internal Server Error", @[("Connection", "close")])

    if wsHandlerFailure:
      break

    if resp.control == rcHandled or resp.statusCode == 0:
      break  # SSE/WS/chunked handler already wrote to stream

    let reqClose = parsed.hasConnectionClose
    let reqKeepAlive = parsed.hasConnectionKeepAlive
    let shouldCloseAfterResponse = reqClose or (req.httpVersion == "HTTP/1.0" and not reqKeepAlive)
    if shouldCloseAfterResponse:
      removeHeadersByName(resp.headers, "connection")
      resp.headers.add(("Connection", "close"))
    elif not headersContainName(resp.headers, "connection"):
      if req.httpVersion == "HTTP/1.0":
        if reqKeepAlive:
          resp.headers.add(("Connection", "keep-alive"))
        else:
          resp.headers.add(("Connection", "close"))
      else:
        if reqClose:
          resp.headers.add(("Connection", "close"))

    var writeFailed = false
    try:
      # Fast path: 200 OK, no custom headers, keep-alive, not HEAD
      if resp.statusCode == 200 and resp.headers.len == 0 and
         not shouldCloseAfterResponse and not eqCaseInsensitive(req.meth, "HEAD"):
        var s = newStringOfCap(64 + resp.body.len)
        s.add "HTTP/1.1 200 OK\r\nContent-Length: "
        s.addInt(resp.body.len)
        s.add "\r\nConnection: keep-alive\r\n\r\n"
        s.add resp.body
        await stream.write(s)
      else:
        let isHeadRequest = eqCaseInsensitive(req.meth, "HEAD")
        if isHeadRequest:
          let hint = headBodyLengthHint(resp)
          await writeResponse(stream, resp, sendBody = false, bodyLengthHint = hint)
        else:
          await writeResponse(stream, resp)
    except CatchableError:
      writeFailed = true
    if writeFailed:
      break

    if shouldCloseAfterResponse:
      break

    # Respect explicit close from response.
    if headersHaveToken(resp.headers, "connection", "close"):
      break

  stream.close()
