## HTTP/3 control stream + SETTINGS behavior tests.

import std/tables
import cps/quic/varint
import cps/http/shared/http3
import cps/http/shared/http3_connection
import cps/http/shared/qpack
import cps/http/client/http3 as client_http3
import cps/http/server/http3 as server_http3

proc firstProtocolErrorCode(events: seq[Http3Event]): uint64 =
  for ev in events:
    if ev.kind == h3evProtocolError:
      return ev.errorCode
  0'u64

block testControlStreamPrefaceAndSettings:
  let sender = newHttp3Connection(isClient = true, qpackTableCapacity = 1024, qpackBlockedStreams = 8)
  let receiver = newHttp3Connection(isClient = false)

  let preface = sender.encodeControlStreamPreface()
  var off = 0
  let streamType = decodeQuicVarInt(preface, off)
  doAssert streamType == H3UniControlStream

  let events = receiver.ingestUniStreamData(2'u64, preface)
  doAssert events.len == 1
  doAssert events[0].kind == h3evSettings
  doAssert receiver.controlState == h3csReady
  doAssert H3SettingQpackMaxTableCapacity in receiver.peerSettings
  doAssert receiver.peerSettings[H3SettingQpackMaxTableCapacity] == 1024'u64
  doAssert receiver.peerSettings[H3SettingQpackBlockedStreams] == 8'u64
  doAssert receiver.peerSettings.getOrDefault(H3SettingEnableConnectProtocol, 0'u64) == 1'u64
  doAssert receiver.peerSettings.getOrDefault(H3SettingH3Datagram, 0'u64) == 1'u64
  echo "PASS: HTTP/3 control stream SETTINGS ingestion"

block testProcessControlStreamDataBuffersFragmentedFrames:
  let conn = newHttp3Connection(isClient = true)
  let settingsFrame = encodeHttp3Frame(H3FrameSettings, @[])
  doAssert settingsFrame.len > 1

  let first = conn.processControlStreamData(2'u64, settingsFrame[0 .. 0])
  doAssert first.len == 0
  doAssert not conn.peerSettingsReceived

  let second = conn.processControlStreamData(2'u64, settingsFrame[1 .. ^1])
  doAssert second.len == 1
  doAssert second[0].kind == h3evSettings
  doAssert conn.peerSettingsReceived
  echo "PASS: HTTP/3 processControlStreamData buffers fragmented control frames"

block testLocalSettingsAdvertiseExtendedConnect:
  let conn = newHttp3Connection(isClient = true)
  doAssert conn.localSettingValue(H3SettingEnableConnectProtocol, 0'u64) == 1'u64
  doAssert conn.localSettingValue(H3SettingH3Datagram, 0'u64) == 1'u64
  echo "PASS: HTTP/3 local SETTINGS advertise extended CONNECT support"

block testSessionConstructorsCanDisableH3DatagramSetting:
  let clientSession = client_http3.newHttp3ClientSession(enableDatagram = false)
  doAssert clientSession.conn.localSettingValue(H3SettingH3Datagram, 1'u64) == 0'u64

  let serverSession = server_http3.newHttp3ServerSession(
    @[0x01'u8],
    nil,
    enableDatagram = false
  )
  doAssert serverSession.conn.localSettingValue(H3SettingH3Datagram, 1'u64) == 0'u64

  let peer = newHttp3Connection(isClient = false)
  discard clientSession.conn.ingestUniStreamData(3'u64, peer.encodeControlStreamPreface())
  doAssert not clientSession.conn.canSendH3Datagrams(),
    "Datagrams must remain disabled when local SETTINGS_H3_DATAGRAM is 0"
  echo "PASS: HTTP/3 session constructors can disable H3 DATAGRAM advertisement"

block testConnectionConstructorRejectsNegativeQpackLimits:
  var rejectedCapacity = false
  try:
    discard newHttp3Connection(isClient = true, qpackTableCapacity = -1)
  except ValueError:
    rejectedCapacity = true
  doAssert rejectedCapacity

  var rejectedBlocked = false
  try:
    discard newHttp3Connection(isClient = true, qpackBlockedStreams = -1)
  except ValueError:
    rejectedBlocked = true
  doAssert rejectedBlocked

  var rejectedMasqueBuffer = false
  try:
    discard newHttp3Connection(isClient = true, maxMasqueCapsuleBufferBytes = -1)
  except ValueError:
    rejectedMasqueBuffer = true
  doAssert rejectedMasqueBuffer

  var rejectedUniBuffer = false
  try:
    discard newHttp3Connection(isClient = true, maxUniStreamBufferBytes = -1)
  except ValueError:
    rejectedUniBuffer = true
  doAssert rejectedUniBuffer

  var rejectedReqBuffer = false
  try:
    discard newHttp3Connection(isClient = true, maxRequestStreamBufferBytes = -1)
  except ValueError:
    rejectedReqBuffer = true
  doAssert rejectedReqBuffer

  var rejectedTotalUniBuffer = false
  try:
    discard newHttp3Connection(isClient = true, maxTotalUniStreamBufferBytes = -1)
  except ValueError:
    rejectedTotalUniBuffer = true
  doAssert rejectedTotalUniBuffer

  var rejectedTotalReqBuffer = false
  try:
    discard newHttp3Connection(isClient = true, maxTotalRequestStreamBufferBytes = -1)
  except ValueError:
    rejectedTotalReqBuffer = true
  doAssert rejectedTotalReqBuffer
  echo "PASS: HTTP/3 connection constructor rejects negative limits"

block testQpackUniStreamPrefaces:
  let conn = newHttp3Connection(isClient = true)

  var off = 0
  let encPref = conn.encodeQpackEncoderStreamPreface()
  doAssert decodeQuicVarInt(encPref, off) == H3UniQpackEncoderStream

  off = 0
  let decPref = conn.encodeQpackDecoderStreamPreface()
  doAssert decodeQuicVarInt(decPref, off) == H3UniQpackDecoderStream
  echo "PASS: HTTP/3 QPACK unidirectional stream prefaces"

block testH3DatagramNegotiationState:
  let client = newHttp3Connection(isClient = true)
  let server = newHttp3Connection(isClient = false)
  doAssert not server.canSendH3Datagrams(), "Datagrams must not be considered negotiated before peer SETTINGS"
  let preface = client.encodeControlStreamPreface()
  discard server.ingestUniStreamData(2'u64, preface)
  doAssert server.canSendH3Datagrams(), "Datagrams should be negotiated when both endpoints advertise SETTINGS_H3_DATAGRAM=1"
  echo "PASS: HTTP/3 H3_DATAGRAM negotiation state tracking"

block testH3DatagramDisabledByPeerSetting:
  let conn = newHttp3Connection(isClient = true)
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(H3UniControlStream)
  payload.add encodeHttp3Frame(H3FrameSettings, encodeSettingsPayload(@[
    (H3SettingH3Datagram, 0'u64)
  ]))
  let events = conn.ingestUniStreamData(3'u64, payload)
  doAssert events.len == 1
  doAssert events[0].kind == h3evSettings
  doAssert not conn.canSendH3Datagrams(),
    "Datagrams must remain disabled when peer advertises SETTINGS_H3_DATAGRAM=0"
  echo "PASS: HTTP/3 H3_DATAGRAM disabled by peer SETTINGS value"

block testClientDatagramIngressRequiresNegotiation:
  let session = client_http3.newHttp3ClientSession()
  let streamId = 0'u64
  discard session.conn.registerWebTransportSession(streamId, "example.com", "/wt")
  let wire = session.conn.encodeH3DatagramForWebTransport(streamId, @[0xAB'u8, 0xCD'u8])

  doAssert not session.ingestApplicationDatagram(wire),
    "Client should ignore incoming H3 DATAGRAM before SETTINGS negotiation"

  let peer = newHttp3Connection(isClient = false)
  let preface = peer.encodeControlStreamPreface()
  discard session.conn.ingestUniStreamData(3'u64, preface)
  doAssert session.ingestApplicationDatagram(wire),
    "Client should accept incoming H3 DATAGRAM after SETTINGS negotiation"
  echo "PASS: HTTP/3 client ingress datagrams gated on negotiation"

block testConnectionDatagramIngressRequiresNegotiation:
  let conn = newHttp3Connection(isClient = false)
  discard conn.registerWebTransportSession(9'u64, "example.com", "/wt")
  let wire = conn.encodeH3DatagramForWebTransport(9'u64, @[0xEE'u8])
  doAssert not conn.ingestH3Datagram(wire),
    "Connection-level datagram ingest must reject payloads before SETTINGS negotiation"

  let peer = newHttp3Connection(isClient = true)
  let preface = peer.encodeControlStreamPreface()
  discard conn.ingestUniStreamData(2'u64, preface)
  doAssert conn.ingestH3Datagram(wire),
    "Connection-level datagram ingest should accept payloads after SETTINGS negotiation"
  echo "PASS: HTTP/3 connection datagram ingest is gated on negotiation"

block testDuplicateSettingIdentifierRejected:
  let conn = newHttp3Connection(isClient = true)
  let dup = encodeSettingsPayload(@[
    (H3SettingQpackBlockedStreams, 4'u64),
    (H3SettingQpackBlockedStreams, 8'u64)
  ])
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(H3UniControlStream)
  payload.add encodeHttp3Frame(H3FrameSettings, dup)
  let events = conn.ingestUniStreamData(2'u64, payload)
  doAssert events.len == 1
  doAssert firstProtocolErrorCode(events) == H3ErrSettingsError
  echo "PASS: HTTP/3 duplicate SETTINGS identifier yields H3_SETTINGS_ERROR"

block testForbiddenHttp2SettingIdentifierRejected:
  let conn = newHttp3Connection(isClient = true)
  let forbidden = encodeSettingsPayload(@[
    (0x04'u64, 65535'u64) # HTTP/2 SETTINGS_INITIAL_WINDOW_SIZE is forbidden in HTTP/3
  ])
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(H3UniControlStream)
  payload.add encodeHttp3Frame(H3FrameSettings, forbidden)
  let events = conn.ingestUniStreamData(2'u64, payload)
  doAssert events.len == 1
  doAssert firstProtocolErrorCode(events) == H3ErrSettingsError
  echo "PASS: forbidden HTTP/2 SETTINGS identifier yields H3_SETTINGS_ERROR"

block testInvalidEnableConnectProtocolValueRejected:
  let conn = newHttp3Connection(isClient = true)
  let badConnectValue = encodeSettingsPayload(@[
    (H3SettingEnableConnectProtocol, 2'u64)
  ])
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(H3UniControlStream)
  payload.add encodeHttp3Frame(H3FrameSettings, badConnectValue)
  let events = conn.ingestUniStreamData(2'u64, payload)
  doAssert events.len == 1
  doAssert firstProtocolErrorCode(events) == H3ErrSettingsError
  echo "PASS: invalid SETTINGS_ENABLE_CONNECT_PROTOCOL yields H3_SETTINGS_ERROR"

block testInvalidH3DatagramSettingValueRejected:
  let conn = newHttp3Connection(isClient = true)
  let badDatagramValue = encodeSettingsPayload(@[
    (H3SettingH3Datagram, 2'u64)
  ])
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(H3UniControlStream)
  payload.add encodeHttp3Frame(H3FrameSettings, badDatagramValue)
  let events = conn.ingestUniStreamData(2'u64, payload)
  doAssert events.len == 1
  doAssert firstProtocolErrorCode(events) == H3ErrSettingsError
  echo "PASS: invalid SETTINGS_H3_DATAGRAM yields H3_SETTINGS_ERROR"

block testLocalSettingRejectsInvalidEnableConnectProtocolValue:
  let conn = newHttp3Connection(isClient = true)
  var accepted = true
  try:
    conn.setLocalSettingValue(H3SettingEnableConnectProtocol, 2'u64)
  except ValueError:
    accepted = false
  doAssert not accepted
  echo "PASS: local SETTINGS_ENABLE_CONNECT_PROTOCOL rejects non-boolean values"

block testLocalSettingRejectsInvalidH3DatagramValue:
  let conn = newHttp3Connection(isClient = true)
  var accepted = true
  try:
    conn.setLocalSettingValue(H3SettingH3Datagram, 2'u64)
  except ValueError:
    accepted = false
  doAssert not accepted
  echo "PASS: local SETTINGS_H3_DATAGRAM rejects non-boolean values"

block testLocalSettingRejectsForbiddenHttp2Identifier:
  let conn = newHttp3Connection(isClient = true)
  var accepted = true
  try:
    conn.setLocalSettingValue(0x04'u64, 65535'u64)
  except ValueError:
    accepted = false
  doAssert not accepted
  echo "PASS: local SETTINGS rejects forbidden HTTP/2 identifiers"

block testLocalSettingRejectsOutOfRangeVarints:
  let conn = newHttp3Connection(isClient = true)
  let outOfRange = (1'u64 shl 62)
  var accepted = true
  try:
    conn.setLocalSettingValue(outOfRange, 1'u64)
  except ValueError:
    accepted = false
  doAssert not accepted

  accepted = true
  try:
    conn.setLocalSettingValue(H3SettingMaxFieldSectionSize, outOfRange)
  except ValueError:
    accepted = false
  doAssert not accepted
  echo "PASS: local SETTINGS rejects out-of-range QUIC varints"

block testControlStreamPrefaceRejectsDuplicateLocalSettings:
  let conn = newHttp3Connection(isClient = true)
  conn.localSettings.add (H3SettingH3Datagram, 1'u64)
  var accepted = true
  try:
    discard conn.encodeControlStreamPreface()
  except ValueError:
    accepted = false
  doAssert not accepted
  doAssert conn.controlState == h3csInit
  echo "PASS: control preface rejects duplicate local SETTINGS identifiers"

block testControlStreamPrefaceRejectsInvalidMutatedLocalSettings:
  let connForbidden = newHttp3Connection(isClient = true)
  connForbidden.localSettings.add (0x02'u64, 1'u64)
  var acceptedForbidden = true
  try:
    discard connForbidden.encodeControlStreamPreface()
  except ValueError:
    acceptedForbidden = false
  doAssert not acceptedForbidden
  doAssert connForbidden.controlState == h3csInit

  let connOutOfRange = newHttp3Connection(isClient = true)
  connOutOfRange.localSettings.add ((1'u64 shl 62), 1'u64)
  var acceptedOutOfRange = true
  try:
    discard connOutOfRange.encodeControlStreamPreface()
  except ValueError:
    acceptedOutOfRange = false
  doAssert not acceptedOutOfRange
  doAssert connOutOfRange.controlState == h3csInit
  echo "PASS: control preface rejects forbidden/out-of-range mutated local SETTINGS"

block testPeerQpackSettingsApplyToLocalEncoderLimits:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(H3UniControlStream)
  payload.add encodeHttp3Frame(H3FrameSettings, encodeSettingsPayload(@[
    (H3SettingQpackMaxTableCapacity, 128'u64),
    (H3SettingQpackBlockedStreams, 1'u64)
  ]))
  let events = conn.ingestUniStreamData(3'u64, payload)
  doAssert events.len == 1
  doAssert events[0].kind == h3evSettings
  doAssert conn.qpackEncoder.maxTableCapacity == 128
  doAssert conn.qpackEncoder.blockedStreamsLimit == 1
  echo "PASS: HTTP/3 applies peer QPACK SETTINGS to local encoder limits"

block testMissingPeerQpackSettingsDefaultEncoderToZeroCapacity:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  var payload: seq[byte] = @[]
  payload.appendQuicVarInt(H3UniControlStream)
  payload.add encodeHttp3Frame(H3FrameSettings, encodeSettingsPayload(@[]))
  let events = conn.ingestUniStreamData(3'u64, payload)
  doAssert events.len == 1
  doAssert events[0].kind == h3evSettings
  doAssert conn.qpackEncoder.maxTableCapacity == 0
  doAssert conn.qpackEncoder.blockedStreamsLimit == 0

  discard conn.encodeHeadersFrame(@[("x-peer-qpack-limit", "1")])
  doAssert conn.qpackEncoder.dynamicTable.len == 0
  doAssert conn.qpackEncoder.insertCount == 0'u64
  echo "PASS: HTTP/3 defaults missing peer QPACK SETTINGS to zero-capacity encoder behavior"

block testLocalQpackTableCapacitySettingAppliesToDecoder:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  conn.setLocalSettingValue(H3SettingQpackMaxTableCapacity, 0'u64)
  doAssert conn.qpackDecoder.maxTableCapacity == 0

  var encoderPayload: seq[byte] = @[]
  encoderPayload.appendQuicVarInt(H3UniQpackEncoderStream)
  encoderPayload.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "200"
  ))
  let events = conn.ingestUniStreamData(7'u64, encoderPayload)
  doAssert firstProtocolErrorCode(events) == 0'u64
  doAssert conn.qpackDecoder.dynamicTable.len == 0
  doAssert conn.qpackDecoder.knownInsertCount == 0'u64
  echo "PASS: HTTP/3 local SETTINGS_QPACK_MAX_TABLE_CAPACITY applies to decoder limits"

block testLocalQpackBlockedStreamsSettingAppliesToDecoder:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  conn.setLocalSettingValue(H3SettingQpackBlockedStreams, 0'u64)
  doAssert conn.qpackDecoder.blockedStreamsLimit == 0

  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
  let events = conn.processRequestStreamData(
    0'u64,
    encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock),
    allowInformationalHeaders = true
  )
  var sawBlocked = false
  for ev in events:
    if ev.kind == h3evNone and ev.errorMessage == "qpack_blocked":
      sawBlocked = true
  doAssert sawBlocked
  doAssert conn.qpackDecoder.blockedStreams == 0
  echo "PASS: HTTP/3 local SETTINGS_QPACK_BLOCKED_STREAMS applies to decoder limits"

block testBlockedRetryWithoutQpackUpdatesDoesNotInflateBlockedCounter:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
  let payload = encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  let first = conn.processRequestStreamData(0'u64, payload, allowInformationalHeaders = true)
  doAssert first.len == 1
  doAssert first[0].kind == h3evNone
  doAssert first[0].errorMessage == "qpack_blocked"
  doAssert conn.qpackDecoder.blockedStreams == 1

  let retryNoUpdates = conn.processRequestStreamData(0'u64, @[], allowInformationalHeaders = true)
  doAssert retryNoUpdates.len == 1
  doAssert retryNoUpdates[0].kind == h3evNone
  doAssert retryNoUpdates[0].errorMessage == "qpack_blocked"
  doAssert conn.qpackDecoder.blockedStreams == 1

  let finNoUpdates = conn.finalizeRequestStream(0'u64, allowInformationalHeaders = true)
  doAssert finNoUpdates.len == 1
  doAssert finNoUpdates[0].kind == h3evNone
  doAssert finNoUpdates[0].errorMessage == "qpack_blocked"
  doAssert conn.qpackDecoder.blockedStreams == 1

  var encoderPayload: seq[byte] = @[]
  encoderPayload.appendQuicVarInt(H3UniQpackEncoderStream)
  encoderPayload.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "200"
  ))
  let encoderEvents = conn.ingestUniStreamData(7'u64, encoderPayload)
  doAssert firstProtocolErrorCode(encoderEvents) == 0'u64

  let retryWithUpdates = conn.processRequestStreamData(0'u64, @[], allowInformationalHeaders = true)
  doAssert retryWithUpdates.len == 1
  doAssert retryWithUpdates[0].kind == h3evHeaders
  doAssert conn.qpackDecoder.blockedStreams == 0
  conn.clearRequestStreamState(0'u64)
  echo "PASS: HTTP/3 blocked retries without QPACK updates do not inflate blocked-stream count"

block testUnrelatedSuccessfulDecodeDoesNotUndercountBlockedStreams:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  let peer = newHttp3Connection(isClient = false, useRfcQpackWire = true)
  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
  let blockedPayload = encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  let blocked = conn.processRequestStreamData(0'u64, blockedPayload, allowInformationalHeaders = true)
  doAssert blocked.len == 1
  doAssert blocked[0].kind == h3evNone
  doAssert blocked[0].errorMessage == "qpack_blocked"
  doAssert conn.qpackDecoder.blockedStreams == 1

  let okPayload = peer.encodeHeadersFrame(@[(":status", "200")])
  let ok = conn.processRequestStreamData(4'u64, okPayload, allowInformationalHeaders = true)
  doAssert ok.len == 1
  doAssert ok[0].kind == h3evHeaders
  doAssert conn.qpackDecoder.blockedStreams == 1

  conn.clearRequestStreamState(0'u64)
  conn.clearRequestStreamState(4'u64)
  doAssert conn.qpackDecoder.blockedStreams == 0
  echo "PASS: unrelated successful decode does not undercount blocked-stream slots"

block testBlockedRetryWithInsufficientQpackUpdatesDoesNotInflateBlockedCounter:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  # Required Insert Count decodes to 2, so one encoder insert is insufficient.
  let blockedHeaderBlock = @[0x03'u8, 0x00'u8, 0x80'u8]
  let payload = encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  let first = conn.processRequestStreamData(0'u64, payload, allowInformationalHeaders = true)
  doAssert first.len == 1
  doAssert first[0].kind == h3evNone
  doAssert first[0].errorMessage == "qpack_blocked"
  doAssert conn.qpackDecoder.blockedStreams == 1

  var firstUpdate: seq[byte] = @[]
  firstUpdate.appendQuicVarInt(H3UniQpackEncoderStream)
  firstUpdate.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "200"
  ))
  discard conn.ingestUniStreamData(7'u64, firstUpdate)

  let retryStillBlocked = conn.processRequestStreamData(0'u64, @[], allowInformationalHeaders = true)
  doAssert retryStillBlocked.len == 1
  doAssert retryStillBlocked[0].kind == h3evNone
  doAssert retryStillBlocked[0].errorMessage == "qpack_blocked"
  doAssert conn.qpackDecoder.blockedStreams == 1

  let secondUpdate = encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "201"
  ))
  discard conn.ingestUniStreamData(7'u64, secondUpdate)

  let retryUnblocked = conn.processRequestStreamData(0'u64, @[], allowInformationalHeaders = true)
  doAssert retryUnblocked.len == 1
  doAssert retryUnblocked[0].kind == h3evHeaders
  doAssert conn.qpackDecoder.blockedStreams == 0
  conn.clearRequestStreamState(0'u64)
  echo "PASS: HTTP/3 blocked retries with insufficient QPACK updates do not inflate blocked-stream count"

block testClearingBlockedRequestStreamReleasesDecoderBlockedSlot:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
  let payload = encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  discard conn.processRequestStreamData(0'u64, payload, allowInformationalHeaders = true)
  doAssert conn.qpackDecoder.blockedStreams == 1

  conn.clearRequestStreamState(0'u64)
  doAssert conn.qpackDecoder.blockedStreams == 0

  discard conn.processRequestStreamData(4'u64, payload, allowInformationalHeaders = true)
  doAssert conn.qpackDecoder.blockedStreams == 1
  conn.clearRequestStreamState(4'u64)
  echo "PASS: clearing blocked request stream releases decoder blocked-stream slot"

block testBlockedRetryAtLimitDoesNotUndercountDecoderBlockedSlots:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  conn.setLocalSettingValue(H3SettingQpackBlockedStreams, 2'u64)
  let blockedHeaderBlock = @[0x03'u8, 0x00'u8, 0x80'u8]
  let payload = encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  discard conn.processRequestStreamData(0'u64, payload, allowInformationalHeaders = true)
  discard conn.processRequestStreamData(4'u64, payload, allowInformationalHeaders = true)
  doAssert conn.qpackDecoder.blockedStreams == 2

  var update: seq[byte] = @[]
  update.appendQuicVarInt(H3UniQpackEncoderStream)
  update.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "200"
  ))
  discard conn.ingestUniStreamData(7'u64, update)

  let retryStillBlocked = conn.processRequestStreamData(0'u64, @[], allowInformationalHeaders = true)
  doAssert retryStillBlocked.len == 1
  doAssert retryStillBlocked[0].kind == h3evNone
  doAssert retryStillBlocked[0].errorMessage == "qpack_blocked"
  doAssert conn.qpackDecoder.blockedStreams == 2
  conn.clearRequestStreamState(0'u64)
  conn.clearRequestStreamState(4'u64)
  echo "PASS: blocked retries at blocked-stream limit do not undercount decoder slots"

block testClearingUncountedBlockedStreamDoesNotUndercountDecoderSlots:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  conn.setLocalSettingValue(H3SettingQpackBlockedStreams, 1'u64)
  let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
  let payload = encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  discard conn.processRequestStreamData(0'u64, payload, allowInformationalHeaders = true)
  discard conn.processRequestStreamData(4'u64, payload, allowInformationalHeaders = true)
  doAssert conn.qpackDecoder.blockedStreams == 1

  # Stream 4 is blocked but uncounted because the blocked-stream limit was
  # already saturated by stream 0. Clearing stream 4 must not decrement.
  conn.clearRequestStreamState(4'u64)
  doAssert conn.qpackDecoder.blockedStreams == 1

  conn.clearRequestStreamState(0'u64)
  doAssert conn.qpackDecoder.blockedStreams == 0
  echo "PASS: clearing uncounted blocked request stream does not undercount decoder slots"

block testPreviouslyUncountedBlockedStreamCanClaimSlotOnRetry:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  conn.setLocalSettingValue(H3SettingQpackBlockedStreams, 1'u64)
  # Required Insert Count decodes to 2, so one encoder insert keeps decode blocked.
  let blockedHeaderBlock = @[0x03'u8, 0x00'u8, 0x80'u8]
  let payload = encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

  discard conn.processRequestStreamData(0'u64, payload, allowInformationalHeaders = true)
  discard conn.processRequestStreamData(4'u64, payload, allowInformationalHeaders = true)
  doAssert conn.qpackDecoder.blockedStreams == 1

  conn.clearRequestStreamState(0'u64)
  doAssert conn.qpackDecoder.blockedStreams == 0

  var update: seq[byte] = @[]
  update.appendQuicVarInt(H3UniQpackEncoderStream)
  update.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "200"
  ))
  discard conn.ingestUniStreamData(7'u64, update)

  let retry = conn.processRequestStreamData(4'u64, @[], allowInformationalHeaders = true)
  doAssert retry.len == 1
  doAssert retry[0].kind == h3evNone
  doAssert retry[0].errorMessage == "qpack_blocked"
  doAssert conn.qpackDecoder.blockedStreams == 1

  conn.clearRequestStreamState(4'u64)
  doAssert conn.qpackDecoder.blockedStreams == 0
  echo "PASS: previously uncounted blocked request stream can claim decoder slot on retry"

block testUncountedBlockedReplaySuccessDoesNotUndercountDecoderSlots:
  let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
  conn.setLocalSettingValue(H3SettingQpackBlockedStreams, 1'u64)
  # Stream 0 requires 3 inserts; stream 4 requires 2 inserts. With blocked-stream
  # limit=1, stream 4 is initially blocked but uncounted.
  let payloadNeedsThreeInserts = encodeHttp3Frame(H3FrameHeaders, @[0x04'u8, 0x00'u8, 0x80'u8])
  let payloadNeedsTwoInserts = encodeHttp3Frame(H3FrameHeaders, @[0x03'u8, 0x00'u8, 0x80'u8])

  discard conn.processRequestStreamData(0'u64, payloadNeedsThreeInserts, allowInformationalHeaders = true)
  discard conn.processRequestStreamData(4'u64, payloadNeedsTwoInserts, allowInformationalHeaders = true)
  doAssert conn.qpackDecoder.blockedStreams == 1

  var firstUpdate: seq[byte] = @[]
  firstUpdate.appendQuicVarInt(H3UniQpackEncoderStream)
  firstUpdate.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "200"
  ))
  discard conn.ingestUniStreamData(7'u64, firstUpdate)
  discard conn.processRequestStreamData(0'u64, @[], allowInformationalHeaders = true)
  discard conn.processRequestStreamData(4'u64, @[], allowInformationalHeaders = true)
  doAssert conn.qpackDecoder.blockedStreams == 1

  let secondUpdate = encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertNameRef,
    nameRefIndex: 25'u64,
    nameRefIsStatic: true,
    value: "201"
  ))
  discard conn.ingestUniStreamData(7'u64, secondUpdate)

  let retrySecond = conn.processRequestStreamData(4'u64, @[], allowInformationalHeaders = true)
  doAssert retrySecond.len == 1
  doAssert retrySecond[0].kind == h3evHeaders
  doAssert conn.qpackDecoder.blockedStreams == 1

  let retryFirst = conn.processRequestStreamData(0'u64, @[], allowInformationalHeaders = true)
  doAssert retryFirst.len == 1
  doAssert retryFirst[0].kind == h3evNone
  doAssert retryFirst[0].errorMessage == "qpack_blocked"
  doAssert conn.qpackDecoder.blockedStreams == 1

  conn.clearRequestStreamState(0'u64)
  conn.clearRequestStreamState(4'u64)
  doAssert conn.qpackDecoder.blockedStreams == 0
  echo "PASS: uncounted blocked replay success does not undercount decoder slots"

echo "All HTTP/3 SETTINGS/control-stream tests passed"
