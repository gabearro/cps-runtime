## QUIC flow control behavior tests.

import cps/quic

proc mkPayload(n: int): seq[byte] =
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = byte(i and 0xFF)

block testStreamFlowControlWindows:
  let conn = newQuicConnection(qcrClient, @[0x11'u8], @[0x22'u8], "127.0.0.1", 4433)
  let stream = conn.openLocalBidiStream()

  # Clamp the send window and ensure we only emit what fits.
  stream.sendWindowLimit = 32
  stream.appendSendData(mkPayload(64))
  let first = stream.nextSendChunk(64)
  doAssert first.payload.len == 32
  let blocked = stream.nextSendChunk(64)
  doAssert blocked.payload.len == 0

  # Grant more stream credit via MAX_STREAM_DATA and continue.
  conn.applyReceivedFrame(
    QuicFrame(
      kind: qfkMaxStreamData,
      maxStreamDataStreamId: stream.id,
      maxStreamData: 64
    )
  )
  let second = stream.nextSendChunk(64)
  doAssert second.payload.len == 32
  doAssert stream.sendCreditRemaining() == 0

  # Connection-level MAX_DATA must update advertised data window.
  let before = conn.localTransportParameters.initialMaxData
  conn.applyReceivedFrame(QuicFrame(kind: qfkMaxData, maxData: before + 4096))
  doAssert conn.localTransportParameters.initialMaxData == before + 4096

  echo "PASS: QUIC stream and connection flow control updates"

