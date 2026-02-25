## HTTPS Client
##
## High-level HTTPS client that uses our CPS library.
## Automatically negotiates HTTP/1.1 or HTTP/2 via ALPN.
## Uses CPS procs for clean, sequential async code.
##
## Supports HTTP/1.1 connection pooling for keep-alive reuse.
## Connections are cached per host:port:tls and reused across requests.
##
## Usage:
##   let client = newHttpsClient()
##   let resp = runCps(client.get("https://example.com"))
##   echo resp.statusCode, " ", resp.body

import std/[strutils, uri, tables, times, options, os]
import ../../runtime
import ../../transform
import ../../eventloop
import ../../io/tcp
import ../../io/streams
import ../../io/buffered
import ../../io/proxy
import ../../tls/client as tls
import ../../quic/endpoint as quic_endpoint
import ./http1
import ./http3 as http3_client
import ../shared/http2
import ../shared/compression
import ../../tls/fingerprint

type
  HttpVersion* = enum
    hvHttp11 = "http/1.1"
    hvHttp2 = "h2"
    hvHttp3 = "h3"

  HttpsResponse* = object
    statusCode*: int
    headers*: seq[(string, string)]
    body*: string
    httpVersion*: HttpVersion

  PoolKey* = object
    host*: string
    port*: int
    useTls*: bool

  PooledConnection* = object
    conn*: Http1Connection
    lastUsed*: float  # epochTime

  ConnectionPool* = ref object
    connections*: Table[PoolKey, seq[PooledConnection]]
    maxPerHost*: int
    maxIdleSeconds*: float

  HttpsClient* = ref object
    ## HTTPS client with automatic HTTP/1.1 and HTTP/2 support.
    ## Includes HTTP/1.1 connection pooling for keep-alive reuse.
    preferHttp2*: bool
    preferHttp3*: bool
    forceHttp3*: bool
    http3FallbackToHttp2*: bool
    http3EnableDatagram*: bool
    http3Enable0Rtt*: bool
    http3VerifyPeer*: bool
    http3CaFile*: string
    http3CaDir*: string
    userAgent*: string
    followRedirects*: bool
    maxRedirects*: int
    autoDecompress*: bool
    fingerprint*: BrowserProfile  ## TLS + HTTP/2 fingerprint profile (nil = default)
    # HTTP/2 connection cache (per host:port)
    h2Connections: Table[string, Http2Connection]
    # HTTP/3 transport cache (per host:port)
    h3Connections: Table[string, http3_client.Http3ClientTransport]
    h3LastUsed: Table[string, float]
    # HTTP/1.1 connection pool
    pool*: ConnectionPool
    maxConnectionsPerHost*: int  ## default 6
    maxIdleSeconds*: float       ## default 30
    altSvcCache*: Table[string, tuple[port: int, expiresAt: float]]
    proxy*: seq[ProxyConfig]   ## Proxy chain (empty = direct connection)

  Http3AttemptResult = object
    response: HttpsResponse
    host: string
    originPort: int

# ============================================================
# Connection Pool
# ============================================================

proc newConnectionPool*(maxPerHost: int = 6,
                        maxIdleSeconds: float = 30.0): ConnectionPool =
  ConnectionPool(
    connections: initTable[PoolKey, seq[PooledConnection]](),
    maxPerHost: maxPerHost,
    maxIdleSeconds: maxIdleSeconds
  )

proc evictExpired*(pool: ConnectionPool) =
  ## Remove connections that have been idle longer than maxIdleSeconds.
  let now = epochTime()
  var keysToDelete: seq[PoolKey]
  for key, conns in pool.connections.mpairs:
    var i = 0
    while i < conns.len:
      if now - conns[i].lastUsed > pool.maxIdleSeconds:
        # Close the expired connection
        conns[i].conn.stream.close()
        conns.delete(i)
      else:
        inc i
    if conns.len == 0:
      keysToDelete.add key
  for key in keysToDelete:
    pool.connections.del(key)

proc acquire*(pool: ConnectionPool, key: PoolKey): Option[Http1Connection] =
  ## Try to acquire an idle connection for the given key.
  ## Evicts expired connections while searching.
  ## Returns none if no idle connection is available.
  let now = epochTime()
  if key notin pool.connections:
    return none(Http1Connection)

  var conns = pool.connections[key]
  while conns.len > 0:
    let pc = conns[conns.len - 1]  # Take from the end (most recently used)
    conns.setLen(conns.len - 1)
    if now - pc.lastUsed > pool.maxIdleSeconds:
      # Expired — close and skip
      pc.conn.stream.close()
      continue
    if pc.conn.stream.closed:
      # Already closed — skip
      continue
    # Found a usable connection
    if conns.len == 0:
      pool.connections.del(key)
    else:
      pool.connections[key] = conns
    return some(pc.conn)

  # All connections were expired or closed
  pool.connections.del(key)
  return none(Http1Connection)

