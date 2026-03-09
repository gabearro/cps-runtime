## BitTorrent tracker client (BEP 3 HTTP/HTTPS, BEP 15 UDP).
##
## Announces to trackers and returns peer lists.

import std/[strutils, sets, uri, times, net, nativesockets]
import ../runtime
import ../transform
import ../eventloop
import ../io/streams
import ../io/tcp
import ../io/udp
import ../io/buffered
import ../io/dns
import ../io/timeouts
import ../tls/client as tls
import bencode
import metainfo
import utils

const
  MaxBodySize = 1_048_576  ## Max tracker response body size (1 MiB)

type
  TrackerPeer* = object
    ip*: string
    port*: uint16
    peerId*: array[20, byte]

  TrackerResponse* = object
    interval*: int             ## Re-announce interval in seconds
    minInterval*: int          ## Minimum re-announce interval
    trackerId*: string         ## Tracker session ID
    complete*: int             ## Seeders
    incomplete*: int           ## Leechers
    peers*: seq[TrackerPeer]
    warningMessage*: string
    failureReason*: string

  TrackerEvent* = enum
    teNone = ""
    teStarted = "started"
    teStopped = "stopped"
    teCompleted = "completed"

  AnnounceParams* = object
    infoHash*: array[20, byte]
    peerId*: array[20, byte]
    port*: uint16
    uploaded*: int64
    downloaded*: int64
    left*: int64
    event*: TrackerEvent
    compact*: bool
    numWant*: int

  TrackerError* = object of CatchableError
  TrackerRedirect* = object of CatchableError  ## HTTP→HTTPS redirect; msg = new URL
  HttpResponseHead = object
    statusCode: int
    contentLength: int
    location: string

proc defaultAnnounceParams*(info: TorrentInfo, peerId: array[20, byte],
                            listenPort: uint16): AnnounceParams =
  AnnounceParams(
    infoHash: info.infoHash,
    peerId: peerId,
    port: listenPort,
    uploaded: 0,
    downloaded: 0,
    left: info.totalLength,
    event: teStarted,
    compact: true,
    numWant: 200
  )

# HTTP tracker helpers
proc buildAnnounceUrl*(baseUrl: string, params: AnnounceParams): string =
  var url = baseUrl
  if '?' in url: url.add('&')
  else: url.add('?')

  url.add("info_hash=")
  url.add(infoHashUrlEncoded(TorrentInfo(infoHash: params.infoHash)))
  url.add("&peer_id=")
  for b in params.peerId:
    url.add('%')
    url.add(b.int.toHex(2).toUpperAscii())
  url.add("&port=" & $params.port)
  url.add("&uploaded=" & $params.uploaded)
  url.add("&downloaded=" & $params.downloaded)
  url.add("&left=" & $params.left)
  if params.compact:
    url.add("&compact=1")
  if params.numWant > 0:
    url.add("&numwant=" & $params.numWant)
  if params.event != teNone:
    url.add("&event=" & $params.event)
  url

proc parseCompactPeers*(data: string): seq[TrackerPeer] =
  ## Parse compact peer format (6 bytes per peer: 4 IP + 2 port).
  if data.len mod 6 != 0:
    raise newException(TrackerError, "compact peers not multiple of 6")
  let count = data.len div 6
  result = newSeq[TrackerPeer](count)
  for i in 0 ..< count:
    let offset = i * 6
    let ip = $data[offset].byte & "." & $data[offset+1].byte & "." &
             $data[offset+2].byte & "." & $data[offset+3].byte
    let port = (uint16(data[offset+4].byte) shl 8) or uint16(data[offset+5].byte)
    result[i] = TrackerPeer(ip: ip, port: port)

proc parseCompactPeers6*(data: string): seq[TrackerPeer] =
  ## Parse compact IPv6 peer format (BEP 7: 18 bytes per peer: 16 IP + 2 port).
  if data.len mod 18 != 0:
    raise newException(TrackerError, "compact peers6 not multiple of 18")
  let count = data.len div 18
  result = newSeq[TrackerPeer](count)
  for i in 0 ..< count:
    let offset = i * 18
    var parts: seq[string]
    for w in 0 ..< 8:
      let hi = data[offset + w*2].byte
      let lo = data[offset + w*2 + 1].byte
      let word = (uint16(hi) shl 8) or uint16(lo)
      parts.add(word.toHex(4).toLowerAscii())
    let ip = canonicalizeIpv6(parts.join(":"))
    let port = (uint16(data[offset+16].byte) shl 8) or uint16(data[offset+17].byte)
    result[i] = TrackerPeer(ip: ip, port: port)

