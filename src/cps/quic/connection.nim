## QUIC connection baseline state machine and packet/frame application.

import std/[tables, algorithm, times, strutils]
import ./types
import ./frame
import ./packet
import ./varint
import ./streams
import ./recovery
import ./path
import ./transport_params
import ./hkdf
import ./packet_protection

const
  QuicOneRttPreviousKeyRetirePackets = 64
  QuicReceivedPacketHistoryWindow = 4096
  QuicMaxCryptoBufferPerLevelBytes* = 512 * 1024
  QuicMaxIncomingDatagramQueueLen* = 256
  QuicMaxIncomingDatagramQueueBytes* = 1024 * 1024
  QuicStreamIdIncrement = 4'u64

type
  QuicConnectionRole* = enum
    qcrClient
    qcrServer

  QuicConnectionState* = enum
    qcsInitial
    qcsHandshaking
    qcsActive
    qcsDraining
    qcsClosed

  QuicQlogSink* = proc(event: string) {.closure.}
  QuicQlogEventSink* = proc(event: QuicQlogEvent) {.closure.}

  QuicHandshakeState* = enum
    qhsInitial
    qhsHandshake
    qhsOneRtt
    qhsClosed

  QuicQlogEvent* = object
    timestampMicros*: int64
    kind*: string
    message*: string
    packetType*: QuicPacketType
    packetNumber*: uint64
    hasPacket*: bool

  QuicConnectionStats* = object
    bytesSent*: uint64
    bytesReceived*: uint64
    datagramsSent*: uint64
    datagramsReceived*: uint64
    congestionWindow*: int
    bytesInFlight*: int
    ptoCount*: int
    lostPackets*: int
    ackedPackets*: int
    addressValidated*: bool
    handshakeState*: QuicHandshakeState
    srttMicros*: int64
    rttVarMicros*: int64
    activePathPeer*: string
    peerValidatedPathCount*: int
    state*: QuicConnectionState

  QuicPacketProtectionKeys* = object
    cipher*: QuicPacketCipher
    key*: seq[byte]
    iv*: seq[byte]
    hp*: seq[byte]
    ready*: bool

  QuicSentPacket* = object
    packetType*: QuicPacketType
    pn*: uint64
    sentAtMicros*: int64
    payloadBytes*: int
    ackEliciting*: bool
    retransmittableFrames*: seq[QuicFrame]

  QuicPendingSendRecord = object
    space: QuicPacketNumberSpace
    pn: uint64
    payloadBytes: int
    ackEliciting: bool

  QuicConnection* = ref object
    role*: QuicConnectionRole
    state*: QuicConnectionState
    handshakeState*: QuicHandshakeState
    version*: uint32
    localConnId*: seq[byte]
    peerConnId*: seq[byte]
    initialSecretConnId*: seq[byte]
    clientOriginalDestinationConnId: seq[byte]
    localTransportParameters*: QuicTransportParameters
    peerTransportParameters*: QuicTransportParameters
    recovery*: QuicRecoveryState
    pathManager*: QuicPathManager
    streams*: Table[uint64, QuicStream]
    nextLocalBidiStreamId*: uint64
    nextLocalUniStreamId*: uint64
    sendPacketNumber*: array[3, uint64]
    largestReceivedPacketNumber*: array[3, uint64]
    hasReceivedPacketInSpace*: array[3, bool]
    receivedPacketNumbers: array[3, Table[uint64, bool]]
    pendingAcks*: array[3, seq[uint64]]
    sentPackets*: array[3, Table[uint64, QuicSentPacket]]
    ptoDeadlineMicros*: array[3, int64]
    pendingRetransmitFrames*: array[3, seq[QuicFrame]]
    ptoProbeCwndBypassBudget: int
    pendingControlFrames*: seq[QuicFrame]
    outgoingDatagrams*: seq[seq[byte]]
    pendingSendRecords*: seq[QuicPendingSendRecord]
    incomingDatagrams*: seq[seq[byte]]
    incomingDatagramBytesQueued: int
    local0RttEnabled*: bool
    peerAccepted0Rtt*: bool
    oneRttKeyPhase*: bool
    oneRttReadKeyPhase*: bool
    packetCipher*: QuicPacketCipher
    packetProtectionHash*: QuicHkdfHash
    levelReadKeys*: array[3, QuicPacketProtectionKeys]
    levelWriteKeys*: array[3, QuicPacketProtectionKeys]
    previousOneRttReadKeys*: QuicPacketProtectionKeys
    hasPreviousOneRttReadKeys*: bool
    applicationReadTrafficSecret*: seq[byte]
    applicationWriteTrafficSecret*: seq[byte]
    oneRttPacketsDecodedInCurrentPhase: int
    peerConnectionIds*: Table[uint64, seq[byte]]
    retiredPeerConnectionIds*: Table[uint64, bool]
    peerResetTokens*: Table[string, array[16, byte]]
    peerTokens*: seq[seq[byte]]
    activeRetryToken*: seq[byte]
    retrySourceConnIdExpected*: seq[byte]
    cryptoRecvFragments*: array[3, Table[uint64, seq[byte]]]
    cryptoRecvNextOffset*: array[3, uint64]
    cryptoRecvReady*: array[3, seq[byte]]
    cryptoRecvBufferedBytes: array[3, int]
    cryptoSendPending*: array[3, seq[byte]]
    cryptoSendNextOffset*: array[3, uint64]
    bytesSent*: uint64
    bytesReceived*: uint64
    datagramsSent*: uint64
    datagramsReceived*: uint64
    addressValidated*: bool
    closeErrorCode*: uint64
    closeReason*: string
    lastActivityMicros*: int64
    drainingSinceMicros*: int64
    tlsKeyLogCallback*: proc(line: string) {.closure.}
    qlogSink*: QuicQlogSink
    qlogEventSink*: QuicQlogEventSink

proc nowMicros(): int64 {.inline.}

proc emitQlog(conn: QuicConnection, event: string,
              kind: string = "event",
              packetType: QuicPacketType = qptInitial,
              packetNumber: uint64 = 0'u64,
              hasPacket: bool = false) =
  if not conn.qlogSink.isNil:
    conn.qlogSink(event)
  if not conn.qlogEventSink.isNil:
    conn.qlogEventSink(QuicQlogEvent(
      timestampMicros: nowMicros(),
      kind: kind,
      message: event,
      packetType: packetType,
      packetNumber: packetNumber,
      hasPacket: hasPacket
    ))

proc nowMicros(): int64 {.inline.} =
  int64(epochTime() * 1_000_000.0)