proc release*(pool: ConnectionPool, key: PoolKey, conn: Http1Connection) =
  ## Return a connection to the pool for reuse.
  ## If the pool for this host is full, close the oldest connection.
  if conn.stream.closed:
    return  # Don't pool closed connections

  let pc = PooledConnection(conn: conn, lastUsed: epochTime())

  if key notin pool.connections:
    pool.connections[key] = @[pc]
    return

  var conns = pool.connections[key]
  if conns.len >= pool.maxPerHost:
    # Pool full — close the oldest (first) connection and add new one
    conns[0].conn.stream.close()
    conns.delete(0)
  conns.add(pc)
  pool.connections[key] = conns

proc poolSize*(pool: ConnectionPool, key: PoolKey): int =
  ## Return the number of idle connections for the given key.
  if key in pool.connections:
    return pool.connections[key].len
  return 0

proc totalPoolSize*(pool: ConnectionPool): int =
  ## Return the total number of idle connections across all hosts.
  for key, conns in pool.connections:
    result += conns.len

proc closeAll*(pool: ConnectionPool) =
  ## Close all pooled connections and clear the pool.
  for key, conns in pool.connections:
    for pc in conns:
      pc.conn.stream.close()
  pool.connections.clear()

proc newHttpsClient*(preferHttp2: bool = true,
                     preferHttp3: bool = false,
                     forceHttp3: bool = false,
                     http3FallbackToHttp2: bool = true,
                     http3EnableDatagram: bool = true,
                     http3Enable0Rtt: bool = true,
                     http3VerifyPeer: bool = true,
                     http3CaFile: string = "",
                     http3CaDir: string = "",
                     userAgent: string = "CPS-Nim-Client/0.1",
                     followRedirects: bool = true,
                     maxRedirects: int = 10,
                     autoDecompress: bool = true,
                     maxConnectionsPerHost: int = 6,
                     maxIdleSeconds: float = 30.0,
                     fingerprint: BrowserProfile = nil,
                     proxy: seq[ProxyConfig] = @[]): HttpsClient =
  var ua = userAgent
  if fingerprint != nil and fingerprint.tls != nil and fingerprint.tls.userAgent.len > 0:
    ua = fingerprint.tls.userAgent
  HttpsClient(
    preferHttp2: preferHttp2,
    preferHttp3: preferHttp3,
    forceHttp3: forceHttp3,
    http3FallbackToHttp2: http3FallbackToHttp2,
    http3EnableDatagram: http3EnableDatagram,
    http3Enable0Rtt: http3Enable0Rtt,
    http3VerifyPeer: http3VerifyPeer,
    http3CaFile: http3CaFile,
    http3CaDir: http3CaDir,
    userAgent: ua,
    followRedirects: followRedirects,
    maxRedirects: maxRedirects,
    autoDecompress: autoDecompress,
    fingerprint: fingerprint,
    h2Connections: initTable[string, Http2Connection](),
    h3Connections: initTable[string, http3_client.Http3ClientTransport](),
    h3LastUsed: initTable[string, float](),
    pool: newConnectionPool(maxConnectionsPerHost, maxIdleSeconds),
    maxConnectionsPerHost: maxConnectionsPerHost,
    maxIdleSeconds: maxIdleSeconds,
    altSvcCache: initTable[string, tuple[port: int, expiresAt: float]](),
    proxy: @proxy
  )

proc altSvcCacheKey(host: string, port: int): string {.inline.} =
  host & ":" & $port

proc h3ConnectionKey(host: string, port: int): string {.inline.} =
  host & ":" & $port

proc closeAndDropH3Connection(client: HttpsClient, key: string) =
  if key in client.h3Connections:
    let h3Conn = client.h3Connections[key]
    if not h3Conn.isNil:
      h3Conn.close(closeSocket = true)
    client.h3Connections.del(key)
  if key in client.h3LastUsed:
    client.h3LastUsed.del(key)

