## HTTP Server Types
##
## Core types for the HTTP server: HttpRequest, HttpResponseBuilder,
## HttpHandler, HttpServerConfig, HttpServer.

import std/[strutils, nativesockets, tables, json]
import ../../private/platform
import ../../runtime
import ../../eventloop
import ../../concurrency/taskgroup
import ../../io/tcp
import ../../io/streams
import ../../io/buffered

type
  ResponseControl* = enum
    rcNone,          ## Normal HTTP response
    rcPassRoute,     ## Internal router control: continue to next matching route
    rcContinue,      ## Internal middleware control: continue chain
    rcHandled        ## Response already written directly to transport

  TemplateRenderer* = proc(name: string, vars: JsonNode): string {.closure.}

  HttpRequest* = object
    meth*: string
    path*: string
    httpVersion*: string
    headers*: seq[(string, string)]
    body*: string
    remoteAddr*: string     ## Remote peer IP address.
    streamId*: uint32       ## HTTP/2 stream ID (0 for HTTP/1.1)
    authority*: string      ## HTTP/2 :authority pseudo-header
    scheme*: string         ## HTTP/2 :scheme pseudo-header
    stream*: AsyncStream    ## Underlying transport (for SSE/WebSocket). nil for HTTP/2.
    reader*: BufferedReader  ## HTTP/1.1 buffered reader (for WebSocket). nil for HTTP/2.
    templateRenderer*: TemplateRenderer  ## Router-scoped template renderer (if configured).
    context*: TableRef[string, string]  ## Shared per-request context across request copies
    appState*: RootRef      ## Typed app state injected by router dispatch

  HttpResponseBuilder* = object
    statusCode*: int
    headers*: seq[(string, string)]
    body*: string
    control*: ResponseControl

  HttpHandler* = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.}

  HttpServerConfig* = object
    host*: string
    port*: int
    certFile*: string
    keyFile*: string
    useTls*: bool
    enableHttp2*: bool
    enableHttp3*: bool
    quicIdleTimeoutMs*: int
    quicUseRetry*: bool
    quicEnableMigration*: bool
    quicEnableDatagram*: bool
    quicMaxDatagramFrameSize*: int
    quicInitialMaxData*: uint64
    quicInitialMaxStreamDataBidiLocal*: uint64
    quicInitialMaxStreamDataBidiRemote*: uint64
    quicInitialMaxStreamDataUni*: uint64
    quicInitialMaxStreamsBidi*: uint64
    quicInitialMaxStreamsUni*: uint64
    maxConnections*: int
    maxRequestBodySize*: int
    readTimeoutMs*: int
    maxRequestLineSize*: int
    maxHeaderLineSize*: int
    maxHeaderBytes*: int
    maxHeaderCount*: int
    maxWsFrameBytes*: int
    maxWsMessageBytes*: int
    trustedProxyCidrs*: seq[string]
    trustedForwardedHeaders*: bool

  HttpServer* = ref object
    config*: HttpServerConfig
    listener*: TcpListener
    handler*: HttpHandler
    running*: bool
    boundPort*: int
    connGroup*: TaskGroup
    shutdownStarted*: bool
    onStartCallbacks*: seq[proc()]
    onShutdownCallbacks*: seq[proc()]

proc newResponse*(statusCode: int, body: string = "",
                  headers: seq[(string, string)] = @[]): HttpResponseBuilder =
  HttpResponseBuilder(
    statusCode: statusCode,
    headers: headers,
    body: body,
    control: rcNone
  )

proc passRouteResponse*(headers: seq[(string, string)] = @[]): HttpResponseBuilder =
  ## Internal control response used by router `pass()`.
  HttpResponseBuilder(
    statusCode: 204,
    headers: headers,
    body: "",
    control: rcPassRoute
  )

proc continueResponse*(): HttpResponseBuilder =
  ## Internal control response used by `before` middleware to continue.
  HttpResponseBuilder(
    statusCode: 204,
    headers: @[],
    body: "",
    control: rcContinue
  )