proc parseDictPeers*(list: BencodeValue): seq[TrackerPeer] =
  ## Parse dictionary peer format.
  for entry in list.listVal:
    if entry.kind != bkDict: continue
    var peer: TrackerPeer
    let ipNode = entry.getOrDefault("ip")
    if ipNode != nil and ipNode.kind == bkStr:
      peer.ip = ipNode.strVal
    let portNode = entry.getOrDefault("port")
    if portNode != nil and portNode.kind == bkInt:
      peer.port = portNode.intVal.uint16
    let idNode = entry.getOrDefault("peer id")
    if idNode != nil and idNode.kind == bkStr and idNode.strVal.len == 20:
      copyMem(addr peer.peerId[0], unsafeAddr idNode.strVal[0], 20)
    result.add(peer)

proc parseTrackerResponse*(data: string): TrackerResponse =
  let root = decode(data)
  if root.kind != bkDict:
    raise newException(TrackerError, "tracker response not a dictionary")

  let failure = root.getOrDefault("failure reason")
  if failure != nil and failure.kind == bkStr:
    result.failureReason = failure.strVal
    return

  let warning = root.getOrDefault("warning message")
  if warning != nil and warning.kind == bkStr:
    result.warningMessage = warning.strVal

  let interval = root.getOrDefault("interval")
  if interval != nil and interval.kind == bkInt:
    result.interval = interval.intVal.int

  let minInterval = root.getOrDefault("min interval")
  if minInterval != nil and minInterval.kind == bkInt:
    result.minInterval = minInterval.intVal.int

  let trackerId = root.getOrDefault("tracker id")
  if trackerId != nil and trackerId.kind == bkStr:
    result.trackerId = trackerId.strVal

  let complete = root.getOrDefault("complete")
  if complete != nil and complete.kind == bkInt:
    result.complete = complete.intVal.int

  let incomplete = root.getOrDefault("incomplete")
  if incomplete != nil and incomplete.kind == bkInt:
    result.incomplete = incomplete.intVal.int

  let peers = root.getOrDefault("peers")
  if peers != nil:
    if peers.kind == bkStr:
      result.peers = parseCompactPeers(peers.strVal)
    elif peers.kind == bkList:
      result.peers = parseDictPeers(peers)

  # BEP 7: IPv6 compact peers
  let peers6 = root.getOrDefault("peers6")
  if peers6 != nil and peers6.kind == bkStr and peers6.strVal.len > 0:
    result.peers.add(parseCompactPeers6(peers6.strVal))

proc parseHttpResponseHead(headBlock: string): HttpResponseHead =
  ## Parse HTTP status line and headers from a block without trailing CRLFCRLF.
  if headBlock.len == 0:
    raise newException(TrackerError, "empty HTTP response headers")

  let lines = headBlock.split("\r\n")
  if lines.len == 0:
    raise newException(TrackerError, "missing HTTP status line")

  let statusLine = lines[0]
  if not statusLine.startsWith("HTTP/"):
    raise newException(TrackerError, "invalid HTTP response: " & statusLine)

  let parts = statusLine.split(' ', 2)
  if parts.len < 2:
    raise newException(TrackerError, "malformed status line")
  let statusPart = parts[1]
  try:
    result.statusCode = parseInt(statusPart)
  except ValueError:
    raise newException(TrackerError, "malformed status code: " & statusPart)

  result.contentLength = -1
  result.location = ""
  var i = 1
  while i < lines.len:
    let line = lines[i]
    inc i
    let colonIdx = line.find(':')
    if colonIdx <= 0:
      continue
    let name = line[0 ..< colonIdx].strip().toLowerAscii()
    let value = line[colonIdx+1 .. ^1].strip()
    if name == "content-length":
      try:
        result.contentLength = parseInt(value)
      except ValueError:
        discard
    elif name == "location":
      result.location = value

