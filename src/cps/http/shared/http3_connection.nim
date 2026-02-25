## HTTP/3 connection/session state.

import std/[tables, strutils, sets]
import ../../quic/varint
import ./http3
import ./qpack
import ./webtransport
import ./masque

const
  DefaultMasqueCapsuleBufferBytes* = 256 * 1024
  DefaultHttp3UniStreamBufferBytes* = 256 * 1024
  DefaultHttp3RequestStreamBufferBytes* = 512 * 1024
  DefaultHttp3TotalUniStreamBufferBytes* = 2 * 1024 * 1024
  DefaultHttp3TotalRequestStreamBufferBytes* = 8 * 1024 * 1024
  MaxQuicVarIntValue = (1'u64 shl 62) - 1'u64
  MaxClientBidirectionalStreamId = MaxQuicVarIntValue and not 0x03'u64

type
  Http3ControlState* = enum
    h3csInit
    h3csSettingsSent
    h3csReady
    h3csGoawaySent
    h3csClosing

  Http3StreamRole* = enum
    h3srUnknown
    h3srControl
    h3srQpackEncoder
    h3srQpackDecoder
    h3srPush
    h3srRequest

  Http3EventKind* = enum
    h3evNone
    h3evHeaders
    h3evData
    h3evSettings
    h3evGoaway
    h3evPushPromise
    h3evCancelPush
    h3evMaxPushId
    h3evProtocolError

  Http3Event* = object
    kind*: Http3EventKind
    streamId*: uint64
    headers*: seq[QpackHeaderField]
    data*: seq[byte]
    settings*: seq[(uint64, uint64)]
    goawayId*: uint64
    pushId*: uint64
    pushHeaders*: seq[QpackHeaderField]
    errorCode*: uint64
    errorMessage*: string

  Http3RequestStreamState = object
    sawInitialHeaders: bool
    sawFinalHeaders: bool
    sawData: bool
    sawTrailers: bool

  Http3Connection* = ref object
    isClient*: bool
    useRfcQpackWire*: bool
    controlState*: Http3ControlState
    qpackEncoder*: QpackEncoder
    qpackDecoder*: QpackDecoder
    controlStreamId*: uint64
    qpackEncoderStreamId*: uint64
    qpackDecoderStreamId*: uint64
    peerSettings*: Table[uint64, uint64]
    peerSettingsReceived*: bool
    localSettings*: seq[(uint64, uint64)]
    uniStreamTypes*: Table[uint64, Http3StreamRole]
    uniStreamBuffers*: Table[uint64, seq[byte]]
    failedUniStreamErrorCodes: Table[uint64, uint64]
    failedUniStreamErrorMessages: Table[uint64, string]
    peerControlStreamId*: int64
    peerQpackEncoderStreamId*: int64
    peerQpackDecoderStreamId*: int64
    peerControlStreamFailed: bool
    peerControlStreamErrorCode: uint64
    peerControlStreamErrorMessage: string
    peerQpackEncoderStreamFailed: bool
    peerQpackEncoderStreamErrorCode: uint64
    peerQpackEncoderStreamErrorMessage: string
    peerQpackDecoderStreamFailed: bool
    peerQpackDecoderStreamErrorCode: uint64
    peerQpackDecoderStreamErrorMessage: string
    requestStates*: Table[uint64, Http3RequestStreamState]
    requestStreamBuffers*: Table[uint64, seq[byte]]
    failedRequestStreamErrorCodes: Table[uint64, uint64]
    failedRequestStreamErrorMessages: Table[uint64, string]
    qpackBlockedRequestStreams*: Table[uint64, bool]
    qpackBlockedRequestStreamCounted: Table[uint64, bool]
    qpackBlockedRequestStreamEpochs: Table[uint64, uint64]
    nextLocalRequestStreamId*: uint64
    maxPushIdAdvertised*: uint64
    hasAdvertisedMaxPushId*: bool
    maxPushIdReceived*: uint64
    hasPeerMaxPushId*: bool
    pushPromises*: Table[uint64, seq[QpackHeaderField]]
    pushPromiseIdsUsed: Table[uint64, bool]
    cancelledPushIds*: Table[uint64, bool]
    pushStreamPushIds: Table[uint64, uint64]
    pushIdToPushStreamId: Table[uint64, uint64]
    pushStreamsEndedWhileQpackBlocked: Table[uint64, bool]
    webTransportSessions*: Table[uint64, WebTransportSession]
    masqueSessions*: Table[uint64, MasqueSession]
    masqueCapsuleBuffers*: Table[uint64, seq[byte]]
    maxMasqueCapsuleBufferBytes*: int
    maxUniStreamBufferBytes*: int
    maxRequestStreamBufferBytes*: int
    maxTotalUniStreamBufferBytes*: int
    maxTotalRequestStreamBufferBytes*: int
    totalUniStreamBufferedBytes: int
    totalRequestStreamBufferedBytes: int
    localGoawayId: uint64
    hasLocalGoaway: bool
    peerGoawayId*: uint64
    hasPeerGoaway*: bool
    pendingQpackEncoderStreamData: seq[byte]
    pendingQpackDecoderStreamData: seq[byte]
    advertisedDecoderInsertCount: uint64
    qpackEncoderInstructionEpoch: uint64

proc newHttp3Connection*(isClient: bool,
                         useRfcQpackWire: bool = false,
                         qpackTableCapacity: int = 4096,
                         qpackBlockedStreams: int = 16,
                         maxMasqueCapsuleBufferBytes: int = DefaultMasqueCapsuleBufferBytes,
                         maxUniStreamBufferBytes: int = DefaultHttp3UniStreamBufferBytes,
                         maxRequestStreamBufferBytes: int = DefaultHttp3RequestStreamBufferBytes,
                         maxTotalUniStreamBufferBytes: int = DefaultHttp3TotalUniStreamBufferBytes,
                         maxTotalRequestStreamBufferBytes: int = DefaultHttp3TotalRequestStreamBufferBytes): Http3Connection =
  if qpackTableCapacity < 0:
    raise newException(ValueError, "HTTP/3 QPACK table capacity must be non-negative")
  if qpackBlockedStreams < 0:
    raise newException(ValueError, "HTTP/3 QPACK blocked-stream limit must be non-negative")
  if maxMasqueCapsuleBufferBytes < 0:
    raise newException(ValueError, "HTTP/3 MASQUE capsule buffer limit must be non-negative")
  if maxUniStreamBufferBytes < 0:
    raise newException(ValueError, "HTTP/3 unidirectional stream buffer limit must be non-negative")
  if maxRequestStreamBufferBytes < 0:
    raise newException(ValueError, "HTTP/3 request stream buffer limit must be non-negative")
  if maxTotalUniStreamBufferBytes < 0:
    raise newException(ValueError, "HTTP/3 total unidirectional stream buffer limit must be non-negative")
  if maxTotalRequestStreamBufferBytes < 0:
    raise newException(ValueError, "HTTP/3 total request stream buffer limit must be non-negative")
  Http3Connection(
    isClient: isClient,
    useRfcQpackWire: useRfcQpackWire,
    controlState: h3csInit,
    qpackEncoder: newQpackEncoder(qpackTableCapacity, qpackBlockedStreams),
    qpackDecoder: newQpackDecoder(qpackTableCapacity, qpackBlockedStreams),
    controlStreamId: if isClient: 2'u64 else: 3'u64,
    qpackEncoderStreamId: if isClient: 6'u64 else: 7'u64,
    qpackDecoderStreamId: if isClient: 10'u64 else: 11'u64,
    peerSettings: initTable[uint64, uint64](),
    peerSettingsReceived: false,
    localSettings: @[
      (H3SettingQpackMaxTableCapacity, uint64(qpackTableCapacity)),
      (H3SettingQpackBlockedStreams, uint64(qpackBlockedStreams)),
      (H3SettingMaxFieldSectionSize, 1_048_576'u64),
      (H3SettingEnableConnectProtocol, 1'u64),
      (H3SettingH3Datagram, 1'u64)
    ],
    uniStreamTypes: initTable[uint64, Http3StreamRole](),
    uniStreamBuffers: initTable[uint64, seq[byte]](),
    failedUniStreamErrorCodes: initTable[uint64, uint64](),
    failedUniStreamErrorMessages: initTable[uint64, string](),
    peerControlStreamId: -1'i64,
    peerQpackEncoderStreamId: -1'i64,
    peerQpackDecoderStreamId: -1'i64,
    peerControlStreamFailed: false,
    peerControlStreamErrorCode: 0'u64,
    peerControlStreamErrorMessage: "",
    peerQpackEncoderStreamFailed: false,
    peerQpackEncoderStreamErrorCode: 0'u64,
    peerQpackEncoderStreamErrorMessage: "",
    peerQpackDecoderStreamFailed: false,
    peerQpackDecoderStreamErrorCode: 0'u64,
    peerQpackDecoderStreamErrorMessage: "",
    requestStates: initTable[uint64, Http3RequestStreamState](),
    requestStreamBuffers: initTable[uint64, seq[byte]](),
    failedRequestStreamErrorCodes: initTable[uint64, uint64](),
    failedRequestStreamErrorMessages: initTable[uint64, string](),
    qpackBlockedRequestStreams: initTable[uint64, bool](),
    qpackBlockedRequestStreamCounted: initTable[uint64, bool](),
    qpackBlockedRequestStreamEpochs: initTable[uint64, uint64](),
    nextLocalRequestStreamId: if isClient: 0'u64 else: 1'u64,
    maxPushIdAdvertised: 0'u64,
    hasAdvertisedMaxPushId: false,
    maxPushIdReceived: 0'u64,
    hasPeerMaxPushId: false,
    pushPromises: initTable[uint64, seq[QpackHeaderField]](),
    pushPromiseIdsUsed: initTable[uint64, bool](),
    cancelledPushIds: initTable[uint64, bool](),
    pushStreamPushIds: initTable[uint64, uint64](),
    pushIdToPushStreamId: initTable[uint64, uint64](),
    pushStreamsEndedWhileQpackBlocked: initTable[uint64, bool](),
    webTransportSessions: initTable[uint64, WebTransportSession](),
    masqueSessions: initTable[uint64, MasqueSession](),
    masqueCapsuleBuffers: initTable[uint64, seq[byte]](),
    maxMasqueCapsuleBufferBytes: maxMasqueCapsuleBufferBytes,
    maxUniStreamBufferBytes: maxUniStreamBufferBytes,
    maxRequestStreamBufferBytes: maxRequestStreamBufferBytes,
    maxTotalUniStreamBufferBytes: maxTotalUniStreamBufferBytes,
    maxTotalRequestStreamBufferBytes: maxTotalRequestStreamBufferBytes,
    totalUniStreamBufferedBytes: 0,
    totalRequestStreamBufferedBytes: 0,
    localGoawayId: 0'u64,
    hasLocalGoaway: false,
    peerGoawayId: 0'u64,
    hasPeerGoaway: false,
    pendingQpackEncoderStreamData: @[],
    pendingQpackDecoderStreamData: @[],
    advertisedDecoderInsertCount: 0'u64,
    qpackEncoderInstructionEpoch: 0'u64
  )

proc validateLocalSettingsForEmission(settings: openArray[(uint64, uint64)])

proc encodeControlStreamPreface*(conn: Http3Connection): seq[byte] =
  ## Unidirectional control stream preface + SETTINGS frame.
  validateLocalSettingsForEmission(conn.localSettings)
  result = @[]
  result.appendQuicVarInt(H3UniControlStream)
  let settingsPayload = encodeSettingsPayload(conn.localSettings)
  result.add encodeHttp3Frame(H3FrameSettings, settingsPayload)
  conn.controlState = h3csSettingsSent

proc encodeQpackEncoderStreamPreface*(conn: Http3Connection): seq[byte] =
  result = @[]
  result.appendQuicVarInt(H3UniQpackEncoderStream)

proc encodeQpackDecoderStreamPreface*(conn: Http3Connection): seq[byte] =
  result = @[]
  result.appendQuicVarInt(H3UniQpackDecoderStream)

proc peerSettingValue*(conn: Http3Connection,
                       settingId: uint64,
                       defaultValue: uint64 = 0'u64): uint64 =
  if conn.isNil:
    return defaultValue
  if settingId in conn.peerSettings:
    return conn.peerSettings[settingId]
  defaultValue

proc localSettingValue*(conn: Http3Connection,
                        settingId: uint64,
                        defaultValue: uint64 = 0'u64): uint64 =
  if conn.isNil:
    return defaultValue
  for (k, v) in conn.localSettings:
    if k == settingId:
      return v
  defaultValue

proc clampSettingToInt(value: uint64): int {.inline.} =
  if value > uint64(high(int)):
    return high(int)
  int(value)

proc qpackDynamicTableBytes(table: openArray[QpackHeaderField]): int =
  for field in table:
    result += field.name.len + field.value.len + 32

proc applyLocalQpackLimits(conn: Http3Connection) =
  if conn.isNil or conn.qpackDecoder.isNil:
    return
  let localMaxCapacity = conn.localSettingValue(H3SettingQpackMaxTableCapacity, 0'u64)
  let localBlockedStreams = conn.localSettingValue(H3SettingQpackBlockedStreams, 0'u64)

  conn.qpackDecoder.maxTableCapacity = clampSettingToInt(localMaxCapacity)
  conn.qpackDecoder.blockedStreamsLimit = clampSettingToInt(localBlockedStreams)
  if conn.qpackDecoder.blockedStreams > conn.qpackDecoder.blockedStreamsLimit:
    conn.qpackDecoder.blockedStreams = conn.qpackDecoder.blockedStreamsLimit

  while conn.qpackDecoder.dynamicTable.len > 0 and
      qpackDynamicTableBytes(conn.qpackDecoder.dynamicTable) > conn.qpackDecoder.maxTableCapacity:
    conn.qpackDecoder.dynamicTable.setLen(conn.qpackDecoder.dynamicTable.len - 1)

proc validateLocalSettingValue(settingId: uint64, value: uint64) =
  case settingId
  of 0x02'u64, 0x03'u64, 0x04'u64, 0x05'u64:
    raise newException(ValueError, "forbidden HTTP/2 SETTINGS identifier")
  of H3SettingEnableConnectProtocol:
    if value > 1'u64:
      raise newException(ValueError, "SETTINGS_ENABLE_CONNECT_PROTOCOL must be 0 or 1")
  of H3SettingH3Datagram:
    if value > 1'u64:
      raise newException(ValueError, "SETTINGS_H3_DATAGRAM must be 0 or 1")
  else:
    discard

proc validateQuicVarIntRange(value: uint64, what: string) =
  if value > MaxQuicVarIntValue:
    raise newException(ValueError, what & " exceeds QUIC varint range")

proc validateLocalSettingsForEmission(settings: openArray[(uint64, uint64)]) =
  var seen = initHashSet[uint64]()
  for (k, v) in settings:
    validateQuicVarIntRange(k, "SETTINGS identifier")
    validateQuicVarIntRange(v, "SETTINGS value")
    if k in seen:
      raise newException(ValueError, "duplicate SETTINGS identifier")
    seen.incl(k)
    validateLocalSettingValue(k, v)

proc setLocalSettingValue*(conn: Http3Connection,
                           settingId: uint64,
                           value: uint64) =
  if conn.isNil:
    return
  validateQuicVarIntRange(settingId, "SETTINGS identifier")
  validateQuicVarIntRange(value, "SETTINGS value")
  validateLocalSettingValue(settingId, value)
  for i in 0 ..< conn.localSettings.len:
    if conn.localSettings[i][0] == settingId:
      conn.localSettings[i] = (settingId, value)
      if settingId == H3SettingQpackMaxTableCapacity or settingId == H3SettingQpackBlockedStreams:
        conn.applyLocalQpackLimits()
      return
  conn.localSettings.add (settingId, value)
  if settingId == H3SettingQpackMaxTableCapacity or settingId == H3SettingQpackBlockedStreams:
    conn.applyLocalQpackLimits()

proc canSendH3Datagrams*(conn: Http3Connection): bool =
  if conn.isNil:
    return false
  if not conn.peerSettingsReceived:
    return false
  conn.localSettingValue(H3SettingH3Datagram, 0'u64) == 1'u64 and
    conn.peerSettingValue(H3SettingH3Datagram, 0'u64) == 1'u64

proc appendPendingQpackEncoderInstructions(conn: Http3Connection,
                                           instructions: openArray[QpackEncoderInstruction]) =
  if instructions.len == 0:
    return
  for inst in instructions:
    conn.pendingQpackEncoderStreamData.add encodeEncoderInstruction(inst)

proc applyPeerQpackLimits(conn: Http3Connection) =
  if conn.isNil or conn.qpackEncoder.isNil:
    return
  let peerMaxCapacity = conn.peerSettingValue(H3SettingQpackMaxTableCapacity, 0'u64)
  let peerBlockedStreams = conn.peerSettingValue(H3SettingQpackBlockedStreams, 0'u64)

  conn.qpackEncoder.maxTableCapacity = clampSettingToInt(peerMaxCapacity)
  conn.qpackEncoder.blockedStreamsLimit = clampSettingToInt(peerBlockedStreams)
  if conn.qpackEncoder.blockedStreams > conn.qpackEncoder.blockedStreamsLimit:
    conn.qpackEncoder.blockedStreams = conn.qpackEncoder.blockedStreamsLimit

  while conn.qpackEncoder.dynamicTable.len > 0 and
      qpackDynamicTableBytes(conn.qpackEncoder.dynamicTable) > conn.qpackEncoder.maxTableCapacity:
    conn.qpackEncoder.dynamicTable.setLen(conn.qpackEncoder.dynamicTable.len - 1)

proc drainQpackEncoderStreamData*(conn: Http3Connection): seq[byte] =
  result = conn.pendingQpackEncoderStreamData
  conn.pendingQpackEncoderStreamData = @[]

proc drainQpackDecoderStreamData*(conn: Http3Connection): seq[byte] =
  result = conn.pendingQpackDecoderStreamData
  conn.pendingQpackDecoderStreamData = @[]

proc encodeHeadersFrame*(conn: Http3Connection, headers: openArray[QpackHeaderField]): seq[byte] =
  let headerBlock =
    if conn.useRfcQpackWire:
      var emitted: seq[QpackEncoderInstruction] = @[]
      let encodedBlock = conn.qpackEncoder.encodeHeadersRfcWireWithInstructions(headers, emitted)
      conn.appendPendingQpackEncoderInstructions(emitted)
      encodedBlock
    else:
      conn.qpackEncoder.encodeHeaders(headers)
  encodeHttp3Frame(H3FrameHeaders, headerBlock)

proc decodeHeadersFrame*(conn: Http3Connection, payload: openArray[byte]): seq[QpackHeaderField] =
  if conn.useRfcQpackWire:
    conn.qpackDecoder.decodeHeadersRfcWire(payload)
  else:
    conn.qpackDecoder.decodeHeaders(payload)

proc encodeDataFrame*(payload: openArray[byte]): seq[byte] =
  encodeHttp3Frame(H3FrameData, payload)

proc encodeGoawayFrame*(id: uint64): seq[byte] =
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(id)
  encodeHttp3Frame(H3FrameGoaway, payload)

proc encodeCancelPushFrame*(pushId: uint64): seq[byte] =
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(pushId)
  encodeHttp3Frame(H3FrameCancelPush, payload)

proc encodeMaxPushIdFrame*(pushId: uint64): seq[byte] =
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(pushId)
  encodeHttp3Frame(H3FrameMaxPushId, payload)

proc advertiseMaxPushId*(conn: Http3Connection, pushId: uint64): seq[byte] =
  if not conn.isClient:
    raise newException(ValueError, "MAX_PUSH_ID can only be advertised by HTTP/3 clients")
  validateQuicVarIntRange(pushId, "MAX_PUSH_ID")
  if conn.hasAdvertisedMaxPushId and pushId < conn.maxPushIdAdvertised:
    raise newException(ValueError, "MAX_PUSH_ID cannot decrease")
  result = encodeMaxPushIdFrame(pushId)
  conn.maxPushIdAdvertised = pushId
  conn.hasAdvertisedMaxPushId = true

proc encodePushPromiseFrame*(pushId: uint64, headerBlock: openArray[byte]): seq[byte] =
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(pushId)
  if headerBlock.len > 0:
    payload.add headerBlock
  encodeHttp3Frame(H3FramePushPromise, payload)

proc openRequest*(conn: Http3Connection): uint64 =
  if not conn.isClient:
    raise newException(ValueError, "request streams can only be opened by HTTP/3 clients")
  if (conn.nextLocalRequestStreamId and 0x03'u64) != 0'u64:
    raise newException(ValueError, "next local request stream ID is not client-initiated bidirectional")
  if conn.nextLocalRequestStreamId > MaxClientBidirectionalStreamId:
    raise newException(ValueError, "exhausted client-initiated bidirectional stream IDs")
  if conn.hasPeerGoaway and conn.nextLocalRequestStreamId >= conn.peerGoawayId:
    raise newException(ValueError, "GOAWAY received; new request stream meets or exceeds peer GOAWAY ID")
  result = conn.nextLocalRequestStreamId
  conn.nextLocalRequestStreamId += 4

proc submitRequest*(conn: Http3Connection,
                    headers: openArray[QpackHeaderField],
                    body: seq[byte] = @[]): seq[byte] =
  result = conn.encodeHeadersFrame(headers)
  if body.len > 0:
    result.add encodeDataFrame(body)

proc sendGoaway*(conn: Http3Connection, id: uint64): seq[byte] =
  validateQuicVarIntRange(id, "GOAWAY ID")
  if not conn.isClient and (id and 0x03'u64) != 0'u64:
    raise newException(ValueError, "server GOAWAY requires a client-initiated bidirectional stream ID")
  if conn.hasLocalGoaway and id > conn.localGoawayId:
    raise newException(ValueError, "local GOAWAY ID must be non-increasing")
  result = encodeGoawayFrame(id)
  conn.localGoawayId = id
  conn.hasLocalGoaway = true
  conn.controlState = h3csGoawaySent

proc fieldSectionSize(headers: openArray[QpackHeaderField]): uint64
proc validatePushPromiseRequestHeaders(streamId: uint64,
                                       headers: openArray[QpackHeaderField]): Http3Event

proc createPushPromise*(conn: Http3Connection,
                        pushId: uint64,
                        headers: openArray[QpackHeaderField]): seq[byte] =
  if conn.isClient:
    raise newException(ValueError, "PUSH_PROMISE can only be sent by HTTP/3 servers")
  if not conn.hasPeerMaxPushId:
    raise newException(ValueError, "cannot create PUSH_PROMISE before receiving MAX_PUSH_ID")
  if pushId > conn.maxPushIdReceived:
    raise newException(ValueError, "push id exceeds peer-advertised MAX_PUSH_ID")
  if not conn.isClient and conn.hasPeerGoaway and pushId >= conn.peerGoawayId:
    raise newException(ValueError, "push id meets or exceeds peer GOAWAY limit")
  if pushId in conn.cancelledPushIds:
    raise newException(ValueError, "push id was cancelled by peer")
  if pushId in conn.pushPromiseIdsUsed:
    raise newException(ValueError, "push id already used in PUSH_PROMISE")
  validateQuicVarIntRange(pushId, "PUSH_PROMISE push ID")
  let headerValidationErr = validatePushPromiseRequestHeaders(0'u64, headers)
  if headerValidationErr.kind == h3evProtocolError:
    raise newException(ValueError, headerValidationErr.errorMessage)
  let peerFieldSectionLimit = conn.peerSettingValue(H3SettingMaxFieldSectionSize, high(uint64))
  if fieldSectionSize(headers) > peerFieldSectionLimit:
    raise newException(
      ValueError,
      "HTTP/3 PUSH_PROMISE headers exceed peer SETTINGS_MAX_FIELD_SECTION_SIZE"
    )
  let headerBlock =
    if conn.useRfcQpackWire:
      var emitted: seq[QpackEncoderInstruction] = @[]
      let encodedBlock = conn.qpackEncoder.encodeHeadersRfcWireWithInstructions(headers, emitted)
      conn.appendPendingQpackEncoderInstructions(emitted)
      encodedBlock
    else:
      conn.qpackEncoder.encodeHeaders(headers)
  result = encodePushPromiseFrame(pushId, headerBlock)
  conn.pushPromiseIdsUsed[pushId] = true
  conn.pushPromises[pushId] = @headers

proc clearUniStreamState(conn: Http3Connection, streamId: uint64)
proc clearRequestStreamState*(conn: Http3Connection, streamId: uint64)

proc cancelPush*(conn: Http3Connection, pushId: uint64): seq[byte] =
  if not conn.isClient:
    raise newException(ValueError, "CANCEL_PUSH can only be sent by HTTP/3 clients")
  validateQuicVarIntRange(pushId, "CANCEL_PUSH ID")
  result = encodeCancelPushFrame(pushId)
  conn.cancelledPushIds[pushId] = true
  if pushId in conn.pushIdToPushStreamId:
    let pushStreamId = conn.pushIdToPushStreamId[pushId]
    conn.clearRequestStreamState(pushStreamId)
    conn.clearUniStreamState(pushStreamId)

proc registerWebTransportSession*(conn: Http3Connection,
                                  streamId: uint64,
                                  authority: string,
                                  path: string): WebTransportSession =
  let session =
    if conn.isClient:
      openWebTransportSession(sessionId = streamId, authority = authority, path = path)
    else:
      acceptWebTransportSession(streamId, authority, path)
  conn.webTransportSessions[streamId] = session
  session

proc registerMasqueUdpSession*(conn: Http3Connection,
                               streamId: uint64,
                               authority: string,
                               targetHostPort: string): MasqueSession =
  let session = connectUdp(authority, targetHostPort)
  conn.masqueSessions[streamId] = session
  session

proc registerMasqueIpSession*(conn: Http3Connection,
                              streamId: uint64,
                              authority: string,
                              targetIpPrefix: string): MasqueSession =
  let session = connectIp(authority, targetIpPrefix)
  conn.masqueSessions[streamId] = session
  session

proc parseUniStreamType(data: openArray[byte], offset: var int): Http3StreamRole =
  let typ = decodeQuicVarInt(data, offset)
  case typ
  of H3UniControlStream: h3srControl
  of H3UniQpackEncoderStream: h3srQpackEncoder
  of H3UniQpackDecoderStream: h3srQpackDecoder
  of H3UniPushStream: h3srPush
  else: h3srUnknown

proc protocolError(streamId: uint64, msg: string,
                   errorCode: uint64 = H3ErrGeneralProtocol): Http3Event =
  Http3Event(
    kind: h3evProtocolError,
    streamId: streamId,
    errorCode: errorCode,
    errorMessage: msg
  )

proc markRequestStreamFatal(conn: Http3Connection,
                            streamId: uint64,
                            msg: string,
                            errorCode: uint64): Http3Event =
  let code = if errorCode != 0'u64: errorCode else: H3ErrGeneralProtocol
  if not conn.isNil:
    conn.failedRequestStreamErrorCodes[streamId] = code
    conn.failedRequestStreamErrorMessages[streamId] = msg
  protocolError(streamId, msg, code)

proc requestStreamFatalEvent(conn: Http3Connection,
                             streamId: uint64): Http3Event =
  if conn.isNil or streamId notin conn.failedRequestStreamErrorCodes:
    return Http3Event(kind: h3evNone, streamId: streamId)
  let code = conn.failedRequestStreamErrorCodes[streamId]
  let msg =
    if streamId in conn.failedRequestStreamErrorMessages:
      conn.failedRequestStreamErrorMessages[streamId]
    else:
      "HTTP/3 request stream is unusable after prior protocol violation"
  protocolError(streamId, msg, code)

proc markUniStreamFatal(conn: Http3Connection,
                        streamId: uint64,
                        msg: string,
                        errorCode: uint64): Http3Event =
  let code = if errorCode != 0'u64: errorCode else: H3ErrGeneralProtocol
  if not conn.isNil:
    conn.failedUniStreamErrorCodes[streamId] = code
    conn.failedUniStreamErrorMessages[streamId] = msg
  protocolError(streamId, msg, code)

proc uniStreamFatalEvent(conn: Http3Connection,
                         streamId: uint64): Http3Event =
  if conn.isNil or streamId notin conn.failedUniStreamErrorCodes:
    return Http3Event(kind: h3evNone, streamId: streamId)
  let code = conn.failedUniStreamErrorCodes[streamId]
  let msg =
    if streamId in conn.failedUniStreamErrorMessages:
      conn.failedUniStreamErrorMessages[streamId]
    else:
      "HTTP/3 unidirectional stream is unusable after prior protocol violation"
  protocolError(streamId, msg, code)

proc markPeerControlStreamFatal(conn: Http3Connection,
                                streamId: uint64,
                                msg: string,
                                errorCode: uint64): Http3Event =
  if not conn.isNil:
    if not conn.peerControlStreamFailed:
      conn.peerControlStreamFailed = true
      conn.peerControlStreamErrorCode = errorCode
      conn.peerControlStreamErrorMessage = msg
    conn.controlState = h3csClosing
  protocolError(streamId, msg, errorCode)

proc controlStreamFatalEvent(conn: Http3Connection,
                             streamId: uint64): Http3Event =
  if conn.isNil or not conn.peerControlStreamFailed:
    return Http3Event(kind: h3evNone, streamId: streamId)
  let code =
    if conn.peerControlStreamErrorCode != 0'u64:
      conn.peerControlStreamErrorCode
    else:
      H3ErrGeneralProtocol
  let msg =
    if conn.peerControlStreamErrorMessage.len > 0:
      conn.peerControlStreamErrorMessage
    else:
      "HTTP/3 control stream is unusable after prior protocol violation"
  protocolError(streamId, msg, code)

proc markPeerQpackEncoderStreamFatal(conn: Http3Connection,
                                     streamId: uint64,
                                     msg: string,
                                     errorCode: uint64): Http3Event =
  if not conn.isNil:
    if not conn.peerQpackEncoderStreamFailed:
      conn.peerQpackEncoderStreamFailed = true
      conn.peerQpackEncoderStreamErrorCode = errorCode
      conn.peerQpackEncoderStreamErrorMessage = msg
    conn.controlState = h3csClosing
  protocolError(streamId, msg, errorCode)

proc qpackEncoderStreamFatalEvent(conn: Http3Connection,
                                  streamId: uint64): Http3Event =
  if conn.isNil or not conn.peerQpackEncoderStreamFailed:
    return Http3Event(kind: h3evNone, streamId: streamId)
  let code =
    if conn.peerQpackEncoderStreamErrorCode != 0'u64:
      conn.peerQpackEncoderStreamErrorCode
    else:
      QpackErrEncoderStream
  let msg =
    if conn.peerQpackEncoderStreamErrorMessage.len > 0:
      conn.peerQpackEncoderStreamErrorMessage
    else:
      "HTTP/3 QPACK encoder stream is unusable after prior protocol violation"
  protocolError(streamId, msg, code)

proc markPeerQpackDecoderStreamFatal(conn: Http3Connection,
                                     streamId: uint64,
                                     msg: string,
                                     errorCode: uint64): Http3Event =
  if not conn.isNil:
    if not conn.peerQpackDecoderStreamFailed:
      conn.peerQpackDecoderStreamFailed = true
      conn.peerQpackDecoderStreamErrorCode = errorCode
      conn.peerQpackDecoderStreamErrorMessage = msg
    conn.controlState = h3csClosing
  protocolError(streamId, msg, errorCode)

proc qpackDecoderStreamFatalEvent(conn: Http3Connection,
                                  streamId: uint64): Http3Event =
  if conn.isNil or not conn.peerQpackDecoderStreamFailed:
    return Http3Event(kind: h3evNone, streamId: streamId)
  let code =
    if conn.peerQpackDecoderStreamErrorCode != 0'u64:
      conn.peerQpackDecoderStreamErrorCode
    else:
      QpackErrDecoderStream
  let msg =
    if conn.peerQpackDecoderStreamErrorMessage.len > 0:
      conn.peerQpackDecoderStreamErrorMessage
    else:
      "HTTP/3 QPACK decoder stream is unusable after prior protocol violation"
  protocolError(streamId, msg, code)

proc isLikelyIncompleteFrameError(msg: string): bool =
  let m = msg.toLowerAscii
  m.contains("truncated") or m.contains("empty input")

const headerTokenChars = {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^',
                          '_', '`', '|', '~'} + Digits + Letters

proc isValidHeaderName(name: string): bool =
  if name.len == 0:
    return false
  for c in name:
    if c notin headerTokenChars:
      return false
  true

proc isValidHeaderValue(value: string): bool =
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

proc fieldSectionSize(headers: openArray[QpackHeaderField]): uint64 =
  for (name, value) in headers:
    let entry = uint64(name.len + value.len + 32)
    if high(uint64) - result < entry:
      return high(uint64)
    result += entry

proc validateFieldSectionSize(conn: Http3Connection,
                              streamId: uint64,
                              headers: openArray[QpackHeaderField],
                              frameLabel: string): Http3Event =
  let maxFieldSectionSize = conn.localSettingValue(H3SettingMaxFieldSectionSize, high(uint64))
  if fieldSectionSize(headers) <= maxFieldSectionSize:
    return Http3Event(kind: h3evNone, streamId: streamId)
  protocolError(
    streamId,
    "HTTP/3 " & frameLabel & " field section exceeds SETTINGS_MAX_FIELD_SECTION_SIZE",
    H3ErrExcessiveLoad
  )

proc validateTrailingHeadersSection(streamId: uint64,
                                    headers: openArray[QpackHeaderField]): Http3Event =
  for (name, value) in headers:
    if name.startsWith(":"):
      return protocolError(
        streamId,
        "HTTP/3 trailing HEADERS must not contain pseudo-headers",
        H3ErrMessageError
      )
    let lower = name.toLowerAscii
    if name != lower:
      return protocolError(
        streamId,
        "HTTP/3 trailing HEADERS field names must be lowercase",
        H3ErrMessageError
      )
    if not isValidHeaderName(name) or not isValidHeaderValue(value):
      return protocolError(
        streamId,
        "HTTP/3 trailing HEADERS contains invalid header field",
        H3ErrMessageError
      )
    case lower
    of "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding", "te":
      return protocolError(
        streamId,
        "HTTP/3 trailing HEADERS contains forbidden connection-specific header: " & lower,
        H3ErrMessageError
      )
    of "content-length":
      return protocolError(
        streamId,
        "HTTP/3 trailing HEADERS must not contain content-length",
        H3ErrMessageError
      )
    else:
      discard
  Http3Event(kind: h3evNone, streamId: streamId)

proc validatePushPromiseRequestHeaders(streamId: uint64,
                                       headers: openArray[QpackHeaderField]): Http3Event =
  var hasMethod = false
  var hasScheme = false
  var hasAuthority = false
  var hasPath = false
  var methodValue = ""
  var schemeValue = ""
  var authorityValue = ""
  var pathValue = ""
  var sawHostHeader = false
  var hostValue = ""
  var seenRegularHeader = false
  for (name, value) in headers:
    if name.len == 0:
      return protocolError(
        streamId,
        "HTTP/3 PUSH_PROMISE contains empty header name",
        H3ErrMessageError
      )
    if name.startsWith(":"):
      if seenRegularHeader:
        return protocolError(
          streamId,
          "HTTP/3 PUSH_PROMISE pseudo-headers must appear before regular headers",
          H3ErrMessageError
        )
      case name
      of ":method":
        if hasMethod:
          return protocolError(
            streamId,
            "HTTP/3 PUSH_PROMISE has duplicate :method pseudo-header",
            H3ErrMessageError
          )
        hasMethod = true
        methodValue = value
      of ":scheme":
        if hasScheme:
          return protocolError(
            streamId,
            "HTTP/3 PUSH_PROMISE has duplicate :scheme pseudo-header",
            H3ErrMessageError
          )
        hasScheme = true
        schemeValue = value
      of ":authority":
        if hasAuthority:
          return protocolError(
            streamId,
            "HTTP/3 PUSH_PROMISE has duplicate :authority pseudo-header",
            H3ErrMessageError
          )
        hasAuthority = true
        authorityValue = value
      of ":path":
        if hasPath:
          return protocolError(
            streamId,
            "HTTP/3 PUSH_PROMISE has duplicate :path pseudo-header",
            H3ErrMessageError
          )
        hasPath = true
        pathValue = value
      else:
        return protocolError(
          streamId,
          "HTTP/3 PUSH_PROMISE contains unsupported pseudo-header: " & name,
          H3ErrMessageError
        )
    else:
      seenRegularHeader = true
      let lower = name.toLowerAscii
      if name != lower:
        return protocolError(
          streamId,
          "HTTP/3 PUSH_PROMISE header names must be lowercase",
          H3ErrMessageError
        )
      if not isValidHeaderName(name) or not isValidHeaderValue(value):
        return protocolError(
          streamId,
          "HTTP/3 PUSH_PROMISE contains invalid header field",
          H3ErrMessageError
        )
      case lower
      of "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding":
        return protocolError(
          streamId,
          "HTTP/3 PUSH_PROMISE contains forbidden connection-specific header: " & lower,
          H3ErrMessageError
        )
      of "te":
        if value.toLowerAscii != "trailers":
          return protocolError(
            streamId,
            "HTTP/3 PUSH_PROMISE TE header must be \"trailers\"",
            H3ErrMessageError
          )
      of "host":
        if sawHostHeader:
          return protocolError(
            streamId,
            "HTTP/3 PUSH_PROMISE has duplicate host header field",
            H3ErrMessageError
          )
        sawHostHeader = true
        hostValue = value
      else:
        discard

  if not hasMethod:
    return protocolError(
      streamId,
      "HTTP/3 PUSH_PROMISE missing required :method pseudo-header",
      H3ErrMessageError
    )
  if methodValue.len == 0:
    return protocolError(
      streamId,
      "HTTP/3 PUSH_PROMISE has empty :method pseudo-header",
      H3ErrMessageError
    )
  if not isValidHeaderName(methodValue):
    return protocolError(
      streamId,
      "HTTP/3 PUSH_PROMISE has invalid :method pseudo-header token",
      H3ErrMessageError
    )
  if not hasScheme or schemeValue.len == 0:
    return protocolError(
      streamId,
      "HTTP/3 PUSH_PROMISE missing required :scheme pseudo-header",
      H3ErrMessageError
    )
  if schemeValue[0] notin Letters:
    return protocolError(
      streamId,
      "HTTP/3 PUSH_PROMISE has invalid :scheme pseudo-header",
      H3ErrMessageError
    )
  for i in 1 ..< schemeValue.len:
    let c = schemeValue[i]
    if c notin (Letters + Digits + {'+', '-', '.'}):
      return protocolError(
        streamId,
        "HTTP/3 PUSH_PROMISE has invalid :scheme pseudo-header",
        H3ErrMessageError
      )
  if not hasAuthority or authorityValue.len == 0:
    return protocolError(
      streamId,
      "HTTP/3 PUSH_PROMISE missing required :authority pseudo-header",
      H3ErrMessageError
    )
  if not hasPath or pathValue.len == 0:
    return protocolError(
      streamId,
      "HTTP/3 PUSH_PROMISE missing required :path pseudo-header",
      H3ErrMessageError
    )
  if sawHostHeader and authorityValue.toLowerAscii != hostValue.toLowerAscii:
    return protocolError(
      streamId,
      "HTTP/3 PUSH_PROMISE host header must match :authority pseudo-header",
      H3ErrMessageError
    )

  Http3Event(kind: h3evNone, streamId: streamId)

proc validatePushResponseInitialHeaders(streamId: uint64,
                                        headers: openArray[QpackHeaderField]): Http3Event =
  var seenRegular = false
  var sawStatus = false
  var parsedStatus = 0
  for (name, value) in headers:
    if name.startsWith(":"):
      if seenRegular:
        return protocolError(
          streamId,
          "HTTP/3 push response pseudo-headers must appear before regular headers",
          H3ErrMessageError
        )
      if name != ":status":
        return protocolError(
          streamId,
          "HTTP/3 push response contains unsupported pseudo-header: " & name,
          H3ErrMessageError
        )
      if sawStatus:
        return protocolError(
          streamId,
          "HTTP/3 push response has duplicate :status pseudo-header",
          H3ErrMessageError
        )
      if value.len != 3:
        return protocolError(
          streamId,
          "HTTP/3 push response has invalid :status pseudo-header",
          H3ErrMessageError
        )
      for ch in value:
        if ch notin Digits:
          return protocolError(
            streamId,
            "HTTP/3 push response has invalid :status pseudo-header",
            H3ErrMessageError
          )
      sawStatus = true
      parsedStatus =
        try:
          parseInt(value)
        except ValueError:
          return protocolError(
            streamId,
            "HTTP/3 push response has invalid :status pseudo-header",
            H3ErrMessageError
          )
    else:
      let lower = name.toLowerAscii
      if name != lower:
        return protocolError(
          streamId,
          "HTTP/3 push response header names must be lowercase",
          H3ErrMessageError
        )
      if not isValidHeaderName(name) or not isValidHeaderValue(value):
        return protocolError(
          streamId,
          "HTTP/3 push response contains invalid header field",
          H3ErrMessageError
        )
      case lower
      of "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding", "te":
        return protocolError(
          streamId,
          "HTTP/3 push response contains forbidden connection-specific header: " & lower,
          H3ErrMessageError
        )
      else:
        discard
      seenRegular = true

  if not sawStatus:
    return protocolError(
      streamId,
      "HTTP/3 push response missing required :status pseudo-header",
      H3ErrMessageError
    )
  if parsedStatus < 200 or parsedStatus > 999:
    return protocolError(
      streamId,
      "HTTP/3 push response has out-of-range :status pseudo-header",
      H3ErrMessageError
    )
  Http3Event(kind: h3evNone, streamId: streamId)

proc isInformationalResponseHeaders(headers: openArray[QpackHeaderField]): bool =
  for (name, value) in headers:
    if name != ":status":
      continue
    if value.len != 3:
      return false
    for ch in value:
      if ch notin Digits:
        return false
    let code =
      try:
        parseInt(value)
      except ValueError:
        return false
    return code >= 100 and code < 200
  false

proc setRequestStreamBuffer(conn: Http3Connection,
                            streamId: uint64,
                            buf: seq[byte]) =
  var oldLen = 0
  if streamId in conn.requestStreamBuffers:
    oldLen = conn.requestStreamBuffers[streamId].len
  conn.requestStreamBuffers[streamId] = buf
  conn.totalRequestStreamBufferedBytes += buf.len - oldLen
  if conn.totalRequestStreamBufferedBytes < 0:
    conn.totalRequestStreamBufferedBytes = 0

proc appendRequestStreamBuffer(conn: Http3Connection,
                               streamId: uint64,
                               payload: openArray[byte]): tuple[msg: string, code: uint64] =
  if payload.len == 0:
    return ("", H3ErrNoError)
  if streamId notin conn.requestStreamBuffers:
    conn.requestStreamBuffers[streamId] = @[]
  let current = conn.requestStreamBuffers[streamId].len
  if conn.maxRequestStreamBufferBytes > 0 and current + payload.len > conn.maxRequestStreamBufferBytes:
    return ("HTTP/3 request stream buffer limit exceeded", H3ErrExcessiveLoad)
  if conn.maxTotalRequestStreamBufferBytes > 0 and
      conn.totalRequestStreamBufferedBytes + payload.len > conn.maxTotalRequestStreamBufferBytes:
    return ("HTTP/3 total request stream buffering limit exceeded", H3ErrExcessiveLoad)
  conn.requestStreamBuffers[streamId].add payload
  conn.totalRequestStreamBufferedBytes += payload.len
  ("", H3ErrNoError)

proc setUniStreamBuffer(conn: Http3Connection,
                        streamId: uint64,
                        buf: seq[byte]) =
  var oldLen = 0
  if streamId in conn.uniStreamBuffers:
    oldLen = conn.uniStreamBuffers[streamId].len
  conn.uniStreamBuffers[streamId] = buf
  conn.totalUniStreamBufferedBytes += buf.len - oldLen
  if conn.totalUniStreamBufferedBytes < 0:
    conn.totalUniStreamBufferedBytes = 0

proc appendUniStreamBuffer(conn: Http3Connection,
                           streamId: uint64,
                           payload: openArray[byte]): tuple[msg: string, code: uint64] =
  if payload.len == 0:
    return ("", H3ErrNoError)
  if streamId notin conn.uniStreamBuffers:
    conn.uniStreamBuffers[streamId] = @[]
  let current = conn.uniStreamBuffers[streamId].len
  if conn.maxUniStreamBufferBytes > 0 and current + payload.len > conn.maxUniStreamBufferBytes:
    return ("HTTP/3 unidirectional stream buffer limit exceeded", H3ErrExcessiveLoad)
  if conn.maxTotalUniStreamBufferBytes > 0 and
      conn.totalUniStreamBufferedBytes + payload.len > conn.maxTotalUniStreamBufferBytes:
    return ("HTTP/3 total unidirectional stream buffering limit exceeded", H3ErrExcessiveLoad)
  conn.uniStreamBuffers[streamId].add payload
  conn.totalUniStreamBufferedBytes += payload.len
  ("", H3ErrNoError)

proc clearUniStreamState(conn: Http3Connection, streamId: uint64) =
  if streamId in conn.uniStreamBuffers:
    conn.totalUniStreamBufferedBytes -= conn.uniStreamBuffers[streamId].len
    if conn.totalUniStreamBufferedBytes < 0:
      conn.totalUniStreamBufferedBytes = 0
    conn.uniStreamBuffers.del(streamId)
  if streamId in conn.failedUniStreamErrorCodes:
    conn.failedUniStreamErrorCodes.del(streamId)
  if streamId in conn.failedUniStreamErrorMessages:
    conn.failedUniStreamErrorMessages.del(streamId)
  if streamId in conn.uniStreamTypes:
    conn.uniStreamTypes.del(streamId)
  if streamId in conn.pushStreamPushIds:
    let pushId = conn.pushStreamPushIds[streamId]
    conn.pushStreamPushIds.del(streamId)
    if pushId in conn.pushIdToPushStreamId and conn.pushIdToPushStreamId[pushId] == streamId:
      conn.pushIdToPushStreamId.del(pushId)
  if streamId in conn.pushStreamsEndedWhileQpackBlocked:
    conn.pushStreamsEndedWhileQpackBlocked.del(streamId)

proc queueQpackSectionAck(conn: Http3Connection, streamId: uint64) =
  if not conn.useRfcQpackWire:
    return
  if conn.qpackDecoder.requiredInsertCount == 0'u64:
    return
  conn.pendingQpackDecoderStreamData.add encodeDecoderInstruction(
    QpackDecoderInstruction(kind: qdikSectionAck, streamId: streamId)
  )

proc processFrame(conn: Http3Connection, streamRole: Http3StreamRole,
                  streamId: uint64,
                  f: Http3Frame,
                  allowRequestTunnelSideEffects: bool = true): Http3Event =
  if streamRole == h3srControl:
    if f.frameType == H3FrameData or f.frameType == H3FrameHeaders or
        f.frameType == H3FramePushPromise:
      return protocolError(
        streamId,
        "invalid frame type on HTTP/3 control stream: " & describeHttp3FrameType(f.frameType),
        H3ErrFrameUnexpected
      )
  elif streamRole in {h3srRequest, h3srPush}:
    if f.frameType == H3FrameSettings or f.frameType == H3FrameGoaway:
      return protocolError(streamId, "control frame on HTTP/3 request stream", H3ErrFrameUnexpected)

  case f.frameType
  of H3FrameSettings:
    result.kind = h3evSettings
    result.streamId = streamId
    try:
      result.settings = decodeSettingsPayloadStrict(f.payload)
    except ValueError as e:
      return protocolError(
        streamId,
        "invalid HTTP/3 SETTINGS payload: " &
          (if e.msg.len > 0: e.msg else: "decode failure"),
        H3ErrSettingsError
      )
    for (k, v) in result.settings:
      conn.peerSettings[k] = v
    conn.applyPeerQpackLimits()
    conn.peerSettingsReceived = true
    conn.controlState = h3csReady
  of H3FrameHeaders:
    result.kind = h3evHeaders
    result.streamId = streamId
    try:
      result.headers = conn.decodeHeadersFrame(f.payload)
    except ValueError as e:
      if e.msg.contains("required insert count not yet available"):
        return Http3Event(kind: h3evNone, streamId: streamId, errorMessage: "qpack_blocked")
      return protocolError(streamId, "QPACK header decode failure", QpackErrDecompressionFailed)
    let sectionSizeErr = validateFieldSectionSize(conn, streamId, result.headers, "HEADERS")
    if sectionSizeErr.kind == h3evProtocolError:
      return sectionSizeErr
    conn.queueQpackSectionAck(streamId)
    if streamRole == h3srRequest and not conn.isClient and allowRequestTunnelSideEffects:
      if isWebTransportConnectRequest(result.headers):
        let req = parseWebTransportConnectHeaders(result.headers)
        if streamId notin conn.webTransportSessions:
          let wtSession =
            if conn.isClient:
              openWebTransportSession(sessionId = streamId, authority = req.authority, path = req.path, origin = req.origin)
            else:
              acceptWebTransportSession(sessionId = streamId, authority = req.authority, path = req.path, origin = req.origin)
          conn.webTransportSessions[streamId] = wtSession
      elif isMasqueConnectRequest(result.headers):
        let req = parseMasqueConnectRequest(result.headers)
        if streamId notin conn.masqueSessions:
          let mSession =
            if req.mode == mmConnectIp:
              connectIp(req.authority, req.target)
            else:
              connectUdp(req.authority, req.target)
          conn.masqueSessions[streamId] = mSession
  of H3FrameData:
    result.kind = h3evData
    result.streamId = streamId
    result.data = f.payload
  of H3FrameGoaway:
    result.kind = h3evGoaway
    result.streamId = streamId
    var off = 0
    try:
      result.goawayId = decodeQuicVarInt(f.payload, off)
    except ValueError:
      return protocolError(streamId, "malformed GOAWAY payload", H3ErrFrameError)
    if off != f.payload.len:
      return protocolError(streamId, "malformed GOAWAY payload", H3ErrFrameError)
    if conn.isClient:
      # Server GOAWAY carries a client-initiated bidirectional request stream ID.
      if (result.goawayId and 0x03'u64) != 0'u64:
        return protocolError(
          streamId,
          "GOAWAY ID does not identify a valid peer request stream ID",
          H3ErrIdError
        )
    else:
      # Client GOAWAY carries a Push ID (not a request stream ID).
      discard
    if conn.hasPeerGoaway and result.goawayId > conn.peerGoawayId:
      return protocolError(
        streamId,
        "GOAWAY ID increased; peer GOAWAY must be non-increasing",
        H3ErrIdError
      )
    conn.controlState = h3csClosing
    conn.peerGoawayId = result.goawayId
    conn.hasPeerGoaway = true
  of H3FramePushPromise:
    if streamRole != h3srRequest:
      return protocolError(
        streamId,
        "PUSH_PROMISE frame is only valid on request streams",
        H3ErrFrameUnexpected
      )
    if not conn.isClient:
      return protocolError(
        streamId,
        "PUSH_PROMISE frame is invalid from a client peer",
        H3ErrFrameUnexpected
      )
    var off = 0
    let pushId =
      try:
        decodeQuicVarInt(f.payload, off)
      except ValueError:
        return protocolError(streamId, "malformed PUSH_PROMISE payload", H3ErrFrameError)
    let headerBlock = if off < f.payload.len: f.payload[off .. ^1] else: @[]
    if not conn.hasAdvertisedMaxPushId:
      return protocolError(
        streamId,
        "PUSH_PROMISE received before client advertised MAX_PUSH_ID",
        H3ErrIdError
      )
    if pushId > conn.maxPushIdAdvertised:
      return protocolError(
        streamId,
        "PUSH_PROMISE push ID exceeds advertised MAX_PUSH_ID",
        H3ErrIdError
      )
    if pushId in conn.cancelledPushIds:
      return Http3Event(kind: h3evNone, streamId: streamId, pushId: pushId)
    if pushId in conn.pushPromiseIdsUsed:
      return protocolError(streamId, "duplicate PUSH_PROMISE push ID", H3ErrIdError)
    result.kind = h3evPushPromise
    result.streamId = streamId
    result.pushId = pushId
    try:
      result.pushHeaders = conn.decodeHeadersFrame(headerBlock)
    except ValueError as e:
      if e.msg.contains("required insert count not yet available"):
        return Http3Event(kind: h3evNone, streamId: streamId, errorMessage: "qpack_blocked")
      return protocolError(streamId, "QPACK decode failure on PUSH_PROMISE", QpackErrDecompressionFailed)
    let sectionSizeErr = validateFieldSectionSize(conn, streamId, result.pushHeaders, "PUSH_PROMISE")
    if sectionSizeErr.kind == h3evProtocolError:
      return sectionSizeErr
    let headerValidationErr = validatePushPromiseRequestHeaders(streamId, result.pushHeaders)
    if headerValidationErr.kind == h3evProtocolError:
      return headerValidationErr
    conn.queueQpackSectionAck(streamId)
    conn.pushPromiseIdsUsed[pushId] = true
    conn.pushPromises[pushId] = result.pushHeaders
  of H3FrameCancelPush:
    if streamRole != h3srControl:
      return protocolError(streamId, "CANCEL_PUSH frame is only valid on control stream", H3ErrFrameUnexpected)
    if conn.isClient:
      return protocolError(streamId, "CANCEL_PUSH frame is invalid from a server peer", H3ErrFrameUnexpected)
    var off = 0
    let pushId =
      try:
        decodeQuicVarInt(f.payload, off)
      except ValueError:
        return protocolError(streamId, "malformed CANCEL_PUSH payload", H3ErrFrameError)
    if off != f.payload.len:
      return protocolError(streamId, "malformed CANCEL_PUSH payload", H3ErrFrameError)
    result.kind = h3evCancelPush
    result.streamId = streamId
    result.pushId = pushId
    conn.cancelledPushIds[pushId] = true
    if pushId in conn.pushIdToPushStreamId:
      let pushStreamId = conn.pushIdToPushStreamId[pushId]
      conn.clearRequestStreamState(pushStreamId)
      conn.clearUniStreamState(pushStreamId)
  of H3FrameMaxPushId:
    if streamRole != h3srControl:
      return protocolError(streamId, "MAX_PUSH_ID frame is only valid on control stream", H3ErrFrameUnexpected)
    if conn.isClient:
      return protocolError(streamId, "MAX_PUSH_ID frame is invalid from a server peer", H3ErrFrameUnexpected)
    var off = 0
    let pushId =
      try:
        decodeQuicVarInt(f.payload, off)
      except ValueError:
        return protocolError(streamId, "malformed MAX_PUSH_ID payload", H3ErrFrameError)
    if off != f.payload.len:
      return protocolError(streamId, "malformed MAX_PUSH_ID payload", H3ErrFrameError)
    if pushId < conn.maxPushIdReceived:
      return protocolError(
        streamId,
        "MAX_PUSH_ID cannot decrease",
        H3ErrIdError
      )
    result.kind = h3evMaxPushId
    result.streamId = streamId
    result.pushId = pushId
    conn.maxPushIdReceived = pushId
    conn.hasPeerMaxPushId = true
  else:
    result.kind = h3evNone

proc processControlStreamBuffer(conn: Http3Connection,
                                streamId: uint64,
                                buffer: var seq[byte]): seq[Http3Event] =
  if conn.peerControlStreamFailed:
    buffer.setLen(0)
    return @[conn.controlStreamFatalEvent(streamId)]
  var off = 0
  while off < buffer.len:
    var frameOff = off
    let f =
      try:
        decodeHttp3Frame(buffer, frameOff)
      except ValueError as e:
        if isLikelyIncompleteFrameError(e.msg):
          # Partial frame; keep unread bytes for future stream data.
          break
        result.add conn.markPeerControlStreamFatal(
          streamId,
          "malformed HTTP/3 control frame: " &
            (if e.msg.len > 0: e.msg else: "decode failure"),
          H3ErrFrameError
        )
        off = buffer.len
        break
    off = frameOff
    if not conn.peerSettingsReceived and f.frameType != H3FrameSettings:
      result.add conn.markPeerControlStreamFatal(
        streamId,
        "SETTINGS must be the first frame on control stream",
        H3ErrMissingSettings
      )
      off = buffer.len
      break
    if conn.peerSettingsReceived and f.frameType == H3FrameSettings:
      result.add conn.markPeerControlStreamFatal(
        streamId,
        "duplicate SETTINGS frame on control stream",
        H3ErrFrameUnexpected
      )
      off = buffer.len
      break
    let ev = conn.processFrame(h3srControl, streamId, f)
    if ev.kind == h3evProtocolError:
      result.add conn.markPeerControlStreamFatal(streamId, ev.errorMessage, ev.errorCode)
      off = buffer.len
      break
    if ev.kind != h3evNone:
      result.add ev
  if off <= 0:
    return
  if off >= buffer.len:
    buffer.setLen(0)
  else:
    buffer = buffer[off .. ^1]

proc processControlStreamData*(conn: Http3Connection,
                               streamId: uint64,
                               payload: openArray[byte]): seq[Http3Event] =
  if streamId in conn.failedUniStreamErrorCodes:
    return @[conn.uniStreamFatalEvent(streamId)]
  if streamId notin conn.uniStreamBuffers:
    conn.setUniStreamBuffer(streamId, @[])
  let appendErr = conn.appendUniStreamBuffer(streamId, payload)
  if appendErr.msg.len > 0:
    conn.setUniStreamBuffer(streamId, @[])
    return @[conn.markUniStreamFatal(streamId, appendErr.msg, appendErr.code)]
  var buf = conn.uniStreamBuffers[streamId]
  result = conn.processControlStreamBuffer(streamId, buf)
  conn.setUniStreamBuffer(streamId, buf)

proc processRequestStreamData*(conn: Http3Connection,
                               streamId: uint64,
                               payload: openArray[byte],
                               allowInformationalHeaders: bool = false,
                               streamRole: Http3StreamRole = h3srRequest): seq[Http3Event] =
  if streamId in conn.failedRequestStreamErrorCodes:
    return @[conn.requestStreamFatalEvent(streamId)]
  if streamId notin conn.requestStreamBuffers:
    conn.setRequestStreamBuffer(streamId, @[])
  let appendErr = conn.appendRequestStreamBuffer(streamId, payload)
  if appendErr.msg.len > 0:
    return @[conn.markRequestStreamFatal(streamId, appendErr.msg, appendErr.code)]
  if streamId in conn.qpackBlockedRequestStreams:
    let lastAttemptEpoch =
      if streamId in conn.qpackBlockedRequestStreamEpochs:
        conn.qpackBlockedRequestStreamEpochs[streamId]
      else:
        0'u64
    if conn.qpackEncoderInstructionEpoch <= lastAttemptEpoch:
      return @[Http3Event(kind: h3evNone, streamId: streamId, errorMessage: "qpack_blocked")]
  var streamBuf = conn.requestStreamBuffers[streamId]

  var st = if streamId in conn.requestStates: conn.requestStates[streamId] else: Http3RequestStreamState()
  var off = 0
  while off < streamBuf.len:
    let frameStart = off
    let f =
      try:
        var frameOff = off
        let frame = decodeHttp3Frame(streamBuf, frameOff)
        off = frameOff
        frame
      except ValueError as e:
        if isLikelyIncompleteFrameError(e.msg):
          # Request stream data may arrive fragmented across datagrams; keep
          # partial bytes and continue when more stream data is received.
          break
        result.add conn.markRequestStreamFatal(
          streamId,
          "malformed HTTP/3 request frame: " &
            (if e.msg.len > 0: e.msg else: "decode failure"),
          H3ErrFrameError
        )
        off = streamBuf.len
        break

    let stBefore = st
    if f.frameType == H3FrameHeaders:
      if not st.sawInitialHeaders:
        st.sawInitialHeaders = true
        if not allowInformationalHeaders or streamRole != h3srRequest:
          st.sawFinalHeaders = true
      elif st.sawTrailers:
        result.add conn.markRequestStreamFatal(streamId, "duplicate trailer HEADERS frame", H3ErrFrameUnexpected)
        off = streamBuf.len
        break
      elif st.sawData:
        st.sawTrailers = true
      elif allowInformationalHeaders and streamRole == h3srRequest and not st.sawFinalHeaders:
        # Client response streams can carry one or more informational header
        # sections before the final response headers.
        discard
      else:
        # Request/push streams can carry trailers even when DATA frame count is
        # zero (HEADERS followed directly by trailing HEADERS).
        st.sawTrailers = true
    elif f.frameType == H3FrameData:
      if not st.sawInitialHeaders:
        result.add conn.markRequestStreamFatal(streamId, "DATA before initial HEADERS", H3ErrFrameUnexpected)
        off = streamBuf.len
        break
      if allowInformationalHeaders and streamRole == h3srRequest and not st.sawFinalHeaders:
        result.add conn.markRequestStreamFatal(streamId, "DATA before final HEADERS", H3ErrFrameUnexpected)
        off = streamBuf.len
        break
      if st.sawTrailers:
        result.add conn.markRequestStreamFatal(streamId, "DATA after trailing HEADERS", H3ErrFrameUnexpected)
        off = streamBuf.len
        break
      st.sawData = true
    elif f.frameType == H3FramePushPromise:
      if streamRole != h3srRequest:
        result.add conn.markRequestStreamFatal(streamId, "PUSH_PROMISE frame is only valid on request streams", H3ErrFrameUnexpected)
        off = streamBuf.len
        break
      if not st.sawInitialHeaders:
        result.add conn.markRequestStreamFatal(streamId, "PUSH_PROMISE before initial HEADERS", H3ErrFrameUnexpected)
        off = streamBuf.len
        break
      if st.sawTrailers:
        result.add conn.markRequestStreamFatal(streamId, "PUSH_PROMISE after trailing HEADERS", H3ErrFrameUnexpected)
        off = streamBuf.len
        break

    let allowRequestTunnelSideEffects = not (
      f.frameType == H3FrameHeaders and
      streamRole == h3srRequest and
      not conn.isClient and
      stBefore.sawInitialHeaders
    )
    let wasBlockedBeforeFrame = streamId in conn.qpackBlockedRequestStreams
    let wasCountedBeforeFrame =
      wasBlockedBeforeFrame and
      streamId in conn.qpackBlockedRequestStreamCounted and
      conn.qpackBlockedRequestStreamCounted[streamId]
    let decoderBlockedBeforeFrame = conn.qpackDecoder.blockedStreams
    var ev = conn.processFrame(
      streamRole,
      streamId,
      f,
      allowRequestTunnelSideEffects = allowRequestTunnelSideEffects
    )
    if streamRole == h3srPush and streamId in conn.pushStreamPushIds:
      ev.pushId = conn.pushStreamPushIds[streamId]
    if conn.qpackDecoder.blockedStreams < decoderBlockedBeforeFrame:
      if wasBlockedBeforeFrame and not wasCountedBeforeFrame:
        # QPACK decoder blocked-stream tracking is stream-agnostic. If this
        # stream never owned a blocked slot, a successful replay must not
        # decrement the global blocked-stream count that belongs to other
        # streams.
        conn.qpackDecoder.markBlocked()
      elif not wasBlockedBeforeFrame and conn.qpackBlockedRequestStreams.len > 0:
        # A successful decode on an unrelated stream must not consume blocked
        # capacity owned by other streams that are still waiting on QPACK.
        conn.qpackDecoder.markBlocked()
    if ev.kind == h3evNone and ev.errorMessage == "qpack_blocked":
      # Header block depends on dynamic-table entries that are not available yet.
      # Keep this frame buffered and retry after more QPACK encoder instructions.
      let blockedIncremented = conn.qpackDecoder.blockedStreams > decoderBlockedBeforeFrame
      var countedNow = wasCountedBeforeFrame
      if blockedIncremented:
        if wasCountedBeforeFrame:
          # Retries of a stream that already owns a blocked slot must not
          # consume additional decoder blocked-stream capacity.
          conn.qpackDecoder.markUnblocked()
        else:
          # Streams that were previously uncounted because the decoder limit was
          # saturated can claim a slot if capacity becomes available later.
          countedNow = true
      if not wasBlockedBeforeFrame:
        countedNow = blockedIncremented
      conn.qpackBlockedRequestStreams[streamId] = true
      conn.qpackBlockedRequestStreamCounted[streamId] = countedNow
      conn.qpackBlockedRequestStreamEpochs[streamId] = conn.qpackEncoderInstructionEpoch
      st = stBefore
      off = frameStart
      result.add ev
      break
    if ev.kind == h3evProtocolError:
      # Treat request-stream protocol violations as fatal for this stream parse
      # pass and stop processing additional frames in this buffered chunk.
      result.add conn.markRequestStreamFatal(streamId, ev.errorMessage, ev.errorCode)
      off = streamBuf.len
      break
    if ev.kind == h3evHeaders and allowInformationalHeaders and streamRole == h3srRequest and
        not stBefore.sawFinalHeaders:
      if not isInformationalResponseHeaders(ev.headers):
        st.sawFinalHeaders = true
    if ev.kind == h3evHeaders and not allowInformationalHeaders and stBefore.sawInitialHeaders:
      let trailerErr = validateTrailingHeadersSection(streamId, ev.headers)
      if trailerErr.kind == h3evProtocolError:
        result.add conn.markRequestStreamFatal(streamId, trailerErr.errorMessage, trailerErr.errorCode)
        off = streamBuf.len
        break
    if ev.kind == h3evHeaders and streamRole == h3srPush and not stBefore.sawInitialHeaders:
      let pushRespErr = validatePushResponseInitialHeaders(streamId, ev.headers)
      if pushRespErr.kind == h3evProtocolError:
        result.add conn.markRequestStreamFatal(streamId, pushRespErr.errorMessage, pushRespErr.errorCode)
        off = streamBuf.len
        break
    if ev.kind == h3evHeaders or ev.kind == h3evPushPromise:
      if streamId in conn.qpackBlockedRequestStreams:
        conn.qpackBlockedRequestStreams.del(streamId)
      if streamId in conn.qpackBlockedRequestStreamCounted:
        conn.qpackBlockedRequestStreamCounted.del(streamId)
      if streamId in conn.qpackBlockedRequestStreamEpochs:
        conn.qpackBlockedRequestStreamEpochs.del(streamId)
    if ev.kind != h3evNone:
      result.add ev
  conn.requestStates[streamId] = st
  if off <= 0:
    conn.setRequestStreamBuffer(streamId, streamBuf)
  elif off >= streamBuf.len:
    conn.setRequestStreamBuffer(streamId, @[])
  else:
    conn.setRequestStreamBuffer(streamId, streamBuf[off .. ^1])

  # A push stream that ended while QPACK-blocked should be cleaned up
  # automatically once replay succeeds (or fails fatally) after decoder updates.
  if streamRole == h3srPush and
      streamId in conn.pushStreamsEndedWhileQpackBlocked and
      streamId notin conn.qpackBlockedRequestStreams:
    if streamId in conn.requestStreamBuffers and conn.requestStreamBuffers[streamId].len > 0:
      result.add protocolError(
        streamId,
        "HTTP/3 request stream ended with incomplete frame payload",
        H3ErrFrameError
      )
    conn.clearRequestStreamState(streamId)
    conn.clearUniStreamState(streamId)

proc clearRequestStreamState*(conn: Http3Connection, streamId: uint64) =
  if streamId in conn.qpackBlockedRequestStreams:
    let wasCounted =
      streamId in conn.qpackBlockedRequestStreamCounted and
      conn.qpackBlockedRequestStreamCounted[streamId]
    conn.qpackBlockedRequestStreams.del(streamId)
    if wasCounted and conn.qpackDecoder.blockedStreams > 0:
      conn.qpackDecoder.markUnblocked()
    if conn.useRfcQpackWire:
      conn.pendingQpackDecoderStreamData.add encodeDecoderInstruction(
        QpackDecoderInstruction(kind: qdikStreamCancel, cancelStreamId: streamId)
      )
  if streamId in conn.qpackBlockedRequestStreamCounted:
    conn.qpackBlockedRequestStreamCounted.del(streamId)
  if streamId in conn.qpackBlockedRequestStreamEpochs:
    conn.qpackBlockedRequestStreamEpochs.del(streamId)
  if streamId in conn.requestStates:
    conn.requestStates.del(streamId)
  if streamId in conn.failedRequestStreamErrorCodes:
    conn.failedRequestStreamErrorCodes.del(streamId)
  if streamId in conn.failedRequestStreamErrorMessages:
    conn.failedRequestStreamErrorMessages.del(streamId)
  if streamId in conn.pushStreamPushIds:
    let pushId = conn.pushStreamPushIds[streamId]
    conn.pushStreamPushIds.del(streamId)
    if pushId in conn.pushIdToPushStreamId and conn.pushIdToPushStreamId[pushId] == streamId:
      conn.pushIdToPushStreamId.del(pushId)
  if streamId in conn.requestStreamBuffers:
    conn.totalRequestStreamBufferedBytes -= conn.requestStreamBuffers[streamId].len
    if conn.totalRequestStreamBufferedBytes < 0:
      conn.totalRequestStreamBufferedBytes = 0
    conn.requestStreamBuffers.del(streamId)
  if streamId in conn.pushStreamsEndedWhileQpackBlocked:
    conn.pushStreamsEndedWhileQpackBlocked.del(streamId)

proc finalizeRequestStream*(conn: Http3Connection, streamId: uint64): seq[Http3Event] =
  ## Apply end-of-stream validation for request/push stream payload parsing.
  result = conn.processRequestStreamData(
    streamId,
    @[],
    allowInformationalHeaders = false,
    streamRole = h3srRequest
  )
  if streamId in conn.qpackBlockedRequestStreams:
    return
  if streamId in conn.requestStreamBuffers and conn.requestStreamBuffers[streamId].len > 0:
    result.add protocolError(
      streamId,
      "HTTP/3 request stream ended with incomplete frame payload",
      H3ErrFrameError
    )

proc ingestUniStreamData*(conn: Http3Connection,
                          streamId: uint64,
                          payload: openArray[byte]): seq[Http3Event]

proc finalizeRequestStream*(conn: Http3Connection,
                            streamId: uint64,
                            allowInformationalHeaders: bool,
                            streamRole: Http3StreamRole = h3srRequest): seq[Http3Event] =
  ## Apply end-of-stream validation for request/push stream payload parsing.
  result = conn.processRequestStreamData(
    streamId,
    @[],
    allowInformationalHeaders = allowInformationalHeaders,
    streamRole = streamRole
  )
  if streamId in conn.qpackBlockedRequestStreams:
    return
  if streamId in conn.requestStreamBuffers and conn.requestStreamBuffers[streamId].len > 0:
    result.add protocolError(
      streamId,
      "HTTP/3 request stream ended with incomplete frame payload",
      H3ErrFrameError
    )

proc finalizeUniStream*(conn: Http3Connection, streamId: uint64): seq[Http3Event] =
  ## Apply end-of-stream validation for unidirectional stream roles.
  result = conn.ingestUniStreamData(streamId, @[])
  if streamId notin conn.uniStreamTypes:
    result.add protocolError(
      streamId,
      "HTTP/3 unidirectional stream ended before full stream preface/frame",
      H3ErrFrameError
    )
    conn.clearUniStreamState(streamId)
    return

  let role = conn.uniStreamTypes[streamId]
  var clearUniState = true
  case role
  of h3srControl:
    result.add protocolError(streamId, "HTTP/3 peer closed control stream", H3ErrClosedCriticalStream)
  of h3srQpackEncoder:
    result.add protocolError(streamId, "HTTP/3 peer closed QPACK encoder stream", H3ErrClosedCriticalStream)
  of h3srQpackDecoder:
    result.add protocolError(streamId, "HTTP/3 peer closed QPACK decoder stream", H3ErrClosedCriticalStream)
  of h3srPush:
    if streamId notin conn.qpackBlockedRequestStreams:
      let finEvents = conn.finalizeRequestStream(
        streamId,
        allowInformationalHeaders = false,
        streamRole = h3srPush
      )
      if finEvents.len > 0:
        result.add finEvents
    if streamId in conn.qpackBlockedRequestStreams:
      # Keep blocked push-stream bytes/state so decoder can retry after peer
      # QPACK encoder-stream updates even after stream FIN.
      clearUniState = false
      conn.pushStreamsEndedWhileQpackBlocked[streamId] = true
    else:
      conn.clearRequestStreamState(streamId)
  else:
    discard

  if clearUniState:
    conn.clearUniStreamState(streamId)

proc requestStreamBufferedBytes*(conn: Http3Connection, streamId: uint64): int =
  if streamId in conn.requestStreamBuffers:
    return conn.requestStreamBuffers[streamId].len
  0

proc totalRequestBufferedBytes*(conn: Http3Connection): int =
  if conn.isNil:
    return 0
  conn.totalRequestStreamBufferedBytes

proc totalUniBufferedBytes*(conn: Http3Connection): int =
  if conn.isNil:
    return 0
  conn.totalUniStreamBufferedBytes

proc isLikelyIncompleteQpackInstruction(msg: string): bool =
  let m = msg.toLowerAscii
  m.contains("truncated")

proc drainQpackEncoderInstructions(conn: Http3Connection,
                                   buf: var seq[byte]): string =
  var off = 0
  while off < buf.len:
    var next = off
    try:
      let inst = decodeEncoderInstructionPrefix(buf, next)
      conn.qpackDecoder.applyEncoderInstruction(inst)
      off = next
    except ValueError as e:
      if isLikelyIncompleteQpackInstruction(e.msg):
        break
      return if e.msg.len > 0: e.msg else: "malformed QPACK encoder instruction"
  if off <= 0:
    return ""
  inc conn.qpackEncoderInstructionEpoch
  if off >= buf.len:
    buf.setLen(0)
  else:
    buf = buf[off .. ^1]
  if conn.qpackDecoder.knownInsertCount > conn.advertisedDecoderInsertCount:
    let delta = conn.qpackDecoder.knownInsertCount - conn.advertisedDecoderInsertCount
    conn.pendingQpackDecoderStreamData.add encodeDecoderInstruction(
      QpackDecoderInstruction(
        kind: qdikInsertCountIncrement,
        insertCountDelta: delta
      )
    )
    conn.advertisedDecoderInsertCount = conn.qpackDecoder.knownInsertCount
  ""

proc drainQpackDecoderInstructions(conn: Http3Connection,
                                   buf: var seq[byte]): string =
  var off = 0
  while off < buf.len:
    var next = off
    try:
      let inst = decodeDecoderInstructionPrefix(buf, next)
      conn.qpackEncoder.applyDecoderInstruction(inst)
      off = next
    except ValueError as e:
      if isLikelyIncompleteQpackInstruction(e.msg):
        break
      return if e.msg.len > 0: e.msg else: "malformed QPACK decoder instruction"
  if off <= 0:
    return ""
  if off >= buf.len:
    buf.setLen(0)
  else:
    buf = buf[off .. ^1]
  ""

proc ingestUniStreamData*(conn: Http3Connection,
                          streamId: uint64,
                          payload: openArray[byte]): seq[Http3Event] =
  if streamId in conn.failedUniStreamErrorCodes:
    if streamId in conn.uniStreamBuffers:
      conn.setUniStreamBuffer(streamId, @[])
    return @[conn.uniStreamFatalEvent(streamId)]
  if streamId notin conn.uniStreamBuffers:
    conn.setUniStreamBuffer(streamId, @[])
  let appendErr = conn.appendUniStreamBuffer(streamId, payload)
  if appendErr.msg.len > 0:
    conn.setUniStreamBuffer(streamId, @[])
    return @[conn.markUniStreamFatal(streamId, appendErr.msg, appendErr.code)]
  var buf = conn.uniStreamBuffers[streamId]

  var role: Http3StreamRole
  if streamId in conn.uniStreamTypes:
    role = conn.uniStreamTypes[streamId]
  else:
    var off = 0
    try:
      role = parseUniStreamType(buf, off)
    except ValueError:
      return @[]
    case role
    of h3srControl:
      if conn.peerControlStreamId >= 0 and uint64(conn.peerControlStreamId) != streamId:
        conn.setUniStreamBuffer(streamId, @[])
        return @[conn.markPeerControlStreamFatal(streamId, "duplicate peer control stream", H3ErrStreamCreation)]
      conn.peerControlStreamId = int64(streamId)
    of h3srQpackEncoder:
      if conn.peerQpackEncoderStreamId >= 0 and uint64(conn.peerQpackEncoderStreamId) != streamId:
        conn.setUniStreamBuffer(streamId, @[])
        return @[conn.markPeerQpackEncoderStreamFatal(streamId, "duplicate peer QPACK encoder stream", H3ErrStreamCreation)]
      conn.peerQpackEncoderStreamId = int64(streamId)
    of h3srQpackDecoder:
      if conn.peerQpackDecoderStreamId >= 0 and uint64(conn.peerQpackDecoderStreamId) != streamId:
        conn.setUniStreamBuffer(streamId, @[])
        return @[conn.markPeerQpackDecoderStreamFatal(streamId, "duplicate peer QPACK decoder stream", H3ErrStreamCreation)]
      conn.peerQpackDecoderStreamId = int64(streamId)
    else:
      discard
    conn.uniStreamTypes[streamId] = role
    if off > 0:
      buf = if off < buf.len: buf[off .. ^1] else: @[]

  var clearBuffer = true
  case role
  of h3srControl:
    result = conn.processControlStreamBuffer(streamId, buf)
    clearBuffer = false
  of h3srQpackEncoder:
    if conn.peerQpackEncoderStreamFailed:
      conn.setUniStreamBuffer(streamId, @[])
      return @[conn.qpackEncoderStreamFatalEvent(streamId)]
    let err = conn.drainQpackEncoderInstructions(buf)
    if err.len > 0:
      clearBuffer = true
      result = @[conn.markPeerQpackEncoderStreamFatal(
        streamId,
        "QPACK encoder stream error: " & err,
        QpackErrEncoderStream
      )]
    else:
      clearBuffer = false
      result = @[]
  of h3srQpackDecoder:
    if conn.peerQpackDecoderStreamFailed:
      conn.setUniStreamBuffer(streamId, @[])
      return @[conn.qpackDecoderStreamFatalEvent(streamId)]
    let err = conn.drainQpackDecoderInstructions(buf)
    if err.len > 0:
      clearBuffer = true
      result = @[conn.markPeerQpackDecoderStreamFatal(
        streamId,
        "QPACK decoder stream error: " & err,
        QpackErrDecoderStream
      )]
    else:
      clearBuffer = false
      result = @[]
  of h3srPush:
    if not conn.isClient:
      conn.clearUniStreamState(streamId)
      return @[protocolError(streamId, "push stream is invalid for server role", H3ErrStreamCreation)]
    var pushId = 0'u64
    var payload: seq[byte] = @[]
    if streamId in conn.pushStreamPushIds:
      pushId = conn.pushStreamPushIds[streamId]
      payload = buf
    else:
      var off = 0
      try:
        pushId = decodeQuicVarInt(buf, off)
      except ValueError:
        # Keep parsed stream-type removal persisted so subsequent fragments parse
        # PUSH_ID from the correct byte boundary.
        conn.setUniStreamBuffer(streamId, buf)
        return @[]
      if not conn.hasAdvertisedMaxPushId:
        conn.clearUniStreamState(streamId)
        return @[protocolError(streamId, "push stream received before client advertised MAX_PUSH_ID", H3ErrIdError)]
      if pushId > conn.maxPushIdAdvertised:
        conn.clearUniStreamState(streamId)
        return @[protocolError(streamId, "push stream push ID exceeds advertised MAX_PUSH_ID", H3ErrIdError)]
      if pushId in conn.cancelledPushIds:
        conn.clearRequestStreamState(streamId)
        conn.clearUniStreamState(streamId)
        return @[]
      if pushId in conn.pushIdToPushStreamId and conn.pushIdToPushStreamId[pushId] != streamId:
        conn.clearUniStreamState(streamId)
        return @[protocolError(streamId, "duplicate push stream for PUSH_ID", H3ErrIdError)]
      conn.pushStreamPushIds[streamId] = pushId
      conn.pushIdToPushStreamId[pushId] = streamId
      payload = if off < buf.len: buf[off .. ^1] else: @[]
    if not conn.hasAdvertisedMaxPushId:
      conn.clearUniStreamState(streamId)
      return @[protocolError(streamId, "push stream received before client advertised MAX_PUSH_ID", H3ErrIdError)]
    if pushId > conn.maxPushIdAdvertised:
      conn.clearUniStreamState(streamId)
      return @[protocolError(streamId, "push stream push ID exceeds advertised MAX_PUSH_ID", H3ErrIdError)]
    if pushId in conn.cancelledPushIds:
      conn.clearRequestStreamState(streamId)
      conn.clearUniStreamState(streamId)
      return @[]
    result = conn.processRequestStreamData(
      streamId,
      payload,
      streamRole = h3srPush
    )
    for i in 0 ..< result.len:
      result[i].pushId = pushId
    clearBuffer = true
    if payload.len == 0 and pushId notin conn.pushPromises:
      conn.pushPromises[pushId] = @[]
  else:
    # RFC 9114: Unknown unidirectional stream types are permitted and should be
    # ignored/discarded by endpoints.
    result = @[]

  if clearBuffer:
    conn.setUniStreamBuffer(streamId, @[])
  else:
    conn.setUniStreamBuffer(streamId, buf)

proc encodeH3DatagramForWebTransport*(conn: Http3Connection,
                                      sessionStreamId: uint64,
                                      payload: openArray[byte]): seq[byte] =
  discard conn
  encodeWebTransportDatagram(sessionStreamId, payload)

proc encodeH3DatagramForMasque*(conn: Http3Connection,
                                streamId: uint64,
                                contextId: uint64,
                                payload: openArray[byte]): seq[byte] =
  discard conn
  result = @[]
  result.appendQuicVarInt(streamId)
  result.add encodeMasqueDatagramWire(contextId, payload)

proc ingestH3Datagram*(conn: Http3Connection, payload: openArray[byte]): bool =
  if conn.isNil or payload.len == 0:
    return false
  if not conn.canSendH3Datagrams():
    return false
  var off = 0
  let streamId =
    try:
      decodeQuicVarInt(payload, off)
    except ValueError:
      return false
  if streamId in conn.webTransportSessions:
    let data = if off < payload.len: payload[off .. ^1] else: @[]
    conn.webTransportSessions[streamId].ingestDatagram(data)
    return true
  if streamId in conn.masqueSessions:
    if off >= payload.len:
      return false
    let dg =
      try:
        decodeMasqueDatagramWire(payload[off .. ^1])
      except ValueError:
        return false
    conn.masqueSessions[streamId].ingestDatagram(dg.contextId, dg.payload)
    return true
  false

proc hasMasqueSession*(conn: Http3Connection, streamId: uint64): bool =
  if conn.isNil:
    return false
  streamId in conn.masqueSessions

proc hasWebTransportSession*(conn: Http3Connection, streamId: uint64): bool =
  if conn.isNil:
    return false
  streamId in conn.webTransportSessions

proc ingestMasqueCapsuleData*(conn: Http3Connection,
                              streamId: uint64,
                              payload: openArray[byte]): bool =
  if conn.isNil or streamId notin conn.masqueSessions:
    return false
  if streamId notin conn.masqueCapsuleBuffers:
    conn.masqueCapsuleBuffers[streamId] = @[]
  if payload.len > 0:
    if conn.maxMasqueCapsuleBufferBytes > 0 and
        conn.masqueCapsuleBuffers[streamId].len + payload.len > conn.maxMasqueCapsuleBufferBytes:
      raise newException(ValueError, "MASQUE capsule buffer limit exceeded")
    conn.masqueCapsuleBuffers[streamId].add payload

  var buf = conn.masqueCapsuleBuffers[streamId]
  var off = 0
  while off < buf.len:
    var next = off
    try:
      let capsule = decodeCapsuleWire(buf, next)
      conn.masqueSessions[streamId].ingestCapsule(capsule.capsuleType, capsule.payload)
      off = next
    except ValueError as e:
      if e.msg.toLowerAscii.contains("truncated"):
        break
      raise

  if off > 0:
    if off >= buf.len:
      buf.setLen(0)
    else:
      buf = buf[off .. ^1]
  conn.masqueCapsuleBuffers[streamId] = buf
  true

proc clearMasqueSessionState*(conn: Http3Connection, streamId: uint64) =
  if conn.isNil:
    return
  if streamId in conn.masqueSessions:
    conn.masqueSessions.del(streamId)
  if streamId in conn.masqueCapsuleBuffers:
    conn.masqueCapsuleBuffers.del(streamId)

proc clearWebTransportSessionState*(conn: Http3Connection, streamId: uint64) =
  if conn.isNil:
    return
  if streamId in conn.webTransportSessions:
    conn.webTransportSessions.del(streamId)

proc popWebTransportOutgoingDatagrams*(conn: Http3Connection): seq[seq[byte]] =
  for streamId, session in conn.webTransportSessions:
    let pending = session.popOutgoingDatagrams()
    for d in pending:
      result.add encodeWebTransportDatagram(streamId, d)

proc popMasqueOutgoingDatagrams*(conn: Http3Connection): seq[seq[byte]] =
  for streamId, session in conn.masqueSessions:
    let pending = session.popOutgoingDatagrams()
    for d in pending:
      result.add conn.encodeH3DatagramForMasque(streamId, d.contextId, d.payload)

proc popMasqueOutgoingCapsulesByStream*(conn: Http3Connection): seq[tuple[streamId: uint64, capsules: seq[MasqueCapsule]]] =
  for streamId, session in conn.masqueSessions:
    let pending = session.popOutgoingCapsules()
    if pending.len > 0:
      result.add (streamId: streamId, capsules: pending)

proc popMasqueOutgoingCapsules*(conn: Http3Connection): seq[MasqueCapsule] =
  let byStream = conn.popMasqueOutgoingCapsulesByStream()
  for item in byStream:
    if item.capsules.len > 0:
      result.add item.capsules
