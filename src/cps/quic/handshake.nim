## QUIC-TLS handshake context and callback wiring.

import ./types
import ./transport_params
import ./connection

type
  QuicHandshakeLifecycleState* = enum
    hsInitial
    hsHandshake
    hs1Rtt
    hsConfirmed
    hsClosed

  HandshakeActions* = object
    state*: QuicHandshakeLifecycleState
    outgoingInitialCrypto*: seq[byte]
    outgoingHandshakeCrypto*: seq[byte]
    outgoingApplicationCrypto*: seq[byte]
    handshakeComplete*: bool
    alertCode*: int

  QuicHandshakeContext* = ref object
    boundConn*: QuicConnection
    localTransportParameters*: QuicTransportParameters
    peerTransportParametersRaw*: seq[byte]
    peerTransportParametersDecoded*: QuicTransportParameters
    peerTransportParametersReady*: bool
    peerTransportParametersProcessed*: bool
    readSecretInitial*: seq[byte]
    writeSecretInitial*: seq[byte]
    readSecretHandshake*: seq[byte]
    writeSecretHandshake*: seq[byte]
    readSecretApplication*: seq[byte]
    writeSecretApplication*: seq[byte]
    outgoingCryptoInitial*: seq[byte]
    outgoingCryptoHandshake*: seq[byte]
    outgoingCryptoApplication*: seq[byte]
    incomingCryptoInitial*: seq[byte]
    incomingCryptoHandshake*: seq[byte]
    incomingCryptoApplication*: seq[byte]
    handshakeComplete*: bool
    alertCode*: int

proc mapHandshakeState(conn: QuicConnection): QuicHandshakeLifecycleState {.inline.} =
  if conn.state == qcsClosed:
    return hsClosed
  case conn.handshakeState
  of qhsInitial: hsInitial
  of qhsHandshake: hsHandshake
  of qhsOneRtt:
    if conn.state == qcsActive: hsConfirmed else: hs1Rtt
  of qhsClosed: hsClosed

proc driveHandshake*(conn: QuicConnection, nowMicros: int64): HandshakeActions =
  ## Drive handshake output scheduling for the runtime packet loop.
  ## Current transport path sources CRYPTO bytes from the handshake context queues.
  discard nowMicros
  if conn.handshakeState == qhsOneRtt and conn.state in {qcsInitial, qcsHandshaking}:
    conn.state = qcsActive
  result.state = mapHandshakeState(conn)
  result.handshakeComplete = result.state in {hs1Rtt, hsConfirmed}
  result.alertCode = 0

proc ingestCrypto*(conn: QuicConnection,
                   level: QuicEncryptionLevel,
                   offset: uint64,
                   bytes: openArray[byte]) =
  ## Ingest CRYPTO fragments by level/offset.
  ## Runtime currently stores CRYPTO in stream-like sequencing to enable TLS plumbing.
  conn.ingestCryptoData(level, offset, bytes)
  if bytes.len > 0 and conn.state == qcsInitial:
    conn.state = qcsHandshaking

proc newQuicHandshakeContext*(localTransportParameters: QuicTransportParameters,
                              boundConn: QuicConnection = nil): QuicHandshakeContext =
  QuicHandshakeContext(
    boundConn: boundConn,
    localTransportParameters: localTransportParameters,
    peerTransportParametersRaw: @[],
    peerTransportParametersDecoded: defaultTransportParameters(),
    peerTransportParametersReady: false,
    peerTransportParametersProcessed: false,
    readSecretInitial: @[],
    writeSecretInitial: @[],
    readSecretHandshake: @[],
    writeSecretHandshake: @[],
    readSecretApplication: @[],
    writeSecretApplication: @[],
    outgoingCryptoInitial: @[],
    outgoingCryptoHandshake: @[],
    outgoingCryptoApplication: @[],
    incomingCryptoInitial: @[],
    incomingCryptoHandshake: @[],
    incomingCryptoApplication: @[],
    handshakeComplete: false,
    alertCode: 0
  )

proc queueCryptoData*(ctx: QuicHandshakeContext, level: QuicEncryptionLevel, data: openArray[byte], outgoing: bool) =
  if data.len == 0:
    return
  case level
  of qelInitial:
    if outgoing:
      ctx.outgoingCryptoInitial.add data
    else:
      ctx.incomingCryptoInitial.add data
  of qelHandshake:
    if outgoing:
      ctx.outgoingCryptoHandshake.add data
    else:
      ctx.incomingCryptoHandshake.add data
  of qelApplication:
    if outgoing:
      ctx.outgoingCryptoApplication.add data
    else:
      ctx.incomingCryptoApplication.add data

