## QUIC engine wrapper API for runtime-facing lifecycle management.

import ../runtime
import ./connection
import ./endpoint

type
  QuicEngine* = ref object
    role*: QuicEndpointRole
    endpoint*: QuicEndpoint
    config*: QuicEndpointConfig

proc newQuicServerEngine*(bindHost: string = "0.0.0.0",
                          bindPort: int = 4433,
                          onConnection: QuicConnectionCallback = nil,
                          onStreamReadable: QuicStreamCallback = nil,
                          onDatagram: QuicDatagramCallback = nil,
                          onHandshakeState: QuicHandshakeStateCallback = nil,
                          onConnectionClosed: QuicConnectionClosedCallback = nil,
                          onPathValidated: QuicPathValidatedCallback = nil,
                          config: QuicEndpointConfig = defaultQuicEndpointConfig()): QuicEngine =
  QuicEngine(
    role: qerServer,
    config: config,
    endpoint: newQuicServerEndpoint(
      bindHost = bindHost,
      bindPort = bindPort,
      onConnection = onConnection,
      onStreamReadable = onStreamReadable,
      onDatagram = onDatagram,
      onHandshakeState = onHandshakeState,
      onConnectionClosed = onConnectionClosed,
      onPathValidated = onPathValidated,
      config = config
    )
  )

proc newQuicClientEngine*(bindHost: string = "0.0.0.0",
                          bindPort: int = 0,
                          onConnection: QuicConnectionCallback = nil,
                          onStreamReadable: QuicStreamCallback = nil,
                          onDatagram: QuicDatagramCallback = nil,
                          onHandshakeState: QuicHandshakeStateCallback = nil,
                          onConnectionClosed: QuicConnectionClosedCallback = nil,
                          onPathValidated: QuicPathValidatedCallback = nil,
                          config: QuicEndpointConfig = defaultQuicEndpointConfig()): QuicEngine =
  QuicEngine(
    role: qerClient,
    config: config,
    endpoint: newQuicClientEndpoint(
      bindHost = bindHost,
      bindPort = bindPort,
      onConnection = onConnection,
      onStreamReadable = onStreamReadable,
      onDatagram = onDatagram,
      onHandshakeState = onHandshakeState,
      onConnectionClosed = onConnectionClosed,
      onPathValidated = onPathValidated,
      config = config
    )
  )

proc listen*(engine: QuicEngine) =
  if not engine.isNil and not engine.endpoint.isNil:
    engine.endpoint.listen()

proc connect*(engine: QuicEngine, remoteAddress: string, remotePort: int): CpsFuture[QuicConnection] =
  if engine.isNil or engine.endpoint.isNil:
    raise newException(ValueError, "QUIC engine is not initialized")
  engine.endpoint.connect(remoteAddress, remotePort)

proc close*(engine: QuicEngine,
            conn: QuicConnection,
            errorCode: uint64 = 0'u64,
            reason: string = ""): CpsVoidFuture =
  if engine.isNil or engine.endpoint.isNil:
    raise newException(ValueError, "QUIC engine is not initialized")
  engine.endpoint.close(conn, errorCode, reason)

proc shutdown*(engine: QuicEngine, closeSocket: bool = true) =
  if not engine.isNil and not engine.endpoint.isNil:
    engine.endpoint.shutdown(closeSocket = closeSocket)

proc updatePath*(engine: QuicEngine,
                 conn: QuicConnection,
                 remoteAddress: string,
                 remotePort: int): CpsVoidFuture =
  if engine.isNil or engine.endpoint.isNil:
    raise newException(ValueError, "QUIC engine is not initialized")
  engine.endpoint.updatePath(conn, remoteAddress, remotePort)