# Keep tracker CPS flows on copy semantics: large async environments carrying
# request/response strings across await points can alias under ARC sink moves.
# HTTP Tracker announce (using raw TCP, not httpclient to avoid circular deps)
proc httpAnnounce*(announceUrl: string, params: AnnounceParams): CpsFuture[TrackerResponse] {.cps, nosinks.} =
  let fullUrl: string = buildAnnounceUrl(announceUrl, params)
  let parsed: Uri = parseUri(fullUrl)

  let host: string = parsed.hostname
  let port: int = if parsed.port.len > 0: parseInt(parsed.port) else: 80
  let path: string = if parsed.path.len > 0: parsed.path else: "/"
  let query: string = if parsed.query.len > 0: path & "?" & parsed.query else: path

  # Try IPv4 first, fall back to IPv6 for dual-stack tracker support
  var stream: TcpStream
  var connectError: string = ""
  try:
    stream = await withTimeout(tcpConnect(host, port, AF_INET), 15000)
  except CatchableError as e:
    connectError = e.msg
  if connectError.len > 0:
    stream = await withTimeout(tcpConnect(host, port, AF_INET6), 15000)

  let httpReq: string = "GET " & query & " HTTP/1.1\r\nHost: " & host &
                "\r\nConnection: close\r\n\r\n"
  await stream.write(httpReq)

  let reader: BufferedReader = newBufferedReader(stream.AsyncStream, 16384)

  # Read status line
  let statusLine: string = await reader.readLine("\r\n")
  if not statusLine.startsWith("HTTP/"):
    raise newException(TrackerError, "invalid HTTP response: " & statusLine)

  let parts: seq[string] = statusLine.split(' ', 2)
  if parts.len < 2:
    raise newException(TrackerError, "malformed status line")
  let statusPart: string = parts[1]
  var statusCode: int = 0
  try:
    statusCode = parseInt(statusPart)
  except ValueError:
    stream.close()
    raise newException(TrackerError, "malformed status code: " & statusPart)

  # Read headers
  var contentLength: int = -1
  var location: string = ""
  while true:
    let line: string = await reader.readLine("\r\n")
    if line.len == 0:
      break
    let colonIdx: int = line.find(':')
    if colonIdx > 0:
      let name: string = line[0 ..< colonIdx].strip().toLowerAscii()
      let value: string = line[colonIdx+1..^1].strip()
      if name == "content-length":
        try:
          contentLength = parseInt(value)
        except ValueError:
          discard
      elif name == "location":
        location = value

  # Handle redirects (HTTP → HTTP only; HTTP → HTTPS handled by announce())
  if statusCode in [301, 302, 303, 307] and location.len > 0:
    stream.close()
    let redirectParsed: Uri = parseUri(location)
    if redirectParsed.scheme == "https":
      raise newException(TrackerRedirect, location)
    else:
      let resp: TrackerResponse = await httpAnnounce(location, params)
      return resp

  # Read body (max 1 MiB to prevent memory exhaustion)
  var body: string = ""
  if contentLength > 0:
    if contentLength > MaxBodySize:
      stream.close()
      raise newException(TrackerError, "tracker response too large: " & $contentLength)
    body = await reader.readExact(contentLength)
  else:
    while not reader.atEof and body.len < MaxBodySize:
      let chunk: string = await reader.read(8192)
      if chunk.len == 0: break
      body.add(chunk)

  stream.close()

  if statusCode != 200:
    raise newException(TrackerError, "tracker HTTP " & $statusCode & ": " & body)

  return parseTrackerResponse(body)