proc evictExpiredHttp3Connections(client: HttpsClient) =
  let now = epochTime()
  var keysToDelete: seq[string] = @[]
  for key, h3Conn in client.h3Connections:
    var shouldDrop = h3Conn.isNil or not h3Conn.isUsable()
    if not shouldDrop and key in client.h3LastUsed:
      shouldDrop = now - client.h3LastUsed[key] > client.maxIdleSeconds
    if shouldDrop:
      keysToDelete.add key
  for key in keysToDelete:
    client.closeAndDropH3Connection(key)

proc h3ClientDebug(msg: string) {.inline.} =
  if existsEnv("CPS_HTTP3_CLIENT_DEBUG"):
    echo "[cps-h3-client] ", msg

proc parseAltSvcH3(altSvcValue: string, defaultPort: int): Option[(int, int)] =
  ## Parse `Alt-Svc` for `h3` token and return (port, maxAgeSeconds).
  ## Accepts values like: h3=":443"; ma=86400
  let lower = altSvcValue.toLowerAscii
  if "h3" notin lower:
    return none((int, int))

  var port = defaultPort
  let pfx = lower.find("h3=\":")
  if pfx >= 0:
    let start = pfx + "h3=\":".len
    var stop = start
    while stop < lower.len and lower[stop] in {'0'..'9'}:
      inc stop
    if stop > start:
      try:
        port = parseInt(lower[start ..< stop])
      except ValueError:
        discard

  var maxAge = 86_400
  let maPos = lower.find("ma=")
  if maPos >= 0:
    let start = maPos + 3
    var stop = start
    while stop < lower.len and lower[stop] in {'0'..'9'}:
      inc stop
    if stop > start:
      try:
        maxAge = max(1, parseInt(lower[start ..< stop]))
      except ValueError:
        discard

  some((port, maxAge))

proc updateAltSvcCache(client: HttpsClient,
                       host: string,
                       port: int,
                       headers: openArray[(string, string)]) =
  for (k, v) in headers:
    if k.toLowerAscii != "alt-svc":
      continue
    let parsed = parseAltSvcH3(v, port)
    if parsed.isSome:
      let (h3Port, ttl) = parsed.get
      client.altSvcCache[altSvcCacheKey(host, port)] = (
        port: h3Port,
        expiresAt: epochTime() + ttl.float
      )
      break

proc getHeader*(resp: HttpsResponse, name: string): string =
  for (k, v) in resp.headers:
    if k.toLowerAscii == name.toLowerAscii:
      return v
  return ""

proc isRedirectStatus(code: int): bool {.inline.} =
  code == 301 or code == 302 or code == 303 or code == 307 or code == 308

proc resolveRedirectUrl(baseUrl: string, location: string): string =
  ## Resolve absolute and relative redirect targets against the original URL.
  if location.len == 0:
    return baseUrl
  let loc = parseUri(location)
  if loc.scheme.len > 0:
    return location
  let base = parseUri(baseUrl)
  if location.startsWith("//"):
    return base.scheme & ":" & location

  var path = ""
  if location[0] == '/':
    path = if loc.path.len > 0: loc.path else: "/"
  else:
    let basePath = if base.path.len > 0: base.path else: "/"
    let slashPos = rfind(basePath, '/')
    let baseDir =
      if slashPos >= 0:
        basePath[0 .. slashPos]
      else:
        "/"
    path = baseDir & loc.path

  result = base.scheme & "://" & base.hostname
  if base.port.len > 0:
    result.add(":" & base.port)
  result.add(path)
  if loc.query.len > 0:
    result.add("?" & loc.query)
  if loc.anchor.len > 0:
    result.add("#" & loc.anchor)

proc connectTls(host: string, port: int,
                alpnProtos: seq[string],
                tlsFp: TlsFingerprint = nil,
                proxies: seq[ProxyConfig] = @[]): CpsFuture[TlsStream] {.cps.} =
  ## Create a TLS connection to host:port with ALPN negotiation.
  ## When `tlsFp` is provided, applies the TLS fingerprint profile.
  ## When `proxies` is non-empty, tunnels through the proxy chain first.
  var tcpStream: TcpStream
  if proxies.len > 0:
    let ps: ProxyStream = await proxyChainConnect(proxies, host, port)
    tcpStream = ps.getUnderlyingTcpStream()
  else:
    tcpStream = await tcpConnect(host, port)
  let tlsStream: TlsStream = newTlsStream(tcpStream, host, alpnProtos, tlsFp)
  await tlsConnect(tlsStream)
  return tlsStream

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

