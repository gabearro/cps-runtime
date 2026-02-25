## QUIC transport parameter codec tests.

import cps/quic

proc appendParamVarIntWire(dst: var seq[byte], id: uint64, value: uint64) =
  let encoded = encodeQuicVarInt(value)
  dst.appendQuicVarInt(id)
  dst.appendQuicVarInt(uint64(encoded.len))
  dst.add encoded

block testTransportParamsRoundTrip:
  var tp = defaultTransportParameters()
  tp.maxIdleTimeout = 15_000
  tp.maxUdpPayloadSize = 1350
  tp.initialMaxData = 2_000_000
  tp.initialMaxStreamDataBidiLocal = 100_000
  tp.initialMaxStreamDataBidiRemote = 120_000
  tp.initialMaxStreamDataUni = 80_000
  tp.initialMaxStreamsBidi = 256
  tp.initialMaxStreamsUni = 128
  tp.ackDelayExponent = 4
  tp.maxAckDelay = 20
  tp.activeConnectionIdLimit = 10
  tp.maxDatagramFrameSize = 1400
  tp.disableActiveMigration = true
  tp.greaseQuicBit = true
  tp.originalDestinationConnectionId = @[1'u8, 2, 3, 4]
  tp.initialSourceConnectionId = @[5'u8, 6, 7, 8]
  tp.retrySourceConnectionId = @[9'u8, 10]
  tp.hasStatelessResetToken = true
  for i in 0 ..< 16:
    tp.statelessResetToken[i] = byte(i)
  tp.unknown = @[(0xdead'u64, @[0x01'u8, 0x02])]

  let enc = encodeTransportParameters(tp)
  let dec = decodeTransportParameters(enc)
  doAssert dec.maxIdleTimeout == tp.maxIdleTimeout
  doAssert dec.maxUdpPayloadSize == tp.maxUdpPayloadSize
  doAssert dec.initialMaxData == tp.initialMaxData
  doAssert dec.initialMaxStreamDataBidiLocal == tp.initialMaxStreamDataBidiLocal
  doAssert dec.initialMaxStreamsBidi == tp.initialMaxStreamsBidi
  doAssert dec.maxDatagramFrameSize == tp.maxDatagramFrameSize
  doAssert dec.disableActiveMigration == tp.disableActiveMigration
  doAssert dec.greaseQuicBit == tp.greaseQuicBit
  doAssert dec.originalDestinationConnectionId == tp.originalDestinationConnectionId
  doAssert dec.initialSourceConnectionId == tp.initialSourceConnectionId
  doAssert dec.retrySourceConnectionId == tp.retrySourceConnectionId
  doAssert dec.hasStatelessResetToken
  doAssert dec.unknown.len == 1
  echo "PASS: QUIC transport parameter round-trip"

block testRetryTokenConnIdBinding:
  let secret = @[0x10'u8, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F]
  let odcid = @[0xA1'u8, 0xA2, 0xA3, 0xA4]
  let rscid = @[0xB1'u8, 0xB2, 0xB3, 0xB4]
  let token = issueQuicToken(
    secretKey = secret,
    purpose = qtpRetry,
    clientAddress = "127.0.0.1:4433",
    originalDestinationConnectionId = odcid,
    retrySourceConnectionId = rscid,
    ttlSeconds = 120,
    nowUnix = 1_700_000_000'i64
  )

  let valid = validateQuicToken(
    secretKey = secret,
    token = token,
    expectedPurpose = qtpRetry,
    clientAddress = "127.0.0.1:4433",
    expectedRetrySourceConnectionId = rscid,
    nowUnix = 1_700_000_001'i64
  )
  doAssert valid.valid
  doAssert valid.originalDestinationConnectionId == odcid
  doAssert valid.retrySourceConnectionId == rscid

  let wrongScid = validateQuicToken(
    secretKey = secret,
    token = token,
    expectedPurpose = qtpRetry,
    clientAddress = "127.0.0.1:4433",
    expectedRetrySourceConnectionId = @[0xC1'u8, 0xC2],
    nowUnix = 1_700_000_001'i64
  )
  doAssert not wrongScid.valid
  echo "PASS: QUIC Retry token CID binding"

block testPeerTransportParamValidationClientRole:
  let conn = newQuicConnection(
    qcrClient,
    @[0x11'u8, 0x12, 0x13, 0x14],
    @[0x21'u8, 0x22, 0x23, 0x24],
    "127.0.0.1",
    4433,
    QuicVersion1
  )
  conn.setExpectedRetrySourceConnectionId(@[0x31'u8, 0x32, 0x33, 0x34])

  var tp = defaultTransportParameters()
  tp.originalDestinationConnectionId = @[0x21'u8, 0x22, 0x23, 0x24]
  tp.initialSourceConnectionId = @[0x21'u8, 0x22, 0x23, 0x24]
  tp.retrySourceConnectionId = @[0x31'u8, 0x32, 0x33, 0x34]
  doAssert conn.validatePeerTransportParameters(tp).len == 0

  tp.initialSourceConnectionId = @[0x91'u8]
  doAssert conn.validatePeerTransportParameters(tp) == "initial_source_connection_id mismatch"
  tp.initialSourceConnectionId = @[0x21'u8, 0x22, 0x23, 0x24]

  tp.retrySourceConnectionId = @[]
  doAssert conn.validatePeerTransportParameters(tp) == "missing retry_source_connection_id after Retry"
  tp.retrySourceConnectionId = @[0x31'u8, 0x32, 0x33, 0x34]

  tp.originalDestinationConnectionId = @[]
  doAssert conn.validatePeerTransportParameters(tp) == "missing original_destination_connection_id"
  echo "PASS: QUIC peer transport-parameter validation (client role)"

block testPeerTransportParamValidationServerRole:
  let conn = newQuicConnection(
    qcrServer,
    @[0x51'u8, 0x52, 0x53, 0x54],
    @[0x61'u8, 0x62, 0x63, 0x64],
    "127.0.0.1",
    4433,
    QuicVersion1
  )

  var tp = defaultTransportParameters()
  tp.initialSourceConnectionId = @[0x61'u8, 0x62, 0x63, 0x64]
  doAssert conn.validatePeerTransportParameters(tp).len == 0

  tp.originalDestinationConnectionId = @[0xAA'u8]
  doAssert conn.validatePeerTransportParameters(tp) == "client sent original_destination_connection_id"
  tp.originalDestinationConnectionId = @[]

  tp.retrySourceConnectionId = @[0xBB'u8]
  doAssert conn.validatePeerTransportParameters(tp) == "client sent retry_source_connection_id"
  tp.retrySourceConnectionId = @[]

  tp.hasStatelessResetToken = true
  doAssert conn.validatePeerTransportParameters(tp) == "client sent stateless_reset_token"
  tp.hasStatelessResetToken = false

  tp.initialSourceConnectionId = @[]
  doAssert conn.validatePeerTransportParameters(tp) == "initial_source_connection_id mismatch"
  echo "PASS: QUIC peer transport-parameter validation (server role)"

block testTransportParamsRejectDuplicateIdentifiers:
  var wire: seq[byte] = @[]
  wire.appendParamVarIntWire(TpInitialMaxData, 1024'u64)
  wire.appendParamVarIntWire(TpInitialMaxData, 2048'u64)

  var raised = false
  try:
    discard decodeTransportParameters(wire)
  except ValueError:
    raised = true
  doAssert raised
  echo "PASS: QUIC transport parameters reject duplicate identifiers"

block testPeerTransportParamNumericLimits:
  let conn = newQuicConnection(
    qcrClient,
    @[0x71'u8, 0x72, 0x73, 0x74],
    @[0x81'u8, 0x82, 0x83, 0x84],
    "127.0.0.1",
    4433,
    QuicVersion1
  )

  var tp = defaultTransportParameters()
  tp.originalDestinationConnectionId = @[0x81'u8, 0x82, 0x83, 0x84]
  tp.initialSourceConnectionId = @[0x81'u8, 0x82, 0x83, 0x84]

  tp.maxUdpPayloadSize = 1199'u64
  doAssert conn.validatePeerTransportParameters(tp) ==
    "max_udp_payload_size below minimum (1200)"
  tp.maxUdpPayloadSize = 1200'u64

  tp.ackDelayExponent = 21'u64
  doAssert conn.validatePeerTransportParameters(tp) == "ack_delay_exponent exceeds 20"
  tp.ackDelayExponent = 20'u64

  tp.maxAckDelay = 16384'u64
  doAssert conn.validatePeerTransportParameters(tp) ==
    "max_ack_delay exceeds QUIC limit (16383)"
  tp.maxAckDelay = 25'u64

  tp.activeConnectionIdLimit = 1'u64
  doAssert conn.validatePeerTransportParameters(tp) ==
    "active_connection_id_limit below minimum (2)"
  tp.activeConnectionIdLimit = 2'u64

  tp.initialMaxStreamsBidi = (1'u64 shl 60)
  doAssert conn.validatePeerTransportParameters(tp) ==
    "initial_max_streams_bidi exceeds QUIC limit (2^60-1)"
  tp.initialMaxStreamsBidi = (1'u64 shl 60) - 1'u64

  tp.initialMaxStreamsUni = (1'u64 shl 60)
  doAssert conn.validatePeerTransportParameters(tp) ==
    "initial_max_streams_uni exceeds QUIC limit (2^60-1)"
  tp.initialMaxStreamsUni = (1'u64 shl 60) - 1'u64

  doAssert conn.validatePeerTransportParameters(tp).len == 0
  echo "PASS: QUIC peer transport-parameter numeric limits"

echo "All QUIC transport parameter tests passed"