# HTTPS Tracker announce
proc httpsAnnounce*(announceUrl: string, params: AnnounceParams): CpsFuture[TrackerResponse] {.cps, nosinks.} =
  let fullUrl: string = buildAnnounceUrl(announceUrl, params)
  let parsed: Uri = parseUri(fullUrl)

  let host: string = parsed.hostname
  let port: int = if parsed.port.len > 0: parseInt(parsed.port) else: 443
  let path: string = if parsed.path.len > 0: parsed.path else: "/"
  let query: string = if parsed.query.len > 0: path & "?" & parsed.query else: path

  # Try IPv4 first, fall back to IPv6 for dual-stack tracker support
  var tcpStream: TcpStream
  var tcpConnectError: string = ""
  try:
    tcpStream = await withTimeout(tcpConnect(host, port, AF_INET), 15000)
  except CatchableError as e:
    tcpConnectError = e.msg
  if tcpConnectError.len > 0:
    tcpStream = await withTimeout(tcpConnect(host, port, AF_INET6), 15000)

  let tlsStream: TlsStream = newTlsStream(tcpStream, host, @["http/1.1"])
  var tlsConnectError: string = ""
  try:
    await withTimeout(tlsConnect(tlsStream), 15000)
  except CatchableError as e:
    tlsConnectError = e.msg
  if tlsConnectError.len > 0:
    tcpStream.close()
    raise newException(TrackerError, "TLS connect failed: " & tlsConnectError)

  let httpReq: string = "GET " & query & " HTTP/1.1\r\nHost: " & host &
                "\r\nConnection: close\r\n\r\n"
  await tlsStream.write(httpReq)

  let reader: BufferedReader = newBufferedReader(tlsStream.AsyncStream, 16384)

  # Read status line
  let statusLine: string = await reader.readLine("\r\n")
  if not statusLine.startsWith("HTTP/"):
    raise newException(TrackerError, "invalid HTTP response: " & statusLine)

  let parts: seq[string] = statusLine.split(' ', 2)
  if parts.len < 2:
    raise newException(TrackerError, "malformed status line")
  let statusPart: string = parts[1]
  var statusCode: int = 0
  try:
    statusCode = parseInt(statusPart)
  except ValueError:
    tlsStream.close()
    raise newException(TrackerError, "malformed status code: " & statusPart)

  # Read headers
  var contentLength: int = -1
  var location: string = ""
  while true:
    let line: string = await reader.readLine("\r\n")
    if line.len == 0:
      break
    let colonIdx: int = line.find(':')
    if colonIdx > 0:
      let name: string = line[0 ..< colonIdx].strip().toLowerAscii()
      let value: string = line[colonIdx+1..^1].strip()
      if name == "content-length":
        try:
          contentLength = parseInt(value)
        except ValueError:
          discard
      elif name == "location":
        location = value

  # Handle redirects
  if statusCode in [301, 302, 303, 307] and location.len > 0:
    tlsStream.close()
    # Follow redirect (recursive, one level)
    let redirectParsed: Uri = parseUri(location)
    if redirectParsed.scheme == "https":
      let resp: TrackerResponse = await httpsAnnounce(location, params)
      return resp
    else:
      let resp: TrackerResponse = await httpAnnounce(location, params)
      return resp

  # Read body (max 1 MiB to prevent memory exhaustion)
  var body: string = ""
  if contentLength > 0:
    if contentLength > MaxBodySize:
      tlsStream.close()
      raise newException(TrackerError, "tracker response too large: " & $contentLength)
    body = await reader.readExact(contentLength)
  else:
    while not reader.atEof and body.len < MaxBodySize:
      let chunk: string = await reader.read(8192)
      if chunk.len == 0: break
      body.add(chunk)

  tlsStream.close()

  if statusCode != 200:
    raise newException(TrackerError, "tracker HTTPS " & $statusCode & ": " & body)

  return parseTrackerResponse(body)

# UDP Tracker protocol (BEP 15)
const
  UdpConnectAction = 0'u32
  UdpAnnounceAction = 1'u32
  UdpScrapeAction = 2'u32
  UdpErrorAction = 3'u32
  UdpProtocolId = 0x41727101980'u64  # magic constant

