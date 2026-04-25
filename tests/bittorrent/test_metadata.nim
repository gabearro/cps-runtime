## Tests for BEP 9: Metadata Exchange / Magnet Links.

import std/[strutils, tables]
import cps/bittorrent/metadata
import cps/bittorrent/sha1
import cps/bittorrent/bencode

block: # metadata request encoding/decoding
  let encoded = encodeMetadataRequest(5)
  let decoded = decodeMetadataMsg(encoded)
  assert decoded.msgType == mtRequest
  assert decoded.piece == 5
  echo "PASS: metadata request encoding/decoding"

block: # metadata reject encoding/decoding
  let encoded = encodeMetadataReject(3)
  let decoded = decodeMetadataMsg(encoded)
  assert decoded.msgType == mtReject
  assert decoded.piece == 3
  echo "PASS: metadata reject encoding/decoding"

block: # metadata data encoding/decoding
  let testData = "this is test metadata content"
  let encoded = encodeMetadataData(2, 1000, testData)
  let decoded = decodeMetadataMsg(encoded)
  assert decoded.msgType == mtData
  assert decoded.piece == 2
  assert decoded.totalSize == 1000
  assert decoded.data == testData
  echo "PASS: metadata data encoding/decoding"

block: # metadata exchange - piece tracking
  var hash: array[20, byte]
  let me = newMetadataExchange(hash)
  me.initFromSize(MetadataBlockSize * 3 + 100)  # 3 full + 1 partial

  assert me.numPieces == 4
  assert me.totalSize == MetadataBlockSize * 3 + 100

  let needed = me.getNeededPieces()
  assert needed.len == 4
  assert needed == @[0, 1, 2, 3]

  discard me.receivePiece(0, "data0")
  discard me.receivePiece(2, "data2")

  let needed2 = me.getNeededPieces()
  assert needed2.len == 2
  assert needed2 == @[1, 3]
  echo "PASS: metadata exchange - piece tracking"

block: # metadata exchange - assembly and verification
  # Create a fake info dict
  let infoDict = "d4:name4:test12:piece lengthi16384e6:pieces20:" &
                 newString(20) & "e"

  # Compute SHA1 hash
  let hash = sha1(infoDict)

  let me = newMetadataExchange(hash)
  me.initFromSize(infoDict.len)

  # Split into pieces and feed them
  var offset = 0
  var piece = 0
  while offset < infoDict.len:
    let length = min(MetadataBlockSize, infoDict.len - offset)
    let data = infoDict[offset ..< offset + length]
    let allDone = me.receivePiece(piece, data)
    offset += length
    piece += 1
    if offset >= infoDict.len:
      assert allDone, "should be complete after last piece"

  let assembled = me.assembleAndVerify()
  assert assembled == infoDict, "assembled data matches"
  assert me.complete
  echo "PASS: metadata exchange - assembly and verification"

block: # metadata exchange - hash mismatch
  var wrongHash: array[20, byte]
  for i in 0 ..< 20:
    wrongHash[i] = 0xFF  # Wrong hash

  let me = newMetadataExchange(wrongHash)
  me.initFromSize(10)

  discard me.receivePiece(0, "1234567890")
  let assembled = me.assembleAndVerify()
  assert assembled == "", "bad hash returns empty string"
  assert not me.complete
  echo "PASS: metadata exchange - hash mismatch"

block: # metadata exchange - hash mismatch deadlocks (regression: getNeededPieces empty after fail)
  var wrongHash: array[20, byte]
  for i in 0 ..< 20:
    wrongHash[i] = 0xFF

  let me = newMetadataExchange(wrongHash)
  me.initFromSize(MetadataBlockSize + 100)  # 2 pieces
  assert me.numPieces == 2

  # Feed all pieces (with wrong data — hash will fail)
  discard me.receivePiece(0, repeat('A', MetadataBlockSize))
  let allDone = me.receivePiece(1, repeat('B', 100))
  assert allDone, "all pieces received"

  # Verify fails (wrong hash)
  let assembled = me.assembleAndVerify()
  assert assembled == "", "hash mismatch returns empty"
  assert not me.complete

  # BUG: after hash failure, getNeededPieces should return pieces to re-request
  let needed = me.getNeededPieces()
  assert needed.len == 2, "after hash fail, all pieces should be needed again but got " & $needed.len

  # Should be able to re-receive pieces
  discard me.receivePiece(0, repeat('C', MetadataBlockSize))
  let allDone2 = me.receivePiece(1, repeat('D', 100))
  assert allDone2, "can re-receive after hash failure reset"
  echo "PASS: metadata exchange - hash mismatch deadlock fix"

