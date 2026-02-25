## High-level QUIC endpoint API.

import std/[tables, strutils, times, os]
import std/openssl
import ../runtime
import ../transform
import ../eventloop
import ./types
import ./packet
import ./token
import ./connection
import ./dispatcher
import ./streams
import ./path
import ./recovery
import ./handshake
import ./secure_random
when defined(useBoringSSL):
  import ./tlsquic
  import ../tls/boringssl_compat

type
  QuicVersion* = enum
    qv1
    qv2

  QuicCongestionControl* = QuicCongestionController

  QuicConnectionCallback* = proc(conn: QuicConnection): CpsVoidFuture {.closure.}
  QuicStreamCallback* = proc(conn: QuicConnection, streamId: uint64): CpsVoidFuture {.closure.}
  QuicDatagramCallback* = proc(conn: QuicConnection, data: seq[byte]): CpsVoidFuture {.closure.}
  QuicHandshakeStateCallback* = proc(conn: QuicConnection, state: QuicHandshakeState): CpsVoidFuture {.closure.}
  QuicConnectionClosedCallback* = proc(conn: QuicConnection, errorCode: uint64, reason: string): CpsVoidFuture {.closure.}
  QuicPathValidatedCallback* = proc(conn: QuicConnection, peerAddress: string, peerPort: int): CpsVoidFuture {.closure.}
  QuicTlsKeyLogCallback* = proc(line: string) {.closure.}

  QuicEndpointRole* = enum
    qerServer
    qerClient

  QuicEndpointConfig* = object
    versions*: seq[QuicVersion]
    tlsCertFile*: string
    tlsKeyFile*: string
    tlsVerifyPeer*: bool
    tlsCaFile*: string
    tlsCaDir*: string
    serverName*: string
    alpn*: seq[string]
    congestionControl*: QuicCongestionControl
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
    maxStreamsPerConnection*: int
    tokenSecretKey*: seq[byte]
    statelessResetSecret*: seq[byte]
    qlogSink*: QuicQlogSink
    qlogEventSink*: QuicQlogEventSink
    tlsKeyLogCallback*: QuicTlsKeyLogCallback

  QuicEndpoint* = ref object
    role*: QuicEndpointRole
    bindHost*: string
    bindPort*: int
    config*: QuicEndpointConfig
    dispatcher*: QuicDispatcher
    directory*: QuicConnectionDirectory
    running*: bool
    connections*: Table[string, QuicConnection]       # secondary map by peer host:port
    connectionsByCid*: Table[string, QuicConnection]  # primary map keyed by local CID hex
    statelessResetByCid*: Table[string, array[16, byte]]
    tlsByConn*: Table[uint, QuicHandshakeContext]
    sslByConn*: Table[uint, openssl.SslPtr]
    sslCtxByConn*: Table[uint, openssl.SslCtx]
    peerCertVerifiedByConn*: Table[uint, bool]
    onConnection*: QuicConnectionCallback
    onStreamReadable*: QuicStreamCallback
    onDatagram*: QuicDatagramCallback
    onHandshakeState*: QuicHandshakeStateCallback
    onConnectionClosed*: QuicConnectionClosedCallback
    onPathValidated*: QuicPathValidatedCallback
    housekeepingTimer: TimerHandle

const
  QuicHousekeepingIntervalMs = 250
  QuicMinDrainingTimeoutMicros = 1_000_000'i64

when defined(useBoringSSL):
  const
    SSL_FILETYPE_PEM = 1.cint
    SSL_ERROR_WANT_READ = 2
    SSL_ERROR_WANT_WRITE = 3
    SSL_ERROR_WANT_X509_LOOKUP = 4
    SSL_ERROR_ZERO_RETURN = 6
    SSL_TLSEXT_ERR_OK = 0
    SSL_TLSEXT_ERR_NOACK = 3

  var quicServerAlpnWireByCtx: Table[uint, seq[byte]]
  var quicTlsKeyLogByCtx: Table[uint, QuicTlsKeyLogCallback]

  type
    SslKeyLogCb = proc(ssl: openssl.SslPtr, line: cstring) {.cdecl.}

  proc SSL_CTX_set_default_verify_paths(ctx: openssl.SslCtx): cint
    {.cdecl, dynlib: openssl.DLLSSLName, importc.}

  proc SSL_CTX_set_keylog_callback(ctx: openssl.SslCtx, cb: SslKeyLogCb)
    {.cdecl, dynlib: openssl.DLLSSLName, importc.}

  proc X509_check_ip_asc(cert: openssl.PX509, ipasc: cstring, flags: cuint): cint
    {.cdecl, dynlib: openssl.DLLSSLName, importc.}

  proc stripBracketedHost(host: string): string {.inline.} =
    if host.len >= 2 and host[0] == '[' and host[^1] == ']':
      host[1 .. ^2]
    else:
      host

  proc isIpv4Literal(host: string): bool =
    let parts = host.split('.')
    if parts.len != 4:
      return false
    for part in parts:
      if part.len == 0 or part.len > 3:
        return false
      var value = 0
      for ch in part:
        if ch < '0' or ch > '9':
          return false
        value = value * 10 + (ord(ch) - ord('0'))
      if value < 0 or value > 255:
        return false
    true

  proc isIpLiteral(host: string): bool {.inline.} =
    let normalized = stripBracketedHost(host)
    isIpv4Literal(normalized) or (':' in normalized)

  proc alpnSelectCallback(ssl: openssl.SslPtr, outProto: ptr cstring,
                          outLen: cstring, inProto: cstring,
                          inLen: cuint, arg: pointer): cint {.cdecl.} =
    discard arg
    let ctx = SSL_get_SSL_CTX(ssl)
    if ctx.isNil:
      return SSL_TLSEXT_ERR_NOACK
    let k = cast[uint](ctx)
    if k notin quicServerAlpnWireByCtx:
      return SSL_TLSEXT_ERR_NOACK
    var selectedProto: cstring = nil
    let rc = SSL_select_next_proto(
      addr selectedProto,
      outLen,
      cast[cstring](unsafeAddr quicServerAlpnWireByCtx[k][0]),
      cuint(quicServerAlpnWireByCtx[k].len),
      inProto,
      inLen
    )
    if rc == 1:
      outProto[] = selectedProto
      return SSL_TLSEXT_ERR_OK
    SSL_TLSEXT_ERR_NOACK

  proc tlsKeyLogCallback(ssl: openssl.SslPtr, line: cstring) {.cdecl.} =
    if ssl.isNil or line.isNil:
      return
    let ctx = SSL_get_SSL_CTX(ssl)
    if ctx.isNil:
      return
    let k = cast[uint](ctx)
    if k in quicTlsKeyLogByCtx and not quicTlsKeyLogByCtx[k].isNil:
      quicTlsKeyLogByCtx[k]($line)

proc bytesToHex(data: openArray[byte]): string =
  result = newStringOfCap(data.len * 2)
  for b in data:
    result.add toHex(int(b), 2).toLowerAscii

proc makeConnKey(host: string, port: int): string {.inline.} =
  host & ":" & $port

proc splitConnKey(peerKey: string): tuple[host: string, port: int] =
  let idx = peerKey.rfind(':')
  if idx <= 0 or idx >= peerKey.high:
    return (host: peerKey, port: 0)
  var parsedPort = 0
  try:
    parsedPort = parseInt(peerKey[idx + 1 .. ^1])
  except ValueError:
    parsedPort = 0
  (host: peerKey[0 ..< idx], port: parsedPort)

proc makeCidKey(cid: openArray[byte]): string {.inline.} =
  bytesToHex(cid)

proc connRefKey(conn: QuicConnection): uint {.inline.} =
  cast[uint](conn)

proc encodeAlpnWire(protos: openArray[string]): seq[byte] =
  result = @[]
  for p in protos:
    if p.len == 0 or p.len > 255:
      continue
    result.add byte(p.len)
    for c in p:
      result.add byte(ord(c) and 0xFF)

proc deriveStatelessResetToken(secret, cid: openArray[byte]): array[16, byte] =
  if secret.len == 0:
    raise newException(ValueError, "stateless reset secret must not be empty")
  var outLen: cuint = 0
  var digest = newSeq[byte](32)
  let rc = HMAC(
    EVP_sha256(),
    cast[pointer](unsafeAddr secret[0]),
    secret.len.cint,
    cast[cstring](if cid.len > 0: unsafeAddr cid[0] else: nil),
    cid.len.csize_t,
    cast[cstring](addr digest[0]),
    addr outLen
  )
  if rc.isNil or outLen < 16:
    raise newException(ValueError, "failed to derive stateless reset token")
  for i in 0 ..< 16:
    result[i] = digest[i]

proc defaultTokenSecret(): seq[byte] =
  secureRandomBytes(32)

proc defaultResetSecret(): seq[byte] =
  secureRandomBytes(32)

