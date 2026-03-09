## BEP 19: HTTP/FTP Seeding (GetRight-style).
##
## Supports downloading pieces from HTTP/FTP URLs specified in the torrent.
## Two styles:
## - BEP 19 (GetRight): url-list in metainfo, use HTTP range requests
## - BEP 17 (Hoffman): httpseeds in metainfo, use custom HTTP protocol
## We implement BEP 19 (GetRight) style.

import std/[strutils, uri]
import ../runtime
import ../transform
import ../eventloop
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
    ## One HTTP byte-range request mapped into a piece offset.
    url*: string
    rangeStart*: int64
    rangeEnd*: int64
    pieceOffset*: int

proc newWebSeed*(url: string): WebSeed =
  WebSeed(url: url, state: wssIdle)

proc singleFileWebSeedUrl(baseUrl: string, filePath: string): string =
  ## For BEP 19 single-file torrents, some `url-list` entries point to a
  ## directory root. If so, append the file name/path.
  ##
  ## - `https://host/path/file.iso` -> unchanged
  ## - `https://host/path/`         -> append `filePath`
  ## - `https://host`               -> append `filePath`
  let encodedPath = encodeUrl(filePath, usePlus = false)
  try:
    let parsed = parseUri(baseUrl)
    if parsed.path.len == 0 or parsed.path.endsWith("/"):
      let slash = if baseUrl.endsWith("/"): "" else: "/"
      return baseUrl & slash & encodedPath
  except CatchableError:
    discard
  result = baseUrl

proc buildRangeUrl*(baseUrl: string, info: TorrentInfo,
                    pieceIdx: int, offset: int, length: int): tuple[url: string, rangeStart: int64, rangeEnd: int64] =
  ## Build the URL and byte range for an HTTP range request.
  ## For single-file torrents: URL is baseUrl, range maps directly.
  ## For multi-file torrents: URL is baseUrl/filepath, range within that file.
  let globalStart = int64(pieceIdx) * int64(info.pieceLength) + int64(offset)
  let globalEnd = globalStart + int64(length) - 1

  if info.files.len == 1:
    # Single file - direct file URL or directory URL (append file path).
    result.url = singleFileWebSeedUrl(baseUrl, info.files[0].path)
    result.rangeStart = globalStart
    result.rangeEnd = globalEnd
  else:
    # Multi-file - find which file(s) this range falls into
    # For simplicity, handle the case where range falls in a single file
    var fileStart: int64 = 0
    for fe in info.files:
      let fileEnd = fileStart + fe.length - 1
      if globalStart >= fileStart and globalStart <= fileEnd:
        let trailingSlash = if baseUrl.endsWith("/"): "" else: "/"
        # URL-encode each path component but preserve / separators
        var encodedParts: seq[string]
        for part in fe.path.split('/'):
          encodedParts.add(encodeUrl(part, usePlus = false))
        result.url = baseUrl & trailingSlash & encodedParts.join("/")
        result.rangeStart = globalStart - fileStart
        result.rangeEnd = min(globalEnd, fileEnd) - fileStart
        return
      fileStart += fe.length
    # Range is past all files
    raise newException(WebSeedError, "range outside file boundaries")

proc buildPieceRanges*(baseUrl: string, info: TorrentInfo,
                       pieceIdx: int, pieceLength: int,
                       maxChunk: int = 16384): seq[WebSeedRange] =
  ## Build byte-range requests that fully cover a piece.
  ## This handles multi-file torrents where a piece spans file boundaries.
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
    result.add(WebSeedRange(
      url: rr.url,
      rangeStart: rr.rangeStart,
      rangeEnd: rr.rangeEnd,
      pieceOffset: pieceOffset
    ))
    pieceOffset += actualLen

