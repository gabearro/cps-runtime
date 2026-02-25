## HTTP/1.1 Client Implementation
##
## Provides HTTP/1.1 request/response handling over an AsyncStream.
## Supports chunked transfer encoding and keep-alive connections.
## Uses CPS procs with BufferedReader for simple, sequential async code.

import std/[strutils]
import ../../runtime
import ../../transform
import ../../io/streams
import ../../io/buffered

type
  HttpResponse* = object
    statusCode*: int
    statusMessage*: string
    httpVersion*: string  ## e.g. "HTTP/1.0" or "HTTP/1.1"
    headers*: seq[(string, string)]
    body*: string

  Http1Connection* = ref object
    stream*: AsyncStream
    reader*: BufferedReader
    host*: string
    port*: int
    keepAlive*: bool

const headerTokenChars = {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^',
                          '_', '`', '|', '~'} + Digits + Letters
const defaultMaxStatusLineSize = 8 * 1024
const defaultMaxHeaderLineSize = 8 * 1024
const defaultMaxHeaderBytes = 64 * 1024
const defaultMaxHeaderCount = 100

proc getHeader*(resp: HttpResponse, name: string): string =
  for (k, v) in resp.headers:
    if k.toLowerAscii == name.toLowerAscii:
      return v
  return ""

proc headerHasToken(value, token: string): bool =
  let expected = token.toLowerAscii
  for part in value.split(','):
    if part.strip().toLowerAscii == expected:
      return true
  false

proc headersHaveToken(headers: openArray[(string, string)],
                      name, token: string): bool =
  let lowerName = name.toLowerAscii
  for (k, v) in headers:
    if k.toLowerAscii == lowerName and headerHasToken(v, token):
      return true
  false

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

proc isValidHeaderName(name: string): bool =
  if name.len == 0:
    return false
  for c in name:
    if c notin headerTokenChars:
      return false
  true

proc isValidHeaderValue(value: string): bool =
  for c in value:
    if c == '\r' or c == '\n':
      return false
    if c == '\0':
      return false
    if ord(c) < 0x20 and c != '\t':
      return false
    if ord(c) == 0x7F:
      return false
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

proc isAllDigits(value: string): bool =
  if value.len == 0:
    return false
  for c in value:
    if c notin Digits:
      return false
  true

proc buildAuthorityHost(host: string, port: int): string =
  ## Build Host header authority form.
  let hostVal = host.strip()
  if hostVal.len == 0:
    raise newException(ValueError, "Invalid Host value")
  if not isValidHeaderValue(hostVal):
    raise newException(ValueError, "Invalid Host value")

  if port <= 0:
    return hostVal

  if hostVal[0] == '[':
    let closing = hostVal.find(']')
    if closing < 0:
      raise newException(ValueError, "Invalid Host value")
    if closing == hostVal.len - 1:
      return hostVal & ":" & $port
    if hostVal.len > closing + 2 and hostVal[closing + 1] == ':' and
       isAllDigits(hostVal[closing + 2 .. ^1]):
      return hostVal
    raise newException(ValueError, "Invalid Host value")

  var colonCount = 0
  for c in hostVal:
    if c == ':':
      inc colonCount
  if colonCount == 0:
    return hostVal & ":" & $port
  if colonCount == 1:
    let lastColon = hostVal.rfind(':')
    if lastColon >= 0 and lastColon + 1 < hostVal.len and
       isAllDigits(hostVal[lastColon + 1 .. ^1]):
      return hostVal
    raise newException(ValueError, "Invalid Host value")

  # Raw IPv6 literal without brackets.
  return "[" & hostVal & "]:" & $port

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

proc statusHasNoBody(statusCode: int): bool {.inline.} =
  (statusCode >= 100 and statusCode < 200) or statusCode == 204 or statusCode == 304