proc doHttp1Request(conn: Http1Connection,
                    meth: string, path: string,
                    headers: seq[(string, string)],
                    body: string): CpsFuture[HttpsResponse] {.cps.} =
  ## Perform an HTTP/1.1 request on an existing connection.
  ## Updates conn.keepAlive based on the response Connection header.
  let h1resp = await http1.request(conn, meth, path, headers, body)

  # Update keepAlive based on HTTP version and Connection header.
  # HTTP/1.1: keep-alive by default unless Connection: close
  # HTTP/1.0: not keep-alive by default unless Connection: keep-alive
  if h1resp.httpVersion == "HTTP/1.0":
    conn.keepAlive = headersHaveToken(h1resp.headers, "connection", "keep-alive")
  else:
    conn.keepAlive = not headersHaveToken(h1resp.headers, "connection", "close")

  return HttpsResponse(
    statusCode: h1resp.statusCode,
    headers: h1resp.headers,
    body: h1resp.body,
    httpVersion: hvHttp11
  )

proc doHttp2Request(client: HttpsClient, stream: AsyncStream,
                    host: string, port: int,
                    meth: string, path: string,
                    headers: seq[(string, string)],
                    body: string): CpsFuture[HttpsResponse] {.cps.} =
  let connKey = host & ":" & $port

  var conn: Http2Connection
  var needsInit = false

  if connKey in client.h2Connections:
    conn = client.h2Connections[connKey]
    if not conn.running or conn.goawayReceived:
      conn = newHttp2Connection(stream)
      client.h2Connections[connKey] = conn
      needsInit = true
  else:
    conn = newHttp2Connection(stream)
    client.h2Connections[connKey] = conn
    needsInit = true

  if needsInit:
    let h2fp = if client.fingerprint != nil: client.fingerprint.h2 else: nil
    await initConnection(conn, h2fp)
    # Start the receive loop in the background (don't await it)
    discard runReceiveLoop(conn)

  var allHeaders: seq[(string, string)] = headers
  var hasUA = false
  for i in 0 ..< allHeaders.len:
    if allHeaders[i][0].toLowerAscii == "user-agent":
      hasUA = true
  if not hasUA:
    allHeaders.add ("user-agent", client.userAgent)

  let authority = if port == 443: host else: host & ":" & $port
  var pseudoOrder: seq[string]
  if client.fingerprint != nil and client.fingerprint.h2 != nil:
    pseudoOrder = client.fingerprint.h2.pseudoHeaderOrder
  let h2resp = await http2.request(conn, meth, path, authority, allHeaders, body, pseudoOrder)

  # Filter out pseudo-headers from response
  var filteredHeaders: seq[(string, string)]
  for i in 0 ..< h2resp.headers.len:
    if not h2resp.headers[i][0].startsWith(":"):
      filteredHeaders.add h2resp.headers[i]

  return HttpsResponse(
    statusCode: h2resp.statusCode,
    headers: filteredHeaders,
    body: h2resp.body,
    httpVersion: hvHttp2
  )

proc createHttp1Connection(host: string, port: int,
                           useTls: bool,
                           tlsFp: TlsFingerprint = nil,
                           proxies: seq[ProxyConfig] = @[]): CpsFuture[Http1Connection] {.cps.} =
  ## Create a new HTTP/1.1 connection, optionally with TLS.
  ## When `proxies` is non-empty, tunnels through the proxy chain first.
  var stream: AsyncStream
  if useTls:
    let tlsStream: TlsStream = await connectTls(host, port, @["http/1.1"], tlsFp, proxies)
    stream = tlsStream.AsyncStream
  else:
    if proxies.len > 0:
      let ps: ProxyStream = await proxyChainConnect(proxies, host, port)
      stream = ps.AsyncStream
    else:
      let tcpStream: TcpStream = await tcpConnect(host, port)
      stream = tcpStream.AsyncStream

  let reader = newBufferedReader(stream)
  let conn = Http1Connection(
    stream: stream,
    reader: reader,
    host: host,
    port: port,
    keepAlive: true
  )
  return conn

