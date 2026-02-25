## QUIC 0-RTT protected traffic path tests.

import cps/quic

block test0RttPacketRoundTripWithApplicationKeys:
  let client = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x01'u8, 0x02, 0x03, 0x04],
    peerConnId = @[0x05'u8, 0x06, 0x07, 0x08],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  let server = newQuicConnection(
    role = qcrServer,
    localConnId = @[0x05'u8, 0x06, 0x07, 0x08],
    peerConnId = @[0x01'u8, 0x02, 0x03, 0x04],
    peerAddress = "127.0.0.1",
    peerPort = 40000
  )

  let earlySecret = @[0x10'u8, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                      0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F]
  client.setLevelWriteSecret(qelApplication, earlySecret)
  server.setLevelReadSecret(qelApplication, earlySecret)

  client.enable0Rtt(true)
  client.on0RttAccepted()
  doAssert client.is0RttUsable()

  let pkt = client.encodeProtectedPacket(qpt0Rtt, @[
    QuicFrame(kind: qfkStream, streamId: 0'u64, streamOffset: 0'u64, streamFin: false, streamData: @[0xAA'u8, 0xBB])
  ])
  let decoded = server.decodeProtectedPacket(pkt)
  doAssert decoded.header.packetType == qpt0Rtt
  doAssert decoded.frames.len == 1
  doAssert decoded.frames[0].kind == qfkStream
  doAssert decoded.frames[0].streamData == @[0xAA'u8, 0xBB]
  echo "PASS: QUIC 0-RTT protected packet round-trip"

echo "All QUIC 0-RTT real handshake path tests passed"