proc readChunkedBody(reader: BufferedReader): CpsFuture[string] {.cps.} =
  var bodyParts: seq[string]
  var trailerBytes = 0
  var trailerCount = 0
  while true:
    let sizeLine = await reader.readLine(maxLen = defaultMaxHeaderLineSize + 1)
    if sizeLine.len > defaultMaxHeaderLineSize:
      raise newException(ValueError, "Chunk metadata line too long")
    let semi = sizeLine.find(';')
    var sizeStr = sizeLine
    if semi >= 0:
      sizeStr = sizeLine[0 ..< semi]
    let token = sizeStr.strip()
    var chunkSize = 0
    if not parseHexChunkSize(token, chunkSize):
      raise newException(ValueError, "Invalid chunk size")
    if chunkSize == 0:
      # Consume trailers until empty line.
      while true:
        let trailerLine = await reader.readLine(maxLen = defaultMaxHeaderLineSize + 1)
        if trailerLine.len > defaultMaxHeaderLineSize:
          raise newException(ValueError, "Chunk trailer line too long")
        if trailerLine.len == 0:
          break
        inc trailerCount
        trailerBytes += trailerLine.len
        if trailerCount > defaultMaxHeaderCount or trailerBytes > defaultMaxHeaderBytes:
          raise newException(ValueError, "Chunk trailers too large")
        if trailerLine[0] == ' ' or trailerLine[0] == '\t':
          raise newException(ValueError, "Invalid chunk trailer line: " & trailerLine)
        let trailerColon = trailerLine.find(':')
        if trailerColon <= 0:
          raise newException(ValueError, "Invalid chunk trailer line: " & trailerLine)
        let trailerKey = trailerLine.substr(0, trailerColon - 1)
        if trailerKey != trailerKey.strip() or not isValidHeaderName(trailerKey):
          raise newException(ValueError, "Invalid chunk trailer line: " & trailerLine)
        let trailerVal = trailerLine[trailerColon + 1 .. ^1].strip()
        if not isValidHeaderValue(trailerVal):
          raise newException(ValueError, "Invalid chunk trailer line: " & trailerLine)
      break
    let data = await reader.readExact(chunkSize)
    bodyParts.add data
    let trailing = await reader.readExact(2)
    if trailing != "\r\n":
      raise newException(ValueError, "Invalid chunk delimiter")
  return bodyParts.join("")

proc sendRequest*(conn: Http1Connection, meth: string, path: string,
                  headers: seq[(string, string)] = @[],
                  body: string = ""): CpsVoidFuture =
  ## Send an HTTP/1.1 request.
  if not isValidHeaderName(meth):
    raise newException(ValueError, "Invalid HTTP method token")
  if path.len == 0:
    raise newException(ValueError, "Invalid HTTP request target")
  for c in path:
    # Disallow control chars, SP, and DEL in request-target.
    if ord(c) < 0x21 or ord(c) == 0x7F:
      raise newException(ValueError, "Invalid HTTP request target")
  if '\r' in conn.host or '\n' in conn.host:
    raise newException(ValueError, "Invalid Host value")

  var req = meth & " " & path & " HTTP/1.1\r\n"

  var hasContentLength = false
  var parsedContentLength = 0
  var hasConnection = false
  var hasHost = false
  for (k, v) in headers:
    if not isValidHeaderName(k):
      raise newException(ValueError, "Invalid request header name")
    if not isValidHeaderValue(v):
      raise newException(ValueError, "Invalid request header value")
    req &= k & ": " & v & "\r\n"
    let keyLower = k.toLowerAscii
    if keyLower == "content-length":
      var parsedLen = 0
      if not parseContentLengthValue(v.strip(), parsedLen):
        raise newException(ValueError, "Invalid Content-Length header")
      if hasContentLength and parsedLen != parsedContentLength:
        raise newException(ValueError, "Conflicting Content-Length header values")
      hasContentLength = true
      parsedContentLength = parsedLen
    elif keyLower == "transfer-encoding":
      raise newException(ValueError, "Unsupported request Transfer-Encoding header")
    if keyLower == "connection":
      hasConnection = true
    if keyLower == "host":
      if v.strip().len == 0:
        raise newException(ValueError, "Invalid Host value")
      hasHost = true

  if hasContentLength and parsedContentLength != body.len:
    raise newException(ValueError, "Content-Length does not match request body size")

  if not hasHost:
    req &= "Host: " & buildAuthorityHost(conn.host, conn.port) & "\r\n"

  if body.len > 0 and not hasContentLength:
    req &= "Content-Length: " & $body.len & "\r\n"

  if not hasConnection:
    req &= "Connection: keep-alive\r\n"

  req &= "\r\n"

  if body.len > 0:
    req &= body

  conn.stream.write(req)

