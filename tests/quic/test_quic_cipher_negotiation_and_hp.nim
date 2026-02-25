## QUIC cipher + header protection selection tests.

import cps/quic

proc mkConnPair(cipher: QuicPacketCipher): tuple[client: QuicConnection, server: QuicConnection] =
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
  c.setPacketCipher(cipher)
  s.setPacketCipher(cipher)
  (c, s)

proc testShortCipher(cipher: QuicPacketCipher, label: string) =
  let (client, server) = mkConnPair(cipher)
  var appSecret = newSeq[byte](32)
  for i in 0 ..< appSecret.len:
    appSecret[i] = byte((i + 1) and 0xFF)
  client.setLevelWriteSecret(qelApplication, appSecret)
  server.setLevelReadSecret(qelApplication, appSecret)

  let pkt = client.encodeProtectedPacket(qptShort, @[
    QuicFrame(kind: qfkStream, streamId: 0'u64, streamOffset: 0'u64, streamFin: false, streamData: @[0x41'u8, 0x42, 0x43])
  ])
  let decoded = server.decodeProtectedPacket(pkt)
  doAssert decoded.header.packetType == qptShort
  doAssert decoded.frames.len == 1
  doAssert decoded.frames[0].kind == qfkStream
  doAssert decoded.frames[0].streamData == @[0x41'u8, 0x42, 0x43]
  echo "PASS: QUIC protected short-header round-trip with " & label

block testAes256GcmPacketProtection:
  testShortCipher(qpcAes256Gcm, "AES-256-GCM")

block testChaCha20Poly1305PacketProtection:
  testShortCipher(qpcChaCha20Poly1305, "CHACHA20-POLY1305")

block testHeaderProtectionKeyLengthValidation:
  var raised = false
  try:
    discard headerProtectionMask(qpcChaCha20Poly1305, @[0x01'u8, 0x02], newSeq[byte](16))
  except ValueError:
    raised = true
  doAssert raised
  echo "PASS: header-protection key length validation for CHACHA20"

echo "All QUIC cipher negotiation/header-protection tests passed"
