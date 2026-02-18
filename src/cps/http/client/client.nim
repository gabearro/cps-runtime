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

import std/[strutils, uri, tables, times, options]
import ../../runtime
import ../../transform
import ../../eventloop
import ../../io/tcp
import ../../io/streams
import ../../io/buffered
import ../../tls/client as tls
import ./http1
import ../shared/http2
import ../shared/compression
import ../../tls/fingerprint

type
  HttpVersion* = enum
    hvHttp11 = "http/1.1"
    hvHttp2 = "h2"

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
    userAgent*: string
    followRedirects*: bool
    maxRedirects*: int
    autoDecompress*: bool
    fingerprint*: BrowserProfile  ## TLS + HTTP/2 fingerprint profile (nil = default)
    # HTTP/2 connection cache (per host:port)
    h2Connections: Table[string, Http2Connection]
    # HTTP/1.1 connection pool
    pool*: ConnectionPool
    maxConnectionsPerHost*: int  ## default 6
    maxIdleSeconds*: float       ## default 30

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
                     userAgent: string = "CPS-Nim-Client/0.1",
                     followRedirects: bool = true,
                     maxRedirects: int = 10,
                     autoDecompress: bool = true,
                     maxConnectionsPerHost: int = 6,
                     maxIdleSeconds: float = 30.0,
                     fingerprint: BrowserProfile = nil): HttpsClient =
  var ua = userAgent
  if fingerprint != nil and fingerprint.tls != nil and fingerprint.tls.userAgent.len > 0:
    ua = fingerprint.tls.userAgent
  HttpsClient(
    preferHttp2: preferHttp2,
    userAgent: ua,
    followRedirects: followRedirects,
    maxRedirects: maxRedirects,
    autoDecompress: autoDecompress,
    fingerprint: fingerprint,
    h2Connections: initTable[string, Http2Connection](),
    pool: newConnectionPool(maxConnectionsPerHost, maxIdleSeconds),
    maxConnectionsPerHost: maxConnectionsPerHost,
    maxIdleSeconds: maxIdleSeconds
  )

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
                tlsFp: TlsFingerprint = nil): CpsFuture[TlsStream] {.cps.} =
  ## Create a TLS connection to host:port with ALPN negotiation.
  ## When `tlsFp` is provided, applies the TLS fingerprint profile.
  let tcpStream = await tcpConnect(host, port)
  let tlsStream = newTlsStream(tcpStream, host, alpnProtos, tlsFp)
  await tlsConnect(tlsStream)
  return tlsStream

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
  let connHeader = h1resp.getHeader("connection").toLowerAscii
  if h1resp.httpVersion == "HTTP/1.0":
    conn.keepAlive = connHeader == "keep-alive"
  else:
    conn.keepAlive = connHeader != "close"

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
                           tlsFp: TlsFingerprint = nil): CpsFuture[Http1Connection] {.cps.} =
  ## Create a new HTTP/1.1 connection, optionally with TLS.
  var stream: AsyncStream
  if useTls:
    let tlsStream = await connectTls(host, port, @["http/1.1"], tlsFp)
    stream = tlsStream.AsyncStream
  else:
    let tcpStream = await tcpConnect(host, port)
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

proc fetchImpl(client: HttpsClient, meth: string, url: string,
               headers: seq[(string, string)],
               body: string,
               redirectsLeft: int): CpsFuture[HttpsResponse] {.cps.} =
  ## Perform an HTTP/HTTPS request.
  ## Automatically negotiates HTTP/1.1 or HTTP/2 via ALPN for HTTPS.
  ## Uses connection pooling for HTTP/1.1 keep-alive connections.
  ## Follows redirects if enabled.
  var allHeaders: seq[(string, string)] = headers
  var hasUA = false
  var hasAE = false
  for i in 0 ..< allHeaders.len:
    if allHeaders[i][0].toLowerAscii == "user-agent":
      hasUA = true
    elif allHeaders[i][0].toLowerAscii == "accept-encoding":
      hasAE = true
  if not hasUA:
    allHeaders.add ("user-agent", client.userAgent)
  if client.autoDecompress and not hasAE:
    allHeaders.add ("Accept-Encoding", buildAcceptEncoding())

  let parsed = parseUri(url)
  let host = parsed.hostname
  let port = if parsed.port != "": parseInt(parsed.port)
              elif parsed.scheme == "https": 443
              else: 80
  let path = if parsed.path != "": parsed.path & (if parsed.query != "": "?" & parsed.query else: "")
              else: "/"
  let useTls = parsed.scheme == "https"

  # HTTP/2 path (TLS only, ALPN negotiation)
  if useTls and client.preferHttp2:
    let tlsFp = if client.fingerprint != nil: client.fingerprint.tls else: nil
    let tlsStream = await connectTls(host, port, @["h2", "http/1.1"], tlsFp)

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

    return resp

  # HTTP/1.1 path (plain HTTP or TLS without HTTP/2 preference)
  let key = PoolKey(host: host, port: port, useTls: useTls)

  # Try to acquire a pooled connection
  var conn: Http1Connection
  var usedPooled = false
  let maybeConn = client.pool.acquire(key)
  let tlsFp1 = if client.fingerprint != nil: client.fingerprint.tls else: nil
  if maybeConn.isSome:
    conn = maybeConn.get
    usedPooled = true
  else:
    conn = await createHttp1Connection(host, port, useTls, tlsFp1)

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
      conn = await createHttp1Connection(host, port, useTls, tlsFp1)
      resp = await doHttp1Request(conn, meth, path, allHeaders, body)
  else:
    resp = await doHttp1Request(conn, meth, path, allHeaders, body)

  # Return to pool if keep-alive, otherwise close
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

  # Handle redirects recursively
  if client.followRedirects and isRedirectStatus(resp.statusCode):
    let location = resp.getHeader("location")
    if location != "":
      if redirectsLeft <= 0:
        raise newException(ValueError, "HTTP redirect limit exceeded (" & $client.maxRedirects & ")")
      let nextUrl = resolveRedirectUrl(url, location)
      return await fetchImpl(client, meth, nextUrl, headers, body, redirectsLeft - 1)

  return resp

proc fetch*(client: HttpsClient, meth: string, url: string,
            headers: seq[(string, string)] = @[],
            body: string = ""): CpsFuture[HttpsResponse] {.cps.} =
  ## Perform an HTTP/HTTPS request, enforcing max redirect depth.
  return await fetchImpl(client, meth, url, headers, body, client.maxRedirects)

# ============================================================
# Client lifecycle
# ============================================================

proc close*(client: HttpsClient) =
  ## Close all pooled connections and clean up resources.
  client.pool.closeAll()

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
