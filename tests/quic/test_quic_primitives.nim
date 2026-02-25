## Tests for direct QUIC protocol primitives.

import std/strutils
import cps/quic

proc hexToBytes(hex: string): seq[byte] =
  let s = hex.strip().replace(" ", "")
  doAssert s.len mod 2 == 0, "hex input length must be even"
  result = newSeq[byte](s.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(s[i * 2 .. i * 2 + 1]))

proc bytesToHex(data: openArray[byte]): string =
  result = newStringOfCap(data.len * 2)
  for b in data:
    result.add toHex(int(b), 2).toLowerAscii

block testVarIntKnownVectors:
  let vectors = @[
    (0'u64, "00"),
    (63'u64, "3f"),
    (64'u64, "4040"),
    (15293'u64, "7bbd"),
    (494_878_333'u64, "9d7f3e7d"),
    (151_288_809_941_952_652'u64, "c2197c5eff14e88c")
  ]

  for (value, expectedHex) in vectors:
    let encoded = encodeQuicVarInt(value)
    doAssert bytesToHex(encoded) == expectedHex,
      "varint encode mismatch for " & $value

    var off = 0
    let decoded = decodeQuicVarInt(encoded, off)
    doAssert decoded == value, "varint decode mismatch for " & $value
    doAssert off == encoded.len

  echo "PASS: QUIC varint vectors"

block testInitialSecretVectors:
  # RFC 9001, Appendix A vectors for DCID 0x8394c8f03e515708
  let dcid = hexToBytes("8394c8f03e515708")
  let secrets = deriveInitialSecrets(dcid)

  doAssert bytesToHex(secrets.clientInitialSecret) ==
    "c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea"
  doAssert bytesToHex(secrets.serverInitialSecret) ==
    "3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b"

  let ck = deriveAeadKey(secrets.clientInitialSecret)
  let civ = deriveAeadIv(secrets.clientInitialSecret)
  let chp = deriveHeaderProtectionKey(secrets.clientInitialSecret)

  doAssert bytesToHex(ck) == "1f369613dd76d5467730efcbe3b1a22d"
  doAssert bytesToHex(civ) == "fa044b2f42a3fd3b46fb255c"
  doAssert bytesToHex(chp) == "9f50449e04a0e810283a1e9933adedd2"

  let sk = deriveAeadKey(secrets.serverInitialSecret)
  let siv = deriveAeadIv(secrets.serverInitialSecret)
  let shp = deriveHeaderProtectionKey(secrets.serverInitialSecret)

  doAssert bytesToHex(sk) == "cf3a5331653c364c88f0f379b6067e37"
  doAssert bytesToHex(siv) == "0ac1493ca1905853b0bba03e"
  doAssert bytesToHex(shp) == "c206b8d9b9f0f37644430b490eeaa314"

  echo "PASS: QUIC initial secret vectors"

block testPacketProtectionRoundTrip:
  let dcid = hexToBytes("8394c8f03e515708")
  let secrets = deriveInitialSecrets(dcid)
  let key = deriveAeadKey(secrets.clientInitialSecret)
  let ivBase = deriveAeadIv(secrets.clientInitialSecret)
  let pn = 7'u64
  let nonce = makeNonce(ivBase, pn)

  let aad = hexToBytes("c300000001088394c8f03e51570800")
  let plaintext = hexToBytes("060040f1010000")

  let enc = encryptAes128Gcm(key, nonce, aad, plaintext)
  let dec = decryptAes128Gcm(key, nonce, aad, enc.ciphertext, enc.tag)
  doAssert dec == plaintext

  let hpKey = deriveHeaderProtectionKey(secrets.clientInitialSecret)
  # Sample is normally taken from encrypted payload. Any 16-byte sample is valid for this unit test.
  let mask = headerProtectionMaskAes128(hpKey, hexToBytes("437b9aec36be423400cdd1154bbf0f3a"))
  doAssert mask.len == 5

  echo "PASS: QUIC packet protection round-trip"

block testFrameRoundTrip:
  let frames = @[
    QuicFrame(kind: qfkPadding),
    QuicFrame(kind: qfkPing),
    QuicFrame(kind: qfkCrypto, cryptoOffset: 0, cryptoData: @[1'u8, 2, 3, 4]),
    QuicFrame(kind: qfkStream, streamId: 4, streamOffset: 1024, streamFin: true,
              streamData: @[10'u8, 20, 30]),
    QuicFrame(kind: qfkAck, largestAcked: 1234, ackDelay: 1, firstAckRange: 2,
              extraRanges: @[QuicAckRange(gap: 1, rangeLen: 3)]),
    QuicFrame(kind: qfkConnectionClose, errorCode: 0x0a, frameType: 0x08,
              reason: "test-close")
  ]

  for f in frames:
    let encoded = encodeFrame(f)
    var off = 0
    let decoded = parseFrame(encoded, off)
    doAssert off == encoded.len
    doAssert decoded.kind == f.kind

  echo "PASS: QUIC frame encode/decode"

block testPacketHeaderRoundTrip:
  let hdr = QuicPacketHeader(
    packetType: qptInitial,
    version: 0x00000001'u32,
    dstConnId: hexToBytes("8394c8f03e515708"),
    srcConnId: hexToBytes("f067a5502a4262b5"),
    token: @[],
    packetNumberLen: 2
  )

  let encoded = encodePacketHeader(hdr, payloadLen = 32, packetNumberLen = 2)
  var off = 0
  let decoded = parsePacketHeader(encoded, off)

  doAssert decoded.packetType == qptInitial
  doAssert decoded.version == hdr.version
  doAssert decoded.dstConnId == hdr.dstConnId
  doAssert decoded.srcConnId == hdr.srcConnId
  doAssert decoded.packetNumberLen == 2

  # Packet number reconstruction sanity check
  let fullPn = decodePacketNumber(largestPn = 0xa82f30ea'u64, truncatedPn = 0x9b32'u64, packetNumberLen = 2)
  doAssert fullPn == 0xa82f9b32'u64

  echo "PASS: QUIC packet header encode/decode"

block testVersionNegotiationCodec:
  let sourceCid = hexToBytes("1122334455667788")
  let destinationCid = hexToBytes("99aabbccddeeff00")
  let versions = @[0x00000001'u32, 0x6b3343cf'u32]

  let packet = encodeVersionNegotiationPacket(
    sourceConnId = sourceCid,
    destinationConnId = destinationCid,
    supportedVersions = versions,
    firstByte = 0xA5'u8
  )
  doAssert packet.len == 7 + sourceCid.len + destinationCid.len + versions.len * 4

  var off = 0
  let hdr = parsePacketHeader(packet, off)
  doAssert hdr.packetType == qptVersionNegotiation
  doAssert hdr.version == 0'u32
  doAssert hdr.dstConnId == destinationCid
  doAssert hdr.srcConnId == sourceCid
  doAssert hdr.packetNumberLen == 0

  let parsed = parseVersionNegotiationPacket(packet)
  doAssert (parsed.firstByte and 0x80'u8) != 0
  doAssert parsed.destinationConnId == destinationCid
  doAssert parsed.sourceConnId == sourceCid
  doAssert parsed.supportedVersions == versions

  echo "PASS: QUIC version negotiation encode/decode"

echo "All QUIC primitive tests passed"
