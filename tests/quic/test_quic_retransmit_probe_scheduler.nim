## QUIC PTO probe scheduling and retransmit queue tests.

import cps/quic

proc containsSpace(spaces: seq[QuicPacketNumberSpace], target: QuicPacketNumberSpace): bool =
  for s in spaces:
    if s == target:
      return true
  false

block testPtoProbeQueuesRetransmittableFrames:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x01'u8, 0x02, 0x03, 0x04],
    peerConnId = @[0x05'u8, 0x06, 0x07, 0x08],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )

  discard conn.encodeUnprotectedPacket(
    qptShort,
    @[QuicFrame(kind: qfkStream, streamId: 0'u64, streamOffset: 0'u64, streamFin: false, streamData: @[0xAA'u8])]
  )
  conn.notePacketActuallySent()

  let expired = conn.ptoExpiredSpaces(high(int64))
  doAssert containsSpace(expired, qpnsApplication)

  let ptoBefore = conn.recovery.ptoCount
  conn.queuePtoProbe(qpnsApplication)
  let probeFrames = conn.popPendingRetransmitFrames(qpnsApplication)
  doAssert probeFrames.len > 0
  doAssert probeFrames[0].kind == qfkStream
  doAssert conn.recovery.ptoCount == ptoBefore + 1
  echo "PASS: QUIC PTO probe scheduler queues retransmittable frames"

block testPtoProbeCwndBypassAllowance:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x0A'u8, 0x0B, 0x0C, 0x0D],
    peerConnId = @[0x11'u8, 0x12, 0x13, 0x14],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )

  discard conn.encodeUnprotectedPacket(
    qptShort,
    @[QuicFrame(kind: qfkStream, streamId: 4'u64, streamOffset: 0'u64, streamFin: false, streamData: @[0xCD'u8])]
  )
  conn.notePacketActuallySent()

  doAssert not conn.consumePtoCwndBypassAllowance()
  conn.queuePtoProbe(qpnsApplication)
  let probeFrames = conn.popPendingRetransmitFrames(qpnsApplication)
  doAssert probeFrames.len > 0
  discard conn.encodeUnprotectedPacket(qptShort, probeFrames)
  doAssert conn.consumePtoCwndBypassAllowance()
  doAssert not conn.consumePtoCwndBypassAllowance()
  echo "PASS: QUIC PTO probe grants one-shot cwnd bypass allowance"

block testAckOnlyQueueIsNotAckEliciting:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x22'u8, 0x23, 0x24, 0x25],
    peerConnId = @[0x32'u8, 0x33, 0x34, 0x35],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )

  discard conn.encodeUnprotectedPacket(qptShort, @[buildAckFrame(@[1'u64])])
  doAssert not conn.nextPendingSendIsAckEliciting()
  conn.notePacketActuallySent()

  discard conn.encodeUnprotectedPacket(
    qptShort,
    @[QuicFrame(kind: qfkStream, streamId: 8'u64, streamOffset: 0'u64, streamFin: false, streamData: @[0xEF'u8])]
  )
  doAssert conn.nextPendingSendIsAckEliciting()
  echo "PASS: QUIC send queue correctly classifies ACK-only datagrams"

echo "All QUIC retransmit/probe scheduler tests passed"
