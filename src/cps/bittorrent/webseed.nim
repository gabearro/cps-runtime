## BEP 19: HTTP/FTP Seeding (GetRight-style).
##
## Supports downloading pieces from HTTP/FTP URLs specified in the torrent.
## We implement BEP 19 (GetRight) style: url-list in metainfo, HTTP range requests.
##
## API:
##   httpRangeRequest(url, start, end) — one-shot range fetch (opens + closes connection)
##   openWebSeedConn(url) / fetchRange(conn, ...) / close(conn) — persistent connection

import std/[strutils, uri]
import ../runtime
import ../transform
import ../io/streams
import ../io/tcp
import ../io/buffered
import ../tls/client as tls
import metainfo

type
  WebSeedError* = object of CatchableError

  WebSeedState* = enum
    wssIdle
    wssDownloading
    wssFailed

  WebSeed* = ref object
    url*: string
    state*: WebSeedState
    failCount*: int
    lastError*: string

  WebSeedRange* = object
    ## A single HTTP byte-range request mapped to a piece offset.
    url*: string
    rangeStart*: int64
    rangeEnd*: int64
    pieceOffset*: int

  WebSeedConn* = ref object
    ## Persistent HTTP/1.1 connection to a web seed host.
    ## Use for downloading multiple ranges without reconnecting.
    stream*: AsyncStream
    reader: BufferedReader
    host: string
    closed*: bool

proc newWebSeed*(url: string): WebSeed =
  WebSeed(url: url, state: wssIdle)

# ------------------------------------------------------------------
# URL helpers
# ------------------------------------------------------------------

proc appendPath(baseUrl, encodedPath: string): string {.inline.} =
  ## Append an already-encoded path to a base URL, adding '/' if needed.
  if baseUrl.endsWith("/"):
    baseUrl & encodedPath
  else:
    baseUrl & "/" & encodedPath

proc encodePathComponents(path: string): string =
  ## URL-encode each path component, preserving '/' separators.
  var first = true
  for part in path.split('/'):
    if not first: result.add('/')
    result.add(encodeUrl(part, usePlus = false))
    first = false

proc singleFileWebSeedUrl(baseUrl, filePath: string): string =
  ## For single-file torrents, append file name if the base URL is a directory.
  let parsed = parseUri(baseUrl)
  if parsed.path.len == 0 or parsed.path.endsWith("/"):
    appendPath(baseUrl, encodeUrl(filePath, usePlus = false))
  else:
    baseUrl

# ------------------------------------------------------------------
# Range URL building
# ------------------------------------------------------------------

proc buildRangeUrl*(baseUrl: string, info: TorrentInfo,
                    pieceIdx, offset, length: int): WebSeedRange =
  ## Map a piece+offset+length to a URL and HTTP byte range.
  ## Single-file: range over the whole file.
  ## Multi-file: range within the file containing the offset.
  let globalStart = int64(pieceIdx) * int64(info.pieceLength) + int64(offset)
  let globalEnd = globalStart + int64(length) - 1

  if info.files.len == 1:
    return WebSeedRange(
      url: singleFileWebSeedUrl(baseUrl, info.files[0].path),
      rangeStart: globalStart,
      rangeEnd: globalEnd,
      pieceOffset: offset)

  var fileStart: int64 = 0
  for fe in info.files:
    let fileEnd = fileStart + fe.length - 1
    if globalStart >= fileStart and globalStart <= fileEnd:
      return WebSeedRange(
        url: appendPath(baseUrl, encodePathComponents(fe.path)),
        rangeStart: globalStart - fileStart,
        rangeEnd: min(globalEnd, fileEnd) - fileStart,
        pieceOffset: offset)
    fileStart += fe.length
  raise newException(WebSeedError, "range outside file boundaries")

proc buildPieceRanges*(baseUrl: string, info: TorrentInfo,
                       pieceIdx, pieceLength: int,
                       maxChunk: int = 16384): seq[WebSeedRange] =
  ## Build byte-range requests covering an entire piece.
  ## Handles multi-file torrents where a piece spans file boundaries.
  if pieceLength <= 0:
    return @[]
  if maxChunk <= 0:
    raise newException(WebSeedError, "invalid maxChunk")

  var pieceOffset = 0
  while pieceOffset < pieceLength:
    let reqLen = min(maxChunk, pieceLength - pieceOffset)
    let rr = buildRangeUrl(baseUrl, info, pieceIdx, pieceOffset, reqLen)
    let actualLen = int(rr.rangeEnd - rr.rangeStart + 1)
    if actualLen <= 0:
      raise newException(WebSeedError, "empty range for piece request")
    result.add(rr)
    pieceOffset += actualLen

# ------------------------------------------------------------------
# HTTP connection
# ------------------------------------------------------------------

type
  ParsedUrl = tuple[host: string, port: int, useTls: bool, requestPath: string]

proc parseUrl(url: string): ParsedUrl =
  let parsed = parseUri(url)
  let scheme = parsed.scheme.toLowerAscii()
  if parsed.hostname.len == 0:
    raise newException(WebSeedError, "missing host in URL: " & url)
  if scheme.len > 0 and scheme notin ["http", "https"]:
    raise newException(WebSeedError, "unsupported scheme: " & scheme)
  let useTls = scheme == "https"
  let port = if parsed.port.len > 0: parseInt(parsed.port)
             elif useTls: 443
             else: 80
  let path = if parsed.path.len > 0: parsed.path else: "/"
  let requestPath = if parsed.query.len > 0: path & "?" & parsed.query else: path
  (parsed.hostname, port, useTls, requestPath)

