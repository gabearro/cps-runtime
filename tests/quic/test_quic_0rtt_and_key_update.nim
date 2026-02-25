## QUIC 0-RTT and key phase update tests.

import cps/quic

block testZeroRttEnableAcceptReject:
  let conn = newQuicConnection(qcrClient, @[0x10'u8], @[0x20'u8], "127.0.0.1", 4433)
  doAssert not conn.is0RttUsable()

  conn.enable0Rtt(true)
  doAssert not conn.is0RttUsable()

  conn.on0RttAccepted()
  doAssert conn.is0RttUsable()

  conn.on0RttRejected()
  doAssert not conn.is0RttUsable()
  echo "PASS: QUIC 0-RTT enable/accept/reject behavior"

block testOneRttKeyPhaseRotation:
  let conn = newQuicConnection(qcrClient, @[0x30'u8], @[0x40'u8], "127.0.0.1", 4433)
  let initial = conn.oneRttKeyPhase
  conn.rotate1RttKeyPhase()
  doAssert conn.oneRttKeyPhase != initial
  conn.rotate1RttKeyPhase()
  doAssert conn.oneRttKeyPhase == initial
  echo "PASS: QUIC 1-RTT key phase rotation"

proc zeroRttPacket(frame: QuicFrame): QuicPacket =
  QuicPacket(
    header: QuicPacketHeader(packetType: qpt0Rtt),
    packetNumber: 1'u64,
    frames: @[frame]
  )

block testZeroRttRejectsDisallowedFrames:
  let connAck = newQuicConnection(qcrServer, @[0x51'u8], @[0x61'u8], "127.0.0.1", 4433)
  connAck.onPacketReceived(
    zeroRttPacket(
      QuicFrame(
        kind: qfkAck,
        largestAcked: 0'u64,
        ackDelay: 0'u64,
        firstAckRange: 0'u64,
        extraRanges: @[]
      )
    )
  )
  doAssert connAck.state == qcsDraining
  doAssert connAck.closeErrorCode == 0x0A'u64

  let connCid = newQuicConnection(qcrServer, @[0x52'u8], @[0x62'u8], "127.0.0.1", 4433)
  var resetToken: array[16, byte]
  connCid.onPacketReceived(
    zeroRttPacket(
      QuicFrame(
        kind: qfkNewConnectionId,
        ncidSequence: 1'u64,
        ncidRetirePriorTo: 0'u64,
        ncidConnectionId: @[0xAA'u8],
        ncidResetToken: resetToken
      )
    )
  )
  doAssert connCid.state == qcsDraining
  doAssert connCid.closeErrorCode == 0x0A'u64
  doAssert connCid.peerConnectionIdForSequence(1'u64).len == 0
  echo "PASS: QUIC 0-RTT rejects disallowed frame types"

block testZeroRttAllowsStreamFrames:
  let conn = newQuicConnection(qcrServer, @[0x53'u8], @[0x63'u8], "127.0.0.1", 4433)
  conn.onPacketReceived(
    zeroRttPacket(
      QuicFrame(
        kind: qfkStream,
        streamId: 0'u64,
        streamOffset: 0'u64,
        streamFin: false,
        streamData: @[0x41'u8, 0x42]
      )
    )
  )
  doAssert conn.state != qcsDraining
  let s = conn.getOrCreateStream(0'u64)
  doAssert s.recvOffset == 2'u64
  echo "PASS: QUIC 0-RTT accepts stream frames"

block testClientRejectsPeerZeroRttPackets:
  let client = newQuicConnection(qcrClient, @[0x54'u8], @[0x64'u8], "127.0.0.1", 4433)
  client.onPacketReceived(
    QuicPacket(
      header: QuicPacketHeader(packetType: qpt0Rtt),
      packetNumber: 1'u64,
      frames: @[
        QuicFrame(
          kind: qfkStream,
          streamId: 1'u64,
          streamOffset: 0'u64,
          streamFin: false,
          streamData: @[0x33'u8]
        )
      ]
    )
  )
  doAssert client.state == qcsDraining
  doAssert client.closeErrorCode == 0x0A'u64
  echo "PASS: QUIC client rejects peer 0-RTT packets"

echo "All QUIC 0-RTT and key update tests passed"
