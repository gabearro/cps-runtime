## Tests for BitTorrent peer wire protocol encoding/decoding.

import cps/bittorrent/peer_protocol
import cps/bittorrent/peer
import cps/bittorrent/utils

# Handshake encoding/decoding
block testHandshake:
  var infoHash: array[20, byte]
  var peerId: array[20, byte]
  for i in 0 ..< 20:
    infoHash[i] = byte(i)
    peerId[i] = byte(i + 100)

  let encoded = encodeHandshake(infoHash, peerId)
  assert encoded.len == HandshakeLength
  assert encoded[0] == char(19)
  assert encoded[1..19] == "BitTorrent protocol"

  let decoded = decodeHandshake(encoded)
  assert decoded.infoHash == infoHash
  assert decoded.peerId == peerId
  assert decoded.supportsExtensions  # BEP 10 flag should be set
  assert (decoded.reserved[7] and 0x04) != 0, "BEP 6 fast-extension bit set"

  echo "PASS: handshake encode/decode"

# Handshake without extensions
block testHandshakeNoExtensions:
  var infoHash: array[20, byte]
  var peerId: array[20, byte]

  let encoded = encodeHandshake(infoHash, peerId, supportExtensions = false)
  let decoded = decodeHandshake(encoded)
  assert not decoded.supportsExtensions
  assert (decoded.reserved[7] and 0x04) != 0, "fast-extension bit still set"
  echo "PASS: handshake without extensions"

# Keep-alive
block testKeepAlive:
  let ka = encodeKeepAlive()
  assert ka.len == 4
  assert readUint32BE(ka, 0) == 0
  echo "PASS: keep-alive"

# Choke/Unchoke/Interested/NotInterested
block testSimpleMessages:
  for msgType in [msgChoke, msgUnchoke, msgInterested, msgNotInterested]:
    let msg = PeerMessage(id: msgType)
    let encoded = encodeMessage(msg)
    assert readUint32BE(encoded, 0) == 1  # length = 1
    assert encoded[4] == char(msgType.byte)
    let payload = encoded[4..^1]
    let decoded = decodeMessage(payload)
    assert decoded.id == msgType
  echo "PASS: simple messages (choke/unchoke/interested/notinterested)"

# Have message
block testHaveMessage:
  let msg = haveMsg(42)
  let encoded = encodeMessage(msg)
  assert readUint32BE(encoded, 0) == 5  # 1 + 4
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgHave
  assert decoded.pieceIndex == 42
  echo "PASS: have message"

# Bitfield message
block testBitfieldMessage:
  let bf: seq[byte] = @[0xFF'u8, 0x80, 0x00]
  let msg = bitfieldMsg(bf)
  let encoded = encodeMessage(msg)
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgBitfield
  assert decoded.bitfield.len == 3
  assert decoded.bitfield[0] == 0xFF
  assert decoded.bitfield[1] == 0x80
  assert decoded.bitfield[2] == 0x00
  echo "PASS: bitfield message"

# Request message
block testRequestMessage:
  let msg = requestMsg(5, 16384, 16384)
  let encoded = encodeMessage(msg)
  assert readUint32BE(encoded, 0) == 13  # 1 + 4 + 4 + 4
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgRequest
  assert decoded.reqIndex == 5
  assert decoded.reqBegin == 16384
  assert decoded.reqLength == 16384
  echo "PASS: request message"

# Piece message
block testPieceMessage:
  let data = "Hello, BitTorrent!"
  let msg = pieceMsg(3, 0, data)
  let encoded = encodeMessage(msg)
  let expectedLen = 1 + 4 + 4 + data.len
  assert readUint32BE(encoded, 0) == uint32(expectedLen)
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgPiece
  assert decoded.blockIndex == 3
  assert decoded.blockBegin == 0
  assert decoded.blockData == data
  echo "PASS: piece message"

# Cancel message
block testCancelMessage:
  let msg = cancelMsg(7, 32768, 16384)
  let encoded = encodeMessage(msg)
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgCancel
  assert decoded.reqIndex == 7
  assert decoded.reqBegin == 32768
  assert decoded.reqLength == 16384
  echo "PASS: cancel message"

# Port message
block testPortMessage:
  let msg = PeerMessage(id: msgPort, dhtPort: 6881)
  let encoded = encodeMessage(msg)
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgPort
  assert decoded.dhtPort == 6881
  echo "PASS: port message"

# Extended message
block testExtendedMessage:
  let msg = PeerMessage(id: msgExtended, extId: 1, extPayload: "test payload")
  let encoded = encodeMessage(msg)
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgExtended
  assert decoded.extId == 1
  assert decoded.extPayload == "test payload"
  echo "PASS: extended message"

# Bitfield helpers
block testBitfieldHelpers:
  var bf = newBitfield(20)
  assert bf.len == 3  # ceil(20/8)
  assert not hasPiece(bf, 0)
  assert not hasPiece(bf, 19)

  setPiece(bf, 0)
  assert hasPiece(bf, 0)
  assert not hasPiece(bf, 1)

  setPiece(bf, 7)
  assert hasPiece(bf, 7)

  setPiece(bf, 8)
  assert hasPiece(bf, 8)

  setPiece(bf, 19)
  assert hasPiece(bf, 19)

  clearPiece(bf, 8)
  assert not hasPiece(bf, 8)

  assert countPieces(bf, 20) == 3

  echo "PASS: bitfield helpers"

# Wire format helpers
block testUint32BE:
  var s = ""
  writeUint32BE(s, 0x01020304'u32)
  assert s.len == 4
  assert s[0] == char(1)
  assert s[1] == char(2)
  assert s[2] == char(3)
  assert s[3] == char(4)
  assert readUint32BE(s, 0) == 0x01020304'u32

  s = ""
  writeUint32BE(s, 0)
  assert readUint32BE(s, 0) == 0

  s = ""
  writeUint32BE(s, 0xFFFFFFFF'u32)
  assert readUint32BE(s, 0) == 0xFFFFFFFF'u32
  echo "PASS: uint32 BE encoding"

block testCanonicalPeerAddressFormatting:
  assert formatPeerAddr("1.2.3.4", 6881) == "1.2.3.4:6881"
  assert formatPeerAddr("2001:db8::1", 6881) == "[2001:db8::1]:6881"
  assert formatPeerAddr("[2001:db8::1]", 6881) == "[2001:db8::1]:6881"
  echo "PASS: canonical peer address formatting"

# Round-trip for all message types
block testRoundTrip:
  let messages = @[
    chokeMsg(),
    unchokeMsg(),
    interestedMsg(),
    notInterestedMsg(),
    haveMsg(1000),
    bitfieldMsg(@[0xAA'u8, 0x55, 0xFF]),
    requestMsg(10, 0, 16384),
    cancelMsg(10, 0, 16384),
    pieceMsg(5, 32768, "block data here"),
    PeerMessage(id: msgPort, dhtPort: 12345),
    PeerMessage(id: msgExtended, extId: 0, extPayload: "d1:v13:test client 1e"),
  ]

  for msg in messages:
    let encoded = encodeMessage(msg)
    let payload = encoded[4..^1]
    let decoded = decodeMessage(payload)
    assert decoded.id == msg.id

  echo "PASS: round-trip all message types"

echo "ALL PEER PROTOCOL TESTS PASSED"
