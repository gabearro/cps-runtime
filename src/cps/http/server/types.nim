## HTTP Server Types
##
## Core types for the HTTP server: HttpRequest, HttpResponseBuilder,
## HttpHandler, HttpServerConfig, HttpServer.

import std/[strutils, nativesockets, tables, json]
from std/posix import Sockaddr_in, getsockname, SockLen
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
    maxConnections*: int
    maxRequestBodySize*: int
    readTimeoutMs*: int
    maxRequestLineSize*: int
    maxHeaderLineSize*: int
    maxHeaderBytes*: int
    maxHeaderCount*: int

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

proc getHeader*(req: HttpRequest, name: string): string =
  for (k, v) in req.headers:
    if k.toLowerAscii == name.toLowerAscii:
      return v
  return ""

proc getResponseHeader*(resp: HttpResponseBuilder, name: string): string =
  for (k, v) in resp.headers:
    if k.toLowerAscii == name.toLowerAscii:
      return v
  return ""

proc statusMessage*(code: int): string =
  case code
  of 200: "OK"
  of 201: "Created"
  of 204: "No Content"
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
  of 431: "Request Header Fields Too Large"
  of 429: "Too Many Requests"
  of 500: "Internal Server Error"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  else: "Unknown"

proc newHttpServer*(handler: HttpHandler,
                    host: string = "127.0.0.1",
                    port: int = 0,
                    useTls: bool = false,
                    certFile: string = "",
                    keyFile: string = "",
                    enableHttp2: bool = true,
                    maxConnections: int = 1000,
                    maxRequestBodySize: int = 10 * 1024 * 1024,
                    readTimeoutMs: int = 30000,
                    maxRequestLineSize: int = 8 * 1024,
                    maxHeaderLineSize: int = 8 * 1024,
                    maxHeaderBytes: int = 64 * 1024,
                    maxHeaderCount: int = 100): HttpServer =
  let config = HttpServerConfig(
    host: host,
    port: port,
    certFile: certFile,
    keyFile: keyFile,
    useTls: useTls,
    enableHttp2: enableHttp2,
    maxConnections: maxConnections,
    maxRequestBodySize: maxRequestBodySize,
    readTimeoutMs: readTimeoutMs,
    maxRequestLineSize: maxRequestLineSize,
    maxHeaderLineSize: maxHeaderLineSize,
    maxHeaderBytes: maxHeaderBytes,
    maxHeaderCount: maxHeaderCount
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
    server.boundPort = ntohs(localAddr.sin_port).int
  else:
    server.boundPort = server.config.port

proc stop*(server: HttpServer) =
  server.running = false