proc openWebSeedConn*(url: string): CpsFuture[WebSeedConn] {.cps.} =
  ## Open a persistent HTTP/1.1 connection to the web seed host.
  let pu: ParsedUrl = parseUrl(url)
  let tcpStream: TcpStream = await tcpConnect(pu.host, pu.port)
  var stream: AsyncStream = tcpStream.AsyncStream
  if pu.useTls:
    let tlsStream: tls.TlsStream = tls.newTlsStream(tcpStream, pu.host, @["http/1.1"])
    await tls.tlsConnect(tlsStream)
    stream = tlsStream.AsyncStream
  return WebSeedConn(
    stream: stream,
    reader: newBufferedReader(stream, 65536),
    host: pu.host)

proc close*(conn: WebSeedConn) =
  ## Close the web seed connection.
  if not conn.closed:
    conn.closed = true
    conn.stream.close()

proc parseStatusCode(statusLine: string): int =
  ## Extract status code from an HTTP status line without allocating a seq.
  let spaceIdx = statusLine.find(' ')
  if spaceIdx < 0:
    raise newException(WebSeedError, "malformed status line")
  let codeStart = spaceIdx + 1
  let secondSpace = statusLine.find(' ', codeStart)
  let codeEnd = if secondSpace > 0: secondSpace else: statusLine.len
  parseInt(statusLine[codeStart ..< codeEnd])

proc fetchRange*(conn: WebSeedConn, url: string,
                 rangeStart, rangeEnd: int64): CpsFuture[string] {.cps.} =
  ## Fetch a byte range over a persistent connection (HTTP/1.1 keep-alive).
  let pu: ParsedUrl = parseUrl(url)
  let httpReq: string = "GET " & pu.requestPath & " HTTP/1.1\r\n" &
                "Host: " & conn.host & "\r\n" &
                "Range: bytes=" & $rangeStart & "-" & $rangeEnd & "\r\n" &
                "Accept-Encoding: identity\r\n\r\n"
  await conn.stream.write(httpReq)

  # Parse status line
  let statusLine: string = await conn.reader.readLine("\r\n")
  if not statusLine.startsWith("HTTP/"):
    raise newException(WebSeedError, "invalid HTTP response")
  let statusCode: int = parseStatusCode(statusLine)

  # Parse headers
  var contentLength: int = -1
  var connectionClose: bool = false
  while true:
    let line: string = await conn.reader.readLine("\r\n")
    if line.len == 0:
      break
    let colonIdx: int = line.find(':')
    if colonIdx > 0:
      let name: string = line[0 ..< colonIdx].strip().toLowerAscii()
      let value: string = line[colonIdx + 1 .. ^1].strip()
      case name
      of "content-length":
        contentLength = parseInt(value)
      of "connection":
        connectionClose = value.toLowerAscii() == "close"
      else: discard

  let expectedLen: int = int(rangeEnd - rangeStart + 1)

  # Guard against OOM: if server ignores Range and returns a huge 200 body
  if statusCode == 200 and contentLength > expectedLen * 100 and contentLength > 10_000_000:
    conn.closed = true
    raise newException(WebSeedError,
      "server returned full body (" & $contentLength & " bytes), range requests not supported")

  # Read body
  var body: string
  if contentLength >= 0:
    body = await conn.reader.readExact(contentLength)
  elif connectionClose:
    body = conn.reader.drainBuffer()
    while not conn.reader.atEof:
      let chunk: string = await conn.reader.stream.read(16384)
      if chunk.len == 0: break
      body.add(chunk)
    conn.closed = true
  else:
    raise newException(WebSeedError, "no Content-Length on keep-alive response")

  if connectionClose:
    conn.closed = true

  # Validate response
  case statusCode
  of 206:
    if body.len != expectedLen:
      raise newException(WebSeedError,
        "short HTTP 206 body: got " & $body.len & ", expected " & $expectedLen)
    return body
  of 200:
    let start: int = int(rangeStart)
    if start + expectedLen <= body.len:
      return body[start ..< start + expectedLen]
    raise newException(WebSeedError, "HTTP 200 body too short for requested range")
  of 301, 302, 303, 307, 308:
    raise newException(WebSeedError, "HTTP redirect " & $statusCode & " (not followed)")
  else:
    raise newException(WebSeedError, "HTTP " & $statusCode)

proc httpRangeRequest*(url: string, rangeStart, rangeEnd: int64): CpsFuture[string] {.cps.} =
  ## One-shot HTTP byte-range request. Opens a connection, fetches, closes.
  ## For multiple requests to the same host, use openWebSeedConn + fetchRange.
  let conn: WebSeedConn = await openWebSeedConn(url)
  var data: string = ""
  var error: string = ""
  try:
    data = await fetchRange(conn, url, rangeStart, rangeEnd)
  except CatchableError as e:
    error = e.msg
  conn.close()
  if error.len > 0:
    raise newException(WebSeedError, error)
  return data

proc parseWebSeeds*(metainfo: TorrentMetainfo): seq[string] =
  ## Extract web seed URLs from torrent metainfo (url-list).
  metainfo.urlList