proc readHttpBody(reader: BufferedReader, contentLength: int): CpsFuture[string] {.cps.} =
  if contentLength >= 0:
    return await reader.readExact(contentLength)
  var data = reader.drainBuffer()
  while not reader.atEof:
    let chunk = await reader.stream.read(16384)
    if chunk.len == 0:
      break
    data.add(chunk)
  return data

proc httpRangeRequest*(url: string, rangeStart: int64, rangeEnd: int64): CpsFuture[string] {.cps.} =
  ## Fetch a byte range from an HTTP URL.
  let parsed: Uri = parseUri(url)
  let scheme: string = parsed.scheme.toLowerAscii()
  let host: string = parsed.hostname
  if host.len == 0:
    raise newException(WebSeedError, "missing host in webseed URL")
  if scheme.len > 0 and scheme notin ["http", "https"]:
    raise newException(WebSeedError, "unsupported scheme: " & scheme)
  let useTls = scheme == "https"
  let port: int = if parsed.port.len > 0:
      parseInt(parsed.port)
    elif useTls:
      443
    else:
      80
  let path: string = if parsed.path.len > 0: parsed.path else: "/"
  let query: string = if parsed.query.len > 0: path & "?" & parsed.query else: path

  let tcpStream: TcpStream = await tcpConnect(host, port)
  var stream: AsyncStream = tcpStream.AsyncStream
  var tlsStream: tls.TlsStream = nil
  if useTls:
    tlsStream = tls.newTlsStream(tcpStream, host, @["http/1.1"])
    await tls.tlsConnect(tlsStream)
    stream = tlsStream.AsyncStream

  let rangeHeader: string = "bytes=" & $rangeStart & "-" & $rangeEnd
  let httpReq: string = "GET " & query & " HTTP/1.1\r\n" &
                        "Host: " & host & "\r\n" &
                        "Range: " & rangeHeader & "\r\n" &
                        "Accept-Encoding: identity\r\n" &
                        "Connection: close\r\n\r\n"
  await stream.write(httpReq)

  let reader: BufferedReader = newBufferedReader(stream, 65536)

  # Read status line
  let statusLine: string = await reader.readLine("\r\n")
  if not statusLine.startsWith("HTTP/"):
    stream.close()
    raise newException(WebSeedError, "invalid HTTP response")

  let parts: seq[string] = statusLine.split(' ', 2)
  if parts.len < 2:
    stream.close()
    raise newException(WebSeedError, "malformed status line")
  let statusStr: string = parts[1]
  let statusCode: int = parseInt(statusStr)

  # Read headers
  var contentLength: int = -1
  while true:
    let line: string = await reader.readLine("\r\n")
    if line.len == 0:
      break
    let colonIdx: int = line.find(':')
    if colonIdx > 0:
      let name: string = line[0 ..< colonIdx].strip().toLowerAscii()
      let value: string = line[colonIdx+1..^1].strip()
      if name == "content-length":
        contentLength = parseInt(value)

  let expectedLen: int = int(rangeEnd - rangeStart + 1)
  let respBody: string = await readHttpBody(reader, contentLength)
  stream.close()

  if statusCode == 206:
    if respBody.len != expectedLen:
      raise newException(WebSeedError, "short HTTP 206 body")
    return respBody

  if statusCode == 200:
    if rangeStart == 0 and respBody.len >= expectedLen:
      return respBody[0 ..< expectedLen]
    let needEnd = int(rangeEnd)
    if rangeStart >= 0 and needEnd < respBody.len:
      return respBody[int(rangeStart) .. needEnd]
    raise newException(WebSeedError, "HTTP 200 did not include requested range")

  raise newException(WebSeedError, "HTTP " & $statusCode)

proc parseWebSeeds*(metainfo: TorrentMetainfo): seq[string] =
  ## Extract web seed URLs from torrent metainfo.
  ## Looks for "url-list" key in the root dictionary.
  ## Can be a single string or a list of strings.
  # Note: The url-list is stored during torrent parsing
  # For now, return the stored list
  return metainfo.urlList