proc doHttp3Attempt(client: HttpsClient,
                    meth: string,
                    url: string,
                    headers: seq[(string, string)],
                    body: string): CpsFuture[Http3AttemptResult] {.cps.} =
  let parsed = parseUri(url)
  let host = parsed.hostname
  let port = if parsed.port != "": parseInt(parsed.port)
             elif parsed.scheme == "https": 443
             else: 80
  let path = if parsed.path != "": parsed.path & (if parsed.query != "": "?" & parsed.query else: "")
             else: "/"
  h3ClientDebug("doHttp3Attempt start meth=" & meth & " url=" & url &
    " host=" & host & " port=" & $port & " path=" & path)

  var h3Port = port
  if client.preferHttp3 and not client.forceHttp3:
    let altSvcKey = altSvcCacheKey(host, port)
    if altSvcKey in client.altSvcCache:
      let cached = client.altSvcCache[altSvcKey]
      if epochTime() <= cached.expiresAt:
        h3Port = cached.port
      else:
        client.altSvcCache.del(altSvcKey)

  if h3Port <= 0:
    h3Port = if parsed.port != "": parseInt(parsed.port)
             elif parsed.scheme == "https": 443
             else: 80

  let authority = if parsed.port != "": host & ":" & $port else: host
  h3ClientDebug("doHttp3Attempt authority=" & authority & " h3Port=" & $h3Port)
  client.evictExpiredHttp3Connections()
  let cacheKey = h3ConnectionKey(host, h3Port)
  var quicCfg = quic_endpoint.defaultQuicEndpointConfig()
  quicCfg.serverName = host
  quicCfg.tlsVerifyPeer = client.http3VerifyPeer
  quicCfg.tlsCaFile = client.http3CaFile
  quicCfg.tlsCaDir = client.http3CaDir
  var transport: http3_client.Http3ClientTransport = nil
  if cacheKey in client.h3Connections:
    let cachedTransport = client.h3Connections[cacheKey]
    if cachedTransport.isNil or not cachedTransport.isUsable():
      client.closeAndDropH3Connection(cacheKey)
    else:
      transport = cachedTransport

  if transport.isNil:
    transport = await http3_client.newHttp3ClientTransport(
      host = host,
      port = h3Port,
      timeoutMs = 5_000,
      enableDatagram = client.http3EnableDatagram,
      enable0Rtt = client.http3Enable0Rtt,
      endpointConfig = quicCfg
    )

  var h3Resp: http3_client.Http3ClientResponse
  var attemptedRetry = false
  while true:
    try:
      h3Resp = await http3_client.doHttp3RequestOnTransport(
        transport = transport,
        meth = meth,
        path = path,
        authority = authority,
        headers = headers,
        body = body,
        timeoutMs = 5_000
      )
      client.h3Connections[cacheKey] = transport
      client.h3LastUsed[cacheKey] = epochTime()
      break
    except CatchableError:
      let errMsg = getCurrentExceptionMsg()
      client.closeAndDropH3Connection(cacheKey)
      if attemptedRetry:
        raise
      attemptedRetry = true
      h3ClientDebug("doHttp3Attempt transport-retry due to error: " & errMsg)
      transport = await http3_client.newHttp3ClientTransport(
        host = host,
        port = h3Port,
        timeoutMs = 5_000,
        enableDatagram = client.http3EnableDatagram,
        enable0Rtt = client.http3Enable0Rtt,
        endpointConfig = quicCfg
      )

  let attempt = Http3AttemptResult(
    response: HttpsResponse(
      statusCode: h3Resp.statusCode,
      headers: h3Resp.headers,
      body: h3Resp.body,
      httpVersion: hvHttp3
    ),
    host: host,
    originPort: port
  )
  h3ClientDebug("doHttp3Attempt done status=" & $attempt.response.statusCode &
    " version=" & $attempt.response.httpVersion)
  return attempt

proc prepareRequestHeaders(client: HttpsClient,
                           headers: seq[(string, string)]): seq[(string, string)] =
  result = headers
  var hasUA = false
  var hasAE = false
  for i in 0 ..< result.len:
    if result[i][0].toLowerAscii == "user-agent":
      hasUA = true
    elif result[i][0].toLowerAscii == "accept-encoding":
      hasAE = true
  if not hasUA:
    result.add ("user-agent", client.userAgent)
  if client.autoDecompress and not hasAE:
    result.add ("Accept-Encoding", buildAcceptEncoding())