block testRecvWindowEnforcement:
  let conn = newQuicConnection(qcrServer, @[0x55'u8], @[0x66'u8], "127.0.0.1", 4433)
  let stream = conn.getOrCreateStream(1'u64)
  stream.recvWindowLimit = 4

  var raised = false
  try:
    stream.pushRecvData(0, @[1'u8, 2, 3, 4, 5], fin = false)
  except ValueError:
    raised = true

  doAssert raised
  echo "PASS: QUIC receive flow-control window enforcement"

block testFinalSizeInvariantEnforcement:
  let conn = newQuicConnection(qcrServer, @[0x01'u8], @[0x02'u8], "127.0.0.1", 4433)
  let stream = conn.getOrCreateStream(1'u64)
  stream.pushRecvData(0'u64, @[0x41'u8, 0x42], fin = true)

  var raised = false
  try:
    stream.pushRecvData(2'u64, @[0x43'u8], fin = false)
  except ValueError:
    raised = true
  doAssert raised
  echo "PASS: QUIC stream final-size invariant enforcement"

block testDirectionalTransportParamMapping:
  let conn = newQuicConnection(qcrClient, @[0xAA'u8], @[0xBB'u8], "127.0.0.1", 4433)
  conn.localTransportParameters.initialMaxStreamDataBidiLocal = 111'u64
  conn.localTransportParameters.initialMaxStreamDataBidiRemote = 222'u64
  conn.localTransportParameters.initialMaxStreamDataUni = 333'u64

  var peerTp = defaultTransportParameters()
  peerTp.initialMaxStreamDataBidiLocal = 444'u64
  peerTp.initialMaxStreamDataBidiRemote = 555'u64
  peerTp.initialMaxStreamDataUni = 666'u64

  conn.activatePeerTransportParameters(peerTp)

  let localBidi = conn.openLocalBidiStream()         # client-initiated bidi
  let peerBidi = conn.getOrCreateStream(1'u64)       # server-initiated bidi
  let localUni = conn.openLocalUniStream()           # client-initiated uni
  let peerUni = conn.getOrCreateStream(3'u64)        # server-initiated uni

  doAssert localBidi.sendWindowLimit == 555'u64
  doAssert localBidi.recvWindowLimit == 111'u64
  doAssert peerBidi.sendWindowLimit == 444'u64
  doAssert peerBidi.recvWindowLimit == 222'u64
  doAssert localUni.sendWindowLimit == 666'u64
  doAssert localUni.recvWindowLimit == 0'u64
  doAssert peerUni.sendWindowLimit == 0'u64
  doAssert peerUni.recvWindowLimit == 333'u64
  echo "PASS: QUIC stream limits map correctly for local/peer initiated streams"

block testPeerTransportParamActivationClampsExistingSendWindows:
  let conn = newQuicConnection(qcrClient, @[0x0A'u8], @[0x0B'u8], "127.0.0.1", 4433)
  let stream = conn.openLocalBidiStream()
  stream.sendWindowLimit = 4096'u64

  var peerTp = defaultTransportParameters()
  peerTp.initialMaxStreamDataBidiRemote = 1024'u64
  conn.activatePeerTransportParameters(peerTp)

  doAssert stream.sendWindowLimit == 1024'u64
  echo "PASS: QUIC peer transport params clamp existing stream send windows"

block testStreamCountLimitsEnforced:
  let conn = newQuicConnection(qcrClient, @[0x31'u8], @[0x32'u8], "127.0.0.1", 4433)
  conn.localTransportParameters.initialMaxStreamsBidi = 1
  conn.localTransportParameters.initialMaxStreamsUni = 1

  var peerTp = defaultTransportParameters()
  peerTp.initialMaxStreamsBidi = 1
  peerTp.initialMaxStreamsUni = 1
  conn.activatePeerTransportParameters(peerTp)

  discard conn.openLocalBidiStream() # stream id 0, allowed
  discard conn.openLocalUniStream()  # stream id 2, allowed
  discard conn.getOrCreateStream(1'u64) # peer bidi first stream, allowed
  discard conn.getOrCreateStream(3'u64) # peer uni first stream, allowed

  var localBidiLimitRaised = false
  try:
    discard conn.openLocalBidiStream() # stream id 4 -> second local bidi
  except ValueError:
    localBidiLimitRaised = true
  doAssert localBidiLimitRaised

  var localUniLimitRaised = false
  try:
    discard conn.openLocalUniStream() # stream id 6 -> second local uni
  except ValueError:
    localUniLimitRaised = true
  doAssert localUniLimitRaised

  var peerBidiLimitRaised = false
  try:
    discard conn.getOrCreateStream(5'u64) # second peer bidi
  except ValueError:
    peerBidiLimitRaised = true
  doAssert peerBidiLimitRaised

  var peerUniLimitRaised = false
  try:
    discard conn.getOrCreateStream(7'u64) # second peer uni
  except ValueError:
    peerUniLimitRaised = true
  doAssert peerUniLimitRaised

  echo "PASS: QUIC stream count limits enforced for local and peer streams"

block testLocalStreamIdClassAndRangeValidation:
  let conn = newQuicConnection(qcrClient, @[0x41'u8], @[0x42'u8], "127.0.0.1", 4433)
  conn.peerTransportParameters.initialMaxStreamsBidi = high(uint64)
  conn.localTransportParameters.initialMaxStreamsBidi = high(uint64)
  conn.peerTransportParameters.initialMaxStreamsUni = high(uint64)
  conn.localTransportParameters.initialMaxStreamsUni = high(uint64)

  conn.nextLocalBidiStreamId = 1'u64
  var bidiClassRaised = false
  try:
    discard conn.openLocalBidiStream()
  except ValueError:
    bidiClassRaised = true
  doAssert bidiClassRaised

  conn.nextLocalBidiStreamId = QuicVarIntMax8 + 1'u64
  var bidiRangeRaised = false
  try:
    discard conn.openLocalBidiStream()
  except ValueError:
    bidiRangeRaised = true
  doAssert bidiRangeRaised

  conn.nextLocalUniStreamId = 3'u64
  var uniClassRaised = false
  try:
    discard conn.openLocalUniStream()
  except ValueError:
    uniClassRaised = true
  doAssert uniClassRaised

  conn.nextLocalUniStreamId = QuicVarIntMax8 + 3'u64
  var uniRangeRaised = false
  try:
    discard conn.openLocalUniStream()
  except ValueError:
    uniRangeRaised = true
  doAssert uniRangeRaised

  echo "PASS: QUIC local stream ID class/range validation"

block testMaxStreamDataRejectsReceiveOnlyStream:
  let conn = newQuicConnection(qcrClient, @[0x51'u8], @[0x52'u8], "127.0.0.1", 4433)
  conn.applyReceivedFrame(
    QuicFrame(
      kind: qfkMaxStreamData,
      maxStreamDataStreamId: 3'u64, # server-initiated unidirectional; receive-only for client
      maxStreamData: 4096'u64
    )
  )
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x05'u64
  echo "PASS: QUIC MAX_STREAM_DATA rejects receive-only streams"

block testMaxStreamsRejectsOversizedValue:
  let conn = newQuicConnection(qcrClient, @[0x61'u8], @[0x62'u8], "127.0.0.1", 4433)
  conn.applyReceivedFrame(
    QuicFrame(
      kind: qfkMaxStreams,
      maxStreamsBidi: true,
      maxStreams: (1'u64 shl 60)
    )
  )
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x07'u64
  echo "PASS: QUIC MAX_STREAMS rejects values above 2^60-1"

block testResetStreamDirectionAndFinalSizeValidation:
  let conn = newQuicConnection(qcrClient, @[0x71'u8], @[0x72'u8], "127.0.0.1", 4433)

  # Peer cannot send on locally initiated unidirectional stream.
  conn.applyReceivedFrame(
    QuicFrame(
      kind: qfkResetStream,
      resetStreamId: 2'u64,
      resetErrorCode: 0'u64,
      resetFinalSize: 0'u64
    )
  )
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x05'u64

  let conn2 = newQuicConnection(qcrClient, @[0x81'u8], @[0x82'u8], "127.0.0.1", 4433)
  conn2.applyReceivedFrame(
    QuicFrame(
      kind: qfkStream,
      streamId: 1'u64, # peer-initiated bidi; peer can send.
      streamOffset: 0'u64,
      streamFin: false,
      streamData: @[0xAA'u8, 0xBB, 0xCC, 0xDD]
    )
  )
  conn2.applyReceivedFrame(
    QuicFrame(
      kind: qfkResetStream,
      resetStreamId: 1'u64,
      resetErrorCode: 0'u64,
      resetFinalSize: 2'u64 # below recvOffset (=4)
    )
  )
  doAssert conn2.state == qcsDraining
  doAssert conn2.closeErrorCode == 0x06'u64
  echo "PASS: QUIC RESET_STREAM enforces direction and final-size invariants"

block testStreamFrameDirectionAndLimitValidation:
  let conn = newQuicConnection(qcrClient, @[0x85'u8], @[0x86'u8], "127.0.0.1", 4433)
  var raisedDirection = false
  try:
    conn.applyReceivedFrame(
      QuicFrame(
        kind: qfkStream,
        streamId: 2'u64, # client-initiated unidirectional; peer cannot send.
        streamOffset: 0'u64,
        streamFin: false,
        streamData: @[0x41'u8]
      )
    )
  except CatchableError:
    raisedDirection = true
  doAssert not raisedDirection
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x05'u64

  let conn2 = newQuicConnection(qcrClient, @[0x87'u8], @[0x88'u8], "127.0.0.1", 4433)
  conn2.localTransportParameters.initialMaxStreamsBidi = 1'u64
  var raisedLimit = false
  try:
    conn2.applyReceivedFrame(
      QuicFrame(
        kind: qfkStream,
        streamId: 5'u64, # peer bidi stream index 1 exceeds local limit of 1.
        streamOffset: 0'u64,
        streamFin: false,
        streamData: @[0x42'u8]
      )
    )
  except CatchableError:
    raisedLimit = true
  doAssert not raisedLimit
  doAssert conn2.state == qcsDraining
  doAssert conn2.closeErrorCode == 0x04'u64
  echo "PASS: QUIC STREAM enforces direction and stream-limit invariants without throwing"

block testStreamFrameFlowControlViolationMapsToClose:
  let conn = newQuicConnection(qcrClient, @[0x89'u8], @[0x8A'u8], "127.0.0.1", 4433)
  conn.localTransportParameters.initialMaxStreamDataBidiRemote = 2'u64
  var raised = false
  try:
    conn.applyReceivedFrame(
      QuicFrame(
        kind: qfkStream,
        streamId: 1'u64, # peer-initiated bidi stream.
        streamOffset: 0'u64,
        streamFin: false,
        streamData: @[0x01'u8, 0x02, 0x03]
      )
    )
  except CatchableError:
    raised = true
  doAssert not raised
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x03'u64
  echo "PASS: QUIC STREAM flow-control violations map to FLOW_CONTROL_ERROR"

block testStopSendingDirectionValidation:
  let conn = newQuicConnection(qcrClient, @[0x91'u8], @[0x92'u8], "127.0.0.1", 4433)
  # Peer cannot receive on peer-initiated unidirectional stream.
  conn.applyReceivedFrame(
    QuicFrame(
      kind: qfkStopSending,
      stopSendingStreamId: 3'u64,
      stopSendingErrorCode: 0'u64
    )
  )
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x05'u64
  echo "PASS: QUIC STOP_SENDING enforces direction invariants"

echo "All QUIC flow control tests passed"
