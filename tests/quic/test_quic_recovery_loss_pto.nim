## QUIC recovery / PTO tests.

import cps/quic

block testRecoverySignals:
  var r = initRecoveryState(1200)
  let initialCwnd = r.congestionWindow

  r.onPacketSent(1200, ackEliciting = true)
  doAssert r.bytesInFlight == 1200

  r.updateRtt(50_000, ackDelayMicros = 5_000)
  doAssert r.smoothedRttMicros > 0
  doAssert r.rttVarMicros > 0

  r.onPacketAcked(1200)
  doAssert r.bytesInFlight == 0
  doAssert r.congestionWindow >= initialCwnd

  r.onPacketSent(2400, ackEliciting = true)
  r.onPacketLost(1200)
  doAssert r.bytesInFlight <= 1200
  doAssert r.congestionWindow <= initialCwnd

  let pto1 = r.currentPtoMicros()
  r.onPtoExpired()
  let pto2 = r.currentPtoMicros()
  doAssert pto2 >= pto1

  r.onPersistentCongestion()
  doAssert r.congestionWindow >= 2 * r.maxDatagramSize

  echo "PASS: QUIC recovery and PTO behavior"

block testConnectionAckProcessing:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x01'u8, 0x02, 0x03, 0x04],
    peerConnId = @[0x05'u8, 0x06, 0x07, 0x08],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )

  # Packet accounting is committed when packets are actually emitted.
  discard conn.encodeUnprotectedPacket(qptShort, @[QuicFrame(kind: qfkPing)]) # pn=0
  conn.notePacketActuallySent()
  discard conn.encodeUnprotectedPacket(qptShort, @[QuicFrame(kind: qfkPing)]) # pn=1
  conn.notePacketActuallySent()
  discard conn.encodeUnprotectedPacket(qptShort, @[QuicFrame(kind: qfkPing)]) # pn=2
  conn.notePacketActuallySent()
  discard conn.encodeUnprotectedPacket(qptShort, @[QuicFrame(kind: qfkPing)]) # pn=3
  conn.notePacketActuallySent()

  let bytesBefore = conn.recovery.bytesInFlight
  doAssert bytesBefore > 0

  conn.applyReceivedFrame(
    QuicFrame(
      kind: qfkAck,
      largestAcked: 3'u64,
      ackDelay: 0'u64,
      firstAckRange: 1'u64,
      extraRanges: @[]
    ),
    qpnsApplication
  )

  doAssert conn.recovery.ackedPackets >= 2
  doAssert conn.recovery.lostPackets >= 1
  doAssert conn.recovery.bytesInFlight < bytesBefore
  doAssert conn.recovery.smoothedRttMicros > 0
  echo "PASS: QUIC connection ACK/loss integration"

block testMalformedAckRangeRejected:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x11'u8, 0x22, 0x33, 0x44],
    peerConnId = @[0x55'u8, 0x66, 0x77, 0x88],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  conn.applyReceivedFrame(
    QuicFrame(
      kind: qfkAck,
      largestAcked: 1'u64,
      ackDelay: 0'u64,
      firstAckRange: 2'u64, # invalid: largest - first range underflow
      extraRanges: @[]
    ),
    qpnsApplication
  )
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x07'u64
  echo "PASS: QUIC malformed ACK ranges map to FRAME_ENCODING_ERROR"

block testAckAcknowledgesUnsentPacketRejected:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x21'u8, 0x22, 0x23, 0x24],
    peerConnId = @[0x25'u8, 0x26, 0x27, 0x28],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  discard conn.encodeUnprotectedPacket(qptShort, @[QuicFrame(kind: qfkPing)]) # pn=0
  conn.notePacketActuallySent()
  conn.applyReceivedFrame(
    QuicFrame(
      kind: qfkAck,
      largestAcked: 5'u64, # unsent packet number
      ackDelay: 0'u64,
      firstAckRange: 0'u64,
      extraRanges: @[]
    ),
    qpnsApplication
  )
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x0A'u64
  echo "PASS: QUIC ACK acknowledging unsent packet numbers is rejected"

echo "All QUIC recovery tests passed"