proc fetchForceHttp3NoFallback(client: HttpsClient,
                               meth: string,
                               url: string,
                               headers: seq[(string, string)],
                               body: string,
                               redirectsLeft: int): CpsFuture[HttpsResponse] {.cps.} =
  when not defined(useBoringSSL):
    raise newException(ValueError, "HTTP/3 requires build with -d:useBoringSSL")
  let parsed = parseUri(url)
  if parsed.scheme != "https":
    raise newException(ValueError, "forceHttp3 requires https URL")

  let allHeaders = client.prepareRequestHeaders(headers)
  let h3Result = await doHttp3Attempt(client, meth, url, allHeaders, body)
  var resp = h3Result.response

  if client.autoDecompress:
    let ceHeader = resp.getHeader("content-encoding")
    if ceHeader.len > 0:
      let enc = parseContentEncoding(ceHeader)
      if enc != ceIdentity:
        resp.body = decompress(resp.body, enc)
        var newHeaders: seq[(string, string)]
        for (k, v) in resp.headers:
          if k.toLowerAscii != "content-encoding":
            newHeaders.add (k, v)
        resp.headers = newHeaders

  client.updateAltSvcCache(h3Result.host, h3Result.originPort, resp.headers)

  if client.followRedirects and isRedirectStatus(resp.statusCode):
    let location = resp.getHeader("location")
    if location != "":
      if redirectsLeft <= 0:
        raise newException(ValueError, "HTTP redirect limit exceeded (" & $client.maxRedirects & ")")
      let nextUrl = resolveRedirectUrl(url, location)
      return await fetchForceHttp3NoFallback(client, meth, nextUrl, headers, body, redirectsLeft - 1)

  return resp