block: # metadata piece serving
  let infoDict = "this is a test info dict for serving"
  let p0 = getMetadataPiece(infoDict, 0)
  assert p0 == infoDict, "single piece returns full data for small dict"

  # Test with larger data
  var largeDict = ""
  for i in 0 ..< MetadataBlockSize + 100:
    largeDict.add(char(i mod 256))

  let piece0 = getMetadataPiece(largeDict, 0)
  assert piece0.len == MetadataBlockSize
  assert piece0 == largeDict[0 ..< MetadataBlockSize]

  let piece1 = getMetadataPiece(largeDict, 1)
  assert piece1.len == 100
  assert piece1 == largeDict[MetadataBlockSize ..< MetadataBlockSize + 100]

  let piece2 = getMetadataPiece(largeDict, 2)
  assert piece2 == "", "out of range piece returns empty"
  echo "PASS: metadata piece serving"

block: # malformed msg_type triggers RangeDefect (should raise ValueError)
  for badType in [-1'i64, 3, 99, 999]:
    var gotValueError = false
    var gotDefect = false
    try:
      var d = initTable[string, BencodeValue]()
      d["msg_type"] = bInt(badType)
      d["piece"] = bInt(0)
      let payload = encode(bDict(d))
      discard decodeMetadataMsg(payload)
    except ValueError:
      gotValueError = true
    except Exception:
      # Catches Defects (RangeDefect) that escape through except Exception
      gotDefect = true
    assert gotValueError, "should raise ValueError (not Defect=" & $gotDefect & ") for msg_type=" & $badType
  echo "PASS: malformed msg_type raises ValueError, not RangeDefect"

block: # magnet link parsing - hex hash
  let magnet = "magnet:?xt=urn:btih:aabbccddee11223344556677889900aabbccddee&dn=Test+File&tr=http%3A%2F%2Ftracker.example.com%2Fannounce"
  let parsed = parseMagnetLink(magnet)

  assert parsed.infoHash[0] == 0xAA
  assert parsed.infoHash[1] == 0xBB
  assert parsed.infoHash[19] == 0xEE
  assert parsed.displayName == "Test File"
  assert parsed.trackers.len == 1
  assert parsed.trackers[0] == "http://tracker.example.com/announce"
  echo "PASS: magnet link parsing - hex hash"

block: # magnet link parsing - base32 hash
  # Use a non-zero base32 hash. "BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB" is not valid length.
  # Base32 of [0x08, 0x00, ...zeros..., 0x01] with 32 chars.
  # Simpler: CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB = 32 chars, first byte = 0x10, last contributes nonzero
  let magnet = "magnet:?xt=urn:btih:CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"
  let parsed = parseMagnetLink(magnet)
  # First byte: C=2, so value = 2 << 5 = 0x40? No: base32 A=0, B=1, C=2
  # First 5 bits = 2 (C), next 5 bits = 0 (A), ... → first byte = (2 << 3) = 0x10
  assert parsed.infoHash[0] == 0x10, "first byte from base32 C = 0x10"
  echo "PASS: magnet link parsing - base32 hash"

block: # magnet link - multiple trackers
  let magnet = "magnet:?xt=urn:btih:aabbccddee11223344556677889900aabbccddee&tr=http%3A%2F%2Ftracker1.com&tr=udp%3A%2F%2Ftracker2.com%3A6969"
  let parsed = parseMagnetLink(magnet)
  assert parsed.trackers.len == 2
  assert parsed.trackers[0] == "http://tracker1.com"
  assert parsed.trackers[1] == "udp://tracker2.com:6969"
  echo "PASS: magnet link - multiple trackers"

block: # magnet link - BEP 53 file selection (so=)
  let magnet = "magnet:?xt=urn:btih:aabbccddee11223344556677889900aabbccddee&dn=sel&so=0-2,5,7"
  let parsed = parseMagnetLink(magnet)
  assert parsed.selectedFiles == @[0, 1, 2, 5, 7]
  echo "PASS: magnet link - file selection (so)"

block: # magnet link - missing xt should raise
  var caught = false
  try:
    discard parseMagnetLink("magnet:?dn=noinfohash&tr=http://tracker.example.com")
  except ValueError:
    caught = true
  assert caught, "magnet link without xt should raise ValueError"
  echo "PASS: magnet link - missing xt raises ValueError"

block: # magnet link - invalid
  var caught = false
  try:
    discard parseMagnetLink("https://example.com")
  except ValueError:
    caught = true
  assert caught, "non-magnet URI raises ValueError"
  echo "PASS: magnet link - invalid"

echo "ALL METADATA EXCHANGE TESTS PASSED"