proc defaultQuicEndpointConfig*(): QuicEndpointConfig =
  QuicEndpointConfig(
    versions: @[qv1, qv2],
    tlsCertFile: "",
    tlsKeyFile: "",
    tlsVerifyPeer: true,
    tlsCaFile: "",
    tlsCaDir: "",
    serverName: "",
    alpn: @["h3"],
    congestionControl: qccCubic,
    quicIdleTimeoutMs: 30_000,
    quicUseRetry: true,
    quicEnableMigration: true,
    quicEnableDatagram: true,
    quicMaxDatagramFrameSize: 1200,
    quicInitialMaxData: 1_048_576'u64,
    quicInitialMaxStreamDataBidiLocal: 262_144'u64,
    quicInitialMaxStreamDataBidiRemote: 262_144'u64,
    quicInitialMaxStreamDataUni: 262_144'u64,
    quicInitialMaxStreamsBidi: 100'u64,
    quicInitialMaxStreamsUni: 100'u64,
    maxConnections: 4096,
    maxStreamsPerConnection: 1024,
    tokenSecretKey: defaultTokenSecret(),
    statelessResetSecret: defaultResetSecret(),
    qlogSink: nil,
    qlogEventSink: nil,
    tlsKeyLogCallback: nil
  )

proc emitQlog(ep: QuicEndpoint, event: string) =
  if not ep.config.qlogSink.isNil:
    ep.config.qlogSink(event)

proc toWireVersion(v: QuicVersion): uint32 {.inline.} =
  case v
  of qv1: QuicVersion1
  of qv2: QuicVersion2

proc supportedWireVersions(ep: QuicEndpoint): seq[uint32] =
  result = @[]
  for v in ep.config.versions:
    let w = toWireVersion(v)
    if w notin result:
      result.add w
  if result.len == 0:
    result = @[QuicVersion1]

proc supportsWireVersion(ep: QuicEndpoint, version: uint32): bool {.inline.} =
  for v in ep.config.versions:
    if toWireVersion(v) == version:
      return true
  false

proc preferredWireVersion(ep: QuicEndpoint): uint32 {.inline.} =
  let supported = ep.supportedWireVersions()
  supported[0]

proc newLocalConnId(seed: string): seq[byte] =
  discard seed
  result = newSeq[byte](8)
  secureRandomFill(result)

proc parseHeaderWithOffset(packet: openArray[byte]): tuple[header: QuicPacketHeader, offset: int] =
  var off = 0
  try:
    let hdr = parsePacketHeader(packet, off)
    (header: hdr, offset: off)
  except ValueError as e:
    let b0 = if packet.len > 0: "0x" & toHex(int(packet[0]), 2) else: "<none>"
    let b1 = if packet.len > 1: "0x" & toHex(int(packet[1]), 2) else: "<none>"
    let b2 = if packet.len > 2: "0x" & toHex(int(packet[2]), 2) else: "<none>"
    raise newException(ValueError,
      "header-parse failed len=" & $packet.len &
      " off=" & $off &
      " b0=" & b0 &
      " b1=" & b1 &
      " b2=" & b2 &
      " reason=" & e.msg)

proc tryParseHeaderWithOffset(packet: openArray[byte],
                              hdr: var QuicPacketHeader,
                              off: var int,
                              err: var string): bool =
  try:
    let parsed = parseHeaderWithOffset(packet)
    hdr = parsed.header
    off = parsed.offset
    err = ""
    return true
  except ValueError as e:
    err = e.msg
    return false

proc tryDecodeProtectedPacket(conn: QuicConnection,
                              datagram: openArray[byte],
                              packet: var QuicPacket,
                              err: var string): bool =
  try:
    packet = conn.decodeProtectedPacket(datagram)
    err = ""
    true
  except CatchableError as e:
    err = e.msg
    false

proc parseValidatedRetry(datagram: openArray[byte],
                         originalDestinationConnId: openArray[byte]): tuple[ok: bool, srcConnId: seq[byte], token: seq[byte]] =
  try:
    let retryPkt = parseRetryPacket(datagram)
    if not validateRetryPacketIntegrity(datagram, originalDestinationConnId):
      return (ok: false, srcConnId: @[], token: @[])
    (ok: true, srcConnId: retryPkt.srcConnId, token: retryPkt.token)
  except ValueError:
    (ok: false, srcConnId: @[], token: @[])

proc byteSliceEq(data: openArray[byte], start: int, rhs: openArray[byte]): bool =
  if start < 0 or start + rhs.len > data.len:
    return false
  for i in 0 ..< rhs.len:
    if data[start + i] != rhs[i]:
      return false
  true

proc registerConnection(ep: QuicEndpoint, peerKey: string, conn: QuicConnection) =
  ep.connections[peerKey] = conn
  let (peerHost, peerPort) = splitConnKey(peerKey)
  if conn.localConnId.len > 0:
    let cidKey = makeCidKey(conn.localConnId)
    ep.connectionsByCid[cidKey] = conn
    ep.directory.register(cidKey, peerHost, peerPort)
    if ep.role == qerServer:
      let resetToken = deriveStatelessResetToken(ep.config.statelessResetSecret, conn.localConnId)
      conn.localTransportParameters.hasStatelessResetToken = true
      conn.localTransportParameters.statelessResetToken = resetToken
      ep.statelessResetByCid[cidKey] = resetToken
    else:
      conn.localTransportParameters.hasStatelessResetToken = false

proc removeConnectionMappings(ep: QuicEndpoint, conn: QuicConnection) =
  if conn.isNil:
    return
  if conn.localConnId.len > 0:
    let cidKey = makeCidKey(conn.localConnId)
    if cidKey in ep.connectionsByCid:
      ep.connectionsByCid.del(cidKey)
    if cidKey in ep.statelessResetByCid:
      ep.statelessResetByCid.del(cidKey)
    ep.directory.retire(cidKey)
  var dropKeys: seq[string] = @[]
  for key, mapped in ep.connections:
    if mapped == conn:
      dropKeys.add key
  for key in dropKeys:
    ep.connections.del(key)
  let rk = connRefKey(conn)
  when defined(useBoringSSL):
    if rk in ep.sslByConn:
      let ssl = ep.sslByConn[rk]
      if not ssl.isNil:
        detachQuicTls(ssl)
        SSL_free(ssl)
      ep.sslByConn.del(rk)
    if rk in ep.sslCtxByConn:
      let ctx = ep.sslCtxByConn[rk]
      if not ctx.isNil:
        quicServerAlpnWireByCtx.del(cast[uint](ctx))
        quicTlsKeyLogByCtx.del(cast[uint](ctx))
        SSL_CTX_free(ctx)
      ep.sslCtxByConn.del(rk)
    if rk in ep.peerCertVerifiedByConn:
      ep.peerCertVerifiedByConn.del(rk)
  if rk in ep.tlsByConn:
    ep.tlsByConn.del(rk)

proc configureConnection(ep: QuicEndpoint, conn: QuicConnection) =
  conn.localTransportParameters.maxIdleTimeout = uint64(max(0, ep.config.quicIdleTimeoutMs))
  conn.localTransportParameters.disableActiveMigration = not ep.config.quicEnableMigration
  conn.localTransportParameters.maxDatagramFrameSize =
    if ep.config.quicEnableDatagram: uint64(max(0, ep.config.quicMaxDatagramFrameSize)) else: 0'u64
  conn.localTransportParameters.initialMaxData = ep.config.quicInitialMaxData
  conn.localTransportParameters.initialMaxStreamDataBidiLocal = ep.config.quicInitialMaxStreamDataBidiLocal
  conn.localTransportParameters.initialMaxStreamDataBidiRemote = ep.config.quicInitialMaxStreamDataBidiRemote
  conn.localTransportParameters.initialMaxStreamDataUni = ep.config.quicInitialMaxStreamDataUni
  conn.localTransportParameters.initialMaxStreamsBidi = ep.config.quicInitialMaxStreamsBidi
  conn.localTransportParameters.initialMaxStreamsUni = ep.config.quicInitialMaxStreamsUni
  conn.localTransportParameters.initialSourceConnectionId = conn.localConnId
  if conn.role == qcrServer:
    conn.localTransportParameters.originalDestinationConnectionId = conn.initialSecretConnId
  else:
    conn.localTransportParameters.originalDestinationConnectionId = @[]
  conn.localTransportParameters.retrySourceConnectionId = @[]
  conn.recovery.maxDatagramSize = max(1200, ep.config.quicMaxDatagramFrameSize)
  conn.recovery.setCongestionController(ep.config.congestionControl)