proc fetchImpl(client: HttpsClient, meth: string, url: string,
               headers: seq[(string, string)],
               body: string,
               redirectsLeft: int): CpsFuture[HttpsResponse] {.cps.} =
  ## Perform an HTTP/HTTPS request.
  ## Automatically negotiates HTTP/1.1 or HTTP/2 via ALPN for HTTPS.
  ## Uses connection pooling for HTTP/1.1 keep-alive connections.
  ## Follows redirects if enabled.
  var allHeaders = client.prepareRequestHeaders(headers)

  let parsed = parseUri(url)
  let host = parsed.hostname
  let port = if parsed.port != "": parseInt(parsed.port)
              elif parsed.scheme == "https": 443
              else: 80
  let path = if parsed.path != "": parsed.path & (if parsed.query != "": "?" & parsed.query else: "")
              else: "/"
  let useTls = parsed.scheme == "https"

  # Dedicated force-HTTP/3 path (no fallback) avoids mixed-transport control flow.
  if useTls and client.forceHttp3 and not client.http3FallbackToHttp2:
    when defined(useBoringSSL):
      h3ClientDebug("fetchImpl force-h3 path meth=" & meth & " url=" & url)
      let h3Result = await doHttp3Attempt(client, meth, url, allHeaders, body)
      var resp = h3Result.response

      if client.autoDecompress:
        let ceHeader = resp.getHeader("content-encoding")
        if ceHeader.len > 0:
          let enc = parseContentEncoding(ceHeader)
          if enc != ceIdentity:
            resp.body = decompress(resp.body, enc)
            var newHeaders: seq[(string, string)]
            for (k, v) in resp.headers:
              if k.toLowerAscii != "content-encoding":
                newHeaders.add (k, v)
            resp.headers = newHeaders

      client.updateAltSvcCache(h3Result.host, h3Result.originPort, resp.headers)

      if client.followRedirects and isRedirectStatus(resp.statusCode):
        let location = resp.getHeader("location")
        if location != "":
          if redirectsLeft <= 0:
            raise newException(ValueError, "HTTP redirect limit exceeded (" & $client.maxRedirects & ")")
          let nextUrl = resolveRedirectUrl(url, location)
          return await fetchImpl(client, meth, nextUrl, headers, body, redirectsLeft - 1)
      return resp
    else:
      raise newException(ValueError, "HTTP/3 requires build with -d:useBoringSSL")

  # HTTP/3 preference/force path. `forceHttp3` attempts QUIC first regardless
  # of `preferHttp3`, and fallback is controlled by `http3FallbackToHttp2`.
  if useTls and (client.forceHttp3 or client.preferHttp3):
    when defined(useBoringSSL):
      var h3AttemptErr = ""
      var h3Resp: HttpsResponse
      var h3HaveResp = false
      var h3RedirectUrl = ""
      try:
        h3ClientDebug("fetchImpl h3-attempt start meth=" & meth & " url=" & url)
        let h3Result = await doHttp3Attempt(client, meth, url, allHeaders, body)
        var resp = h3Result.response
        h3ClientDebug("fetchImpl h3-attempt response status=" & $resp.statusCode &
          " bodyLen=" & $resp.body.len)

        if client.autoDecompress:
          let ceHeader = resp.getHeader("content-encoding")
          if ceHeader.len > 0:
            let enc = parseContentEncoding(ceHeader)
            if enc != ceIdentity:
              resp.body = decompress(resp.body, enc)
              var newHeaders: seq[(string, string)]
              for (k, v) in resp.headers:
                if k.toLowerAscii != "content-encoding":
                  newHeaders.add (k, v)
              resp.headers = newHeaders

        client.updateAltSvcCache(h3Result.host, h3Result.originPort, resp.headers)
        h3ClientDebug("fetchImpl h3-attempt alt-svc-updated host=" & h3Result.host &
          " port=" & $h3Result.originPort)

        if client.followRedirects and isRedirectStatus(resp.statusCode):
          let location = resp.getHeader("location")
          if location != "":
            if redirectsLeft <= 0:
              raise newException(ValueError, "HTTP redirect limit exceeded (" & $client.maxRedirects & ")")
            h3RedirectUrl = resolveRedirectUrl(url, location)
          else:
            h3Resp = resp
            h3HaveResp = true
        else:
          h3Resp = resp
          h3HaveResp = true
      except CatchableError as e:
        h3AttemptErr = e.msg
        h3ClientDebug("fetchImpl h3-attempt error: " & h3AttemptErr)
        if not client.http3FallbackToHttp2:
          raise
      if h3RedirectUrl.len > 0:
        h3ClientDebug("fetchImpl h3 redirect -> " & h3RedirectUrl)
        return await fetchImpl(client, meth, h3RedirectUrl, headers, body, redirectsLeft - 1)
      if h3HaveResp:
        h3ClientDebug("fetchImpl h3 return status=" & $h3Resp.statusCode)
        return h3Resp
      if client.forceHttp3 and not client.http3FallbackToHttp2:
        raise newException(ValueError, "HTTP/3 attempt failed and fallback disabled: " & h3AttemptErr)
    else:
      if client.forceHttp3 and not client.http3FallbackToHttp2:
        raise newException(ValueError, "HTTP/3 requires build with -d:useBoringSSL")

  # HTTP/2 path (TLS only, ALPN negotiation)
  if useTls and client.preferHttp2:
    let tlsFp = if client.fingerprint != nil: client.fingerprint.tls else: nil
    let tlsStream = await connectTls(host, port, @["h2", "http/1.1"], tlsFp, client.proxy)

    var resp: HttpsResponse
    if tlsStream.alpnProto == "h2":
      resp = await doHttp2Request(client, tlsStream.AsyncStream, host, port,
                                  meth, path, allHeaders, body)
    else:
      # ALPN negotiated HTTP/1.1 over TLS — use pooling
      let key = PoolKey(host: host, port: port, useTls: true)
      # We already have a fresh TLS stream, wrap it as Http1Connection
      let reader = newBufferedReader(tlsStream.AsyncStream)
      let conn = Http1Connection(
        stream: tlsStream.AsyncStream,
        reader: reader,
        host: host,
        port: port,
        keepAlive: true
      )
      resp = await doHttp1Request(conn, meth, path, allHeaders, body)
      if conn.keepAlive:
        client.pool.release(key, conn)
      else:
        conn.stream.close()

    # Auto-decompress response body
    if client.autoDecompress:
      let ceHeader = resp.getHeader("content-encoding")
      if ceHeader.len > 0:
        let enc = parseContentEncoding(ceHeader)
        if enc != ceIdentity:
          resp.body = decompress(resp.body, enc)
          var newHeaders: seq[(string, string)]
          for (k, v) in resp.headers:
            if k.toLowerAscii != "content-encoding":
              newHeaders.add (k, v)
          resp.headers = newHeaders

    # Handle redirects
    if client.followRedirects and isRedirectStatus(resp.statusCode):
      let location = resp.getHeader("location")
      if location != "":
        if redirectsLeft <= 0:
          raise newException(ValueError, "HTTP redirect limit exceeded (" & $client.maxRedirects & ")")
        let nextUrl = resolveRedirectUrl(url, location)
        return await fetchImpl(client, meth, nextUrl, headers, body, redirectsLeft - 1)

    if useTls:
      client.updateAltSvcCache(host, port, resp.headers)

    return resp

  # HTTP/1.1 path (plain HTTP or TLS without HTTP/2 preference)
  let poolKey = PoolKey(host: host, port: port, useTls: useTls)

  # Try to acquire a pooled connection
  var conn: Http1Connection
  var usedPooled = false
  let maybeConn = client.pool.acquire(poolKey)
  let tlsFp1 = if client.fingerprint != nil: client.fingerprint.tls else: nil
  if maybeConn.isSome:
    conn = maybeConn.get
    usedPooled = true
  else:
    conn = await createHttp1Connection(host, port, useTls, tlsFp1, client.proxy)

  # Try the request; if using a pooled connection and it fails,
  # retry once with a new connection (server may have closed it).
  # Note: `await` inside except bodies is not supported by the CPS transform,
  # so we use a flag to trigger the retry after the try/except block.
  var resp: HttpsResponse
  var needsRetry = false
  if usedPooled:
    try:
      resp = await doHttp1Request(conn, meth, path, allHeaders, body)
    except CatchableError:
      # Stale connection — mark for retry
      conn.stream.close()
      needsRetry = true
    if needsRetry:
      conn = await createHttp1Connection(host, port, useTls, tlsFp1, client.proxy)
      resp = await doHttp1Request(conn, meth, path, allHeaders, body)
  else:
    resp = await doHttp1Request(conn, meth, path, allHeaders, body)

  # Return to pool if keep-alive, otherwise close
  if conn.keepAlive:
    client.pool.release(poolKey, conn)
  else:
    conn.stream.close()

  # Auto-decompress response body
  if client.autoDecompress:
    let ceHeader = resp.getHeader("content-encoding")
    if ceHeader.len > 0:
      let enc = parseContentEncoding(ceHeader)
      if enc != ceIdentity:
        resp.body = decompress(resp.body, enc)
        var newHeaders: seq[(string, string)]
        for (k, v) in resp.headers:
          if k.toLowerAscii != "content-encoding":
            newHeaders.add (k, v)
        resp.headers = newHeaders

  # Handle redirects recursively
  if client.followRedirects and isRedirectStatus(resp.statusCode):
    let location = resp.getHeader("location")
    if location != "":
      if redirectsLeft <= 0:
        raise newException(ValueError, "HTTP redirect limit exceeded (" & $client.maxRedirects & ")")
      let nextUrl = resolveRedirectUrl(url, location)
      return await fetchImpl(client, meth, nextUrl, headers, body, redirectsLeft - 1)

  if useTls:
    client.updateAltSvcCache(host, port, resp.headers)

  return resp