proc handledResponse*(): HttpResponseBuilder =
  ## Internal control response used by SSE/WebSocket/chunked handlers.
  HttpResponseBuilder(
    statusCode: 200,
    headers: @[],
    body: "",
    control: rcHandled
  )

proc eqCaseInsensitive*(a, b: string): bool {.inline.} =
  ## Zero-allocation case-insensitive string comparison.
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if toLowerAscii(a[i]) != toLowerAscii(b[i]): return false
  true

proc ensureContext*(req: var HttpRequest) {.inline.} =
  ## Lazily allocate the context table on first use.
  if req.context.isNil:
    req.context = newTable[string, string]()

proc getHeader*(req: HttpRequest, name: string): string =
  for (k, v) in req.headers:
    if eqCaseInsensitive(k, name):
      return v
  return ""

proc getResponseHeader*(resp: HttpResponseBuilder, name: string): string =
  for (k, v) in resp.headers:
    if eqCaseInsensitive(k, name):
      return v
  return ""

const headerTokenChars = {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^',
                          '_', '`', '|', '~'} + Digits + Letters

proc isValidHeaderName*(name: string): bool =
  ## RFC token validation for header names.
  if name.len == 0:
    return false
  for c in name:
    if c notin headerTokenChars:
      return false
  true

proc isValidHeaderValue*(value: string): bool =
  ## Strict header value validation: rejects CR/LF and control chars (except HTAB).
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

proc validateHeaderPair*(name, value: string): bool =
  isValidHeaderName(name) and isValidHeaderValue(value)

proc validateResponseHeaders*(headers: seq[(string, string)]): bool =
  for (k, v) in headers:
    if not validateHeaderPair(k, v):
      return false
  true

proc parseIpv4(ip: string, value: var uint32): bool =
  let parts = ip.split('.')
  if parts.len != 4:
    return false
  var parsed: uint32 = 0
  for part in parts:
    if part.len == 0:
      return false
    var n = -1
    try:
      n = parseInt(part)
    except ValueError:
      return false
    if n < 0 or n > 255:
      return false
    parsed = (parsed shl 8) or uint32(n)
  value = parsed
  true

proc ipInCidr(ip: string, cidr: string): bool =
  if cidr == "*":
    return true
  let slash = cidr.find('/')
  if slash < 0:
    return ip == cidr

  let networkIp = cidr[0 ..< slash]
  let maskStr = cidr[slash + 1 .. ^1]
  var maskBits = -1
  try:
    maskBits = parseInt(maskStr)
  except ValueError:
    return false
  if maskBits < 0 or maskBits > 32:
    return false

  var ipVal, netVal: uint32
  if not parseIpv4(ip, ipVal):
    return false
  if not parseIpv4(networkIp, netVal):
    return false

  let mask: uint32 =
    if maskBits == 0: 0'u32
    else: 0xFFFF_FFFF'u32 shl (32 - maskBits)
  (ipVal and mask) == (netVal and mask)

proc isTrustedProxyAddress*(ip: string, cidrs: seq[string]): bool =
  ## Returns true when the remote peer is trusted to provide forwarded headers.
  if ip.len == 0:
    return false
  if cidrs.len == 0:
    return false
  for cidr in cidrs:
    if ipInCidr(ip, cidr.strip()):
      return true
  false

proc statusMessage*(code: int): string =
  case code
  of 200: "OK"
  of 201: "Created"
  of 204: "No Content"
  of 205: "Reset Content"
  of 301: "Moved Permanently"
  of 302: "Found"
  of 304: "Not Modified"
  of 400: "Bad Request"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 406: "Not Acceptable"
  of 408: "Request Timeout"
  of 409: "Conflict"
  of 414: "URI Too Long"
  of 411: "Length Required"
  of 413: "Payload Too Large"
  of 415: "Unsupported Media Type"
  of 417: "Expectation Failed"
  of 431: "Request Header Fields Too Large"
  of 429: "Too Many Requests"
  of 500: "Internal Server Error"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  of 505: "HTTP Version Not Supported"
  else: "Unknown"

