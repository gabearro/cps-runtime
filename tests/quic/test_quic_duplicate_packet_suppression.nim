## QUIC duplicate packet suppression and reordered-packet acceptance.

import cps/quic

proc mkShortDatagramPacket(pn: uint64, payload: seq[byte]): QuicPacket =
  QuicPacket(
    header: QuicPacketHeader(
      packetType: qptShort,
      version: QuicVersion1,
      dstConnId: @[0xA1'u8, 0xA2, 0xA3, 0xA4],
      srcConnId: @[0xB1'u8, 0xB2, 0xB3, 0xB4],
      token: @[],
      keyPhase: false,
      packetNumberLen: 2,
      payloadLen: -1
    ),
    packetNumber: pn,
    frames: @[
      QuicFrame(kind: qfkDatagram, datagramData: payload)
    ]
  )

block testDuplicatePacketDroppedButReorderedPacketAccepted:
  var conn = newQuicConnection(
    role = qcrServer,
    localConnId = @[0xA1'u8, 0xA2, 0xA3, 0xA4],
    peerConnId = @[0xB1'u8, 0xB2, 0xB3, 0xB4],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )

  let packet42 = mkShortDatagramPacket(42'u64, @[0x42'u8])
  let packet41 = mkShortDatagramPacket(41'u64, @[0x41'u8])

  # In-order, then reordered older packet, then duplicate of the first.
  conn.onPacketReceived(packet42)
  conn.onPacketReceived(packet41)
  conn.onPacketReceived(packet42)

  let datagrams = conn.popIncomingDatagrams()
  doAssert datagrams.len == 2, "duplicate packet should not reapply DATAGRAM frame"
  doAssert datagrams[0] == @[0x42'u8]
  doAssert datagrams[1] == @[0x41'u8]

  # Duplicate arrivals are suppressed from ACK queue growth.
  let acks = conn.consumePendingAcks(qpnsApplication)
  doAssert acks.len == 2
  let ack = buildAckFrame(acks)
  doAssert ack.kind == qfkAck
  doAssert ack.largestAcked == 42'u64
  doAssert ack.firstAckRange == 1'u64
  echo "PASS: QUIC duplicate packet suppression preserves reordered packets"

echo "All QUIC duplicate packet suppression tests passed"