proc noteActivity*(conn: QuicConnection, atMicros: int64 = 0'i64) =
  if conn.isNil:
    return
  conn.lastActivityMicros = if atMicros > 0: atMicros else: nowMicros()

proc enterDraining*(conn: QuicConnection, atMicros: int64 = 0'i64) =
  if conn.isNil:
    return
  conn.state = qcsDraining
  let ts = if atMicros > 0: atMicros else: nowMicros()
  if conn.drainingSinceMicros <= 0:
    conn.drainingSinceMicros = ts
  conn.noteActivity(ts)

proc setCloseReason*(conn: QuicConnection,
                     errorCode: uint64 = 0'u64,
                     reason: string = "") =
  if conn.isNil:
    return
  if conn.closeErrorCode == 0'u64 and errorCode != 0'u64:
    conn.closeErrorCode = errorCode
  elif errorCode != 0'u64:
    conn.closeErrorCode = errorCode
  if reason.len > 0:
    conn.closeReason = reason

proc bytesToHex(data: openArray[byte]): string =
  result = newStringOfCap(data.len * 2)
  for b in data:
    result.add toHex(int(b), 2).toLowerAscii

proc bytesEq(lhs, rhs: openArray[byte]): bool {.inline.} =
  if lhs.len != rhs.len:
    return false
  for i in 0 ..< lhs.len:
    if lhs[i] != rhs[i]:
      return false
  true

proc spaceIdx(space: QuicPacketNumberSpace): int {.inline.} =
  case space
  of qpnsInitial: 0
  of qpnsHandshake: 1
  of qpnsApplication: 2

proc initLocalStreamIds(role: QuicConnectionRole): tuple[bidi, uni: uint64] =
  if role == qcrClient:
    (0'u64, 2'u64)
  else:
    (1'u64, 3'u64)

proc keyIdx(level: QuicEncryptionLevel): int {.inline.} =
  case level
  of qelInitial: 0
  of qelHandshake: 1
  of qelApplication: 2

proc encryptionLevelForSpace*(space: QuicPacketNumberSpace): QuicEncryptionLevel {.inline.} =
  case space
  of qpnsInitial: qelInitial
  of qpnsHandshake: qelHandshake
  of qpnsApplication: qelApplication

proc setLevelReadSecret*(conn: QuicConnection, level: QuicEncryptionLevel, secret: openArray[byte]) =
  let (cipher, hashAlg) =
    if level == qelInitial:
      (qpcAes128Gcm, qhhSha256)
    else:
      (conn.packetCipher, conn.packetProtectionHash)
  let i = keyIdx(level)
  conn.levelReadKeys[i] = QuicPacketProtectionKeys(
    cipher: cipher,
    key: deriveAeadKey(secret, keyLen = keyLenForCipher(cipher), version = conn.version, hashAlg = hashAlg),
    iv: deriveAeadIv(secret, version = conn.version, hashAlg = hashAlg),
    hp: deriveHeaderProtectionKey(secret, keyLen = hpKeyLenForCipher(cipher), version = conn.version, hashAlg = hashAlg),
    ready: true
  )
  case level
  of qelInitial:
    discard
  of qelHandshake:
    if conn.handshakeState == qhsInitial:
      conn.handshakeState = qhsHandshake
  of qelApplication:
    conn.applicationReadTrafficSecret = @secret
    conn.oneRttReadKeyPhase = false
    conn.hasPreviousOneRttReadKeys = false
    conn.oneRttPacketsDecodedInCurrentPhase = 0
    conn.handshakeState = qhsOneRtt

proc setLevelWriteSecret*(conn: QuicConnection, level: QuicEncryptionLevel, secret: openArray[byte]) =
  let (cipher, hashAlg) =
    if level == qelInitial:
      (qpcAes128Gcm, qhhSha256)
    else:
      (conn.packetCipher, conn.packetProtectionHash)
  let i = keyIdx(level)
  conn.levelWriteKeys[i] = QuicPacketProtectionKeys(
    cipher: cipher,
    key: deriveAeadKey(secret, keyLen = keyLenForCipher(cipher), version = conn.version, hashAlg = hashAlg),
    iv: deriveAeadIv(secret, version = conn.version, hashAlg = hashAlg),
    hp: deriveHeaderProtectionKey(secret, keyLen = hpKeyLenForCipher(cipher), version = conn.version, hashAlg = hashAlg),
    ready: true
  )
  case level
  of qelInitial:
    discard
  of qelHandshake:
    if conn.handshakeState == qhsInitial:
      conn.handshakeState = qhsHandshake
  of qelApplication:
    conn.applicationWriteTrafficSecret = @secret
    conn.handshakeState = qhsOneRtt

proc installInitialSecrets(conn: QuicConnection, cid: openArray[byte]) =
  if cid.len == 0:
    return
  let s = deriveInitialSecrets(cid, conn.version)
  if conn.role == qcrClient:
    conn.setLevelWriteSecret(qelInitial, s.clientInitialSecret)
    conn.setLevelReadSecret(qelInitial, s.serverInitialSecret)
  else:
    conn.setLevelWriteSecret(qelInitial, s.serverInitialSecret)
    conn.setLevelReadSecret(qelInitial, s.clientInitialSecret)

proc setPacketCipher*(conn: QuicConnection, cipher: QuicPacketCipher) =
  ## Sets the AEAD/HP cipher used for future secret installations.
  ## Existing installed level keys are retained until refreshed by new secrets.
  conn.packetCipher = cipher

proc setPacketCipherSuite*(conn: QuicConnection,
                           cipher: QuicPacketCipher,
                           hashAlg: QuicHkdfHash) =
  ## Sets AEAD/HP cipher and HKDF hash used for future secret installations.
  ## Existing installed level keys are retained until refreshed by new secrets.
  conn.packetCipher = cipher
  conn.packetProtectionHash = hashAlg

proc newQuicConnection*(role: QuicConnectionRole,
                        localConnId: openArray[byte],
                        peerConnId: openArray[byte],
                        peerAddress: string,
                        peerPort: int,
                        version: uint32 = QuicVersion1,
                        qlogSink: QuicQlogSink = nil,
                        qlogEventSink: QuicQlogEventSink = nil,
                        tlsKeyLogCallback: proc(line: string) {.closure.} = nil): QuicConnection =
  let streamIds = initLocalStreamIds(role)
  let cidForInitial =
    if role == qcrClient:
      if peerConnId.len > 0: @peerConnId
      elif localConnId.len > 0: @localConnId
      else: @[]
    else:
      if localConnId.len > 0: @localConnId
      elif peerConnId.len > 0: @peerConnId
      else: @[]
  result = QuicConnection(
    role: role,
    state: qcsInitial,
    handshakeState: qhsInitial,
    version: version,
    localConnId: @localConnId,
    peerConnId: @peerConnId,
    initialSecretConnId: @cidForInitial,
    clientOriginalDestinationConnId: (if role == qcrClient: @cidForInitial else: @[]),
    localTransportParameters: defaultTransportParameters(),
    peerTransportParameters: defaultTransportParameters(),
    recovery: initRecoveryState(),
    pathManager: initPathManager(peerAddress, peerPort, validated = role == qcrClient),
    streams: initTable[uint64, QuicStream](),
    nextLocalBidiStreamId: streamIds.bidi,
    nextLocalUniStreamId: streamIds.uni,
    sendPacketNumber: [0'u64, 0'u64, 0'u64],
    largestReceivedPacketNumber: [0'u64, 0'u64, 0'u64],
    hasReceivedPacketInSpace: [false, false, false],
    receivedPacketNumbers: [
      initTable[uint64, bool](),
      initTable[uint64, bool](),
      initTable[uint64, bool]()
    ],
    pendingAcks: [@[], @[], @[]],
    sentPackets: [
      initTable[uint64, QuicSentPacket](),
      initTable[uint64, QuicSentPacket](),
      initTable[uint64, QuicSentPacket]()
    ],
    ptoDeadlineMicros: [0'i64, 0'i64, 0'i64],
    pendingRetransmitFrames: [@[], @[], @[]],
    ptoProbeCwndBypassBudget: 0,
    pendingControlFrames: @[],
    outgoingDatagrams: @[],
    pendingSendRecords: @[],
    incomingDatagrams: @[],
    incomingDatagramBytesQueued: 0,
    local0RttEnabled: false,
    peerAccepted0Rtt: false,
    oneRttKeyPhase: false,
    oneRttReadKeyPhase: false,
    packetCipher: qpcAes128Gcm,
    packetProtectionHash: qhhSha256,
    levelReadKeys: [QuicPacketProtectionKeys(), QuicPacketProtectionKeys(), QuicPacketProtectionKeys()],
    levelWriteKeys: [QuicPacketProtectionKeys(), QuicPacketProtectionKeys(), QuicPacketProtectionKeys()],
    previousOneRttReadKeys: QuicPacketProtectionKeys(),
    hasPreviousOneRttReadKeys: false,
    applicationReadTrafficSecret: @[],
    applicationWriteTrafficSecret: @[],
    oneRttPacketsDecodedInCurrentPhase: 0,
    peerConnectionIds: initTable[uint64, seq[byte]](),
    retiredPeerConnectionIds: initTable[uint64, bool](),
    peerResetTokens: initTable[string, array[16, byte]](),
    peerTokens: @[],
    activeRetryToken: @[],
    retrySourceConnIdExpected: @[],
    cryptoRecvFragments: [
      initTable[uint64, seq[byte]](),
      initTable[uint64, seq[byte]](),
      initTable[uint64, seq[byte]]()
    ],
    cryptoRecvNextOffset: [0'u64, 0'u64, 0'u64],
    cryptoRecvReady: [@[], @[], @[]],
    cryptoRecvBufferedBytes: [0, 0, 0],
    cryptoSendPending: [@[], @[], @[]],
    cryptoSendNextOffset: [0'u64, 0'u64, 0'u64],
    bytesSent: 0,
    bytesReceived: 0,
    datagramsSent: 0,
    datagramsReceived: 0,
    addressValidated: role == qcrClient,
    closeErrorCode: 0'u64,
    closeReason: "",
    lastActivityMicros: nowMicros(),
    drainingSinceMicros: 0'i64,
    tlsKeyLogCallback: tlsKeyLogCallback,
    qlogSink: qlogSink,
    qlogEventSink: qlogEventSink
  )
  result.installInitialSecrets(cidForInitial)

proc setInitialSecretConnectionId*(conn: QuicConnection, cid: openArray[byte]) =
  ## Set the CID used for current Initial packet protection key derivation.
  ## For clients, this can change after Retry when Initial DCID changes.
  conn.initialSecretConnId = @cid
  if conn.role == qcrClient and conn.clientOriginalDestinationConnId.len == 0:
    conn.clientOriginalDestinationConnId = @cid
  conn.installInitialSecrets(conn.initialSecretConnId)

proc originalDestinationConnectionIdForValidation*(conn: QuicConnection): seq[byte] =
  ## Returns client ODCID expected in peer transport parameters.
  if conn.isNil:
    return @[]
  if conn.role == qcrClient and conn.clientOriginalDestinationConnId.len > 0:
    return conn.clientOriginalDestinationConnId
  conn.initialSecretConnId

proc onRetryReceived*(conn: QuicConnection,
                      retrySourceConnId: openArray[byte],
                      retryToken: openArray[byte]) =
  ## RFC9000 Retry processing for clients:
  ## - switch Initial key derivation to Retry SCID
  ## - reset Initial packet-number space state
  ## - requeue retransmittable Initial frames (ClientHello CRYPTO)
  if conn.isNil or conn.role != qcrClient:
    return

  let i = spaceIdx(qpnsInitial)
  var retransmit: seq[QuicFrame] = @[]
  var pns: seq[uint64] = @[]
  for pn, _ in conn.sentPackets[i]:
    pns.add pn
  sort(pns, proc(a, b: uint64): int =
    if a < b: -1
    elif a > b: 1
    else: 0
  )
  for pn in pns:
    let meta = conn.sentPackets[i][pn]
    if meta.ackEliciting:
      conn.recovery.bytesInFlight = max(0, conn.recovery.bytesInFlight - max(0, meta.payloadBytes))
    for frame in meta.retransmittableFrames:
      if frame.kind notin {qfkPadding, qfkAck}:
        retransmit.add frame

  conn.sendPacketNumber[i] = 0'u64
  conn.largestReceivedPacketNumber[i] = 0'u64
  conn.hasReceivedPacketInSpace[i] = false
  conn.receivedPacketNumbers[i].clear()
  conn.pendingAcks[i] = @[]
  conn.sentPackets[i].clear()
  conn.ptoDeadlineMicros[i] = 0'i64
  conn.pendingRetransmitFrames[i] = @[]
  conn.ptoProbeCwndBypassBudget = 0
  var retainedRecords: seq[QuicPendingSendRecord] = @[]
  for rec in conn.pendingSendRecords:
    if rec.space != qpnsInitial:
      retainedRecords.add rec
  conn.pendingSendRecords = retainedRecords

  conn.peerConnId = @retrySourceConnId
  conn.setInitialSecretConnectionId(retrySourceConnId)
  conn.activeRetryToken = @retryToken
  conn.retrySourceConnIdExpected = @retrySourceConnId

  if retransmit.len > 0:
    conn.pendingRetransmitFrames[i].add retransmit
  else:
    conn.pendingControlFrames.add QuicFrame(kind: qfkPing)

proc streamRoleForConnection(conn: QuicConnection): QuicStreamEndpointRole {.inline.} =
  if conn.role == qcrClient: qserClient else: qserServer

proc isLocalInitiatedStream(conn: QuicConnection, streamId: uint64): bool {.inline.} =
  let initiatedByClient = isClientInitiatedStream(streamId)
  (conn.role == qcrClient and initiatedByClient) or
    (conn.role == qcrServer and not initiatedByClient)

proc initialSendWindowLimit(conn: QuicConnection,
                            direction: QuicStreamDirection,
                            localInitiated: bool): uint64 {.inline.} =
  if direction == qsdUnidirectional:
    if localInitiated: conn.peerTransportParameters.initialMaxStreamDataUni else: 0'u64
  else:
    if localInitiated:
      conn.peerTransportParameters.initialMaxStreamDataBidiRemote
    else:
      conn.peerTransportParameters.initialMaxStreamDataBidiLocal

proc initialRecvWindowLimit(conn: QuicConnection,
                            direction: QuicStreamDirection,
                            localInitiated: bool): uint64 {.inline.} =
  if direction == qsdUnidirectional:
    if localInitiated: 0'u64 else: conn.localTransportParameters.initialMaxStreamDataUni
  else:
    if localInitiated:
      conn.localTransportParameters.initialMaxStreamDataBidiLocal
    else:
      conn.localTransportParameters.initialMaxStreamDataBidiRemote

proc enforceStreamOpenLimit(conn: QuicConnection,
                            streamId: uint64,
                            direction: QuicStreamDirection,
                            localInitiated: bool) =
  let streamIndex = streamId shr 2
  let limit =
    if localInitiated:
      if direction == qsdBidirectional:
        conn.peerTransportParameters.initialMaxStreamsBidi
      else:
        conn.peerTransportParameters.initialMaxStreamsUni
    else:
      if direction == qsdBidirectional:
        conn.localTransportParameters.initialMaxStreamsBidi
      else:
        conn.localTransportParameters.initialMaxStreamsUni
  if streamIndex >= limit:
    raise newException(
      ValueError,
      "stream limit exceeded: id=" & $streamId &
        " index=" & $streamIndex & " limit=" & $limit &
        " direction=" & $direction & " localInitiated=" & $localInitiated
    )

proc getOrCreateStream*(conn: QuicConnection, streamId: uint64): QuicStream =
  if streamId > QuicVarIntMax8:
    raise newException(ValueError, "stream ID exceeds QUIC varint range")
  if streamId in conn.streams:
    return conn.streams[streamId]
  let direction = streamDirection(streamId)
  let localInitiated = conn.isLocalInitiatedStream(streamId)
  conn.enforceStreamOpenLimit(streamId, direction, localInitiated)
  let s = newQuicStream(
    streamId,
    localRole = conn.streamRoleForConnection(),
    sendWindowLimit = conn.initialSendWindowLimit(direction, localInitiated),
    recvWindowLimit = conn.initialRecvWindowLimit(direction, localInitiated)
  )
  conn.streams[streamId] = s
  s

proc validateNextLocalStreamId(conn: QuicConnection,
                               streamId: uint64,
                               expectedLowBits: uint64,
                               streamKind: string) =
  if streamId > QuicVarIntMax8:
    raise newException(ValueError, "exhausted local " & streamKind & " stream IDs")
  if (streamId and 0x03'u64) != expectedLowBits:
    raise newException(
      ValueError,
      "next local " & streamKind & " stream ID has invalid initiator/direction bits"
    )

proc openLocalBidiStream*(conn: QuicConnection): QuicStream =
  let sid = conn.nextLocalBidiStreamId
  let expectedLowBits = if conn.role == qcrClient: 0'u64 else: 1'u64
  conn.validateNextLocalStreamId(sid, expectedLowBits, "bidirectional")
  conn.enforceStreamOpenLimit(sid, qsdBidirectional, localInitiated = true)
  if sid > QuicVarIntMax8 - QuicStreamIdIncrement:
    conn.nextLocalBidiStreamId = QuicVarIntMax8 + 1'u64
  else:
    conn.nextLocalBidiStreamId += QuicStreamIdIncrement
  conn.getOrCreateStream(sid)

proc openLocalUniStream*(conn: QuicConnection): QuicStream =
  let sid = conn.nextLocalUniStreamId
  let expectedLowBits = if conn.role == qcrClient: 2'u64 else: 3'u64
  conn.validateNextLocalStreamId(sid, expectedLowBits, "unidirectional")
  conn.enforceStreamOpenLimit(sid, qsdUnidirectional, localInitiated = true)
  if sid > QuicVarIntMax8 - QuicStreamIdIncrement:
    conn.nextLocalUniStreamId = QuicVarIntMax8 + 1'u64
  else:
    conn.nextLocalUniStreamId += QuicStreamIdIncrement
  conn.getOrCreateStream(sid)

proc nextPacketNumber(conn: QuicConnection, space: QuicPacketNumberSpace): uint64 =
  let i = spaceIdx(space)
  result = conn.sendPacketNumber[i]
  conn.sendPacketNumber[i] += 1

proc pushPendingAck(conn: QuicConnection, space: QuicPacketNumberSpace, pn: uint64) =
  conn.pendingAcks[spaceIdx(space)].add pn

proc pruneReceivedPacketHistory(conn: QuicConnection, idx: int) =
  if idx < 0 or idx > 2:
    return
  let historyLen = conn.receivedPacketNumbers[idx].len
  if historyLen <= QuicReceivedPacketHistoryWindow * 2:
    return
  var minKeep = 0'u64
  let window = uint64(QuicReceivedPacketHistoryWindow)
  if conn.largestReceivedPacketNumber[idx] > window:
    minKeep = conn.largestReceivedPacketNumber[idx] - window
  if minKeep == 0'u64:
    return
  var stale: seq[uint64] = @[]
  for pn, _ in conn.receivedPacketNumbers[idx]:
    if pn < minKeep:
      stale.add pn
  for pn in stale:
    conn.receivedPacketNumbers[idx].del(pn)

proc markPacketNumberReceived(conn: QuicConnection,
                              space: QuicPacketNumberSpace,
                              pn: uint64): bool =
  let idx = spaceIdx(space)
  if pn in conn.receivedPacketNumbers[idx]:
    return false
  conn.receivedPacketNumbers[idx][pn] = true
  if not conn.hasReceivedPacketInSpace[idx] or pn > conn.largestReceivedPacketNumber[idx]:
    conn.hasReceivedPacketInSpace[idx] = true
    conn.largestReceivedPacketNumber[idx] = pn
  conn.pruneReceivedPacketHistory(idx)
  true

proc updatePtoDeadline(conn: QuicConnection, space: QuicPacketNumberSpace) =
  let i = spaceIdx(space)
  if conn.sentPackets[i].len == 0:
    conn.ptoDeadlineMicros[i] = 0
    return
  var latestSent = 0'i64
  for _, meta in conn.sentPackets[i]:
    if meta.ackEliciting and meta.sentAtMicros > latestSent:
      latestSent = meta.sentAtMicros
  if latestSent <= 0:
    conn.ptoDeadlineMicros[i] = 0
    return
  conn.ptoDeadlineMicros[i] = latestSent + conn.recovery.currentPtoMicros()

proc queueRetransmittableFrames(conn: QuicConnection,
                                space: QuicPacketNumberSpace,
                                frames: openArray[QuicFrame])

proc ptoExpiredSpaces*(conn: QuicConnection, nowMicros: int64): seq[QuicPacketNumberSpace] =
  for space in [qpnsInitial, qpnsHandshake, qpnsApplication]:
    let i = spaceIdx(space)
    if conn.ptoDeadlineMicros[i] <= 0:
      continue
    if nowMicros >= conn.ptoDeadlineMicros[i] and conn.sentPackets[i].len > 0:
      result.add space

proc queuePtoProbe*(conn: QuicConnection, space: QuicPacketNumberSpace) =
  ## Queue one retransmittable packet payload as PTO probe for the given space.
  let i = spaceIdx(space)
  if conn.sentPackets[i].len == 0:
    return
  var oldestPn = high(uint64)
  var found = false
  for pn, meta in conn.sentPackets[i]:
    if meta.ackEliciting and meta.retransmittableFrames.len > 0 and pn < oldestPn:
      oldestPn = pn
      found = true
  if not found:
    return
  let meta = conn.sentPackets[i][oldestPn]
  conn.queueRetransmittableFrames(space, meta.retransmittableFrames)
  if conn.ptoProbeCwndBypassBudget < high(int):
    inc conn.ptoProbeCwndBypassBudget
  conn.recovery.onPtoExpired()
  conn.updatePtoDeadline(space)

proc nextPendingSendIsAckEliciting*(conn: QuicConnection): bool =
  ## True when the next queued datagram contributes to bytes-in-flight and
  ## should be subject to cwnd gating.
  if conn.pendingSendRecords.len == 0:
    return true
  conn.pendingSendRecords[0].ackEliciting

proc consumePtoCwndBypassAllowance*(conn: QuicConnection): bool =
  if conn.ptoProbeCwndBypassBudget <= 0:
    return false
  if conn.pendingSendRecords.len == 0:
    return false
  if not conn.nextPendingSendIsAckEliciting():
    return false
  dec conn.ptoProbeCwndBypassBudget
  true

proc consumePendingAcks*(conn: QuicConnection, space: QuicPacketNumberSpace): seq[uint64] =
  let i = spaceIdx(space)
  result = conn.pendingAcks[i]
  conn.pendingAcks[i] = @[]

proc buildAckFrame*(ackedPns: seq[uint64]): QuicFrame =
  if ackedPns.len == 0:
    return QuicFrame(kind: qfkPing)

  var pns = ackedPns
  sort(pns, proc(a, b: uint64): int =
    if a < b: -1
    elif a > b: 1
    else: 0
  )
  var dedup: seq[uint64] = @[]
  for pn in pns:
    if dedup.len == 0 or dedup[^1] != pn:
      dedup.add pn

  var ranges: seq[(uint64, uint64)] = @[] # (start, end), descending by end
  var start = dedup[^1]
  var ending = dedup[^1]
  if dedup.len > 1:
    for i in countdown(dedup.high - 1, 0):
      let pn = dedup[i]
      if pn + 1 == start:
        start = pn
      else:
        ranges.add (start, ending)
        start = pn
        ending = pn
  ranges.add (start, ending)

  let first = ranges[0]
  var extras: seq[QuicAckRange] = @[]
  if ranges.len > 1:
    for i in 1 ..< ranges.len:
      let prev = ranges[i - 1]
      let curr = ranges[i]
      let gap = prev[0] - curr[1] - 2'u64
      let rangeLen = curr[1] - curr[0]
      extras.add QuicAckRange(gap: gap, rangeLen: rangeLen)

  QuicFrame(
    kind: qfkAck,
    largestAcked: first[1],
    ackDelay: 0,
    firstAckRange: first[1] - first[0],
    extraRanges: extras
  )

proc applyFlowControlFrame(conn: QuicConnection, frame: QuicFrame) =
  proc getOrCloseOnStreamAccess(streamId: uint64,
                                frameLabel: string): QuicStream =
    try:
      result = conn.getOrCreateStream(streamId)
    except ValueError as e:
      let lower = e.msg.toLowerAscii
      if lower.contains("stream limit exceeded"):
        conn.setCloseReason(0x04'u64, frameLabel & " exceeds stream limit")
      elif lower.contains("stream id exceeds quic varint range"):
        conn.setCloseReason(0x07'u64, frameLabel & " has invalid stream id")
      else:
        conn.setCloseReason(0x0A'u64, frameLabel & " stream error")
      conn.enterDraining()
      return nil

  case frame.kind
  of qfkMaxData:
    conn.localTransportParameters.initialMaxData =
      max(conn.localTransportParameters.initialMaxData, frame.maxData)
  of qfkMaxStreamData:
    let direction = streamDirection(frame.maxStreamDataStreamId)
    let localInitiated = conn.isLocalInitiatedStream(frame.maxStreamDataStreamId)
    let canLocalSend = direction == qsdBidirectional or localInitiated
    if not canLocalSend:
      conn.setCloseReason(0x05'u64, "MAX_STREAM_DATA on receive-only stream")
      conn.enterDraining()
      return
    let s = getOrCloseOnStreamAccess(frame.maxStreamDataStreamId, "MAX_STREAM_DATA")
    if s.isNil:
      return
    s.updateSendWindowLimit(frame.maxStreamData)
  of qfkMaxStreams:
    if frame.maxStreams > ((1'u64 shl 60) - 1'u64):
      conn.setCloseReason(0x07'u64, "MAX_STREAMS exceeds maximum value")
      conn.enterDraining()
      return
    if frame.maxStreamsBidi:
      conn.localTransportParameters.initialMaxStreamsBidi =
        max(conn.localTransportParameters.initialMaxStreamsBidi, frame.maxStreams)
    else:
      conn.localTransportParameters.initialMaxStreamsUni =
        max(conn.localTransportParameters.initialMaxStreamsUni, frame.maxStreams)
  else:
    discard

proc decodeAckRanges(frame: QuicFrame): tuple[ranges: seq[(uint64, uint64)], valid: bool] =
  if frame.kind != qfkAck:
    return (@[], false)
  if frame.firstAckRange > frame.largestAcked:
    return (@[], false)

  var largest = frame.largestAcked
  var smallest = largest - frame.firstAckRange
  result.ranges.add (smallest, largest)
  result.valid = true

  for r in frame.extraRanges:
    if smallest < r.gap + 2'u64:
      return (@[], false)
    largest = smallest - r.gap - 2'u64
    if r.rangeLen > largest:
      return (@[], false)
    smallest = largest - r.rangeLen
    result.ranges.add (smallest, largest)

proc containsPacketNumber(ranges: openArray[(uint64, uint64)], pn: uint64): bool {.inline.} =
  for (lo, hi) in ranges:
    if pn >= lo and pn <= hi:
      return true
  false

proc isRetransmittableFrame(frame: QuicFrame): bool {.inline.} =
  case frame.kind
  of qfkPadding, qfkAck:
    false
  else:
    true

proc isAckElicitingFrame(frame: QuicFrame): bool {.inline.} =
  case frame.kind
  of qfkPadding, qfkAck:
    false
  else:
    true

proc hasAckElicitingFrames(frames: openArray[QuicFrame]): bool {.inline.} =
  for f in frames:
    if isAckElicitingFrame(f):
      return true
  false

proc isFrameAllowedInPacketType(kind: QuicFrameKind,
                                packetType: QuicPacketType): bool {.inline.} =
  case packetType
  of qptInitial, qptHandshake:
    kind in {qfkPadding, qfkPing, qfkAck, qfkCrypto, qfkConnectionClose}
  of qpt0Rtt:
    kind in {
      qfkPadding,
      qfkPing,
      qfkResetStream,
      qfkStopSending,
      qfkStream,
      qfkMaxData,
      qfkMaxStreamData,
      qfkMaxStreams,
      qfkDataBlocked,
      qfkStreamDataBlocked,
      qfkStreamsBlocked,
      qfkConnectionClose,
      qfkDatagram
    }
  of qptShort:
    true
  else:
    true

proc queueRetransmittableFrames(conn: QuicConnection,
                                space: QuicPacketNumberSpace,
                                frames: openArray[QuicFrame]) =
  let idx = spaceIdx(space)
  for f in frames:
    if isRetransmittableFrame(f):
      conn.pendingRetransmitFrames[idx].add f

proc markAckedStreamFrames(conn: QuicConnection, frames: openArray[QuicFrame]) =
  for f in frames:
    if f.kind == qfkStream:
      let s = conn.getOrCreateStream(f.streamId)
      let acked = f.streamOffset + uint64(f.streamData.len)
      s.markSendAcked(acked)

proc processAckFrame(conn: QuicConnection, frame: QuicFrame, ackSpace: QuicPacketNumberSpace) =
  if frame.kind != qfkAck:
    return

  let i = spaceIdx(ackSpace)
  let decoded = decodeAckRanges(frame)
  if not decoded.valid:
    conn.setCloseReason(0x07'u64, "malformed ACK frame range encoding")
    conn.enterDraining()
    return
  let nextUnsentPn = conn.sendPacketNumber[i]
  if frame.largestAcked >= nextUnsentPn:
    conn.setCloseReason(0x0A'u64, "ACK acknowledges unsent packet number")
    conn.enterDraining()
    return
  let ranges = decoded.ranges
  if ranges.len == 0:
    return

  var acked: seq[uint64] = @[]
  var largestAckedPn = 0'u64
  var largestAckedSentAt = 0'i64
  var haveLargest = false
  for pn, meta in conn.sentPackets[i].pairs:
    if containsPacketNumber(ranges, pn):
      acked.add pn
      if not haveLargest or pn > largestAckedPn:
        largestAckedPn = pn
        largestAckedSentAt = meta.sentAtMicros
        haveLargest = true

  for pn in acked:
    let meta = conn.sentPackets[i][pn]
    conn.markAckedStreamFrames(meta.retransmittableFrames)
    conn.recovery.onPacketAcked(meta.payloadBytes)
    conn.sentPackets[i].del(pn)

  if haveLargest and largestAckedSentAt > 0:
    let latestRtt = max(1'i64, nowMicros() - largestAckedSentAt)
    let ackDelayExponent = int(conn.peerTransportParameters.ackDelayExponent)
    let ackDelayMicros = int64(frame.ackDelay shl min(ackDelayExponent, 20))
    conn.recovery.updateRtt(latestRtt, ackDelayMicros)

  let nowTs = nowMicros()
  let srtt = if conn.recovery.smoothedRttMicros > 0: conn.recovery.smoothedRttMicros else: QuicInitialRttMicros
  let latest = if conn.recovery.latestRttMicros > 0: conn.recovery.latestRttMicros else: srtt
  let timeThreshold = max((max(srtt, latest) * 9'i64) div 8'i64, QuicGranularityMicros)
  let lossTimeCutoff = nowTs - timeThreshold

  var lost: seq[uint64] = @[]
  var earliestLostAckElicitingAt = int64.high
  var latestLostAckElicitingAt = 0'i64
  for pn, meta in conn.sentPackets[i].pairs:
    let packetThresholdLost = pn + 3'u64 <= frame.largestAcked
    let timeThresholdLost = meta.sentAtMicros > 0 and meta.sentAtMicros <= lossTimeCutoff
    if packetThresholdLost or timeThresholdLost:
      lost.add pn
  for pn in lost:
    let meta = conn.sentPackets[i][pn]
    conn.recovery.onPacketLost(meta.payloadBytes)
    conn.queueRetransmittableFrames(ackSpace, meta.retransmittableFrames)
    if meta.ackEliciting and meta.sentAtMicros > 0:
      earliestLostAckElicitingAt = min(earliestLostAckElicitingAt, meta.sentAtMicros)
      latestLostAckElicitingAt = max(latestLostAckElicitingAt, meta.sentAtMicros)
    conn.sentPackets[i].del(pn)

  if earliestLostAckElicitingAt != int64.high and latestLostAckElicitingAt >= earliestLostAckElicitingAt:
    # RFC9002-style persistent congestion approximation: sustained ack-eliciting loss
    # over a period longer than two PTO intervals.
    let lossSpan = latestLostAckElicitingAt - earliestLostAckElicitingAt
    if lossSpan >= conn.recovery.currentPtoMicros() * 2'i64:
      conn.recovery.onPersistentCongestion()

  conn.emitQlog("ack-processed space=" & $ackSpace &
    " acked=" & $acked.len & " lost=" & $lost.len)
  conn.updatePtoDeadline(ackSpace)

proc queueCryptoData*(conn: QuicConnection,
                      level: QuicEncryptionLevel,
                      data: openArray[byte]) =
  if data.len == 0:
    return
  let i = keyIdx(level)
  conn.cryptoSendPending[i].add data

proc drainCryptoFrames*(conn: QuicConnection,
                        level: QuicEncryptionLevel,
                        maxFrameData: int = 1024): seq[QuicFrame] =
  let i = keyIdx(level)
  if conn.cryptoSendPending[i].len == 0:
    return @[]
  let chunkSize = max(1, maxFrameData)
  while conn.cryptoSendPending[i].len > 0:
    let n = min(chunkSize, conn.cryptoSendPending[i].len)
    var payload = newSeq[byte](n)
    for j in 0 ..< n:
      payload[j] = conn.cryptoSendPending[i][j]
    result.add QuicFrame(
      kind: qfkCrypto,
      cryptoOffset: conn.cryptoSendNextOffset[i],
      cryptoData: payload
    )
    conn.cryptoSendNextOffset[i] += uint64(n)
    if n == conn.cryptoSendPending[i].len:
      conn.cryptoSendPending[i] = @[]
    else:
      conn.cryptoSendPending[i] = conn.cryptoSendPending[i][n .. ^1]

proc ingestCryptoData*(conn: QuicConnection,
                       level: QuicEncryptionLevel,
                       offset: uint64,
                       data: openArray[byte]) =
  if data.len == 0:
    return
  let i = keyIdx(level)
  var start = offset
  var payload = @data

  if start < conn.cryptoRecvNextOffset[i]:
    let trim = int(conn.cryptoRecvNextOffset[i] - start)
    if trim >= payload.len:
      return
    payload = payload[trim .. ^1]
    start = conn.cryptoRecvNextOffset[i]

  var existingLen = 0
  if start in conn.cryptoRecvFragments[i]:
    existingLen = conn.cryptoRecvFragments[i][start].len
    if existingLen >= payload.len:
      return

  let delta = payload.len - existingLen
  if delta > 0 and conn.cryptoRecvBufferedBytes[i] + delta > QuicMaxCryptoBufferPerLevelBytes:
    conn.emitQlog(
      "crypto-buffer-exceeded level=" & $level &
      " buffered=" & $conn.cryptoRecvBufferedBytes[i] &
      " incoming_delta=" & $delta,
      kind = "error"
    )
    conn.setCloseReason(0x0D'u64, "CRYPTO buffer exceeded")
    conn.enterDraining()
    return

  conn.cryptoRecvFragments[i][start] = payload
  conn.cryptoRecvBufferedBytes[i] += delta
  while conn.cryptoRecvNextOffset[i] in conn.cryptoRecvFragments[i]:
    let chunkOffset = conn.cryptoRecvNextOffset[i]
    let chunk = conn.cryptoRecvFragments[i][chunkOffset]
    conn.cryptoRecvFragments[i].del(chunkOffset)
    if chunk.len == 0:
      break
    conn.cryptoRecvReady[i].add chunk
    conn.cryptoRecvNextOffset[i] += uint64(chunk.len)

proc takeCryptoData*(conn: QuicConnection, level: QuicEncryptionLevel): seq[byte] =
  let i = keyIdx(level)
  result = conn.cryptoRecvReady[i]
  conn.cryptoRecvReady[i] = @[]
  if result.len > 0:
    conn.cryptoRecvBufferedBytes[i] = max(0, conn.cryptoRecvBufferedBytes[i] - result.len)

proc popPeerTokens*(conn: QuicConnection): seq[seq[byte]] =
  result = conn.peerTokens
  conn.peerTokens = @[]

proc setActiveRetryToken*(conn: QuicConnection, token: openArray[byte]) =
  conn.activeRetryToken = @token
  if token.len == 0:
    conn.retrySourceConnIdExpected = @[]

proc setExpectedRetrySourceConnectionId*(conn: QuicConnection, cid: openArray[byte]) =
  conn.retrySourceConnIdExpected = @cid

proc validatePeerTransportParameters*(conn: QuicConnection,
                                      tp: QuicTransportParameters): string =
  ## Validate role-specific transport parameter invariants.
  ## Returns an empty string when valid, otherwise a short error reason.
  if conn.isNil:
    return "connection is nil"
  if tp.maxUdpPayloadSize < 1200'u64:
    return "max_udp_payload_size below minimum (1200)"
  if tp.ackDelayExponent > 20'u64:
    return "ack_delay_exponent exceeds 20"
  if tp.maxAckDelay >= (1'u64 shl 14):
    return "max_ack_delay exceeds QUIC limit (16383)"
  if tp.activeConnectionIdLimit < 2'u64:
    return "active_connection_id_limit below minimum (2)"
  if tp.initialMaxStreamsBidi > ((1'u64 shl 60) - 1'u64):
    return "initial_max_streams_bidi exceeds QUIC limit (2^60-1)"
  if tp.initialMaxStreamsUni > ((1'u64 shl 60) - 1'u64):
    return "initial_max_streams_uni exceeds QUIC limit (2^60-1)"

  if conn.role == qcrClient:
    if tp.originalDestinationConnectionId.len == 0:
      return "missing original_destination_connection_id"
    if not bytesEq(tp.originalDestinationConnectionId, conn.originalDestinationConnectionIdForValidation()):
      return "original_destination_connection_id mismatch"
    if not bytesEq(tp.initialSourceConnectionId, conn.peerConnId):
      return "initial_source_connection_id mismatch"
    if conn.retrySourceConnIdExpected.len > 0:
      if tp.retrySourceConnectionId.len == 0:
        return "missing retry_source_connection_id after Retry"
      if not bytesEq(tp.retrySourceConnectionId, conn.retrySourceConnIdExpected):
        return "retry_source_connection_id mismatch"
    elif tp.retrySourceConnectionId.len > 0:
      return "unexpected retry_source_connection_id without Retry"
    return ""

  if tp.originalDestinationConnectionId.len > 0:
    return "client sent original_destination_connection_id"
  if tp.retrySourceConnectionId.len > 0:
    return "client sent retry_source_connection_id"
  if tp.hasStatelessResetToken:
    return "client sent stateless_reset_token"
  if not bytesEq(tp.initialSourceConnectionId, conn.peerConnId):
    return "initial_source_connection_id mismatch"
  ""

proc peerConnectionIdForSequence*(conn: QuicConnection, sequence: uint64): seq[byte] =
  if sequence in conn.peerConnectionIds:
    return conn.peerConnectionIds[sequence]
  @[]

proc isPeerConnectionIdRetired*(conn: QuicConnection, sequence: uint64): bool =
  sequence in conn.retiredPeerConnectionIds

proc activatePeerTransportParameters*(conn: QuicConnection,
                                      tp: QuicTransportParameters) =
  conn.peerTransportParameters = tp
  # Respect peer-advertised stream and connection flow-control limits for outbound data.
  conn.localTransportParameters.initialMaxData =
    min(conn.localTransportParameters.initialMaxData, tp.initialMaxData)
  for _, s in conn.streams:
    if not s.canSend():
      continue
    let newLimit = conn.initialSendWindowLimit(s.direction, s.localInitiated)
    s.clampSendWindowLimit(newLimit)

proc applyReceivedFrame*(conn: QuicConnection,
                         frame: QuicFrame,
                         frameSpace: QuicPacketNumberSpace = qpnsApplication,
                         peerAddress: string = "",
                         peerPort: int = 0) =
  proc requiresApplicationSpace(kind: QuicFrameKind): bool =
    case kind
    of qfkStream,
        qfkResetStream,
        qfkStopSending,
        qfkDatagram,
        qfkMaxData,
        qfkMaxStreamData,
        qfkMaxStreams,
        qfkDataBlocked,
        qfkStreamDataBlocked,
        qfkStreamsBlocked,
        qfkNewToken,
        qfkNewConnectionId,
        qfkRetireConnectionId,
        qfkPathChallenge,
        qfkPathResponse,
        qfkHandshakeDone:
      true
    else:
      false

  proc getOrCloseOnStreamAccess(streamId: uint64,
                                frameLabel: string): QuicStream =
    try:
      result = conn.getOrCreateStream(streamId)
    except ValueError as e:
      let lower = e.msg.toLowerAscii
      if lower.contains("stream limit exceeded"):
        conn.setCloseReason(0x04'u64, frameLabel & " exceeds stream limit")
      elif lower.contains("stream id exceeds quic varint range"):
        conn.setCloseReason(0x07'u64, frameLabel & " has invalid stream id")
      else:
        conn.setCloseReason(0x0A'u64, frameLabel & " stream error")
      conn.enterDraining()
      return nil

  if frameSpace != qpnsApplication and requiresApplicationSpace(frame.kind):
    conn.setCloseReason(0x0A'u64, "frame not allowed outside application packet space")
    conn.enterDraining()
    return

  case frame.kind
  of qfkStream:
    let direction = streamDirection(frame.streamId)
    let localInitiated = conn.isLocalInitiatedStream(frame.streamId)
    let canPeerSend = direction == qsdBidirectional or not localInitiated
    if not canPeerSend:
      conn.setCloseReason(0x05'u64, "STREAM on stream peer cannot send")
      conn.enterDraining()
      return
    let s = getOrCloseOnStreamAccess(frame.streamId, "STREAM")
    if s.isNil:
      return
    try:
      s.pushRecvData(frame.streamOffset, frame.streamData, frame.streamFin)
    except ValueError as e:
      let lower = e.msg.toLowerAscii
      if lower.contains("flow-control window exceeded"):
        conn.setCloseReason(0x03'u64, "STREAM exceeds flow-control limit")
      elif lower.contains("final size"):
        conn.setCloseReason(0x06'u64, "STREAM violates final size")
      else:
        conn.setCloseReason(0x0A'u64, "invalid STREAM frame")
      conn.enterDraining()
      return
  of qfkCrypto:
    if frameSpace == qpnsApplication:
      conn.setCloseReason(0x0A'u64, "CRYPTO frame in application packet space")
      conn.enterDraining()
      return
    conn.ingestCryptoData(encryptionLevelForSpace(frameSpace), frame.cryptoOffset, frame.cryptoData)
    if conn.state == qcsInitial:
      conn.state = qcsHandshaking
  of qfkDatagram:
    let datagramLen = frame.datagramData.len
    let queueWouldOverflowCount = conn.incomingDatagrams.len >= QuicMaxIncomingDatagramQueueLen
    let queueWouldOverflowBytes =
      conn.incomingDatagramBytesQueued + datagramLen > QuicMaxIncomingDatagramQueueBytes
    if queueWouldOverflowCount or queueWouldOverflowBytes:
      conn.emitQlog(
        "incoming-datagram-dropped queue_count=" & $conn.incomingDatagrams.len &
        " queue_bytes=" & $conn.incomingDatagramBytesQueued &
        " frame_bytes=" & $datagramLen,
        kind = "drop"
      )
    else:
      conn.incomingDatagrams.add frame.datagramData
      conn.incomingDatagramBytesQueued += datagramLen
  of qfkNewToken:
    if conn.role != qcrClient:
      conn.setCloseReason(0x0A'u64, "NEW_TOKEN from client peer")
      conn.enterDraining()
      return
    if frame.newToken.len > 0:
      conn.peerTokens.add frame.newToken
  of qfkNewConnectionId:
    if frame.ncidRetirePriorTo > frame.ncidSequence:
      conn.setCloseReason(0x0A'u64, "NEW_CONNECTION_ID retire_prior_to exceeds sequence")
      conn.enterDraining()
      return
    if frame.ncidSequence in conn.peerConnectionIds:
      let existingCid = conn.peerConnectionIds[frame.ncidSequence]
      if not bytesEq(existingCid, frame.ncidConnectionId):
        conn.setCloseReason(0x0A'u64, "NEW_CONNECTION_ID sequence reuses different connection id")
        conn.enterDraining()
        return
      if existingCid.len > 0:
        let tokenKey = bytesToHex(existingCid)
        if tokenKey in conn.peerResetTokens and conn.peerResetTokens[tokenKey] != frame.ncidResetToken:
          conn.setCloseReason(0x0A'u64, "NEW_CONNECTION_ID sequence reuses different stateless reset token")
          conn.enterDraining()
          return
    let activeCidLimit = conn.localTransportParameters.activeConnectionIdLimit
    if activeCidLimit > 0'u64:
      var projectedPeerCidCount = conn.peerConnectionIds.len
      if frame.ncidSequence notin conn.peerConnectionIds:
        inc projectedPeerCidCount
      for seqNo, cid in conn.peerConnectionIds.pairs:
        discard cid
        if seqNo < frame.ncidRetirePriorTo:
          dec projectedPeerCidCount
      if uint64(projectedPeerCidCount) > activeCidLimit:
        conn.setCloseReason(0x09'u64, "NEW_CONNECTION_ID exceeds active_connection_id_limit")
        conn.enterDraining()
        return
    conn.peerConnectionIds[frame.ncidSequence] = frame.ncidConnectionId
    if frame.ncidConnectionId.len > 0:
      conn.peerConnId = frame.ncidConnectionId
      conn.peerResetTokens[bytesToHex(frame.ncidConnectionId)] = frame.ncidResetToken
    var retireSeq: seq[uint64] = @[]
    for seqNo, cid in conn.peerConnectionIds.pairs:
      discard cid
      if seqNo < frame.ncidRetirePriorTo:
        retireSeq.add seqNo
    for seqNo in retireSeq:
      conn.retiredPeerConnectionIds[seqNo] = true
      let cid = conn.peerConnectionIds[seqNo]
      if cid.len > 0:
        let k = bytesToHex(cid)
        if k in conn.peerResetTokens:
          conn.peerResetTokens.del(k)
      conn.peerConnectionIds.del(seqNo)
  of qfkRetireConnectionId:
    conn.retiredPeerConnectionIds[frame.retireCidSequence] = true
  of qfkPathChallenge:
    # PATH_RESPONSE is generated as a control frame and packetized by sender path.
    conn.pendingControlFrames.add QuicFrame(kind: qfkPathResponse, pathData: frame.pathData)
  of qfkPathResponse:
    let respPeerAddress =
      if peerAddress.len > 0: peerAddress
      else: conn.pathManager.activePath().peerAddress
    let respPeerPort =
      if peerPort > 0: peerPort
      else: conn.pathManager.activePath().peerPort
    if conn.pathManager.onPathResponse(respPeerAddress, respPeerPort, frame.pathData):
      conn.addressValidated = true
  of qfkConnectionClose:
    if frame.isApplicationClose and frameSpace != qpnsApplication:
      conn.setCloseReason(0x0A'u64, "application CONNECTION_CLOSE outside application packet space")
      conn.enterDraining()
      return
    conn.setCloseReason(frame.errorCode, frame.reason)
    conn.enterDraining()
  of qfkHandshakeDone:
    if conn.role != qcrClient:
      conn.setCloseReason(0x0A'u64, "HANDSHAKE_DONE from client peer")
      conn.enterDraining()
      return
    conn.handshakeState = qhsOneRtt
    conn.state = qcsActive
  of qfkAck:
    conn.processAckFrame(frame, frameSpace)
  of qfkResetStream:
    let direction = streamDirection(frame.resetStreamId)
    let localInitiated = conn.isLocalInitiatedStream(frame.resetStreamId)
    let canPeerSend = direction == qsdBidirectional or not localInitiated
    if not canPeerSend:
      conn.setCloseReason(0x05'u64, "RESET_STREAM on stream peer cannot send")
      conn.enterDraining()
      return
    let s = getOrCloseOnStreamAccess(frame.resetStreamId, "RESET_STREAM")
    if s.isNil:
      return
    if s.finalSizeKnown and s.finalSize != frame.resetFinalSize:
      conn.setCloseReason(0x06'u64, "RESET_STREAM final size mismatch")
      conn.enterDraining()
      return
    if s.recvOffset > frame.resetFinalSize:
      conn.setCloseReason(0x06'u64, "RESET_STREAM final size below received offset")
      conn.enterDraining()
      return
    s.finalSizeKnown = true
    s.finalSize = frame.resetFinalSize
    s.recvState = qrsResetRecvd
  of qfkStopSending:
    let direction = streamDirection(frame.stopSendingStreamId)
    let localInitiated = conn.isLocalInitiatedStream(frame.stopSendingStreamId)
    let canPeerReceive = direction == qsdBidirectional or localInitiated
    if not canPeerReceive:
      conn.setCloseReason(0x05'u64, "STOP_SENDING on stream peer cannot receive")
      conn.enterDraining()
      return
    let s = getOrCloseOnStreamAccess(frame.stopSendingStreamId, "STOP_SENDING")
    if s.isNil:
      return
    s.sendState = qssResetSent
  of qfkDataBlocked, qfkStreamDataBlocked, qfkStreamsBlocked, qfkMaxData, qfkMaxStreamData, qfkMaxStreams:
    conn.applyFlowControlFrame(frame)
  else:
    discard

proc parsePacketNumberBytes(data: openArray[byte], offset: var int, pnLen: int): uint64 =
  if pnLen < 1 or pnLen > 4:
    raise newException(ValueError, "invalid packet number length")
  if offset + pnLen > data.len:
    raise newException(ValueError, "packet number truncated")
  var pn = 0'u64
  for i in 0 ..< pnLen:
    pn = (pn shl 8) or uint64(data[offset + i])
  offset += pnLen
  pn

proc parseFramesPayload(data: openArray[byte]): seq[QuicFrame]

proc tryDecodeWithPacketKeys(conn: QuicConnection,
                             packetBytes: openArray[byte],
                             packetType: QuicPacketType,
                             headerTemplate: QuicPacketHeader,
                             pnOffset: int,
                             keys: QuicPacketProtectionKeys,
                             decoded: var QuicPacket,
                             decodeErr: var string): bool =
  if not keys.ready:
    decodeErr = "missing packet keys"
    return false
  if pnOffset < 0 or pnOffset >= packetBytes.len:
    decodeErr = "invalid packet-number offset"
    return false

  var mutablePacket: seq[byte] = @packetBytes
  var hdr = headerTemplate

  let sampleOffset = pnOffset + 4
  if sampleOffset + 16 > mutablePacket.len:
    decodeErr = "protected packet sample truncated"
    return false
  var sample = newSeq[byte](16)
  for i in 0 ..< 16:
    sample[i] = mutablePacket[sampleOffset + i]
  let mask =
    try:
      headerProtectionMask(keys.cipher, keys.hp, sample)
    except CatchableError:
      decodeErr =
        if getCurrentExceptionMsg().len > 0:
          getCurrentExceptionMsg()
        else:
          "header protection mask failure"
      return false
  let firstMask = if packetType == qptShort: 0x1F'u8 else: 0x0F'u8
  mutablePacket[0] = mutablePacket[0] xor (mask[0] and firstMask)
  let pnLen = int(mutablePacket[0] and 0x03'u8) + 1
  if pnOffset + pnLen > mutablePacket.len:
    decodeErr = "protected packet packet-number truncated"
    return false
  for i in 0 ..< pnLen:
    mutablePacket[pnOffset + i] = mutablePacket[pnOffset + i] xor mask[i + 1]

  hdr.packetNumberLen = pnLen
  if packetType == qptShort:
    hdr.keyPhase = (mutablePacket[0] and 0x04'u8) != 0

  var pnOff = pnOffset
  let truncatedPn =
    try:
      parsePacketNumberBytes(mutablePacket, pnOff, pnLen)
    except ValueError as e:
      decodeErr = e.msg
      return false
  let space = packetTypeToSpace(packetType)
  let idx = spaceIdx(space)
  let largestSeen = if conn.hasReceivedPacketInSpace[idx]:
    conn.largestReceivedPacketNumber[idx]
  else:
    0'u64
  let packetNumber = decodePacketNumber(largestSeen, truncatedPn, pnLen)

  let payloadStart = pnOffset + pnLen
  let payloadEnd =
    if packetType == qptShort:
      mutablePacket.len
    else:
      min(mutablePacket.len, payloadStart + max(0, hdr.payloadLen - pnLen))
  if payloadEnd - payloadStart < GcmTagLen:
    decodeErr = "protected packet payload too short"
    return false

  let cipherLen = (payloadEnd - payloadStart) - GcmTagLen
  var aad = newSeq[byte](payloadStart)
  for i in 0 ..< payloadStart:
    aad[i] = mutablePacket[i]
  var ciphertext = newSeq[byte](cipherLen)
  for i in 0 ..< cipherLen:
    ciphertext[i] = mutablePacket[payloadStart + i]
  var tag = newSeq[byte](GcmTagLen)
  for i in 0 ..< GcmTagLen:
    tag[i] = mutablePacket[payloadStart + cipherLen + i]

  let nonce = makeNonce(keys.iv, packetNumber)
  let plaintext =
    try:
      decryptPacketPayload(keys.cipher, keys.key, nonce, aad, ciphertext, tag)
    except CatchableError:
      decodeErr =
        if getCurrentExceptionMsg().len > 0:
          getCurrentExceptionMsg()
        else:
          "payload decrypt failure"
      return false

  let parsedFrames =
    try:
      parseFramesPayload(plaintext)
    except ValueError as e:
      decodeErr =
        if e.msg.len > 0:
          e.msg
        else:
          "frame decode failure"
      return false

  decoded = QuicPacket(
    header: hdr,
    packetNumber: packetNumber,
    frames: parsedFrames
  )
  true

proc decodeUnprotectedPacket*(conn: QuicConnection,
                              packetBytes: openArray[byte]): QuicPacket
proc encodeUnprotectedPacket*(conn: QuicConnection,
                              packetType: QuicPacketType,
                              frames: openArray[QuicFrame]): seq[byte]

proc packetTypeFromFirstByte(first: byte): QuicPacketType {.inline.} =
  if (first and 0x80'u8) == 0:
    return qptShort
  case (first shr 4) and 0x03
  of 0: qptInitial
  of 1: qpt0Rtt
  of 2: qptHandshake
  of 3: qptRetry
  else: qptInitial

proc parseFramesPayload(data: openArray[byte]): seq[QuicFrame] =
  var off = 0
  while off < data.len:
    result.add parseFrame(data, off)

proc readKeysForPacket(conn: QuicConnection,
                       packetType: QuicPacketType,
                       header: QuicPacketHeader): QuicPacketProtectionKeys =
  if packetType == qptInitial:
    # Initial secrets are bound to the original destination CID across the
    # whole Initial epoch (RFC 9001).
    let cid =
      if conn.initialSecretConnId.len > 0: conn.initialSecretConnId
      else: header.dstConnId
    if cid.len > 0:
      conn.initialSecretConnId = @cid
      conn.installInitialSecrets(cid)
  let i = case packetType
    of qptInitial: keyIdx(qelInitial)
    of qptHandshake: keyIdx(qelHandshake)
    of qptShort, qpt0Rtt: keyIdx(qelApplication)
    else: keyIdx(qelInitial)
  result = conn.levelReadKeys[i]

proc writeKeysForPacket(conn: QuicConnection,
                        packetType: QuicPacketType,
                        header: QuicPacketHeader): QuicPacketProtectionKeys =
  if packetType == qptInitial:
    # Initial secrets are bound to the original destination CID across the
    # whole Initial epoch (RFC 9001).
    let cid =
      if conn.initialSecretConnId.len > 0: conn.initialSecretConnId
      else: header.dstConnId
    if cid.len > 0:
      conn.initialSecretConnId = @cid
      conn.installInitialSecrets(cid)
  let i = case packetType
    of qptInitial: keyIdx(qelInitial)
    of qptHandshake: keyIdx(qelHandshake)
    of qptShort, qpt0Rtt: keyIdx(qelApplication)
    else: keyIdx(qelInitial)
  result = conn.levelWriteKeys[i]

proc canEncodePacketType*(conn: QuicConnection, packetType: QuicPacketType): bool =
  if packetType in {qptRetry, qptVersionNegotiation}:
    return true
  if packetType == qptShort:
    if conn.state != qcsActive or conn.handshakeState != qhsOneRtt:
      return false
  let header = QuicPacketHeader(
    packetType: packetType,
    version: conn.version,
    dstConnId: conn.peerConnId,
    srcConnId: conn.localConnId,
    token: @[],
    keyPhase: false,
    packetNumberLen: 2,
    payloadLen: 0
  )
  let keys = conn.writeKeysForPacket(packetType, header)
  keys.ready

proc encodeProtectedPacket*(conn: QuicConnection,
                            packetType: QuicPacketType,
                            frames: openArray[QuicFrame]): seq[byte] =
  if packetType == qptRetry or packetType == qptVersionNegotiation:
    return conn.encodeUnprotectedPacket(packetType, frames)

  var payload: seq[byte] = @[]
  for f in frames:
    payload.add encodeFrame(f)

  let space = packetTypeToSpace(packetType)
  let pn = conn.nextPacketNumber(space)
  let pnLen = 2
  let header = QuicPacketHeader(
    packetType: packetType,
    version: conn.version,
    dstConnId: conn.peerConnId,
    srcConnId: conn.localConnId,
    token: if packetType == qptInitial: conn.activeRetryToken else: @[],
    keyPhase: (packetType == qptShort and conn.oneRttKeyPhase),
    packetNumberLen: pnLen,
    payloadLen: payload.len + pnLen + GcmTagLen
  )
  let keys = conn.writeKeysForPacket(packetType, header)
  if not keys.ready:
    raise newException(ValueError, "protected packet encode requires active keys for packet type " & $packetType)

  var plaintext = payload
  let minPlainForSample = max(0, 4 - pnLen)
  if plaintext.len < minPlainForSample:
    for _ in 0 ..< (minPlainForSample - plaintext.len):
      plaintext.add 0'u8

  # RFC9000: client Initial packets must be at least 1200 bytes (UDP payload).
  if packetType == qptInitial and conn.role == qcrClient:
    while true:
      let hdrLen = encodePacketHeader(
        header,
        payloadLen = plaintext.len + GcmTagLen,
        packetNumberLen = pnLen
      ).len
      let packetLen = hdrLen + pnLen + plaintext.len + GcmTagLen
      if packetLen >= 1200:
        break
      let need = 1200 - packetLen
      if need <= 0:
        break
      for _ in 0 ..< need:
        plaintext.add 0'u8

  let headerBytes = encodePacketHeader(header, payloadLen = plaintext.len + GcmTagLen, packetNumberLen = pnLen)
  var aad = headerBytes
  aad.appendPacketNumber(pn, pnLen)
  let nonce = makeNonce(keys.iv, pn)
  let enc = encryptPacketPayload(keys.cipher, keys.key, nonce, aad, plaintext)

  result = headerBytes
  result.appendPacketNumber(pn, pnLen)
  result.add enc.ciphertext
  for i in 0 ..< GcmTagLen:
    result.add enc.tag[i]

  let pnOffset = headerBytes.len
  let sampleOffset = pnOffset + 4
  if sampleOffset + 16 > result.len:
    raise newException(ValueError, "protected packet encode sample truncated")

  var sample = newSeq[byte](16)
  for i in 0 ..< 16:
    sample[i] = result[sampleOffset + i]
  let mask = headerProtectionMask(keys.cipher, keys.hp, sample)
  let firstMask = if packetType == qptShort: 0x1F'u8 else: 0x0F'u8
  result[0] = result[0] xor (mask[0] and firstMask)
  for i in 0 ..< pnLen:
    result[pnOffset + i] = result[pnOffset + i] xor mask[i + 1]

  let idx = spaceIdx(space)
  let ackEliciting = hasAckElicitingFrames(frames)
  conn.sentPackets[idx][pn] = QuicSentPacket(
    packetType: packetType,
    pn: pn,
    sentAtMicros: 0'i64,
    payloadBytes: result.len,
    ackEliciting: ackEliciting,
    retransmittableFrames: @frames
  )
  conn.pendingSendRecords.add QuicPendingSendRecord(
    space: space,
    pn: pn,
    payloadBytes: result.len,
    ackEliciting: ackEliciting
  )
  conn.emitQlog("protected-packet-sent type=" & $packetType & " pn=" & $pn,
    kind = "packet-sent", packetType = packetType, packetNumber = pn, hasPacket = true)

proc decodeProtectedPacket*(conn: QuicConnection,
                            packetBytes: openArray[byte]): QuicPacket =
  if packetBytes.len == 0:
    raise newException(ValueError, "empty packet")
  let packetType = packetTypeFromFirstByte(packetBytes[0])

  var off = 0
  result.header = parsePacketHeader(packetBytes, off)
  if result.header.packetType == qptVersionNegotiation or result.header.packetType == qptRetry:
    result.packetNumber = 0
    result.frames = @[]
    return

  if packetType == qptShort:
    let dcidLen = conn.localConnId.len
    if dcidLen > 0:
      if packetBytes.len < 1 + dcidLen:
        raise newException(ValueError, "short packet truncated destination CID")
      result.header.dstConnId = newSeq[byte](dcidLen)
      for i in 0 ..< dcidLen:
        result.header.dstConnId[i] = packetBytes[1 + i]
      off = 1 + dcidLen

  let pnOffset = off

  if packetType != qptShort:
    let keys = conn.readKeysForPacket(packetType, result.header)
    if not keys.ready:
      raise newException(ValueError, "protected packet decode requires active keys for packet type " & $packetType)
    var decodeErr = ""
    if not conn.tryDecodeWithPacketKeys(
      packetBytes,
      packetType,
      result.header,
      pnOffset,
      keys,
      result,
      decodeErr
    ):
      raise newException(ValueError, decodeErr)
    conn.emitQlog("protected-packet-received type=" & $packetType & " pn=" & $result.packetNumber,
      kind = "packet-received", packetType = packetType, packetNumber = result.packetNumber, hasPacket = true)
    return

  let appIdx = keyIdx(qelApplication)
  let currentKeys = conn.levelReadKeys[appIdx]
  if not currentKeys.ready:
    raise newException(ValueError, "protected packet decode requires active keys for packet type " & $packetType)

  var attemptErrs: seq[string] = @[]
  var decoded = QuicPacket()
  var decodedOk = false
  var decodeErr = ""
  var usedPreviousKeys = false

  if conn.tryDecodeWithPacketKeys(
    packetBytes,
    packetType,
    result.header,
    pnOffset,
    currentKeys,
    decoded,
    decodeErr
  ):
    decodedOk = true
    conn.oneRttReadKeyPhase = decoded.header.keyPhase
  else:
    attemptErrs.add "current: " & decodeErr

  if not decodedOk and conn.hasPreviousOneRttReadKeys and conn.previousOneRttReadKeys.ready:
    if conn.tryDecodeWithPacketKeys(
      packetBytes,
      packetType,
      result.header,
      pnOffset,
      conn.previousOneRttReadKeys,
      decoded,
      decodeErr
    ):
      decodedOk = true
      usedPreviousKeys = true
    else:
      attemptErrs.add "previous: " & decodeErr

  if not decodedOk and conn.applicationReadTrafficSecret.len > 0:
    let nextSecret = deriveNextTrafficSecret(
      conn.applicationReadTrafficSecret,
      version = conn.version,
      hashAlg = conn.packetProtectionHash
    )
    let nextKeys = QuicPacketProtectionKeys(
      cipher: conn.packetCipher,
      key: deriveAeadKey(
        nextSecret,
        keyLen = keyLenForCipher(conn.packetCipher),
        version = conn.version,
        hashAlg = conn.packetProtectionHash
      ),
      iv: deriveAeadIv(
        nextSecret,
        version = conn.version,
        hashAlg = conn.packetProtectionHash
      ),
      hp: deriveHeaderProtectionKey(
        nextSecret,
        keyLen = hpKeyLenForCipher(conn.packetCipher),
        version = conn.version,
        hashAlg = conn.packetProtectionHash
      ),
      ready: true
    )
    if conn.tryDecodeWithPacketKeys(
      packetBytes,
      packetType,
      result.header,
      pnOffset,
      nextKeys,
      decoded,
      decodeErr
    ):
      if conn.levelReadKeys[appIdx].ready:
        conn.previousOneRttReadKeys = conn.levelReadKeys[appIdx]
        conn.hasPreviousOneRttReadKeys = true
      conn.levelReadKeys[appIdx] = nextKeys
      conn.applicationReadTrafficSecret = nextSecret
      conn.oneRttPacketsDecodedInCurrentPhase = 0
      conn.oneRttReadKeyPhase = decoded.header.keyPhase
      decodedOk = true
    else:
      attemptErrs.add "next: " & decodeErr

  if not decodedOk:
    let detail =
      if attemptErrs.len > 0:
        attemptErrs.join("; ")
      else:
        "decode failed"
    raise newException(ValueError, "protected packet decode failed: " & detail)

  # When older packets from the previous key phase arrive reordered, keep the
  # currently active key phase unchanged.
  if not usedPreviousKeys:
    conn.oneRttReadKeyPhase = decoded.header.keyPhase
    if conn.oneRttPacketsDecodedInCurrentPhase < high(int):
      inc conn.oneRttPacketsDecodedInCurrentPhase
    if conn.hasPreviousOneRttReadKeys and
        conn.oneRttPacketsDecodedInCurrentPhase >= QuicOneRttPreviousKeyRetirePackets:
      conn.previousOneRttReadKeys = QuicPacketProtectionKeys()
      conn.hasPreviousOneRttReadKeys = false
      conn.emitQlog("retired previous 1-rtt read keys",
        kind = "key-update")
  result = decoded
  conn.emitQlog("protected-packet-received type=" & $packetType & " pn=" & $result.packetNumber,
    kind = "packet-received", packetType = packetType, packetNumber = result.packetNumber, hasPacket = true)

proc decodeUnprotectedPacket*(conn: QuicConnection,
                              packetBytes: openArray[byte]): QuicPacket =
  var off = 0
  result.header = parsePacketHeader(packetBytes, off)
  if result.header.packetType == qptVersionNegotiation or result.header.packetType == qptRetry:
    result.packetNumber = 0
    result.frames = @[]
    return

  let space = packetTypeToSpace(result.header.packetType)
  let idx = spaceIdx(space)
  if result.header.packetType == qptShort and conn.localConnId.len > 0:
    off = min(packetBytes.len, 1 + conn.localConnId.len)

  let truncatedPn = parsePacketNumberBytes(packetBytes, off, result.header.packetNumberLen)
  let largestSeen = if conn.hasReceivedPacketInSpace[idx]:
    conn.largestReceivedPacketNumber[idx]
  else:
    0'u64
  result.packetNumber = decodePacketNumber(largestSeen, truncatedPn, result.header.packetNumberLen)

  var payloadEnd = packetBytes.len
  if result.header.packetType != qptShort:
    payloadEnd = min(packetBytes.len, off - result.header.packetNumberLen + result.header.payloadLen)
  if payloadEnd < off:
    raise newException(ValueError, "invalid packet payload bounds")

  result.frames = @[]
  while off < payloadEnd:
    result.frames.add parseFrame(packetBytes, off)

proc isStatelessResetFromPeer*(conn: QuicConnection, datagram: openArray[byte]): bool =
  if datagram.len < StatelessResetMinLen:
    return false
  if conn.peerTransportParameters.hasStatelessResetToken and
      isStatelessResetCandidate(datagram, conn.peerTransportParameters.statelessResetToken):
    return true
  for _, token in conn.peerResetTokens:
    if isStatelessResetCandidate(datagram, token):
      return true
  false

proc onPacketReceived*(conn: QuicConnection,
                       packet: QuicPacket,
                       peerAddress: string = "",
                       peerPort: int = 0) =
  if packet.header.packetType == qptRetry or packet.header.packetType == qptVersionNegotiation:
    return
  if packet.header.packetType == qpt0Rtt and conn.role == qcrClient:
    conn.setCloseReason(0x0A'u64, "client received forbidden 0-RTT packet from peer")
    conn.enterDraining()
    return
  let space = packetTypeToSpace(packet.header.packetType)
  let freshPacket = conn.markPacketNumberReceived(space, packet.packetNumber)
  if not freshPacket:
    conn.emitQlog("packet-duplicate type=" & $packet.header.packetType & " pn=" & $packet.packetNumber,
      kind = "packet-duplicate", packetType = packet.header.packetType, packetNumber = packet.packetNumber, hasPacket = true)
    return
  conn.pushPendingAck(space, packet.packetNumber)
  if packet.header.packetType == qptHandshake or packet.header.packetType == qptShort:
    conn.addressValidated = true
    if peerAddress.len > 0 and peerPort > 0:
      let pathIdx = conn.pathManager.ensurePath(peerAddress, peerPort)
      let activeIdx = conn.pathManager.activePathIndex()
      let isActivePath =
        activeIdx >= 0 and conn.pathManager.paths[pathIdx].pathId == conn.pathManager.paths[activeIdx].pathId
      let alreadyValidated =
        conn.pathManager.paths[pathIdx].addressValidated or
        conn.pathManager.paths[pathIdx].validationState == qpvsValidated
      # Do not auto-validate a new migration candidate path from ordinary
      # short-header traffic; require explicit PATH_RESPONSE validation first.
      if packet.header.packetType == qptHandshake or isActivePath or alreadyValidated:
        conn.pathManager.markPathValidated(peerAddress, peerPort)
  for f in packet.frames:
    if not isFrameAllowedInPacketType(f.kind, packet.header.packetType):
      conn.setCloseReason(
        0x0A'u64,
        "frame not allowed in packet type " & $packet.header.packetType
      )
      conn.enterDraining()
      break
    conn.applyReceivedFrame(f, space, peerAddress = peerAddress, peerPort = peerPort)
    if conn.state == qcsDraining:
      break
  conn.emitQlog("packet-received type=" & $packet.header.packetType & " pn=" & $packet.packetNumber)

proc encodeUnprotectedPacket*(conn: QuicConnection,
                              packetType: QuicPacketType,
                              frames: openArray[QuicFrame]): seq[byte] =
  var payload: seq[byte] = @[]
  for f in frames:
    payload.add encodeFrame(f)

  let space = packetTypeToSpace(packetType)
  let pn = conn.nextPacketNumber(space)
  let pnLen = 2
  let header = QuicPacketHeader(
    packetType: packetType,
    version: conn.version,
    dstConnId: conn.peerConnId,
    srcConnId: conn.localConnId,
    token: if packetType == qptInitial: conn.activeRetryToken else: @[],
    keyPhase: false,
    packetNumberLen: pnLen,
    payloadLen: payload.len + pnLen
  )
  result = encodePacketHeader(header, payloadLen = payload.len, packetNumberLen = pnLen)
  result.appendPacketNumber(pn, pnLen)
  result.add payload

  let i = spaceIdx(space)
  let ackEliciting = hasAckElicitingFrames(frames)
  conn.sentPackets[i][pn] = QuicSentPacket(
    packetType: packetType,
    pn: pn,
    sentAtMicros: 0'i64,
    payloadBytes: result.len,
    ackEliciting: ackEliciting,
    retransmittableFrames: @frames
  )
  conn.pendingSendRecords.add QuicPendingSendRecord(
    space: space,
    pn: pn,
    payloadBytes: result.len,
    ackEliciting: ackEliciting
  )
  conn.emitQlog("packet-sent type=" & $packetType & " pn=" & $pn)

proc queueDatagramForSend*(conn: QuicConnection, payload: openArray[byte]) =
  if payload.len == 0:
    return
  conn.outgoingDatagrams.add @payload

proc queueDatagramForSendFront*(conn: QuicConnection, payload: openArray[byte]) =
  ## Queue a datagram at the front of the send queue and keep pending
  ## send-record ordering aligned with payload ordering.
  ##
  ## Callers must only use this immediately after creating a packet payload that
  ## appended its matching pending-send record to the tail.
  if payload.len == 0:
    return
  let bytes = @payload
  conn.outgoingDatagrams.insert(bytes, 0)
  if conn.pendingSendRecords.len == 0:
    return
  let rec = conn.pendingSendRecords[^1]
  conn.pendingSendRecords.setLen(conn.pendingSendRecords.len - 1)
  conn.pendingSendRecords.insert(rec, 0)

proc notePacketActuallySent*(conn: QuicConnection) =
  if conn.pendingSendRecords.len == 0:
    return
  let rec = conn.pendingSendRecords[0]
  if conn.pendingSendRecords.len == 1:
    conn.pendingSendRecords.setLen(0)
  else:
    conn.pendingSendRecords = conn.pendingSendRecords[1 .. ^1]

  let i = spaceIdx(rec.space)
  if rec.pn in conn.sentPackets[i]:
    conn.sentPackets[i][rec.pn].sentAtMicros = nowMicros()
  conn.recovery.onPacketSent(rec.payloadBytes, ackEliciting = rec.ackEliciting)
  conn.updatePtoDeadline(rec.space)
  conn.noteActivity()

proc popOutgoingDatagrams*(conn: QuicConnection): seq[seq[byte]] =
  result = conn.outgoingDatagrams
  conn.outgoingDatagrams = @[]

proc popPendingControlFrames*(conn: QuicConnection): seq[QuicFrame] =
  result = conn.pendingControlFrames
  conn.pendingControlFrames = @[]

proc drainSendStreamFrames*(conn: QuicConnection,
                            maxFrameData: int = 1024,
                            maxFrames: int = 0): seq[QuicFrame] =
  ## Drain queued stream send buffers into STREAM frames.
  ##
  ## This lets buffered data resume after flow-control credit updates
  ## (e.g. MAX_STREAM_DATA) even when the app does not re-enter sendStreamData().
  let chunkSize = max(1, maxFrameData)
  var remaining =
    if maxFrames > 0:
      maxFrames
    else:
      high(int)

  for streamId, streamObj in conn.streams.pairs:
    while remaining > 0:
      let chunk = streamObj.nextSendChunk(chunkSize)
      if chunk.payload.len == 0 and not chunk.fin:
        break
      result.add QuicFrame(
        kind: qfkStream,
        streamId: streamId,
        streamOffset: chunk.offset,
        streamFin: chunk.fin,
        streamData: chunk.payload
      )
      if maxFrames > 0:
        dec remaining
      if chunk.fin:
        break
      if maxFrames > 0 and remaining == 0:
        return

proc popPendingRetransmitFrames*(conn: QuicConnection,
                                 space: QuicPacketNumberSpace,
                                 maxFrames: int = 0): seq[QuicFrame] =
  let i = spaceIdx(space)
  let total = conn.pendingRetransmitFrames[i].len
  if total == 0:
    return @[]
  let limit =
    if maxFrames <= 0:
      total
    else:
      min(total, maxFrames)
  result = conn.pendingRetransmitFrames[i][0 ..< limit]
  if limit >= total:
    conn.pendingRetransmitFrames[i] = @[]
  else:
    conn.pendingRetransmitFrames[i] = conn.pendingRetransmitFrames[i][limit .. ^1]

proc popIncomingDatagrams*(conn: var QuicConnection): seq[seq[byte]] =
  result = conn.incomingDatagrams
  conn.incomingDatagrams = @[]
  conn.incomingDatagramBytesQueued = 0

proc closeConnection*(conn: QuicConnection) =
  if conn.closeReason.len == 0:
    conn.closeReason = "connection closed"
  conn.state = qcsClosed
  conn.noteActivity()

proc enable0Rtt*(conn: QuicConnection, enabled: bool = true) =
  conn.local0RttEnabled = enabled

proc on0RttAccepted*(conn: QuicConnection) =
  conn.peerAccepted0Rtt = true

proc on0RttRejected*(conn: QuicConnection) =
  conn.peerAccepted0Rtt = false

proc is0RttUsable*(conn: QuicConnection): bool =
  conn.local0RttEnabled and conn.peerAccepted0Rtt

proc rotate1RttKeyPhase*(conn: QuicConnection) =
  if conn.applicationWriteTrafficSecret.len > 0:
    let nextSecret = deriveNextTrafficSecret(
      conn.applicationWriteTrafficSecret,
      version = conn.version,
      hashAlg = conn.packetProtectionHash
    )
    conn.setLevelWriteSecret(qelApplication, nextSecret)
  conn.oneRttKeyPhase = not conn.oneRttKeyPhase

proc noteDatagramReceived*(conn: QuicConnection,
                           datagramBytes: int,
                           peerAddress: string = "",
                           peerPort: int = 0) =
  if datagramBytes <= 0:
    return
  conn.bytesReceived += uint64(datagramBytes)
  inc conn.datagramsReceived
  conn.noteActivity()
  if peerAddress.len > 0 and peerPort > 0:
    conn.pathManager.noteDatagramReceived(peerAddress, peerPort, datagramBytes)

proc canSendOnPath*(conn: QuicConnection,
                    peerAddress: string,
                    peerPort: int,
                    datagramBytes: int): bool =
  if datagramBytes <= 0:
    return true
  if conn.role == qcrServer:
    if not conn.pathManager.canSendToPath(peerAddress, peerPort, datagramBytes, enforceAmplification = true):
      return false
  true

proc noteDatagramSentOnPath*(conn: QuicConnection,
                             peerAddress: string,
                             peerPort: int,
                             datagramBytes: int) =
  if datagramBytes <= 0:
    return
  conn.pathManager.noteDatagramSent(peerAddress, peerPort, datagramBytes)

proc snapshotStats*(conn: QuicConnection): QuicConnectionStats =
  let activePath = conn.pathManager.activePath()
  var validated = 0
  for p in conn.pathManager.paths:
    if p.validationState == qpvsValidated:
      inc validated
  QuicConnectionStats(
    bytesSent: conn.bytesSent,
    bytesReceived: conn.bytesReceived,
    datagramsSent: conn.datagramsSent,
    datagramsReceived: conn.datagramsReceived,
    congestionWindow: conn.recovery.congestionWindow,
    bytesInFlight: conn.recovery.bytesInFlight,
    ptoCount: conn.recovery.ptoCount,
    lostPackets: conn.recovery.lostPackets,
    ackedPackets: conn.recovery.ackedPackets,
    addressValidated: conn.addressValidated,
    handshakeState: conn.handshakeState,
    srttMicros: conn.recovery.smoothedRttMicros,
    rttVarMicros: conn.recovery.rttVarMicros,
    activePathPeer: activePath.peerAddress & ":" & $activePath.peerPort,
    peerValidatedPathCount: validated,
    state: conn.state
  )