proc newHttpServer*(handler: HttpHandler,
                    host: string = "127.0.0.1",
                    port: int = 0,
                    useTls: bool = false,
                    certFile: string = "",
                    keyFile: string = "",
                    enableHttp2: bool = true,
                    enableHttp3: bool = false,
                    quicIdleTimeoutMs: int = 30_000,
                    quicUseRetry: bool = true,
                    quicEnableMigration: bool = true,
                    quicEnableDatagram: bool = true,
                    quicMaxDatagramFrameSize: int = 1200,
                    quicInitialMaxData: uint64 = 1_048_576'u64,
                    quicInitialMaxStreamDataBidiLocal: uint64 = 262_144'u64,
                    quicInitialMaxStreamDataBidiRemote: uint64 = 262_144'u64,
                    quicInitialMaxStreamDataUni: uint64 = 262_144'u64,
                    quicInitialMaxStreamsBidi: uint64 = 100'u64,
                    quicInitialMaxStreamsUni: uint64 = 100'u64,
                    maxConnections: int = 1000,
                    maxRequestBodySize: int = 10 * 1024 * 1024,
                    readTimeoutMs: int = 30000,
                    maxRequestLineSize: int = 8 * 1024,
                    maxHeaderLineSize: int = 8 * 1024,
                    maxHeaderBytes: int = 64 * 1024,
                    maxHeaderCount: int = 100,
                    maxWsFrameBytes: int = 1024 * 1024,
                    maxWsMessageBytes: int = 16 * 1024 * 1024,
                    trustedProxyCidrs: seq[string] = @[],
                    trustedForwardedHeaders: bool = false): HttpServer =
  let config = HttpServerConfig(
    host: host,
    port: port,
    certFile: certFile,
    keyFile: keyFile,
    useTls: useTls,
    enableHttp2: enableHttp2,
    enableHttp3: enableHttp3,
    quicIdleTimeoutMs: quicIdleTimeoutMs,
    quicUseRetry: quicUseRetry,
    quicEnableMigration: quicEnableMigration,
    quicEnableDatagram: quicEnableDatagram,
    quicMaxDatagramFrameSize: quicMaxDatagramFrameSize,
    quicInitialMaxData: quicInitialMaxData,
    quicInitialMaxStreamDataBidiLocal: quicInitialMaxStreamDataBidiLocal,
    quicInitialMaxStreamDataBidiRemote: quicInitialMaxStreamDataBidiRemote,
    quicInitialMaxStreamDataUni: quicInitialMaxStreamDataUni,
    quicInitialMaxStreamsBidi: quicInitialMaxStreamsBidi,
    quicInitialMaxStreamsUni: quicInitialMaxStreamsUni,
    maxConnections: maxConnections,
    maxRequestBodySize: maxRequestBodySize,
    readTimeoutMs: readTimeoutMs,
    maxRequestLineSize: maxRequestLineSize,
    maxHeaderLineSize: maxHeaderLineSize,
    maxHeaderBytes: maxHeaderBytes,
    maxHeaderCount: maxHeaderCount,
    maxWsFrameBytes: maxWsFrameBytes,
    maxWsMessageBytes: maxWsMessageBytes,
    trustedProxyCidrs: trustedProxyCidrs,
    trustedForwardedHeaders: trustedForwardedHeaders
  )
  HttpServer(
    config: config,
    handler: handler,
    running: false,
    boundPort: 0,
    connGroup: newTaskGroup(epCollectAll),
    shutdownStarted: false
  )

proc getPort*(server: HttpServer): int =
  server.boundPort

proc bindAndListen*(server: HttpServer) =
  ## Bind and listen. Call before start().
  server.listener = tcpListen(server.config.host, server.config.port)
  # Get the actual bound port
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = getsockname(server.listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  if rc == 0:
    server.boundPort = nativesockets.ntohs(localAddr.sin_port).int
  else:
    server.boundPort = server.config.port

proc stop*(server: HttpServer) =
  server.running = false

proc onStart*(server: HttpServer, cb: proc()) =
  ## Register a callback invoked once when the server starts accepting.
  server.onStartCallbacks.add cb

proc onShutdown*(server: HttpServer, cb: proc()) =
  ## Register a callback invoked once when graceful shutdown begins.
  server.onShutdownCallbacks.add cb
