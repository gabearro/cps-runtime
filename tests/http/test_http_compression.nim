## Tests for HTTP compression middleware and client auto-decompress

import std/[strutils, nativesockets]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/server/router
import cps/http/shared/compression

# ============================================================
# Helpers
# ============================================================

proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = posix.getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

proc parseHttpResponse(raw: string): (int, seq[(string, string)], string) =
  ## Simple HTTP/1.1 response parser. Returns (statusCode, headers, body).
  let headerEnd = raw.find("\r\n\r\n")
  if headerEnd < 0:
    return (0, @[], raw)
  let headerPart = raw[0 ..< headerEnd]
  let body = raw[headerEnd + 4 .. ^1]
  let lines = headerPart.split("\r\n")
  var statusCode = 0
  if lines.len > 0:
    let parts = lines[0].split(' ')
    if parts.len >= 2:
      statusCode = parseInt(parts[1])
  var headers: seq[(string, string)]
  for i in 1 ..< lines.len:
    let colonPos = lines[i].find(':')
    if colonPos > 0:
      headers.add (lines[i][0 ..< colonPos].strip(), lines[i][colonPos+1 .. ^1].strip())
  return (statusCode, headers, body)

proc getHeader(headers: seq[(string, string)], name: string): string =
  for (k, v) in headers:
    if k.toLowerAscii == name.toLowerAscii:
      return v
  return ""

# ============================================================
# Test 1: Compression middleware compresses text response
# ============================================================

block testCompressionMiddleware:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  let largeBody = "Hello, World! ".repeat(100)  # ~1400 bytes, above default minBodySize

  proc handler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "Hello, World! ".repeat(100),
      @[("Content-Type", "text/plain")])

  let compMw = compressionMiddleware()

  let wrappedHandler: HttpHandler = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
    compMw(req, proc(r: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      handler(r))

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, wrappedHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reqStr = "GET /test HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip, deflate\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(reqStr)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let raw = cf.read()
  let (statusCode, headers, body) = parseHttpResponse(raw)
  assert statusCode == 200, "Expected 200, got: " & $statusCode
  let ceHeader = getHeader(headers, "Content-Encoding")
  assert ceHeader == "gzip", "Expected Content-Encoding: gzip, got: " & ceHeader
  let varyHeader = getHeader(headers, "Vary")
  assert "Accept-Encoding" in varyHeader, "Expected Vary: Accept-Encoding, got: " & varyHeader
  # Body should be compressed (smaller than original)
  assert body.len < largeBody.len, "Compressed body should be smaller: " & $body.len & " vs " & $largeBody.len
  # Decompress and verify
  let decompressed = gzipDecompress(body)
  assert decompressed == largeBody, "Decompressed body mismatch"
  echo "PASS: compression middleware compresses text response"

# ============================================================
# Test 2: Compression middleware skips small bodies
# ============================================================

block testCompressionSkipsSmall:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc handler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "Hi",
      @[("Content-Type", "text/plain")])

  let compMw = compressionMiddleware()

  let wrappedHandler: HttpHandler = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
    compMw(req, proc(r: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      handler(r))

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, wrappedHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reqStr = "GET / HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(reqStr)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let raw = cf.read()
  let (statusCode, headers, body) = parseHttpResponse(raw)
  assert statusCode == 200
  let ceHeader = getHeader(headers, "Content-Encoding")
  assert ceHeader == "", "Should not compress small bodies, got Content-Encoding: " & ceHeader
  assert body == "Hi"
  echo "PASS: compression middleware skips small bodies"

# ============================================================
# Test 3: Compression middleware skips binary content types
# ============================================================

block testCompressionSkipsBinary:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  let binaryBody = "x".repeat(500)

  proc handler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "x".repeat(500),
      @[("Content-Type", "image/png")])

  let compMw = compressionMiddleware()

  let wrappedHandler: HttpHandler = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
    compMw(req, proc(r: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      handler(r))

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, wrappedHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reqStr = "GET / HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(reqStr)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let raw = cf.read()
  let (statusCode, headers, body) = parseHttpResponse(raw)
  assert statusCode == 200
  let ceHeader = getHeader(headers, "Content-Encoding")
  assert ceHeader == "", "Should not compress binary content, got Content-Encoding: " & ceHeader
  assert body == binaryBody
  echo "PASS: compression middleware skips binary content types"

# ============================================================
# Test 4: Compression middleware skips already-encoded response
# ============================================================

block testCompressionSkipsAlreadyEncoded:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  let preCompressed = gzipCompress("original text ".repeat(100))

  proc handler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    let data = gzipCompress("original text ".repeat(100))
    return newResponse(200, data,
      @[("Content-Type", "text/plain"), ("Content-Encoding", "gzip")])

  let compMw = compressionMiddleware()

  let wrappedHandler: HttpHandler = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
    compMw(req, proc(r: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      handler(r))

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, wrappedHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let reqStr = "GET / HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(reqStr)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let raw = cf.read()
  let (statusCode, headers, body) = parseHttpResponse(raw)
  assert statusCode == 200
  # Should still have Content-Encoding: gzip (from original handler, not double-compressed)
  let decompressed = gzipDecompress(body)
  assert decompressed == "original text ".repeat(100)
  echo "PASS: compression middleware skips already-encoded response"

# ============================================================
# Test 5: No Accept-Encoding -> no compression
# ============================================================

block testCompressionNoAcceptEncoding:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  let largeBody = "Hello, World! ".repeat(100)

  proc handler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "Hello, World! ".repeat(100),
      @[("Content-Type", "text/plain")])

  let compMw = compressionMiddleware()

  let wrappedHandler: HttpHandler = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
    compMw(req, proc(r: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
      handler(r))

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, wrappedHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    # No Accept-Encoding header
    let reqStr = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    await conn.AsyncStream.write(reqStr)
    var response = ""
    while true:
      let chunk = await conn.AsyncStream.read(4096)
      if chunk.len == 0:
        break
      response &= chunk
    conn.AsyncStream.close()
    return response

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  let raw = cf.read()
  let (statusCode, headers, body) = parseHttpResponse(raw)
  assert statusCode == 200
  let ceHeader = getHeader(headers, "Content-Encoding")
  assert ceHeader == "", "Should not compress without Accept-Encoding"
  assert body == largeBody
  echo "PASS: no Accept-Encoding -> no compression"

echo "ALL HTTP COMPRESSION TESTS PASSED"
