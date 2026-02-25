## QUIC varint + packet codec tests.

import std/strutils
import cps/quic

proc hexToBytes(hex: string): seq[byte] =
  let s = hex.strip().replace(" ", "")
  doAssert s.len mod 2 == 0
  result = newSeq[byte](s.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(s[i * 2 .. i * 2 + 1]))

block testCoalescedSplit:
  let hdr1 = QuicPacketHeader(
    packetType: qptInitial,
    version: QuicVersion1,
    dstConnId: hexToBytes("0102030405060708"),
    srcConnId: hexToBytes("1112131415161718"),
    token: @[],
    packetNumberLen: 2
  )
  let p1 = encodePacketHeader(hdr1, payloadLen = 2, packetNumberLen = 2) &
    @[0x00'u8, 0x01'u8, FramePing, FrameHandshakeDone]
  let hdr2 = QuicPacketHeader(
    packetType: qptHandshake,
    version: QuicVersion1,
    dstConnId: hexToBytes("0102030405060708"),
    srcConnId: hexToBytes("1112131415161718"),
    token: @[],
    packetNumberLen: 2
  )
  let p2 = encodePacketHeader(hdr2, payloadLen = 1, packetNumberLen = 2) &
    @[0x00'u8, 0x02'u8, FramePing]
  let coalesced = encodeCoalescedPackets([p1, p2])
  let split = splitCoalescedPackets(coalesced)
  doAssert split.len == 2
  doAssert split[0] == p1
  doAssert split[1] == p2
  echo "PASS: QUIC coalesced packet split"

block testRetryPacketCodecAndIntegrity:
  let odcid = hexToBytes("8394c8f03e515708")
  let dcid = hexToBytes("1122334455667788")
  let scid = hexToBytes("99aabbccddeeff00")
  let token = hexToBytes("01020304a1a2a3a4")
  let pkt = encodeRetryPacket(
    version = QuicVersion1,
    destinationConnId = dcid,
    sourceConnId = scid,
    token = token,
    originalDestinationConnId = odcid
  )
  let parsed = parseRetryPacket(pkt)
  doAssert parsed.version == QuicVersion1
  doAssert parsed.dstConnId == dcid
  doAssert parsed.srcConnId == scid
  doAssert parsed.token == token
  doAssert validateRetryPacketIntegrity(pkt, odcid)
  echo "PASS: QUIC Retry packet codec + integrity"

block testStatelessResetHelpers:
  let token = hexToBytes("00112233445566778899aabbccddeeff")
  let sr = generateStatelessReset(token, 43)
  doAssert sr.len == 43
  doAssert isStatelessResetCandidate(sr, token)
  var altered = sr
  altered[^1] = altered[^1] xor 0x01
  doAssert not isStatelessResetCandidate(altered, token)
  echo "PASS: QUIC stateless reset helpers"

echo "All QUIC varint/packet codec tests passed"
