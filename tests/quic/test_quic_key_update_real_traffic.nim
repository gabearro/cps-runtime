## QUIC key-update behavior on protected 1-RTT traffic.

import cps/quic

block testKeyPhaseFlipOn1RttTraffic:
  let client = newQuicConnection(
    role = qcrClient,
    localConnId = @[0xAA'u8, 0xBB, 0xCC, 0xDD],
    peerConnId = @[0x01'u8, 0x02, 0x03, 0x04],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  let server = newQuicConnection(
    role = qcrServer,
    localConnId = @[0x01'u8, 0x02, 0x03, 0x04],
    peerConnId = @[0xAA'u8, 0xBB, 0xCC, 0xDD],
    peerAddress = "127.0.0.1",
    peerPort = 40000
  )

  let secret0 = @[0x21'u8, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
                  0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30]
  client.setLevelWriteSecret(qelApplication, secret0)
  server.setLevelReadSecret(qelApplication, secret0)

  let firstPkt = client.encodeProtectedPacket(qptShort, @[QuicFrame(kind: qfkPing)])
  let firstDecoded = server.decodeProtectedPacket(firstPkt)
  doAssert not firstDecoded.header.keyPhase

  let writeKeyBefore = client.levelWriteKeys[2].key
  client.rotate1RttKeyPhase()
  doAssert client.levelWriteKeys[2].key != writeKeyBefore,
    "rotate1RttKeyPhase should derive fresh 1-RTT write keys"

  let secondPkt = client.encodeProtectedPacket(qptShort, @[QuicFrame(kind: qfkPing)])
  let secondDecoded = server.decodeProtectedPacket(secondPkt)
  doAssert secondDecoded.header.keyPhase
  var sawPing = false
  for f in secondDecoded.frames:
    if f.kind == qfkPing:
      sawPing = true
      break
  doAssert sawPing

  # A reordered packet from the previous key phase should still decrypt
  # via the retained previous read-key window.
  let lateDecoded = server.decodeProtectedPacket(firstPkt)
  doAssert not lateDecoded.header.keyPhase
  var sawLatePing = false
  for f in lateDecoded.frames:
    if f.kind == qfkPing:
      sawLatePing = true
      break
  doAssert sawLatePing

  echo "PASS: QUIC 1-RTT key update key-phase traffic decode"

block testPreviousReadKeysRetireAfterWindow:
  let client = newQuicConnection(
    role = qcrClient,
    localConnId = @[0xDA'u8, 0x7A, 0xA1, 0x10],
    peerConnId = @[0x10'u8, 0xA1, 0x7A, 0xDA],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  let server = newQuicConnection(
    role = qcrServer,
    localConnId = @[0x10'u8, 0xA1, 0x7A, 0xDA],
    peerConnId = @[0xDA'u8, 0x7A, 0xA1, 0x10],
    peerAddress = "127.0.0.1",
    peerPort = 41000
  )

  let secret0 = @[0x31'u8, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
                  0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40]
  client.setLevelWriteSecret(qelApplication, secret0)
  server.setLevelReadSecret(qelApplication, secret0)

  var lateOldPhasePacket: seq[byte] = @[]
  for _ in 0 ..< 4:
    lateOldPhasePacket = client.encodeProtectedPacket(qptShort, @[QuicFrame(kind: qfkPing)])
    discard server.decodeProtectedPacket(lateOldPhasePacket)

  client.rotate1RttKeyPhase()
  let switchPkt = client.encodeProtectedPacket(qptShort, @[QuicFrame(kind: qfkPing)])
  discard server.decodeProtectedPacket(switchPkt)

  # Immediately after key update, previous-phase packets still decrypt.
  discard server.decodeProtectedPacket(lateOldPhasePacket)

  # After enough current-phase packets, previous keys should retire.
  for _ in 0 ..< 80:
    let pkt = client.encodeProtectedPacket(qptShort, @[QuicFrame(kind: qfkPing)])
    discard server.decodeProtectedPacket(pkt)

  var retired = false
  try:
    discard server.decodeProtectedPacket(lateOldPhasePacket)
  except ValueError:
    retired = true
  doAssert retired,
    "previous 1-RTT read keys should retire after sustained current-phase traffic"
  echo "PASS: QUIC previous 1-RTT read keys retire after window"

echo "All QUIC key-update real traffic tests passed"
