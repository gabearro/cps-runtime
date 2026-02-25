## Deterministic QUIC fault-injection tests for recovery/ack handling.
##
## These tests simulate drop/reorder/duplicate network effects by
## reordering ACK delivery and duplicating retransmitted frames.

import cps/quic

const ApplicationSpaceIdx = 2

proc newTestConn(): QuicConnection =
  newQuicConnection(
    role = qcrClient,
    localConnId = @[0x01'u8, 0x02, 0x03, 0x04],
    peerConnId = @[0x05'u8, 0x06, 0x07, 0x08],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )

proc sendStreamPacket(conn: QuicConnection, sid: uint64, payloadByte: byte) =
  discard conn.encodeUnprotectedPacket(
    qptShort,
    @[
      QuicFrame(
        kind: qfkStream,
        streamId: sid,
        streamOffset: 0'u64,
        streamFin: false,
        streamData: @[payloadByte]
      )
    ]
  )
  conn.notePacketActuallySent()

block testAckReorderDropDuplicateMatrix:
  let conn = newTestConn()
  for i in 0 ..< 10:
    sendStreamPacket(conn, 0'u64, byte(i))

  let bytesBefore = conn.recovery.bytesInFlight
  doAssert bytesBefore > 0

  # Reordered ACK arrival (high packet numbers first) forces loss marking.
  let highAck = buildAckFrame(@[7'u64, 8'u64])
  conn.applyReceivedFrame(highAck, qpnsApplication)
  doAssert conn.recovery.lostPackets > 0

  let lostAfterFirstHighAck = conn.recovery.lostPackets
  let retransmit = conn.popPendingRetransmitFrames(qpnsApplication)
  doAssert retransmit.len > 0

  # Duplicate ACK should be idempotent for already-accounted packets.
  conn.applyReceivedFrame(highAck, qpnsApplication)
  doAssert conn.recovery.lostPackets == lostAfterFirstHighAck

  # Emit a few retransmissions as if network duplicated delayed traffic.
  let retransmitCount = min(3, retransmit.len)
  for i in 0 ..< retransmitCount:
    discard conn.encodeUnprotectedPacket(qptShort, @[retransmit[i]])
    conn.notePacketActuallySent()
    discard conn.encodeUnprotectedPacket(qptShort, @[retransmit[i]]) # duplicate
    conn.notePacketActuallySent()

  # Late ACK for previously missing low numbers arrives out-of-order.
  let lowAck = buildAckFrame(@[0'u64, 1, 2, 3, 4, 5, 6])
  conn.applyReceivedFrame(lowAck, qpnsApplication)

  # ACK all packet numbers emitted so far to ensure cleanup converges.
  let lastPn = conn.sendPacketNumber[ApplicationSpaceIdx] - 1'u64
  var allPns: seq[uint64] = @[]
  for pn in 0'u64 .. lastPn:
    allPns.add pn
  conn.applyReceivedFrame(buildAckFrame(allPns), qpnsApplication)

  doAssert conn.recovery.bytesInFlight == 0
  doAssert conn.recovery.ackedPackets > 0
  doAssert conn.recovery.congestionWindow > 0
  echo "PASS: QUIC deterministic reorder/drop/duplicate ACK matrix"

block testDropWithPtoProbeAndDuplicateRetransmit:
  let conn = newTestConn()
  for i in 0 ..< 3:
    sendStreamPacket(conn, 4'u64, byte(0xA0 + i))

  # Simulate full drop of original packets -> PTO should arm probe frames.
  let expired = conn.ptoExpiredSpaces(high(int64))
  var hasApplication = false
  for s in expired:
    if s == qpnsApplication:
      hasApplication = true
      break
  doAssert hasApplication

  conn.queuePtoProbe(qpnsApplication)
  doAssert conn.recovery.ptoCount > 0
  let probeFrames = conn.popPendingRetransmitFrames(qpnsApplication)
  doAssert probeFrames.len > 0

  # Duplicate probe transmission (network duplication).
  discard conn.encodeUnprotectedPacket(qptShort, @[probeFrames[0]])
  conn.notePacketActuallySent()
  discard conn.encodeUnprotectedPacket(qptShort, @[probeFrames[0]])
  conn.notePacketActuallySent()

  # ACK only the latest duplicate; earlier sends should be loss-accounted.
  let newestPn = conn.sendPacketNumber[ApplicationSpaceIdx] - 1'u64
  conn.applyReceivedFrame(buildAckFrame(@[newestPn]), qpnsApplication)

  doAssert conn.recovery.ptoCount == 0
  doAssert conn.recovery.lostPackets > 0
  doAssert conn.recovery.bytesInFlight >= 0
  echo "PASS: QUIC deterministic drop + PTO probe + duplicate retransmit"

echo "All QUIC fault-injection tests passed"