proc udpAnnounce*(announceUrl: string, params: AnnounceParams): CpsFuture[TrackerResponse] {.cps, nosinks.} =
  let parsed: Uri = parseUri(announceUrl)
  let host: string = parsed.hostname
  let port: uint16 = if parsed.port.len > 0: parseInt(parsed.port).uint16 else: 6969'u16

  # Resolve hostname — try IPv4 first, fall back to IPv6
  var ips: seq[string] = await asyncResolve(host, Port(0), AF_INET)
  if ips.len == 0:
    ips = await asyncResolve(host, Port(0), AF_INET6)
  if ips.len == 0:
    raise newException(TrackerError, "DNS resolution failed for " & host)

  # Detect address family from resolved IP and create matching socket
  let trackerIsIpv6: bool = ':' in ips[0]
  let sockDomain: Domain = if trackerIsIpv6: AF_INET6 else: AF_INET
  let sock: UdpSocket = newUdpSocket(sockDomain)
  if trackerIsIpv6:
    sock.bindAddr("::", 0)
  else:
    sock.bindAddr("0.0.0.0", 0)

  # Use try/except + close + re-raise to ensure socket cleanup (CPS can't return inside try/finally)
  var udpError: string = ""
  var annRespData: string = ""
  var transId: uint32 = uint32(epochTime().int64 and 0xFFFFFFFF)
  try:

    # Step 1: Connect request
    var connectReq = newStringOfCap(16)
    connectReq.writeUint64BE(UdpProtocolId)
    connectReq.writeUint32BE(UdpConnectAction)
    connectReq.writeUint32BE(transId)

    await sock.sendToAddr(connectReq, ips[0], port.int)

    # Wait for connect response with timeout
    let connResp = await withTimeout(sock.recvFrom(65535), 10000)

    if connResp.data.len < 16:
      raise newException(TrackerError, "UDP connect response too short")

    let respAction = readUint32BE(connResp.data, 0)
    let respTransId = readUint32BE(connResp.data, 4)
    if respAction != UdpConnectAction or respTransId != transId:
      raise newException(TrackerError, "UDP connect response mismatch")

    let connectionId = readUint64BE(connResp.data, 8)

    # Step 2: Announce request
    transId = transId + 1
    var announceReq = newStringOfCap(98)
    announceReq.writeUint64BE(connectionId)
    announceReq.writeUint32BE(UdpAnnounceAction)
    announceReq.writeUint32BE(transId)
    # info_hash (20 bytes)
    for b in params.infoHash:
      announceReq.add(char(b))
    # peer_id (20 bytes)
    for b in params.peerId:
      announceReq.add(char(b))
    # downloaded (8 bytes)
    announceReq.writeUint64BE(uint64(params.downloaded))
    # left (8 bytes)
    announceReq.writeUint64BE(uint64(params.left))
    # uploaded (8 bytes)
    announceReq.writeUint64BE(uint64(params.uploaded))
    # event (4 bytes)
    let eventCode: uint32 = case params.event
      of teNone: 0
      of teCompleted: 1
      of teStopped: 3
      of teStarted: 2
    announceReq.writeUint32BE(eventCode)
    # ip address (4 bytes, 0 = default)
    announceReq.writeUint32BE(0)
    # key (4 bytes, random)
    announceReq.writeUint32BE(uint32(epochTime().int64 and 0xFFFFFFFF) xor 0xDEADBEEF'u32)
    # num_want (4 bytes)
    announceReq.writeInt32BE(int32(params.numWant))
    # port (2 bytes)
    announceReq.add(char((params.port shr 8).byte))
    announceReq.add(char((params.port and 0xFF).byte))

    await sock.sendToAddr(announceReq, ips[0], port.int)

    let annResp = await withTimeout(sock.recvFrom(65535), 10000)
    annRespData = annResp.data
  except CatchableError as e:
    udpError = e.msg
  sock.close()
  if udpError.len > 0:
    raise newException(TrackerError, udpError)

  if annRespData.len < 20:
    raise newException(TrackerError, "UDP announce response too short")

  let annAction = readUint32BE(annRespData, 0)
  let annTransId = readUint32BE(annRespData, 4)

  if annAction == UdpErrorAction:
    let errMsg: string = if annRespData.len > 8: annRespData[8..^1] else: "unknown error"
    raise newException(TrackerError, "UDP tracker error: " & errMsg)

  if annAction != UdpAnnounceAction or annTransId != transId:
    raise newException(TrackerError, "UDP announce response mismatch")

  var resp: TrackerResponse
  resp.interval = readInt32BE(annRespData, 8).int
  resp.incomplete = readInt32BE(annRespData, 12).int  # leechers
  resp.complete = readInt32BE(annRespData, 16).int     # seeders

  # Parse compact peers from remaining data
  let peersData: string = annRespData[20..^1]
  resp.peers = parseCompactPeers(peersData)
  return resp

# ============================================================
# Scrape (BEP 48)
# ============================================================

type
  ScrapeInfo* = object
    complete*: int       ## Number of seeders
    incomplete*: int     ## Number of leechers
    downloaded*: int     ## Number of completed downloads

proc announceToScrapeUrl*(announceUrl: string): string =
  ## Derive scrape URL from announce URL by replacing last "announce" with "scrape".
  let idx = announceUrl.rfind("announce")
  if idx < 0:
    raise newException(TrackerError, "cannot derive scrape URL: no 'announce' in " & announceUrl)
  result = announceUrl[0 ..< idx] & "scrape" & announceUrl[idx + 8 .. ^1]

proc parseScrapeResponse*(data: string, infoHash: array[20, byte]): ScrapeInfo =
  let root = decode(data)
  if root.kind != bkDict:
    raise newException(TrackerError, "scrape response not a dictionary")
  let failure = root.getOrDefault("failure reason")
  if failure != nil and failure.kind == bkStr:
    raise newException(TrackerError, "scrape failed: " & failure.strVal)
  let files = root.getOrDefault("files")
  if files == nil or files.kind != bkDict:
    raise newException(TrackerError, "scrape response missing 'files' dict")
  let hashStr = newString(20)
  copyMem(addr hashStr[0], unsafeAddr infoHash[0], 20)
  let entry = files.getOrDefault(hashStr)
  if entry == nil or entry.kind != bkDict:
    raise newException(TrackerError, "scrape: info_hash not found in response")
  let c = entry.getOrDefault("complete")
  if c != nil and c.kind == bkInt: result.complete = c.intVal.int
  let i = entry.getOrDefault("incomplete")
  if i != nil and i.kind == bkInt: result.incomplete = i.intVal.int
  let d = entry.getOrDefault("downloaded")
  if d != nil and d.kind == bkInt: result.downloaded = d.intVal.int

proc httpScrape*(announceUrl: string, infoHash: array[20, byte]): CpsFuture[ScrapeInfo] {.cps, nosinks.} =
  let scrapeBase: string = announceToScrapeUrl(announceUrl)
  var url: string = scrapeBase
  if '?' in url: url.add('&')
  else: url.add('?')
  url.add("info_hash=")
  url.add(infoHashUrlEncoded(TorrentInfo(infoHash: infoHash)))

  let parsed: Uri = parseUri(url)
  let host: string = parsed.hostname
  let port: int = if parsed.port.len > 0: parseInt(parsed.port) else: 80
  let path: string = if parsed.path.len > 0: parsed.path else: "/"
  let query: string = if parsed.query.len > 0: path & "?" & parsed.query else: path

  let stream: TcpStream = await withTimeout(tcpConnect(host, port), 15000)
  let httpReq: string = "GET " & query & " HTTP/1.1\r\nHost: " & host &
                "\r\nConnection: close\r\n\r\n"
  await stream.write(httpReq)
  let reader: BufferedReader = newBufferedReader(stream.AsyncStream, 16384)

  let statusLine: string = await reader.readLine("\r\n")
  if not statusLine.startsWith("HTTP/"):
    raise newException(TrackerError, "invalid HTTP response: " & statusLine)
  let statusParts: seq[string] = statusLine.split(' ', 2)
  if statusParts.len < 2:
    raise newException(TrackerError, "malformed status line")
  let statusCode: int = parseInt(statusParts[1])

  var contentLength: int = -1
  while true:
    let line: string = await reader.readLine("\r\n")
    if line.len == 0: break
    let colonIdx: int = line.find(':')
    if colonIdx > 0:
      let name: string = line[0 ..< colonIdx].strip().toLowerAscii()
      let value: string = line[colonIdx+1..^1].strip()
      if name == "content-length":
        try: contentLength = parseInt(value)
        except ValueError: discard

  var body: string = ""
  if contentLength > 0:
    if contentLength > MaxBodySize:
      stream.close()
      raise newException(TrackerError, "scrape response too large")
    body = await reader.readExact(contentLength)
  else:
    while not reader.atEof and body.len < MaxBodySize:
      let chunk: string = await reader.read(8192)
      if chunk.len == 0: break
      body.add(chunk)
  stream.close()

  if statusCode != 200:
    raise newException(TrackerError, "scrape HTTP " & $statusCode)
  return parseScrapeResponse(body, infoHash)

proc httpsScrape*(announceUrl: string, infoHash: array[20, byte]): CpsFuture[ScrapeInfo] {.cps, nosinks.} =
  let scrapeBase: string = announceToScrapeUrl(announceUrl)
  var url: string = scrapeBase
  if '?' in url: url.add('&')
  else: url.add('?')
  url.add("info_hash=")
  url.add(infoHashUrlEncoded(TorrentInfo(infoHash: infoHash)))

  let parsed: Uri = parseUri(url)
  let host: string = parsed.hostname
  let port: int = if parsed.port.len > 0: parseInt(parsed.port) else: 443
  let path: string = if parsed.path.len > 0: parsed.path else: "/"
  let query: string = if parsed.query.len > 0: path & "?" & parsed.query else: path

  let tcpStream: TcpStream = await withTimeout(tcpConnect(host, port), 15000)
  let tlsStream: TlsStream = newTlsStream(tcpStream, host, @["http/1.1"])
  try:
    await withTimeout(tlsConnect(tlsStream), 15000)
  except CatchableError as e:
    tcpStream.close()
    raise newException(TrackerError, "TLS connect failed: " & e.msg)

  let httpReq: string = "GET " & query & " HTTP/1.1\r\nHost: " & host &
                "\r\nConnection: close\r\n\r\n"
  await tlsStream.write(httpReq)
  let reader: BufferedReader = newBufferedReader(tlsStream.AsyncStream, 16384)

  let statusLine: string = await reader.readLine("\r\n")
  if not statusLine.startsWith("HTTP/"):
    raise newException(TrackerError, "invalid HTTP response: " & statusLine)
  let statusParts: seq[string] = statusLine.split(' ', 2)
  if statusParts.len < 2:
    raise newException(TrackerError, "malformed status line")
  let statusCode: int = parseInt(statusParts[1])

  var contentLength: int = -1
  var location: string = ""
  while true:
    let line: string = await reader.readLine("\r\n")
    if line.len == 0: break
    let colonIdx: int = line.find(':')
    if colonIdx > 0:
      let name: string = line[0 ..< colonIdx].strip().toLowerAscii()
      let value: string = line[colonIdx+1..^1].strip()
      if name == "content-length":
        try: contentLength = parseInt(value)
        except ValueError: discard
      elif name == "location":
        location = value

  if statusCode in [301, 302, 303, 307] and location.len > 0:
    tlsStream.close()
    let redirectParsed: Uri = parseUri(location)
    if redirectParsed.scheme == "https":
      let resp: ScrapeInfo = await httpsScrape(location, infoHash)
      return resp
    else:
      let resp: ScrapeInfo = await httpScrape(location, infoHash)
      return resp

  var body: string = ""
  if contentLength > 0:
    if contentLength > MaxBodySize:
      tlsStream.close()
      raise newException(TrackerError, "scrape response too large")
    body = await reader.readExact(contentLength)
  else:
    while not reader.atEof and body.len < MaxBodySize:
      let chunk: string = await reader.read(8192)
      if chunk.len == 0: break
      body.add(chunk)
  tlsStream.close()

  if statusCode != 200:
    raise newException(TrackerError, "scrape HTTPS " & $statusCode)
  return parseScrapeResponse(body, infoHash)

proc udpScrape*(announceUrl: string, infoHash: array[20, byte]): CpsFuture[ScrapeInfo] {.cps, nosinks.} =
  ## UDP tracker scrape (BEP 15).
  let parsed: Uri = parseUri(announceUrl)
  let host: string = parsed.hostname
  let port: uint16 = if parsed.port.len > 0: parseInt(parsed.port).uint16 else: 6969'u16

  let ips: seq[string] = await asyncResolve(host)
  if ips.len == 0:
    raise newException(TrackerError, "DNS resolution failed for " & host)

  let sock: UdpSocket = newUdpSocket(AF_INET)
  sock.bindAddr("0.0.0.0", 0)

  var transId: uint32 = uint32(epochTime().int64 and 0xFFFFFFFF)
  var udpError: string = ""
  var scrapeRespData: string = ""

  try:
    # Connect
    var connectReq = newStringOfCap(16)
    connectReq.writeUint64BE(UdpProtocolId)
    connectReq.writeUint32BE(UdpConnectAction)
    connectReq.writeUint32BE(transId)
    await sock.sendToAddr(connectReq, ips[0], port.int)
    let connResp: Datagram = await withTimeout(sock.recvFrom(65535), 15000)
    if connResp.data.len < 16:
      raise newException(TrackerError, "UDP connect response too short")
    let respAction: uint32 = readUint32BE(connResp.data, 0)
    let respTransId: uint32 = readUint32BE(connResp.data, 4)
    if respAction != UdpConnectAction or respTransId != transId:
      raise newException(TrackerError, "UDP connect response mismatch")
    let connectionId: uint64 = readUint64BE(connResp.data, 8)

    # Scrape request: connection_id(8) + action(4) + transaction_id(4) + info_hash(20)
    transId = transId + 1
    var scrapeReq = newStringOfCap(36)
    scrapeReq.writeUint64BE(connectionId)
    scrapeReq.writeUint32BE(UdpScrapeAction)
    scrapeReq.writeUint32BE(transId)
    var ihStr = newString(20)
    copyMem(addr ihStr[0], unsafeAddr infoHash[0], 20)
    scrapeReq.add(ihStr)
    await sock.sendToAddr(scrapeReq, ips[0], port.int)
    let scrapeResp: Datagram = await withTimeout(sock.recvFrom(65535), 15000)
    scrapeRespData = scrapeResp.data
  except CatchableError as e:
    udpError = e.msg
  sock.close()
  if udpError.len > 0:
    raise newException(TrackerError, udpError)

  if scrapeRespData.len < 20:
    raise newException(TrackerError, "UDP scrape response too short")
  let sAction: uint32 = readUint32BE(scrapeRespData, 0)
  let sTrans: uint32 = readUint32BE(scrapeRespData, 4)
  if sAction == UdpErrorAction:
    let errMsg: string = if scrapeRespData.len > 8: scrapeRespData[8..^1] else: "unknown"
    raise newException(TrackerError, "UDP scrape error: " & errMsg)
  if sAction != UdpScrapeAction or sTrans != transId:
    raise newException(TrackerError, "UDP scrape response mismatch")
  # Response: action(4) + transaction_id(4) + seeders(4) + completed(4) + leechers(4)
  return ScrapeInfo(
    complete: readUint32BE(scrapeRespData, 8).int,
    downloaded: readUint32BE(scrapeRespData, 12).int,
    incomplete: readUint32BE(scrapeRespData, 16).int
  )

proc scrape*(announceUrl: string, infoHash: array[20, byte]): CpsFuture[ScrapeInfo] {.cps, nosinks.} =
  ## Scrape a tracker (auto-detects HTTP, HTTPS, or UDP).
  let parsed: Uri = parseUri(announceUrl)
  if parsed.scheme == "udp":
    let resp: ScrapeInfo = await udpScrape(announceUrl, infoHash)
    return resp
  elif parsed.scheme == "https":
    let resp: ScrapeInfo = await httpsScrape(announceUrl, infoHash)
    return resp
  else:
    let resp: ScrapeInfo = await httpScrape(announceUrl, infoHash)
    return resp

proc announce*(announceUrl: string, params: AnnounceParams): CpsFuture[TrackerResponse] {.cps, nosinks.} =
  ## Announce to a tracker (auto-detects HTTP, HTTPS, or UDP).
  let parsed: Uri = parseUri(announceUrl)
  if parsed.scheme == "udp":
    let resp: TrackerResponse = await udpAnnounce(announceUrl, params)
    return resp
  elif parsed.scheme == "https":
    let resp: TrackerResponse = await httpsAnnounce(announceUrl, params)
    return resp
  else:
    # Handle HTTP→HTTPS redirects via TrackerRedirect exception
    var redirectUrl: string = ""
    var httpError: string = ""
    try:
      let resp: TrackerResponse = await httpAnnounce(announceUrl, params)
      return resp
    except TrackerRedirect as r:
      redirectUrl = r.msg
    except CatchableError as e:
      httpError = e.msg
    if httpError.len > 0:
      raise newException(TrackerError, httpError)
    if redirectUrl.len > 0:
      let resp: TrackerResponse = await httpsAnnounce(redirectUrl, params)
      return resp
    raise newException(TrackerError, "announce failed")

proc announceToAll*(urls: seq[string], params: AnnounceParams): CpsFuture[TrackerResponse] {.cps, nosinks.} =
  ## Try announcing to each tracker URL until one succeeds.
  var lastError: string = ""
  var i: int = 0
  while i < urls.len:
    let url: string = urls[i]
    i += 1
    try:
      let resp: TrackerResponse = await announce(url, params)
      return resp
    except CatchableError as e:
      lastError = url & ": " & e.msg
  raise newException(TrackerError, "all trackers failed, last error: " & lastError)

proc announceToAllMerge*(urls: seq[string], params: AnnounceParams): CpsFuture[TrackerResponse] {.cps, nosinks.} =
  ## Announce to ALL trackers in parallel and merge their peer lists.
  ## Each tracker is queried concurrently; results are collected with a timeout.
  var merged: TrackerResponse
  var anySuccess: bool = false
  var lastError: string = ""
  var seen: HashSet[string]

  # Fire all tracker announces in parallel
  var futures: seq[CpsFuture[TrackerResponse]]
  var fi: int = 0
  while fi < urls.len:
    let url: string = urls[fi]
    fi += 1
    futures.add(announce(url, params))

  # Collect results — wait up to 20s for all trackers, but process each as it completes
  var remaining: int = futures.len
  var waitedMs: int = 0
  while remaining > 0 and waitedMs < 20000:
    var ri: int = 0
    while ri < futures.len:
      let trkFut: CpsFuture[TrackerResponse] = futures[ri]
      ri += 1
      if trkFut == nil:
        continue
      if not trkFut.finished:
        continue
      # This future is done — process it
      futures[ri - 1] = nil
      remaining -= 1
      if trkFut.hasError:
        lastError = trkFut.getError().msg
        continue
      let resp: TrackerResponse = trkFut.read()
      if resp.failureReason.len > 0:
        lastError = resp.failureReason
        continue
      anySuccess = true
      # Merge peers (deduplicate)
      var pi: int = 0
      while pi < resp.peers.len:
        let p: TrackerPeer = resp.peers[pi]
        pi += 1
        let key: string = p.ip & ":" & $p.port
        if key notin seen:
          seen.incl(key)
          merged.peers.add(p)
      # Take best stats
      if resp.complete > merged.complete:
        merged.complete = resp.complete
      if resp.incomplete > merged.incomplete:
        merged.incomplete = resp.incomplete
      if resp.interval > 0 and (merged.interval == 0 or resp.interval < merged.interval):
        merged.interval = resp.interval
    if remaining > 0:
      await cpsSleep(250)
      waitedMs += 250

  # Cancel any still-running tracker announces
  var ci: int = 0
  while ci < futures.len:
    if futures[ci] != nil and not futures[ci].finished:
      futures[ci].cancel()
    ci += 1

  if not anySuccess:
    raise newException(TrackerError, "all trackers failed, last error: " & lastError)
  return merged