proc takeCryptoData*(ctx: QuicHandshakeContext, level: QuicEncryptionLevel, outgoing: bool): seq[byte] =
  case level
  of qelInitial:
    if outgoing:
      result = ctx.outgoingCryptoInitial
      ctx.outgoingCryptoInitial = @[]
    else:
      result = ctx.incomingCryptoInitial
      ctx.incomingCryptoInitial = @[]
  of qelHandshake:
    if outgoing:
      result = ctx.outgoingCryptoHandshake
      ctx.outgoingCryptoHandshake = @[]
    else:
      result = ctx.incomingCryptoHandshake
      ctx.incomingCryptoHandshake = @[]
  of qelApplication:
    if outgoing:
      result = ctx.outgoingCryptoApplication
      ctx.outgoingCryptoApplication = @[]
    else:
      result = ctx.incomingCryptoApplication
      ctx.incomingCryptoApplication = @[]

proc setReadSecret*(ctx: QuicHandshakeContext, level: QuicEncryptionLevel, secret: openArray[byte]) =
  if not ctx.isNil and not ctx.boundConn.isNil:
    ctx.boundConn.setLevelReadSecret(level, secret)
  case level
  of qelInitial:
    ctx.readSecretInitial = @secret
  of qelHandshake:
    ctx.readSecretHandshake = @secret
  of qelApplication:
    ctx.readSecretApplication = @secret

proc setWriteSecret*(ctx: QuicHandshakeContext, level: QuicEncryptionLevel, secret: openArray[byte]) =
  if not ctx.isNil and not ctx.boundConn.isNil:
    ctx.boundConn.setLevelWriteSecret(level, secret)
  case level
  of qelInitial:
    ctx.writeSecretInitial = @secret
  of qelHandshake:
    ctx.writeSecretHandshake = @secret
  of qelApplication:
    ctx.writeSecretApplication = @secret

proc setPeerTransportParameters*(ctx: QuicHandshakeContext, raw: openArray[byte]) =
  ctx.peerTransportParametersRaw = @raw
  ctx.peerTransportParametersDecoded = decodeTransportParameters(raw)
  ctx.peerTransportParametersReady = true
  ctx.peerTransportParametersProcessed = false

