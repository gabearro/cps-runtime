## HTTP Server - Accept Loop and Lifecycle
##
## Server accept loop, graceful shutdown, and convenience serve() proc.

import ../../runtime
import ../../transform
import ../../eventloop
import ../../concurrency/signals
import ../../concurrency/taskgroup
import ../../io/streams
import ../../io/tcp
import ../../tls/server as tls_server
import ./types
import ./http1
import ./http2

export types

proc handleAcceptedConnection(server: HttpServer, client: TcpStream,
                              tlsCtx: tls_server.TlsServerContext): CpsVoidFuture {.cps.} =
  let handler = server.handler
  let config = server.config
  if config.useTls:
    let tlsStream = await tls_server.tlsAccept(tlsCtx, client)
    if config.enableHttp2 and tlsStream.alpnProto == "h2":
      await handleHttp2Connection(tlsStream.AsyncStream, config, handler)
    else:
      await handleHttp1Connection(tlsStream.AsyncStream, config, handler)
  else:
    await handleHttp1Connection(client.AsyncStream, config, handler)

proc start*(server: HttpServer): CpsVoidFuture {.cps.} =
  ## Accept loop: accepts TCP connections and dispatches each to
  ## HTTP/1.1 or HTTP/2 handlers via the server's TaskGroup.
  ## Runs until server.running is set to false.
  var tlsCtx: tls_server.TlsServerContext = nil
  if server.config.useTls:
    let alpnProtos =
      if server.config.enableHttp2: @["h2", "http/1.1"]
      else: @["http/1.1"]
    tlsCtx = tls_server.newTlsServerContext(server.config.certFile, server.config.keyFile, alpnProtos)

  server.running = true
  for cb in server.onStartCallbacks:
    cb()
  try:
    while server.running:
      var client: TcpStream
      var acceptFailed = false
      try:
        client = await server.listener.accept()
      except CatchableError:
        acceptFailed = true
      if acceptFailed:
        if server.running:
          continue
        else:
          break

      # Apply a hard cap on concurrent active connections.
      if server.config.maxConnections > 0 and server.connGroup.activeCount >= server.config.maxConnections:
        client.close()
        continue

      server.connGroup.spawn(handleAcceptedConnection(server, client, tlsCtx))
  finally:
    if tlsCtx != nil:
      tls_server.closeTlsServerContext(tlsCtx)

proc shutdown*(server: HttpServer, drainTimeoutMs: int = 5000): CpsVoidFuture {.cps.} =
  ## Stop accepting new connections.
  ## Wait up to drainTimeoutMs for in-flight requests to complete.
  ## Cancel remaining connections after timeout.
  if server.shutdownStarted:
    return  # Idempotent: already shutting down
  server.shutdownStarted = true
  server.running = false
  for cb in server.onShutdownCallbacks:
    cb()
  # Close the listener socket to stop accepting new connections
  if server.listener != nil and not server.listener.closed:
    server.listener.close()
  # Wait for active connections to drain, with a timeout
  if server.connGroup.activeCount > 0:
    let waitFut = server.connGroup.wait()
    let timeoutFut = cpsSleep(drainTimeoutMs)
    while not waitFut.finished and not timeoutFut.finished:
      getEventLoop().tick()
    if not waitFut.finished:
      echo "Shutdown timeout: " & $server.connGroup.activeCount & " connections still active, cancelling"
      server.connGroup.cancelAll()

proc shutdownOnSignal*(server: HttpServer, drainTimeoutMs: int = 5000): CpsVoidFuture {.cps.} =
  ## Register SIGINT/SIGTERM handlers that trigger graceful shutdown.
  ## Blocks until the signal is received and shutdown completes.
  initSignalHandling()
  await waitForShutdown()
  await shutdown(server, drainTimeoutMs)
  deinitSignalHandling()

proc serve*(handler: HttpHandler, port: int = 8080,
            host: string = "127.0.0.1") =
  ## Convenience: create server, bind, start accept loop, run event loop.
  let server = newHttpServer(handler, host = host, port = port)
  server.bindAndListen()
  echo "Listening on " & host & ":" & $server.getPort()
  let loop = getEventLoop()
  discard server.start()
  while true:
    loop.tick()
