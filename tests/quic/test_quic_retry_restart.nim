## QUIC client Retry restart regression tests.

import cps/quic/types
import cps/quic/connection

proc hasFrameKind(frames: openArray[QuicFrame], kind: QuicFrameKind): bool =
  for f in frames:
    if f.kind == kind:
      return true
  false

block retryRestartRebindsInitialSecretsAndRequeuesCrypto:
  let localCid = @[0x11'u8, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18]
  let initialOdcid = @[0x21'u8, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28]
  let retryScid = @[0x31'u8, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38]
  let retryToken = @[0xAA'u8, 0xBB, 0xCC, 0xDD]

  let conn = newQuicConnection(
    qcrClient,
    localCid,
    initialOdcid,
    "127.0.0.1",
    4433,
    version = 0x00000001'u32
  )

  let crypto = QuicFrame(kind: qfkCrypto, cryptoOffset: 0'u64, cryptoData: @[0x01'u8, 0x02, 0x03, 0x04])
  let initialPacket = conn.encodeProtectedPacket(qptInitial, @[crypto])
  conn.queueDatagramForSend(initialPacket)
  conn.notePacketActuallySent()
  doAssert conn.recovery.bytesInFlight > 0, "expected bytes-in-flight after Initial send"

  let preservedOdcid = conn.originalDestinationConnectionIdForValidation()
  doAssert preservedOdcid == initialOdcid

  conn.onRetryReceived(retryScid, retryToken)

  doAssert conn.peerConnId == retryScid
  doAssert conn.initialSecretConnId == retryScid
  doAssert conn.originalDestinationConnectionIdForValidation() == preservedOdcid
  doAssert conn.activeRetryToken == retryToken
  doAssert conn.retrySourceConnIdExpected == retryScid
  doAssert conn.recovery.bytesInFlight == 0, "retry restart must clear prior Initial bytes-in-flight"

  let retransmit = conn.popPendingRetransmitFrames(qpnsInitial)
  doAssert retransmit.len > 0, "retry restart should requeue Initial retransmittable frames"
  doAssert hasFrameKind(retransmit, qfkCrypto), "retry restart should preserve CRYPTO retransmission"
  doAssert not hasFrameKind(retransmit, qfkAck), "retry restart should not queue ACK-only frames"

  echo "PASS: QUIC Retry restart rebinds Initial secrets and requeues CRYPTO"

block retryRestartWithoutOutstandingFramesQueuesPing:
  let localCid = @[0x41'u8, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48]
  let initialOdcid = @[0x51'u8, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58]
  let retryScid = @[0x61'u8, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68]
  let retryToken = @[0xE1'u8, 0xE2]

  let conn = newQuicConnection(
    qcrClient,
    localCid,
    initialOdcid,
    "127.0.0.1",
    4433,
    version = 0x00000001'u32
  )

  conn.onRetryReceived(retryScid, retryToken)
  let retransmit = conn.popPendingRetransmitFrames(qpnsInitial)
  doAssert retransmit.len == 0
  doAssert conn.pendingControlFrames.len > 0
  doAssert conn.pendingControlFrames[^1].kind == qfkPing

  echo "PASS: QUIC Retry restart queues ping when no Initial retransmittables exist"

echo "All QUIC Retry restart tests passed"
