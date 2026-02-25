## QUIC v2 codec and negotiation tests.

import cps/quic

proc mkV2Pair(): tuple[client: QuicConnection, server: QuicConnection] =
  let cCid = @[0x10'u8, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80]
  let sCid = @[0x90'u8, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0, 0x01]
  let client = newQuicConnection(
    role = qcrClient,
    localConnId = cCid,
    peerConnId = sCid,
    peerAddress = "127.0.0.1",
    peerPort = 4433,
    version = QuicVersion2
  )
  let server = newQuicConnection(
    role = qcrServer,
    localConnId = sCid,
    peerConnId = cCid,
    peerAddress = "127.0.0.1",
    peerPort = 4433,
    version = QuicVersion2
  )
  (client, server)

block testQuicV2ProtectedInitialPacket:
  let (client, server) = mkV2Pair()
  let pkt = client.encodeProtectedPacket(qptInitial, @[QuicFrame(kind: qfkPing)])
  let decoded = server.decodeProtectedPacket(pkt)
  doAssert decoded.header.packetType == qptInitial
  doAssert decoded.frames.len >= 1
  var sawPing = false
  for f in decoded.frames:
    if f.kind == qfkPing:
      sawPing = true
  doAssert sawPing
  echo "PASS: QUIC v2 protected Initial packet round-trip"

block testVersionNegotiationIncludesV2:
  let vn = encodeVersionNegotiationPacket(
    sourceConnId = @[0xAA'u8, 0xBB],
    destinationConnId = @[0xCC'u8, 0xDD],
    supportedVersions = @[QuicVersion1, QuicVersion2]
  )
  let parsed = parseVersionNegotiationPacket(vn)
  doAssert QuicVersion1 in parsed.supportedVersions
  doAssert QuicVersion2 in parsed.supportedVersions
  echo "PASS: Version Negotiation packet carries QUIC v1 + v2"

block testRetryIntegrityV2:
  let odcid = @[0x83'u8, 0x94, 0xC8, 0xF0, 0x3E, 0x51, 0x57, 0x08]
  let retry = encodeRetryPacket(
    version = QuicVersion2,
    destinationConnId = @[0x11'u8, 0x22, 0x33, 0x44],
    sourceConnId = @[0x55'u8, 0x66, 0x77, 0x88],
    token = @[0x01'u8, 0x02, 0x03, 0x04],
    originalDestinationConnId = odcid
  )
  doAssert validateRetryPacketIntegrity(retry, odcid)
  echo "PASS: QUIC v2 Retry integrity validates"

block testDefaultEndpointConfigVersions:
  let cfg = defaultQuicEndpointConfig()
  doAssert qv1 in cfg.versions
  doAssert qv2 in cfg.versions
  doAssert cfg.congestionControl == qccCubic
  doAssert cfg.maxConnections > 0
  doAssert cfg.maxStreamsPerConnection > 0
  echo "PASS: Endpoint config defaults include v1+v2 and CUBIC"

echo "All QUIC v2 codec/negotiation tests passed"
