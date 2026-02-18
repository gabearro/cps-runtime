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

proc getHeader*(resp: HttpResponse, name: string): string =
  for (k, v) in resp.headers:
    if k.toLowerAscii == name.toLowerAscii:
      return v
  return ""

proc sendRequest*(conn: Http1Connection, meth: string, path: string,
                  headers: seq[(string, string)] = @[],
                  body: string = ""): CpsVoidFuture =
  ## Send an HTTP/1.1 request.
  var req = meth & " " & path & " HTTP/1.1\r\n"
  req &= "Host: " & conn.host & "\r\n"

  var hasContentLength = false
  var hasConnection = false
  for (k, v) in headers:
    req &= k & ": " & v & "\r\n"
    if k.toLowerAscii == "content-length":
      hasContentLength = true
    if k.toLowerAscii == "connection":
      hasConnection = true

  if body.len > 0 and not hasContentLength:
    req &= "Content-Length: " & $body.len & "\r\n"

  if not hasConnection:
    req &= "Connection: keep-alive\r\n"

  req &= "\r\n"

  if body.len > 0:
    req &= body

  conn.stream.write(req)

proc recvResponse*(conn: Http1Connection): CpsFuture[HttpResponse] {.cps.} =
  ## Receive an HTTP/1.1 response.
  var resp = HttpResponse()

  # Parse status line
  let statusLine = await conn.reader.readLine()
  let parts = statusLine.split(' ', 2)
  if parts.len < 2:
    raise newException(ValueError, "Invalid HTTP status line: " & statusLine)
  resp.httpVersion = parts[0]  # e.g. "HTTP/1.0" or "HTTP/1.1"
  resp.statusCode = parseInt(parts[1])
  if parts.len > 2:
    resp.statusMessage = parts[2]

  # Read headers
  while true:
    let line = await conn.reader.readLine()
    if line == "":
      break
    let colonPos = line.find(':')
    if colonPos > 0:
      let key = line[0 ..< colonPos].strip()
      let val = line[colonPos + 1 .. ^1].strip()
      resp.headers.add (key, val)

  # Read body
  let contentLength = resp.getHeader("content-length")
  let transferEncoding = resp.getHeader("transfer-encoding")
  let connection = resp.getHeader("connection")

  var bodyStr = ""
  if transferEncoding.toLowerAscii == "chunked":
    var bodyParts: seq[string]
    while true:
      let sizeLine = await conn.reader.readLine()
      let sizeStr = sizeLine.strip().split(';')[0].strip()
      let chunkSize = parseHexInt(sizeStr)
      if chunkSize == 0:
        discard await conn.reader.readLine()  # trailing CRLF
        break
      let data = await conn.reader.readExact(chunkSize)
      bodyParts.add data
      discard await conn.reader.readLine()  # chunk-trailing CRLF
    bodyStr = bodyParts.join("")
  elif contentLength != "":
    let cl = parseInt(contentLength)
    if cl > 0:
      bodyStr = await conn.reader.readExact(cl)
  elif connection.toLowerAscii == "close":
    var bodyParts: seq[string]
    while true:
      let chunk = await conn.reader.read(8192)
      if chunk.len == 0:
        break
      bodyParts.add chunk
    bodyStr = bodyParts.join("")

  resp.body = bodyStr
  return resp

proc request*(conn: Http1Connection, meth: string, path: string,
              headers: seq[(string, string)] = @[],
              body: string = ""): CpsFuture[HttpResponse] {.cps.} =
  ## Send a request and receive the response.
  await sendRequest(conn, meth, path, headers, body)
  return await recvResponse(conn)