proc recvResponse*(conn: Http1Connection, skipBody: bool = false): CpsFuture[HttpResponse] {.cps.} =
  ## Receive an HTTP/1.1 response.
  var interimCount = 0
  while true:
    var resp = HttpResponse()

    # Parse status line
    let statusLine = await conn.reader.readLine(maxLen = defaultMaxStatusLineSize + 1)
    if statusLine.len > defaultMaxStatusLineSize:
      raise newException(ValueError, "HTTP status line too long")
    if statusLine.len == 0:
      raise newException(ValueError, "Invalid HTTP status line: " & statusLine)
    let parts = statusLine.split(' ', 2)
    if parts.len < 2:
      raise newException(ValueError, "Invalid HTTP status line: " & statusLine)
    resp.httpVersion = parts[0]  # e.g. "HTTP/1.0" or "HTTP/1.1"
    if resp.httpVersion != "HTTP/1.1" and resp.httpVersion != "HTTP/1.0":
      raise newException(ValueError, "Invalid HTTP status line: " & statusLine)
    if parts[1].len != 3:
      raise newException(ValueError, "Invalid HTTP status line: " & statusLine)
    for c in parts[1]:
      if c notin Digits:
        raise newException(ValueError, "Invalid HTTP status line: " & statusLine)
    resp.statusCode = parseInt(parts[1])
    if resp.statusCode < 100 or resp.statusCode > 999:
      raise newException(ValueError, "Invalid HTTP status line: " & statusLine)
    if parts.len > 2:
      resp.statusMessage = parts[2]

    # Read headers
    var parsedContentLength = 0
    var sawContentLength = false
    var transferEncoding = ""
    var headerCount = 0
    var totalHeaderBytes = 0
    while true:
      let line = await conn.reader.readLine(maxLen = defaultMaxHeaderLineSize + 1)
      if line.len > defaultMaxHeaderLineSize:
        raise newException(ValueError, "HTTP response headers too large")
      if line == "":
        break
      inc headerCount
      totalHeaderBytes += line.len
      if headerCount > defaultMaxHeaderCount or totalHeaderBytes > defaultMaxHeaderBytes:
        raise newException(ValueError, "HTTP response headers too large")
      if line[0] == ' ' or line[0] == '\t':
        raise newException(ValueError, "Invalid HTTP header line: " & line)
      let colonPos = line.find(':')
      if colonPos <= 0:
        raise newException(ValueError, "Invalid HTTP header line: " & line)
      let key = line.substr(0, colonPos - 1)
      if key != key.strip() or not isValidHeaderName(key):
        raise newException(ValueError, "Invalid HTTP header line: " & line)
      let val = line[colonPos + 1 .. ^1].strip()
      if not isValidHeaderValue(val):
        raise newException(ValueError, "Invalid HTTP header line: " & line)
      let keyLower = key.toLowerAscii
      if keyLower == "content-length":
        var parsedLen = 0
        if not parseContentLengthValue(val, parsedLen):
          raise newException(ValueError, "Invalid Content-Length header")
        if sawContentLength and parsedLen != parsedContentLength:
          raise newException(ValueError, "Conflicting Content-Length header values")
        sawContentLength = true
        parsedContentLength = parsedLen
      elif keyLower == "transfer-encoding":
        if transferEncoding.len > 0:
          transferEncoding.add(",")
        transferEncoding.add(val)
      resp.headers.add (key, val)

    # Skip informational responses (e.g. 100 Continue) and continue reading the final response.
    if resp.statusCode >= 100 and resp.statusCode < 200 and resp.statusCode != 101:
      if transferEncoding.len > 0 and sawContentLength:
        raise newException(ValueError, "Response cannot include both Content-Length and Transfer-Encoding")
      if transferEncoding.len > 0:
        var teTokens: seq[string]
        if not parseTransferEncodingTokens(transferEncoding, teTokens):
          raise newException(ValueError, "Unsupported Transfer-Encoding header")
        discard await readChunkedBody(conn.reader)
      elif sawContentLength and parsedContentLength > 0:
        discard await conn.reader.readExact(parsedContentLength)
      inc interimCount
      if interimCount > 8:
        raise newException(ValueError, "Too many informational HTTP responses")
      continue

    # Read body for final response.
    let responseCloses = headersHaveToken(resp.headers, "connection", "close")
    var bodyStr = ""
    if skipBody or statusHasNoBody(resp.statusCode):
      discard
    elif transferEncoding.len > 0:
      if sawContentLength:
        raise newException(ValueError, "Response cannot include both Content-Length and Transfer-Encoding")
      var teTokens: seq[string]
      if not parseTransferEncodingTokens(transferEncoding, teTokens):
        raise newException(ValueError, "Unsupported Transfer-Encoding header")
      bodyStr = await readChunkedBody(conn.reader)
    elif sawContentLength:
      let cl = parsedContentLength
      if cl > 0:
        bodyStr = await conn.reader.readExact(cl)
    elif resp.httpVersion == "HTTP/1.0" or responseCloses:
      var bodyParts: seq[string]
      while true:
        let chunk = await conn.reader.read(8192)
        if chunk.len == 0:
          break
        bodyParts.add chunk
      bodyStr = bodyParts.join("")
    else:
      raise newException(ValueError, "HTTP/1.1 response missing Content-Length or Transfer-Encoding")

    resp.body = bodyStr
    return resp

proc request*(conn: Http1Connection, meth: string, path: string,
              headers: seq[(string, string)] = @[],
              body: string = ""): CpsFuture[HttpResponse] {.cps.} =
  ## Send a request and receive the response.
  await sendRequest(conn, meth, path, headers, body)
  return await recvResponse(conn, skipBody = meth.toUpperAscii == "HEAD")