when defined(useBoringSSL):
  import std/[tables, openssl, os, strutils]
  import ./tlsquic
  import ./packet_protection
  import ./hkdf

  var handshakeContexts: Table[uint, QuicHandshakeContext]
  var quicMethodInitialized = false
  var quicMethod: SslQuicMethod

  proc levelToQuic(level: SslEncryptionLevel): QuicEncryptionLevel =
    case level
    of selInitial: qelInitial
    of selHandshake: qelHandshake
    of selApplication, selEarlyData: qelApplication

  proc readCtx(ssl: SslPtr): QuicHandshakeContext =
    let k = cast[uint](ssl)
    if k in handshakeContexts:
      return handshakeContexts[k]
    nil

  proc negotiatedPacketSuite(cipher: ptr SslCipher): tuple[cipher: QuicPacketCipher, hashAlg: QuicHkdfHash] =
    if cipher.isNil:
      return (qpcAes128Gcm, qhhSha256)
    let fullId = uint64(SSL_CIPHER_get_id(cipher))
    let suiteId = uint32(fullId and 0xFFFF'u64)
    case suiteId
    of 0x1301'u32: (qpcAes128Gcm, qhhSha256)
    of 0x1302'u32: (qpcAes256Gcm, qhhSha384)
    of 0x1303'u32: (qpcChaCha20Poly1305, qhhSha256)
    else:
      (qpcAes128Gcm, qhhSha256)

  proc maybeSetNegotiatedSuite(ctx: QuicHandshakeContext,
                               level: SslEncryptionLevel,
                               cipher: ptr SslCipher) =
    if ctx.isNil or ctx.boundConn.isNil:
      return
    if level in {selHandshake, selApplication}:
      let mapped = negotiatedPacketSuite(cipher)
      ctx.boundConn.setPacketCipherSuite(mapped.cipher, mapped.hashAlg)
      if existsEnv("CPS_QUIC_DEBUG"):
        let fullId = if cipher.isNil: 0'u64 else: uint64(SSL_CIPHER_get_id(cipher))
        echo "[cps-quic-tlscb] setCipher level=", $level, " id=0x", toHex(int(fullId), 8).toLowerAscii,
          " mapped=", $mapped.cipher, " hash=", $mapped.hashAlg

  proc setReadSecretCb(ssl: SslPtr, level: SslEncryptionLevel,
                       cipher: ptr SslCipher, secret: ptr uint8,
                       secretLen: csize_t): cint {.cdecl.} =
    let ctx = readCtx(ssl)
    if ctx.isNil:
      return 0
    # Early-data secrets are not 1-RTT traffic keys; ignore for now.
    if level == selEarlyData:
      return 1
    maybeSetNegotiatedSuite(ctx, level, cipher)
    if secretLen > 0 and not secret.isNil:
      var s = newSeq[byte](int(secretLen))
      let src = cast[ptr UncheckedArray[uint8]](secret)
      for i in 0 ..< int(secretLen):
        s[i] = src[i]
      ctx.setReadSecret(levelToQuic(level), s)
      if existsEnv("CPS_QUIC_DEBUG"):
        echo "[cps-quic-tlscb] setReadSecret level=", $level, " len=", $secretLen
    1

  proc setWriteSecretCb(ssl: SslPtr, level: SslEncryptionLevel,
                        cipher: ptr SslCipher, secret: ptr uint8,
                        secretLen: csize_t): cint {.cdecl.} =
    let ctx = readCtx(ssl)
    if ctx.isNil:
      return 0
    # Early-data secrets are not 1-RTT traffic keys; ignore for now.
    if level == selEarlyData:
      return 1
    maybeSetNegotiatedSuite(ctx, level, cipher)
    if secretLen > 0 and not secret.isNil:
      var s = newSeq[byte](int(secretLen))
      let src = cast[ptr UncheckedArray[uint8]](secret)
      for i in 0 ..< int(secretLen):
        s[i] = src[i]
      ctx.setWriteSecret(levelToQuic(level), s)
      if existsEnv("CPS_QUIC_DEBUG"):
        echo "[cps-quic-tlscb] setWriteSecret level=", $level, " len=", $secretLen
    1

  proc addHandshakeDataCb(ssl: SslPtr, level: SslEncryptionLevel,
                          data: ptr uint8, dataLen: csize_t): cint {.cdecl.} =
    let ctx = readCtx(ssl)
    if ctx.isNil:
      return 0
    if level == selEarlyData:
      return 1
    if dataLen > 0 and not data.isNil:
      var b = newSeq[byte](int(dataLen))
      let src = cast[ptr UncheckedArray[uint8]](data)
      for i in 0 ..< int(dataLen):
        b[i] = src[i]
      ctx.queueCryptoData(levelToQuic(level), b, outgoing = true)
      if existsEnv("CPS_QUIC_DEBUG"):
        echo "[cps-quic-tlscb] addHandshakeData level=", $level, " len=", $dataLen
    1

  proc flushFlightCb(ssl: SslPtr): cint {.cdecl.} =
    1

  proc sendAlertCb(ssl: SslPtr, level: SslEncryptionLevel, alert: uint8): cint {.cdecl.} =
    let ctx = readCtx(ssl)
    if not ctx.isNil:
      ctx.alertCode = int(alert)
    1

  proc ensureQuicMethod() =
    if quicMethodInitialized:
      return
    quicMethod = SslQuicMethod(
      setReadSecret: setReadSecretCb,
      setWriteSecret: setWriteSecretCb,
      addHandshakeData: addHandshakeDataCb,
      flushFlight: flushFlightCb,
      sendAlert: sendAlertCb
    )
    quicMethodInitialized = true

  proc attachQuicTls*(ssl: SslPtr, ctx: QuicHandshakeContext): bool =
    ensureQuicMethod()
    if ssl.isNil or ctx.isNil:
      return false
    handshakeContexts[cast[uint](ssl)] = ctx
    if SSL_set_quic_method(ssl, addr quicMethod) != 1:
      return false
    let tp = encodeTransportParameters(ctx.localTransportParameters)
    if tp.len > 0:
      if SSL_set_quic_transport_params(ssl, unsafeAddr tp[0], tp.len.csize_t) != 1:
        return false
    true

  proc detachQuicTls*(ssl: SslPtr) =
    if ssl.isNil:
      return
    let k = cast[uint](ssl)
    if k in handshakeContexts:
      handshakeContexts.del(k)

  proc provideCryptoDataToTls*(ssl: SslPtr, level: QuicEncryptionLevel, data: openArray[byte]): bool =
    if ssl.isNil:
      return false
    let lvl = case level
      of qelInitial: selInitial
      of qelHandshake: selHandshake
      of qelApplication: selApplication
    if data.len == 0:
      return true
    SSL_provide_quic_data(ssl, lvl, unsafeAddr data[0], data.len.csize_t) == 1

  proc readPeerTransportParametersFromTls*(ssl: SslPtr, ctx: QuicHandshakeContext) =
    if ssl.isNil or ctx.isNil:
      return
    if ctx.peerTransportParametersProcessed:
      return
    var ptrParams: ptr uint8 = nil
    var paramsLen: csize_t = 0
    SSL_get_peer_quic_transport_params(ssl, addr ptrParams, addr paramsLen)
    if ptrParams.isNil or paramsLen == 0:
      return
    var raw = newSeq[byte](int(paramsLen))
    let src = cast[ptr UncheckedArray[uint8]](ptrParams)
    for i in 0 ..< int(paramsLen):
      raw[i] = src[i]
    ctx.setPeerTransportParameters(raw)

else:
  type
    SslPtr* = pointer

  proc attachQuicTls*(ssl: SslPtr, ctx: QuicHandshakeContext): bool =
    discard ssl
    not ctx.isNil

  proc detachQuicTls*(ssl: SslPtr) =
    discard ssl

  proc provideCryptoDataToTls*(ssl: SslPtr, level: QuicEncryptionLevel, data: openArray[byte]): bool =
    discard ssl
    discard level
    discard data
    false

  proc readPeerTransportParametersFromTls*(ssl: SslPtr, ctx: QuicHandshakeContext) =
    discard ssl
    discard ctx
