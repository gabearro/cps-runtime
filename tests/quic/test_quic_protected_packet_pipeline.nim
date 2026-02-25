## QUIC protected packet pipeline tests.

import cps/quic

proc mkConnPair(): tuple[client: QuicConnection, server: QuicConnection] =
  let cCid = @[0x11'u8, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
  let sCid = @[0x99'u8, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x10]
  let c = newQuicConnection(
    role = qcrClient,
    localConnId = cCid,
    peerConnId = sCid,
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  let s = newQuicConnection(
    role = qcrServer,
    localConnId = sCid,
    peerConnId = cCid,
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  (c, s)

block testProtectedInitialRoundTrip:
  let (client, server) = mkConnPair()
  let pkt = client.encodeProtectedPacket(qptInitial, @[
    QuicFrame(kind: qfkPing),
    QuicFrame(kind: qfkCrypto, cryptoOffset: 0, cryptoData: @[1'u8, 2, 3])
  ])
  let decoded = server.decodeProtectedPacket(pkt)
  doAssert decoded.header.packetType == qptInitial
  doAssert decoded.frames.len >= 2
  doAssert decoded.frames[0].kind == qfkPing
  doAssert decoded.frames[1].kind == qfkCrypto
  echo "PASS: QUIC protected Initial packet round-trip"

block testProtectedShortRoundTrip:
  let (client, server) = mkConnPair()
  let appSecret = @[1'u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
  client.setLevelWriteSecret(qelApplication, appSecret)
  server.setLevelReadSecret(qelApplication, appSecret)

  let pkt = client.encodeProtectedPacket(qptShort, @[
    QuicFrame(kind: qfkStream, streamId: 0'u64, streamOffset: 0'u64, streamFin: true, streamData: @[0x41'u8, 0x42])
  ])
  let decoded = server.decodeProtectedPacket(pkt)
  doAssert decoded.header.packetType == qptShort
  doAssert decoded.frames.len == 1
  doAssert decoded.frames[0].kind == qfkStream
  doAssert decoded.frames[0].streamFin
  doAssert decoded.frames[0].streamData == @[0x41'u8, 0x42]
  server.onPacketReceived(decoded)
  let stats = server.snapshotStats()
  doAssert stats.handshakeState == qhsOneRtt
  doAssert stats.activePathPeer.len > 0
  echo "PASS: QUIC protected 1-RTT short-header packet round-trip"

block testShortHeaderRequiresApplicationKeys:
  let (client, server) = mkConnPair()
  var sendRaised = false
  try:
    discard client.encodeProtectedPacket(qptShort, @[QuicFrame(kind: qfkPing)])
  except ValueError:
    sendRaised = true
  doAssert sendRaised

  let initial = client.encodeProtectedPacket(qptInitial, @[QuicFrame(kind: qfkPing)])
  var recvRaised = false
  try:
    discard server.decodeProtectedPacket(initial)
  except ValueError:
    recvRaised = true
  doAssert not recvRaised
  echo "PASS: QUIC protected short-header packets require application keys"

block testQlogEventSinkCompatibility:
  var stringEvents: seq[string] = @[]
  var structuredEvents: seq[QuicQlogEvent] = @[]
  let onQlog = proc(event: string) {.closure.} =
    stringEvents.add event
  let onQlogEvent = proc(event: QuicQlogEvent) {.closure.} =
    structuredEvents.add event
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[1'u8, 2, 3, 4],
    peerConnId = @[5'u8, 6, 7, 8],
    peerAddress = "127.0.0.1",
    peerPort = 4433,
    qlogSink = onQlog,
    qlogEventSink = onQlogEvent
  )
  discard conn.encodeProtectedPacket(qptInitial, @[QuicFrame(kind: qfkPing)])
  doAssert stringEvents.len > 0
  doAssert structuredEvents.len > 0
  doAssert structuredEvents[^1].kind.len > 0
  echo "PASS: QUIC qlog string + structured sink compatibility"

echo "All QUIC protected packet pipeline tests passed"