proc fetch*(client: HttpsClient, meth: string, url: string,
            headers: seq[(string, string)] = @[],
            body: string = ""): CpsFuture[HttpsResponse] {.cps.} =
  ## Perform an HTTP/HTTPS request, enforcing max redirect depth.
  let parsed = parseUri(url)
  if client.forceHttp3 and not client.http3FallbackToHttp2 and parsed.scheme == "https":
    return await fetchForceHttp3NoFallback(client, meth, url, headers, body, client.maxRedirects)
  return await fetchImpl(client, meth, url, headers, body, client.maxRedirects)

# ============================================================
# Client lifecycle
# ============================================================

proc close*(client: HttpsClient) =
  ## Close all pooled connections and clean up resources.
  client.pool.closeAll()
  for _, h2Conn in client.h2Connections:
    if not h2Conn.isNil and not h2Conn.stream.closed:
      h2Conn.stream.close()
  client.h2Connections.clear()
  var h3Keys: seq[string] = @[]
  for key, _ in client.h3Connections:
    h3Keys.add key
  for key in h3Keys:
    client.closeAndDropH3Connection(key)

# ============================================================
# Convenience methods
# ============================================================

proc get*(client: HttpsClient, url: string,
          headers: seq[(string, string)] = @[]): CpsFuture[HttpsResponse] =
  fetch(client, "GET", url, headers)

proc post*(client: HttpsClient, url: string, body: string,
           headers: seq[(string, string)] = @[]): CpsFuture[HttpsResponse] =
  fetch(client, "POST", url, headers, body)

proc put*(client: HttpsClient, url: string, body: string,
          headers: seq[(string, string)] = @[]): CpsFuture[HttpsResponse] =
  fetch(client, "PUT", url, headers, body)

proc delete*(client: HttpsClient, url: string,
             headers: seq[(string, string)] = @[]): CpsFuture[HttpsResponse] =
  fetch(client, "DELETE", url, headers)

proc head*(client: HttpsClient, url: string,
           headers: seq[(string, string)] = @[]): CpsFuture[HttpsResponse] =
  fetch(client, "HEAD", url, headers)