when defined(useBoringSSL):
  proc initializeConnectionTls(ep: QuicEndpoint, conn: QuicConnection, host: string) =
    if conn.isNil:
      return
    let rk = connRefKey(conn)
    if rk in ep.tlsByConn:
      return

    let sslCtx = SSL_CTX_new(TLS_method())
    if sslCtx.isNil:
      raise newException(ValueError, "SSL_CTX_new failed for QUIC connection")

    if ep.role == qerServer:
      if ep.config.tlsCertFile.len == 0 or ep.config.tlsKeyFile.len == 0:
        SSL_CTX_free(sslCtx)
        raise newException(ValueError, "QUIC server requires tlsCertFile/tlsKeyFile")
      if SSL_CTX_use_certificate_chain_file(sslCtx, ep.config.tlsCertFile.cstring) != 1:
        SSL_CTX_free(sslCtx)
        raise newException(ValueError, "QUIC server failed loading certificate chain")
      if SSL_CTX_use_PrivateKey_file(sslCtx, ep.config.tlsKeyFile.cstring, SSL_FILETYPE_PEM) != 1:
        SSL_CTX_free(sslCtx)
        raise newException(ValueError, "QUIC server failed loading private key")
      if SSL_CTX_check_private_key(sslCtx) != 1:
        SSL_CTX_free(sslCtx)
        raise newException(ValueError, "QUIC server private key does not match certificate")
    else:
      if ep.config.tlsVerifyPeer:
        SSL_CTX_set_verify(sslCtx, SSL_VERIFY_PEER, nil)
        if ep.config.tlsCaFile.len > 0 or ep.config.tlsCaDir.len > 0:
          if SSL_CTX_load_verify_locations(
            sslCtx,
            if ep.config.tlsCaFile.len > 0: ep.config.tlsCaFile.cstring else: nil,
            if ep.config.tlsCaDir.len > 0: ep.config.tlsCaDir.cstring else: nil
          ) != 1:
            SSL_CTX_free(sslCtx)
            raise newException(ValueError, "QUIC client failed loading TLS CA trust roots")
        else:
          if SSL_CTX_set_default_verify_paths(sslCtx) != 1:
            SSL_CTX_free(sslCtx)
            raise newException(ValueError, "QUIC client could not load default TLS trust roots")
      else:
        SSL_CTX_set_verify(sslCtx, SSL_VERIFY_NONE, nil)

    if ep.config.alpn.len > 0:
      let wire = encodeAlpnWire(ep.config.alpn)
      if wire.len > 0:
        if ep.role == qerServer:
          quicServerAlpnWireByCtx[cast[uint](sslCtx)] = wire
          discard SSL_CTX_set_alpn_select_cb(sslCtx, alpnSelectCallback, nil)
        else:
          discard SSL_CTX_set_alpn_protos(sslCtx, cast[cstring](unsafeAddr wire[0]), cuint(wire.len))

    let ssl = SSL_new(sslCtx)
    if ssl.isNil:
      quicServerAlpnWireByCtx.del(cast[uint](sslCtx))
      quicTlsKeyLogByCtx.del(cast[uint](sslCtx))
      SSL_CTX_free(sslCtx)
      raise newException(ValueError, "SSL_new failed for QUIC connection")

    if not ep.config.tlsKeyLogCallback.isNil:
      quicTlsKeyLogByCtx[cast[uint](sslCtx)] = ep.config.tlsKeyLogCallback
      SSL_CTX_set_keylog_callback(sslCtx, tlsKeyLogCallback)
    else:
      quicTlsKeyLogByCtx.del(cast[uint](sslCtx))

    if ep.role == qerClient:
      let sni = if ep.config.serverName.len > 0: ep.config.serverName else: host
      if sni.len > 0:
        if boringSslSetTlsExtHostName(ssl, sni.cstring) != 1:
          SSL_free(ssl)
          quicServerAlpnWireByCtx.del(cast[uint](sslCtx))
          quicTlsKeyLogByCtx.del(cast[uint](sslCtx))
          SSL_CTX_free(sslCtx)
          raise newException(ValueError, "QUIC client failed setting TLS SNI")
      sslSetConnectState(ssl)
    else:
      sslSetAcceptState(ssl)

    let hsCtx = newQuicHandshakeContext(
      localTransportParameters = conn.localTransportParameters,
      boundConn = conn
    )
    if not attachQuicTls(ssl, hsCtx):
      SSL_free(ssl)
      quicServerAlpnWireByCtx.del(cast[uint](sslCtx))
      quicTlsKeyLogByCtx.del(cast[uint](sslCtx))
      SSL_CTX_free(sslCtx)
      raise newException(ValueError, "failed to attach QUIC TLS callbacks")

    ep.tlsByConn[rk] = hsCtx
    ep.sslByConn[rk] = ssl
    ep.sslCtxByConn[rk] = sslCtx
    if ep.role == qerClient:
      ep.peerCertVerifiedByConn[rk] = false

  proc flushTlsCryptoToConnection(conn: QuicConnection, hsCtx: QuicHandshakeContext) =
    if conn.isNil or hsCtx.isNil:
      return
    for level in [qelInitial, qelHandshake, qelApplication]:
      let bytes = hsCtx.takeCryptoData(level, outgoing = true)
      if bytes.len > 0:
        conn.queueCryptoData(level, bytes)

  proc verifyClientPeerIdentity(ep: QuicEndpoint,
                                conn: QuicConnection,
                                ssl: openssl.SslPtr): string =
    if ep.isNil or conn.isNil or ssl.isNil:
      return "invalid TLS peer verification context"
    if not ep.config.tlsVerifyPeer:
      return ""

    let rk = connRefKey(conn)
    if rk in ep.peerCertVerifiedByConn and ep.peerCertVerifiedByConn[rk]:
      return ""

    let verifyResult = SSL_get_verify_result(ssl)
    if verifyResult != X509_V_OK:
      return "TLS peer certificate verification failed with code " & $verifyResult

    let cert = boringSslGetPeerCertificate(ssl)
    if cert.isNil:
      return "TLS peer did not provide a certificate"

    let expectedHostRaw =
      if ep.config.serverName.len > 0:
        ep.config.serverName
      else:
        conn.pathManager.activePath().peerAddress
    let expectedHost = stripBracketedHost(expectedHostRaw.strip())
    if expectedHost.len == 0:
      X509_free(cert)
      return "missing expected peer host name for certificate validation"

    var hostMatch = 0
    if isIpLiteral(expectedHost):
      hostMatch = X509_check_ip_asc(cert, expectedHost.cstring, 0'u32)
    else:
      hostMatch = X509_check_host(cert, expectedHost.cstring, expectedHost.len.cint, 0'u32, nil)
    X509_free(cert)
    if hostMatch != 1:
      return "TLS peer certificate host verification failed for '" & expectedHost & "'"

    ep.peerCertVerifiedByConn[rk] = true
    ""

  proc driveConnectionTls(ep: QuicEndpoint, conn: QuicConnection, nowMicros: int64 = 0'i64) =
    if conn.isNil:
      return
    let rk = connRefKey(conn)
    if rk notin ep.sslByConn or rk notin ep.tlsByConn:
      return
    let ssl = ep.sslByConn[rk]
    let hsCtx = ep.tlsByConn[rk]

    let rc = sslDoHandshake(ssl)
    var errCode = 0
    if rc != 1:
      let err = SSL_get_error(ssl, rc)
      errCode = err
      if err notin {SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE, SSL_ERROR_WANT_X509_LOOKUP, SSL_ERROR_ZERO_RETURN}:
        conn.setCloseReason(0x100'u64, "TLS handshake failure")
        conn.enterDraining()
        conn.pendingControlFrames.add QuicFrame(
          kind: qfkConnectionClose,
          isApplicationClose: false,
          errorCode: 0x100'u64, # TLS handshake failure mapped to generic crypto error.
          frameType: 0'u64,
          reason: "TLS handshake failure"
        )
    else:
      hsCtx.handshakeComplete = true
      if ep.role == qerClient:
        let peerVerifyErr = ep.verifyClientPeerIdentity(conn, ssl)
        if peerVerifyErr.len > 0:
          conn.setCloseReason(0x100'u64, peerVerifyErr)
          conn.pendingControlFrames.add QuicFrame(
            kind: qfkConnectionClose,
            isApplicationClose: false,
            errorCode: 0x100'u64,
            frameType: 0'u64,
            reason: peerVerifyErr
          )
          conn.enterDraining()
          ep.emitQlog("tls-peer-verify-failed conn=" & $rk & " reason=" & peerVerifyErr)
      if conn.handshakeState == qhsOneRtt and conn.state in {qcsInitial, qcsHandshaking}:
        conn.state = qcsActive
        conn.setActiveRetryToken(@[])
        if conn.role == qcrServer:
          conn.pendingControlFrames.add QuicFrame(kind: qfkHandshakeDone)
      discard SSL_process_quic_post_handshake(ssl)

    flushTlsCryptoToConnection(conn, hsCtx)
    let keyReadyInitial = if conn.levelWriteKeys[0].ready: 1 else: 0
    let keyReadyHandshake = if conn.levelWriteKeys[1].ready: 1 else: 0
    let keyReadyApp = if conn.levelWriteKeys[2].ready: 1 else: 0
    ep.emitQlog("tls-drive conn=" & $rk &
      " rc=" & $rc &
      " err=" & $errCode &
      " readLevel=" & $SSL_quic_read_level(ssl) &
      " writeLevel=" & $SSL_quic_write_level(ssl) &
      " keysW(i,h,a)=" & $keyReadyInitial & "," & $keyReadyHandshake & "," & $keyReadyApp &
      " cryptoPending(i,h,a)=" &
        $conn.cryptoSendPending[0].len & "," &
        $conn.cryptoSendPending[1].len & "," &
        $conn.cryptoSendPending[2].len &
      " alert=" & $hsCtx.alertCode &
      " now=" & $nowMicros)

    readPeerTransportParametersFromTls(ssl, hsCtx)
    if hsCtx.peerTransportParametersReady:
      let peerTp = hsCtx.peerTransportParametersDecoded
      let tpErr = conn.validatePeerTransportParameters(peerTp)
      if tpErr.len > 0:
        conn.setCloseReason(0x08'u64, tpErr)
        conn.pendingControlFrames.add QuicFrame(
          kind: qfkConnectionClose,
          isApplicationClose: false,
          errorCode: 0x08'u64, # TRANSPORT_PARAMETER_ERROR
          frameType: 0'u64,
          reason: tpErr
        )
        conn.enterDraining()
        ep.emitQlog("peer-transport-params-invalid conn=" & $rk & " reason=" & tpErr)
      else:
        conn.activatePeerTransportParameters(peerTp)
      hsCtx.peerTransportParametersReady = false
      hsCtx.peerTransportParametersProcessed = true

proc findConnectionByShortHeader(ep: QuicEndpoint, data: openArray[byte]): QuicConnection =
  for _, conn in ep.connections:
    if conn.localConnId.len == 0:
      continue
    if byteSliceEq(data, 1, conn.localConnId):
      return conn

proc findConnection(ep: QuicEndpoint,
                    hdr: QuicPacketHeader,
                    datagram: openArray[byte],
                    peerKey: string): QuicConnection =
  if hdr.dstConnId.len > 0:
    let k = makeCidKey(hdr.dstConnId)
    if k in ep.connectionsByCid:
      return ep.connectionsByCid[k]
  if hdr.packetType == qptShort:
    let byShort = ep.findConnectionByShortHeader(datagram)
    if not byShort.isNil:
      return byShort
  let (peerHost, peerPort) = splitConnKey(peerKey)
  let mappedCid = ep.directory.lookupByPath(peerHost, peerPort)
  if mappedCid.len > 0 and mappedCid in ep.connectionsByCid:
    return ep.connectionsByCid[mappedCid]
  if peerKey in ep.connections:
    return ep.connections[peerKey]

proc validatedPathCount(conn: QuicConnection): int =
  for p in conn.pathManager.paths:
    if p.validationState == qpvsValidated:
      inc result

proc cleanupExpiredConnections(ep: QuicEndpoint) =
  if ep.isNil or not ep.running:
    return
  let nowUs = int64(epochTime() * 1_000_000.0)
  let idleTimeoutUs = int64(max(0, ep.config.quicIdleTimeoutMs)) * 1_000'i64
  var expired: seq[(QuicConnection, uint64, string)] = @[]

  for _, conn in ep.connectionsByCid:
    if conn.isNil:
      continue
    if conn.state == qcsClosed:
      expired.add((conn, 0'u64, "connection closed"))
      continue

    if conn.state == qcsDraining:
      if conn.drainingSinceMicros <= 0:
        conn.drainingSinceMicros = nowUs
      var drainRecovery = conn.recovery
      # Draining timeout uses a non-backed-off PTO baseline so previous probe
      # backoff does not indefinitely extend close completion.
      drainRecovery.ptoCount = 0
      let drainTimeoutUs = max(QuicMinDrainingTimeoutMicros, 3 * drainRecovery.currentPtoMicros())
      if nowUs - conn.drainingSinceMicros >= drainTimeoutUs:
        expired.add((conn, 0'u64, "draining timeout"))
      continue

    if idleTimeoutUs > 0 and conn.lastActivityMicros > 0 and nowUs - conn.lastActivityMicros >= idleTimeoutUs:
      conn.closeConnection()
      expired.add((conn, 0'u64, "idle timeout"))

  for item in expired:
    let conn = item[0]
    let code = item[1]
    let reason = item[2]
    if not ep.onConnectionClosed.isNil:
      discard ep.onConnectionClosed(conn, code, reason)
    ep.removeConnectionMappings(conn)

proc flushConnectionPackets(ep: QuicEndpoint,
                            conn: QuicConnection,
                            targetAddress: string = "",
                            targetPort: int = 0): CpsVoidFuture {.cps.} =
  let dg = conn.popOutgoingDatagrams()
  var deferred: seq[seq[byte]] = @[]
  var payloadIdx = 0
  while payloadIdx < dg.len:
    let payload = dg[payloadIdx]
    let p = conn.pathManager.activePath()
    let sendHost = if targetAddress.len > 0: targetAddress else: p.peerAddress
    let sendPort = if targetPort > 0: targetPort else: p.peerPort
    let applyCwndGating = conn.nextPendingSendIsAckEliciting()

    # Enforce congestion window gating before packet emission. If we cannot send
    # the next queued packet right now, defer it and the remaining queue to keep
    # payload/send-record ordering aligned.
    if applyCwndGating:
      if conn.recovery.congestionWindowAvailable() < payload.len:
        if conn.consumePtoCwndBypassAllowance():
          ep.emitQlog("datagram-send-cwnd-bypass reason=pto peer=" & sendHost & ":" & $sendPort &
            " bytes=" & $payload.len)
        else:
          ep.emitQlog("datagram-send-deferred cwnd peer=" & sendHost & ":" & $sendPort &
            " bytes=" & $payload.len)
          while payloadIdx < dg.len:
            deferred.add dg[payloadIdx]
            inc payloadIdx
          break

    if not conn.canSendOnPath(sendHost, sendPort, payload.len):
      ep.emitQlog("datagram-send-blocked amplification peer=" & sendHost & ":" & $sendPort &
        " bytes=" & $payload.len)
      while payloadIdx < dg.len:
        deferred.add dg[payloadIdx]
        inc payloadIdx
      break

    await ep.dispatcher.sendDatagram(payload, sendHost, sendPort)
    conn.notePacketActuallySent()
    conn.bytesSent += uint64(payload.len)
    inc conn.datagramsSent
    conn.noteDatagramSentOnPath(sendHost, sendPort, payload.len)
    if existsEnv("CPS_QUIC_DEBUG"):
      var outHdr: QuicPacketHeader
      var outOff = 0
      var outErr = ""
      if tryParseHeaderWithOffset(payload, outHdr, outOff, outErr):
        ep.emitQlog("datagram-sent type=" & $outHdr.packetType &
          " bytes=" & $payload.len &
          " dcidLen=" & $outHdr.dstConnId.len &
          " scidLen=" & $outHdr.srcConnId.len &
          " peer=" & sendHost & ":" & $sendPort)
      else:
        ep.emitQlog("datagram-sent bytes=" & $payload.len &
          " peer=" & sendHost & ":" & $sendPort &
          " parse=failed reason=" & outErr)
    else:
      ep.emitQlog("datagram-sent bytes=" & $payload.len & " peer=" & sendHost & ":" & $sendPort)
    if applyCwndGating:
      let pacingUs = conn.recovery.pacingDelayMicros(payload.len)
      if pacingUs >= 1000:
        await cpsSleep(int(pacingUs div 1000))
    inc payloadIdx

  if deferred.len > 0:
    # Preserve payload/send-record ordering if new datagrams were queued while
    # we were awaiting socket I/O or pacing delay during this flush.
    if conn.outgoingDatagrams.len == 0:
      conn.outgoingDatagrams = deferred
    else:
      let existing = conn.outgoingDatagrams
      conn.outgoingDatagrams = @[]
      var deferredIdx = 0
      while deferredIdx < deferred.len:
        conn.outgoingDatagrams.add deferred[deferredIdx]
        inc deferredIdx
      var existingIdx = 0
      while existingIdx < existing.len:
        conn.outgoingDatagrams.add existing[existingIdx]
        inc existingIdx

proc queueAckAndControl(ep: QuicEndpoint,
                        conn: QuicConnection,
                        space: QuicPacketNumberSpace,
                        targetAddress: string = "",
                        targetPort: int = 0): CpsVoidFuture {.cps.} =
  let typ = if space == qpnsApplication: qptShort
    elif space == qpnsHandshake: qptHandshake
    else: qptInitial
  if not conn.canEncodePacketType(typ):
    ep.emitQlog("packet-send-skipped missing keys type=" & $typ)
    return

  let acks = conn.consumePendingAcks(space)
  if acks.len > 0:
    let ack = buildAckFrame(acks)
    if existsEnv("CPS_QUIC_DEBUG"):
      ep.emitQlog("send-packet reason=ack type=" & $typ &
        " count=" & $acks.len)
    let bytes = conn.encodeProtectedPacket(typ, @[ack])
    if conn.outgoingDatagrams.len > 0:
      conn.queueDatagramForSendFront(bytes)
    else:
      conn.queueDatagramForSend(bytes)

  let retransmitFrames = conn.popPendingRetransmitFrames(space)
  if retransmitFrames.len > 0:
    if existsEnv("CPS_QUIC_DEBUG"):
      ep.emitQlog("send-packet reason=retransmit type=" & $typ &
        " frames=" & $retransmitFrames.len)
    let bytes = conn.encodeProtectedPacket(typ, retransmitFrames)
    conn.queueDatagramForSend(bytes)

  let cryptoFrames = conn.drainCryptoFrames(
    encryptionLevelForSpace(space),
    maxFrameData = max(1, ep.config.quicMaxDatagramFrameSize - 96)
  )
  var cryptoIdx = 0
  while cryptoIdx < cryptoFrames.len:
    let cf = cryptoFrames[cryptoIdx]
    if existsEnv("CPS_QUIC_DEBUG"):
      ep.emitQlog("send-packet reason=crypto type=" & $typ &
        " off=" & $cf.cryptoOffset &
        " len=" & $cf.cryptoData.len)
    let bytes = conn.encodeProtectedPacket(typ, @[cf])
    conn.queueDatagramForSend(bytes)
    inc cryptoIdx

  let controlFrames = conn.popPendingControlFrames()
  if controlFrames.len > 0:
    var sendControl: seq[QuicFrame] = @[]
    var deferControl: seq[QuicFrame] = @[]
    for f in controlFrames:
      # HANDSHAKE_DONE is only valid in 1-RTT packets.
      if f.kind == qfkHandshakeDone and typ != qptShort:
        deferControl.add f
      else:
        sendControl.add f
    if deferControl.len > 0:
      for f in deferControl:
        conn.pendingControlFrames.add f
    if sendControl.len == 0:
      discard
    else:
      if existsEnv("CPS_QUIC_DEBUG"):
        var kinds: seq[string] = @[]
        for f in sendControl:
          kinds.add $f.kind
        ep.emitQlog("send-packet reason=control type=" & $typ &
          " frames=" & $sendControl.len &
          " kinds=" & kinds.join(","))
      let bytes = conn.encodeProtectedPacket(typ, sendControl)
      conn.queueDatagramForSend(bytes)

  if typ == qptShort:
    let streamFrames = conn.drainSendStreamFrames(
      maxFrameData = max(1, ep.config.quicMaxDatagramFrameSize - 64),
      maxFrames = 256
    )
    for sf in streamFrames:
      if existsEnv("CPS_QUIC_DEBUG"):
        ep.emitQlog("send-short reason=queued-stream sid=" & $sf.streamId &
          " len=" & $sf.streamData.len & " fin=" & $sf.streamFin)
      let bytes = conn.encodeProtectedPacket(typ, @[sf])
      conn.queueDatagramForSend(bytes)

  await ep.flushConnectionPackets(conn, targetAddress = targetAddress, targetPort = targetPort)

proc runPeriodicPtoMaintenance(ep: QuicEndpoint): CpsVoidFuture {.cps.} =
  if ep.isNil or not ep.running:
    return
  let nowUs = int64(epochTime() * 1_000_000.0)
  var connections: seq[QuicConnection] = @[]
  for _, mappedConn in ep.connectionsByCid:
    if mappedConn.isNil:
      continue
    connections.add mappedConn

  for qconn in connections:
    if qconn.state in {qcsClosed, qcsDraining}:
      continue
    let expiredSpaces = qconn.ptoExpiredSpaces(nowUs)
    if expiredSpaces.len == 0:
      continue

    for space in expiredSpaces:
      qconn.queuePtoProbe(space)
      await ep.queueAckAndControl(qconn, space)

proc scheduleHousekeeping(ep: QuicEndpoint) =
  if ep.isNil or not ep.running:
    return
  let loop = getEventLoop()
  ep.housekeepingTimer = loop.registerTimer(QuicHousekeepingIntervalMs, proc() =
    if not ep.running:
      return
    cleanupExpiredConnections(ep)
    let ptoFut = runPeriodicPtoMaintenance(ep)
    if not ptoFut.isNil:
      ptoFut.addCallback(proc() =
        if ptoFut.hasError():
          let err = ptoFut.getError()
          if err.isNil:
            ep.emitQlog("housekeeping-pto-error unknown")
          else:
            ep.emitQlog("housekeeping-pto-error reason=" & err.msg)
      )
      discard ptoFut
    ep.scheduleHousekeeping()
  )

proc flushPendingControl*(ep: QuicEndpoint,
                          conn: QuicConnection): CpsVoidFuture {.cps.} =
  ## Attempt to flush queued ACK/control/retransmit data for the best
  ## available packet number space on this connection.
  if ep.isNil or conn.isNil:
    return
  let p = conn.pathManager.activePath()
  if conn.canEncodePacketType(qptShort):
    await ep.queueAckAndControl(conn, qpnsApplication, targetAddress = p.peerAddress, targetPort = p.peerPort)
  elif conn.canEncodePacketType(qptHandshake):
    await ep.queueAckAndControl(conn, qpnsHandshake, targetAddress = p.peerAddress, targetPort = p.peerPort)
  elif conn.canEncodePacketType(qptInitial):
    await ep.queueAckAndControl(conn, qpnsInitial, targetAddress = p.peerAddress, targetPort = p.peerPort)

proc maybeSendVersionNegotiation(ep: QuicEndpoint,
                                 hdr: QuicPacketHeader,
                                 host: string,
                                 port: int): CpsVoidFuture {.cps.} =
  let versions = ep.supportedWireVersions()
  let vn = encodeVersionNegotiationPacket(
    sourceConnId = hdr.dstConnId,
    destinationConnId = hdr.srcConnId,
    supportedVersions = versions
  )
  await ep.dispatcher.sendDatagram(vn, host, port)
  ep.emitQlog("version-negotiation-sent peer=" & host & ":" & $port)

proc maybeSendStatelessReset(ep: QuicEndpoint, data: seq[byte], host: string, port: int): CpsVoidFuture {.cps.} =
  if ep.role != qerServer:
    return
  # RFC 9000: stateless reset datagrams are at least 21 bytes and should not
  # exceed the triggering datagram size.
  if data.len < StatelessResetMinLen:
    return
  if (data[0] and 0x80'u8) != 0:
    return
  var cidGuess = newSeq[byte](8)
  for i in 0 ..< 8:
    cidGuess[i] = data[1 + i]
  let token = deriveStatelessResetToken(ep.config.statelessResetSecret, cidGuess)
  let srLen = min(64, data.len)
  let reset = generateStatelessReset(token, srLen)
  await ep.dispatcher.sendDatagram(reset, host, port)
  ep.emitQlog("stateless-reset-sent peer=" & host & ":" & $port)

proc createConnection(ep: QuicEndpoint,
                      role: QuicConnectionRole,
                      peerKey: string,
                      host: string,
                      port: int,
                      hdr: QuicPacketHeader,
                      serverOriginalDestinationConnId: openArray[byte] = @[],
                      serverRetrySourceConnId: openArray[byte] = @[]): QuicConnection =
  let localCid = newLocalConnId((if role == qcrClient: "client-" else: "server-") & peerKey)
  var peerCid: seq[byte]
  if role == qcrServer:
    # Server packets are addressed to the CID chosen by the client
    # (the client's Source CID), which can legitimately be zero-length.
    peerCid = hdr.srcConnId
  else:
    peerCid = if hdr.srcConnId.len > 0: hdr.srcConnId else: hdr.dstConnId
  let version = if hdr.version != 0'u32: hdr.version else: ep.preferredWireVersion()
  if role == qcrClient and peerCid.len == 0:
    peerCid = newLocalConnId("odcid-" & peerKey)
  result = newQuicConnection(
    role,
    localCid,
    peerCid,
    host,
    port,
    version,
    qlogSink = ep.config.qlogSink,
    qlogEventSink = ep.config.qlogEventSink,
    tlsKeyLogCallback = ep.config.tlsKeyLogCallback
  )
  if role == qcrServer and hdr.dstConnId.len > 0:
    # RFC9001 Initial secrets are derived from the client's original DCID.
    result.setInitialSecretConnectionId(hdr.dstConnId)
  ep.configureConnection(result)
  if role == qcrServer and serverOriginalDestinationConnId.len > 0:
    result.localTransportParameters.originalDestinationConnectionId = @serverOriginalDestinationConnId
  if role == qcrServer:
    result.localTransportParameters.retrySourceConnectionId = @serverRetrySourceConnId
  ep.registerConnection(peerKey, result)
  when defined(useBoringSSL):
    ep.initializeConnectionTls(result, host)
    ep.driveConnectionTls(result, nowMicros = 0'i64)

proc handleDatagram(ep: QuicEndpoint, data: seq[byte], host: string, port: int): CpsVoidFuture {.cps.} =
  if data.len == 0:
    return

  var packets: seq[seq[byte]] = @[]
  try:
    packets = splitCoalescedPackets(data)
  except ValueError:
    packets = @[data]
  if packets.len > 1:
    # Process first packet and any additional long-header packets.
    # Ignore trailing short-header fragments here to avoid treating coalesced
    # datagram tail bytes as standalone undecryptable packets.
    var packetIdx = 0
    while packetIdx < packets.len:
      let coalescedPacket = packets[packetIdx]
      if packetIdx == 0:
        await ep.handleDatagram(coalescedPacket, host, port)
      elif coalescedPacket.len > 0 and (coalescedPacket[0] and 0x80'u8) != 0'u8:
        await ep.handleDatagram(coalescedPacket, host, port)
      elif existsEnv("CPS_QUIC_DEBUG"):
        ep.emitQlog("coalesced-tail-dropped bytes=" & $coalescedPacket.len &
          " first=0x" & (if coalescedPacket.len > 0: toHex(int(coalescedPacket[0]), 2) else: "00"))
      inc packetIdx
    return

  var hdr: QuicPacketHeader
  var hdrOff = 0
  var parseErr = ""
  if not tryParseHeaderWithOffset(data, hdr, hdrOff, parseErr):
    if existsEnv("CPS_QUIC_DEBUG"):
      var preview: seq[string] = @[]
      let limit = min(data.len, 30)
      for i in 0 ..< limit:
        preview.add("0x" & toHex(int(data[i]), 2))
      ep.emitQlog("datagram-parse-failed peer=" & host & ":" & $port &
        " bytes=" & $data.len &
        " first=" & preview.join(",") &
        " reason=" & parseErr)
    await ep.maybeSendStatelessReset(data, host, port)
    return

  let peerKey = makeConnKey(host, port)
  var retryTokenValidated = false
  var retryTokenOriginalDcid: seq[byte] = @[]
  var retryTokenSourceCid: seq[byte] = @[]
  if existsEnv("CPS_QUIC_DEBUG"):
    ep.emitQlog("datagram-header type=" & $hdr.packetType &
      " version=" & $hdr.version &
      " dcidLen=" & $hdr.dstConnId.len &
      " scidLen=" & $hdr.srcConnId.len &
      " peer=" & peerKey)

  if ep.role == qerServer and hdr.packetType != qptShort and hdr.packetType != qptVersionNegotiation:
    if not ep.supportsWireVersion(hdr.version):
      await ep.maybeSendVersionNegotiation(hdr, host, port)
      return
    if hdr.packetType == qptInitial and ep.config.quicUseRetry:
      if hdr.token.len == 0:
        let retryScid = newLocalConnId("retry-" & peerKey)
        let retryToken = issueQuicToken(
          secretKey = ep.config.tokenSecretKey,
          purpose = qtpRetry,
          clientAddress = peerKey,
          originalDestinationConnectionId = hdr.dstConnId,
          retrySourceConnectionId = retryScid,
          ttlSeconds = 120
        )
        let retry = encodeRetryPacket(
          version = hdr.version,
          destinationConnId = hdr.srcConnId,
          sourceConnId = retryScid,
          token = retryToken,
          originalDestinationConnId = hdr.dstConnId
        )
        await ep.dispatcher.sendDatagram(retry, host, port)
        ep.emitQlog("retry-sent peer=" & peerKey)
        return
      else:
        let validation = validateQuicToken(
          secretKey = ep.config.tokenSecretKey,
          token = hdr.token,
          expectedPurpose = qtpRetry,
          clientAddress = peerKey,
          expectedRetrySourceConnectionId = hdr.dstConnId
        )
        if not validation.valid:
          ep.emitQlog("retry-token-invalid peer=" & peerKey)
          return
        retryTokenValidated = true
        retryTokenOriginalDcid = validation.originalDestinationConnectionId
        retryTokenSourceCid = validation.retrySourceConnectionId

  var conn = ep.findConnection(hdr, data, peerKey)
  if conn.isNil:
    if ep.role == qerServer and hdr.packetType != qptInitial:
      # Servers must only create new connections from Initial packets.
      # Unknown short-header packets get a stateless reset signal; other
      # packet types are silently dropped.
      if hdr.packetType == qptShort:
        await ep.maybeSendStatelessReset(data, host, port)
      return
    if ep.config.maxConnections > 0 and ep.connectionsByCid.len >= ep.config.maxConnections:
      ep.emitQlog("connection-limit-reached peer=" & peerKey)
      return
    let role = if ep.role == qerServer: qcrServer else: qcrClient
    conn = ep.createConnection(
      role,
      peerKey,
      host,
      port,
      hdr,
      serverOriginalDestinationConnId = retryTokenOriginalDcid,
      serverRetrySourceConnId = retryTokenSourceCid
    )
    if not ep.onConnection.isNil:
      await ep.onConnection(conn)
  elif hdr.packetType == qptShort and conn.handshakeState == qhsOneRtt:
    # NAT rebinding / migration candidate detection: validate new path before use.
    let pathIdx = conn.pathManager.ensurePath(host, port)
    if conn.pathManager.paths[pathIdx].validationState == qpvsNone and ep.config.quicEnableMigration:
      let candidate = conn.pathManager.beginValidation(host, port)
      if conn.canEncodePacketType(qptShort):
        conn.pendingControlFrames.add QuicFrame(kind: qfkPathChallenge, pathData: candidate.challengeData)
    elif conn.pathManager.paths[pathIdx].validationState == qpvsValidated:
      conn.pathManager.activePathId = conn.pathManager.paths[pathIdx].pathId

  if retryTokenValidated:
    conn.addressValidated = true
    conn.pathManager.markPathValidated(host, port)
    if retryTokenOriginalDcid.len > 0:
      conn.localTransportParameters.originalDestinationConnectionId = retryTokenOriginalDcid
    if retryTokenSourceCid.len > 0:
      conn.localTransportParameters.retrySourceConnectionId = retryTokenSourceCid

  if hdr.packetType == qptVersionNegotiation:
    if conn.role == qcrClient:
      try:
        let vn = parseVersionNegotiationPacket(data)
        var chosen = 0'u32
        let supported = ep.supportedWireVersions()
        for localVer in supported:
          for peerVer in vn.supportedVersions:
            if localVer == peerVer:
              chosen = localVer
              break
          if chosen != 0'u32:
            break
        if chosen != 0'u32 and chosen != conn.version:
          conn.version = chosen
          if vn.sourceConnId.len > 0:
            conn.peerConnId = vn.sourceConnId
          conn.setActiveRetryToken(@[])
          if conn.canEncodePacketType(qptInitial):
            let initial = conn.encodeProtectedPacket(qptInitial, @[QuicFrame(kind: qfkPing)])
            conn.queueDatagramForSend(initial)
            await ep.flushConnectionPackets(conn, targetAddress = host, targetPort = port)
      except ValueError:
        discard
    return

  if hdr.packetType == qptRetry:
    if conn.role == qcrClient:
      let odcid = conn.originalDestinationConnectionIdForValidation()
      let parsedRetry = parseValidatedRetry(data, odcid)
      if parsedRetry.ok:
        conn.onRetryReceived(parsedRetry.srcConnId, parsedRetry.token)
        when defined(useBoringSSL):
          ep.driveConnectionTls(conn, nowMicros = int64(epochTime() * 1_000_000.0))
        await ep.queueAckAndControl(conn, qpnsInitial, targetAddress = host, targetPort = port)
        await ep.flushConnectionPackets(conn, targetAddress = host, targetPort = port)
      elif existsEnv("CPS_QUIC_DEBUG"):
        ep.emitQlog("retry-parse-or-integrity-failed peer=" & peerKey)
    return

  conn.noteDatagramReceived(data.len, peerAddress = host, peerPort = port)
  if conn.isStatelessResetFromPeer(data):
    conn.setCloseReason(0'u64, "stateless reset")
    conn.closeConnection()
    ep.emitQlog("stateless-reset-received peer=" & peerKey)
    if not ep.onConnectionClosed.isNil:
      await ep.onConnectionClosed(conn, 0'u64, "stateless reset")
    return

  var packet: QuicPacket
  var decodeErr = ""
  if not tryDecodeProtectedPacket(conn, data, packet, decodeErr):
    if existsEnv("CPS_QUIC_DEBUG"):
      ep.emitQlog("protected-decode-failed type=" & $hdr.packetType &
        " peer=" & peerKey & " reason=" & decodeErr)
    # Drop undecryptable short-header packets for existing path traffic.
    # Stateless reset emission is reserved for unknown/invalid short-header probes.
    if hdr.packetType != qptShort:
      await ep.maybeSendStatelessReset(data, host, port)
    return
  if hdr.srcConnId.len > 0:
    # Keep peer CID current before TLS TP validation so
    # initial_source_connection_id checks compare against the active peer SCID.
    conn.peerConnId = hdr.srcConnId
  let prevHs = conn.handshakeState
  let prevConnState = conn.state
  let prevValidatedCount = validatedPathCount(conn)
  let space = if hdr.packetType == qptShort: qpnsApplication else: packetTypeToSpace(hdr.packetType)
  if existsEnv("CPS_QUIC_DEBUG"):
    for frameItem in packet.frames:
      if frameItem.kind == qfkCrypto:
        ep.emitQlog("frame-recv kind=crypto level=" & $encryptionLevelForSpace(space) &
          " off=" & $frameItem.cryptoOffset & " len=" & $frameItem.cryptoData.len)
      elif frameItem.kind == qfkStream:
        ep.emitQlog("frame-recv kind=stream sid=" & $frameItem.streamId &
          " off=" & $frameItem.streamOffset &
          " len=" & $frameItem.streamData.len &
          " fin=" & $frameItem.streamFin)
      elif frameItem.kind == qfkConnectionClose:
        ep.emitQlog("frame-recv kind=qfkConnectionClose app=" & $frameItem.isApplicationClose &
          " code=" & $frameItem.errorCode &
          " frameType=" & $frameItem.frameType &
          " reason=" & frameItem.reason)
      else:
        ep.emitQlog("frame-recv kind=" & $frameItem.kind)
  when defined(useBoringSSL):
    let rk = connRefKey(conn)
    let hasTls = rk in ep.sslByConn

  var packetApplyErr = ""
  try:
    conn.onPacketReceived(packet, peerAddress = host, peerPort = port)
  except CatchableError as e:
    packetApplyErr = e.msg

  if packetApplyErr.len > 0:
    var reason = packetApplyErr
    if reason.len > 120:
      reason = reason[0 ..< 120]
    conn.pendingControlFrames.add QuicFrame(
      kind: qfkConnectionClose,
      isApplicationClose: false,
      errorCode: 0x0A'u64, # PROTOCOL_VIOLATION
      frameType: 0'u64,
      reason: reason
    )
    conn.setCloseReason(0x0A'u64, reason)
    conn.enterDraining()
    ep.emitQlog("packet-apply-failed peer=" & peerKey & " reason=" & reason)
    await ep.queueAckAndControl(conn, space, targetAddress = host, targetPort = port)
    if not ep.onConnectionClosed.isNil:
      await ep.onConnectionClosed(conn, 0x0A'u64, reason)
    ep.removeConnectionMappings(conn)
    return

  when defined(useBoringSSL):
    if hasTls:
      let ssl = ep.sslByConn[rk]
      var tlsCryptoError = false
      let tlsLevels = [qelInitial, qelHandshake, qelApplication]
      var levelIdx = 0
      while levelIdx < tlsLevels.len and not tlsCryptoError:
        let cryptoLevel = tlsLevels[levelIdx]
        let tlsBytes = conn.takeCryptoData(cryptoLevel)
        if tlsBytes.len > 0:
          let ok = provideCryptoDataToTls(ssl, cryptoLevel, tlsBytes)
          if existsEnv("CPS_QUIC_DEBUG") and not ok:
            ep.emitQlog("tls-provide-crypto-failed level=" & $cryptoLevel &
              " bytes=" & $tlsBytes.len)
          if not ok:
            tlsCryptoError = true
        inc levelIdx
      if tlsCryptoError:
        conn.pendingControlFrames.add QuicFrame(
          kind: qfkConnectionClose,
          isApplicationClose: false,
          errorCode: 0x100'u64, # generic crypto error mapping
          frameType: 0'u64,
          reason: "TLS CRYPTO ingest failure"
        )
        conn.enterDraining()
      else:
        ep.driveConnectionTls(conn, nowMicros = int64(epochTime() * 1_000_000.0))

  if conn.localConnId.len > 0:
    let ap = conn.pathManager.activePath()
    if ap.validationState == qpvsValidated:
      ep.directory.updatePath(makeCidKey(conn.localConnId), ap.peerAddress, ap.peerPort)

  ep.registerConnection(peerKey, conn)

  var sawStream = false
  for f in packet.frames:
    if f.kind == qfkStream:
      sawStream = true
    elif f.kind == qfkDatagram and not ep.onDatagram.isNil:
      await ep.onDatagram(conn, f.datagramData)

  await ep.queueAckAndControl(conn, space, targetAddress = host, targetPort = port)
  let ptoSpaces = conn.ptoExpiredSpaces(int64(epochTime() * 1_000_000.0))
  for ptoSpace in ptoSpaces:
    conn.queuePtoProbe(ptoSpace)
    await ep.queueAckAndControl(conn, ptoSpace)

  # TLS-driven state changes can queue CRYPTO in a different packet number space
  # (notably Initial -> Handshake on the server flight). Flush all spaces so
  # Handshake packets are emitted promptly instead of stalling on Initial ACKs.
  let allSpaces = [qpnsInitial, qpnsHandshake, qpnsApplication]
  var flushSpaceIdx = 0
  while flushSpaceIdx < allSpaces.len:
    let flushSpace = allSpaces[flushSpaceIdx]
    if flushSpace != space:
      await ep.queueAckAndControl(conn, flushSpace, targetAddress = host, targetPort = port)
    inc flushSpaceIdx

  if not ep.onHandshakeState.isNil:
    let hsChanged = prevHs != conn.handshakeState
    let becameActiveOneRtt =
      prevConnState != conn.state and
      conn.state == qcsActive and
      conn.handshakeState == qhsOneRtt
    if hsChanged or becameActiveOneRtt:
      await ep.onHandshakeState(conn, conn.handshakeState)
  let newValidatedCount = validatedPathCount(conn)
  if newValidatedCount > prevValidatedCount and not ep.onPathValidated.isNil:
    let pathInfo = conn.pathManager.activePath()
    if conn.localConnId.len > 0:
      ep.directory.updatePath(makeCidKey(conn.localConnId), pathInfo.peerAddress, pathInfo.peerPort)
    await ep.onPathValidated(conn, pathInfo.peerAddress, pathInfo.peerPort)

  if sawStream and not ep.onStreamReadable.isNil:
    for f in packet.frames:
      if f.kind == qfkStream:
        await ep.onStreamReadable(conn, f.streamId)

  if (conn.state == qcsClosed or conn.state == qcsDraining) and
      prevConnState != conn.state and
      not ep.onConnectionClosed.isNil:
    let closeCode = conn.closeErrorCode
    let closeReason =
      if conn.closeReason.len > 0:
        conn.closeReason
      else:
        "connection draining/closed"
    await ep.onConnectionClosed(conn, closeCode, closeReason)

  if conn.state == qcsClosed:
    ep.removeConnectionMappings(conn)
  else:
    ep.connections[peerKey] = conn

proc newQuicEndpoint*(role: QuicEndpointRole,
                      bindHost: string,
                      bindPort: int,
                      onConnection: QuicConnectionCallback = nil,
                      onStream: QuicStreamCallback = nil,
                      onDatagram: QuicDatagramCallback = nil,
                      config: QuicEndpointConfig = defaultQuicEndpointConfig(),
                      onHandshakeState: QuicHandshakeStateCallback = nil,
                      onConnectionClosed: QuicConnectionClosedCallback = nil,
                      onPathValidated: QuicPathValidatedCallback = nil,
                      onStreamReadable: QuicStreamCallback = nil): QuicEndpoint =
  let streamReadableCb = if onStreamReadable.isNil: onStream else: onStreamReadable
  result = QuicEndpoint(
    role: role,
    bindHost: bindHost,
    bindPort: bindPort,
    config: config,
    dispatcher: nil,
    directory: newQuicConnectionDirectory(),
    running: false,
    connections: initTable[string, QuicConnection](),
    connectionsByCid: initTable[string, QuicConnection](),
    statelessResetByCid: initTable[string, array[16, byte]](),
    tlsByConn: initTable[uint, QuicHandshakeContext](),
    sslByConn: initTable[uint, openssl.SslPtr](),
    sslCtxByConn: initTable[uint, openssl.SslCtx](),
    peerCertVerifiedByConn: initTable[uint, bool](),
    onConnection: onConnection,
    onStreamReadable: streamReadableCb,
    onDatagram: onDatagram,
    onHandshakeState: onHandshakeState,
    onConnectionClosed: onConnectionClosed,
    onPathValidated: onPathValidated
  )

proc newQuicServerEndpoint*(bindHost: string = "0.0.0.0",
                            bindPort: int = 4433,
                            onConnection: QuicConnectionCallback = nil,
                            onStream: QuicStreamCallback = nil,
                            onDatagram: QuicDatagramCallback = nil,
                            config: QuicEndpointConfig = defaultQuicEndpointConfig(),
                            onHandshakeState: QuicHandshakeStateCallback = nil,
                            onConnectionClosed: QuicConnectionClosedCallback = nil,
                            onPathValidated: QuicPathValidatedCallback = nil,
                            onStreamReadable: QuicStreamCallback = nil): QuicEndpoint =
  newQuicEndpoint(
    qerServer, bindHost, bindPort, onConnection, onStream, onDatagram, config,
    onHandshakeState = onHandshakeState,
    onConnectionClosed = onConnectionClosed,
    onPathValidated = onPathValidated,
    onStreamReadable = onStreamReadable
  )

proc newQuicClientEndpoint*(bindHost: string = "0.0.0.0",
                            bindPort: int = 0,
                            onConnection: QuicConnectionCallback = nil,
                            onStream: QuicStreamCallback = nil,
                            onDatagram: QuicDatagramCallback = nil,
                            config: QuicEndpointConfig = defaultQuicEndpointConfig(),
                            onHandshakeState: QuicHandshakeStateCallback = nil,
                            onConnectionClosed: QuicConnectionClosedCallback = nil,
                            onPathValidated: QuicPathValidatedCallback = nil,
                            onStreamReadable: QuicStreamCallback = nil): QuicEndpoint =
  newQuicEndpoint(
    qerClient, bindHost, bindPort, onConnection, onStream, onDatagram, config,
    onHandshakeState = onHandshakeState,
    onConnectionClosed = onConnectionClosed,
    onPathValidated = onPathValidated,
    onStreamReadable = onStreamReadable
  )

proc start*(ep: QuicEndpoint) =
  if ep.running:
    return
  ep.running = true
  ep.dispatcher = newQuicDispatcher(
    ep.bindHost,
    ep.bindPort,
    onDatagram = proc(data: seq[byte], host: string, port: int): CpsVoidFuture {.closure.} =
      if existsEnv("CPS_QUIC_DEBUG"):
        ep.emitQlog("datagram-recv bytes=" & $data.len & " peer=" & host & ":" & $port)
      handleDatagram(ep, data, host, port),
    maxDatagramSize = max(2048, ep.config.quicMaxDatagramFrameSize + 256)
  )
  ep.dispatcher.start()
  ep.scheduleHousekeeping()
  ep.emitQlog("endpoint-start role=" & $ep.role & " bind=" & ep.bindHost & ":" & $ep.bindPort)

proc listen*(ep: QuicEndpoint) =
  ep.start()

proc shutdown*(ep: QuicEndpoint, closeSocket: bool = true) =
  if not ep.running:
    return
  ep.running = false
  ep.housekeepingTimer.cancel()
  var toClose: seq[QuicConnection] = @[]
  for _, conn in ep.connectionsByCid:
    toClose.add conn
  for conn in toClose:
    ep.removeConnectionMappings(conn)
  if not ep.dispatcher.isNil:
    ep.dispatcher.stop(closeSocket = closeSocket)
  ep.emitQlog("endpoint-shutdown role=" & $ep.role)

proc close*(ep: QuicEndpoint,
            conn: QuicConnection,
            errorCode: uint64 = 0'u64,
            reason: string = ""): CpsVoidFuture {.cps.} =
  if conn.isNil:
    return
  conn.setCloseReason(errorCode, reason)
  conn.closeConnection()
  ep.removeConnectionMappings(conn)
  if not ep.onConnectionClosed.isNil:
    await ep.onConnectionClosed(conn, errorCode, reason)

proc updatePath*(ep: QuicEndpoint,
                 conn: QuicConnection,
                 remoteAddress: string,
                 remotePort: int): CpsVoidFuture {.cps.} =
  if conn.isNil:
    return
  if not conn.canEncodePacketType(qptShort):
    raise newException(ValueError, "cannot migrate path before 1-RTT keys are available")
  let candidate = conn.pathManager.beginValidation(remoteAddress, remotePort)
  if existsEnv("CPS_QUIC_DEBUG"):
    ep.emitQlog("send-short reason=update-path challenge")
  let packet = conn.encodeProtectedPacket(qptShort, @[candidate.pathChallengeFrame()])
  conn.queueDatagramForSend(packet)
  await ep.flushConnectionPackets(conn, targetAddress = remoteAddress, targetPort = remotePort)

proc connect*(ep: QuicEndpoint, remoteAddress: string, remotePort: int): CpsFuture[QuicConnection] {.cps.} =
  if not ep.running:
    raise newException(ValueError, "endpoint is not running")
  let peerKey = makeConnKey(remoteAddress, remotePort)
  if peerKey in ep.connections:
    return ep.connections[peerKey]
  if ep.config.maxConnections > 0 and ep.connectionsByCid.len >= ep.config.maxConnections:
    raise newException(ValueError, "endpoint maxConnections limit reached")

  let fakeHdr = QuicPacketHeader(
    packetType: qptInitial,
    version: ep.preferredWireVersion(),
    srcConnId: @[],
    dstConnId: @[],
    token: @[],
    keyPhase: false,
    packetNumberLen: 2,
    payloadLen: -1
  )
  let conn = ep.createConnection(qcrClient, peerKey, remoteAddress, remotePort, fakeHdr)
  ep.connections[peerKey] = conn
  if not ep.onConnection.isNil:
    await ep.onConnection(conn)

  when defined(useBoringSSL):
    ep.driveConnectionTls(conn, nowMicros = int64(epochTime() * 1_000_000.0))
  await ep.queueAckAndControl(conn, qpnsInitial)
  await ep.flushConnectionPackets(conn)

  if conn.canEncodePacketType(qptInitial):
    let initialPacket = conn.encodeProtectedPacket(qptInitial, @[QuicFrame(kind: qfkPing)])
    conn.queueDatagramForSend(initialPacket)
    await ep.flushConnectionPackets(conn)

  # Wait briefly for 1-RTT readiness so callers can immediately open streams.
  let waitBudgetMs = max(0, min(ep.config.quicIdleTimeoutMs, 5_000))
  var waitedMs = 0
  while waitedMs < waitBudgetMs and not conn.canEncodePacketType(qptShort):
    if conn.state == qcsClosed or conn.state == qcsDraining:
      break
    await cpsSleep(5)
    waitedMs += 5

  ep.connections[peerKey] = conn
  return conn

proc sendStreamData*(ep: QuicEndpoint,
                     conn: QuicConnection,
                     streamId: uint64,
                     data: seq[byte],
                     fin: bool = false): CpsVoidFuture {.cps.} =
  if not conn.canEncodePacketType(qptShort):
    raise newException(ValueError, "cannot send stream data before 1-RTT keys are available")
  if streamId notin conn.streams and ep.config.maxStreamsPerConnection > 0 and
      conn.streams.len >= ep.config.maxStreamsPerConnection:
    raise newException(ValueError, "connection stream limit exceeded")
  let streamObj = conn.getOrCreateStream(streamId)
  if data.len > 0:
    streamObj.appendSendData(data)
  if fin:
    streamObj.markFinPlanned()

  let maxChunk = max(1, ep.config.quicMaxDatagramFrameSize - 64)
  while true:
    let chunk = streamObj.nextSendChunk(maxChunk)
    if chunk.payload.len == 0 and not chunk.fin:
      break
    let streamFrame = QuicFrame(
      kind: qfkStream,
      streamId: streamId,
      streamOffset: chunk.offset,
      streamFin: chunk.fin,
      streamData: chunk.payload
    )
    if existsEnv("CPS_QUIC_DEBUG"):
      ep.emitQlog("send-short reason=api-stream sid=" & $streamId &
        " len=" & $chunk.payload.len & " fin=" & $chunk.fin)
    let bytes = conn.encodeProtectedPacket(qptShort, @[streamFrame])
    conn.queueDatagramForSend(bytes)
    if chunk.fin:
      break

  await ep.flushConnectionPackets(conn)

proc sendDatagram*(ep: QuicEndpoint,
                   conn: QuicConnection,
                   payload: seq[byte]): CpsVoidFuture {.cps.} =
  if not ep.config.quicEnableDatagram:
    raise newException(ValueError, "QUIC DATAGRAM disabled in endpoint config")
  if payload.len > ep.config.quicMaxDatagramFrameSize:
    raise newException(ValueError, "QUIC DATAGRAM exceeds configured max frame size")
  if not conn.canEncodePacketType(qptShort):
    raise newException(ValueError, "cannot send datagram before 1-RTT keys are available")
  let dg = QuicFrame(kind: qfkDatagram, datagramData: payload)
  if existsEnv("CPS_QUIC_DEBUG"):
    ep.emitQlog("send-short reason=api-datagram len=" & $payload.len)
  let bytes = conn.encodeProtectedPacket(qptShort, @[dg])
  conn.queueDatagramForSend(bytes)
  await ep.flushConnectionPackets(conn)
