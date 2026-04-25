## Tests for torrent metainfo parsing.

import std/strutils
import cps/bittorrent/bencode
import cps/bittorrent/metainfo
import cps/bittorrent/sha1

# Create a minimal valid torrent and verify parsing
block testSingleFileTorrent:
  let info = bDict()
  info["name"] = bStr("test_file.txt")
  info["piece length"] = bInt(262144)
  info["length"] = bInt(1000)
  # Create 1 piece hash (20 bytes)
  var fakeHash = ""
  for i in 0 ..< 20:
    fakeHash.add(char(i))
  info["pieces"] = bStr(fakeHash)

  let root = bDict()
  root["announce"] = bStr("http://tracker.example.com/announce")
  root["info"] = info
  root["comment"] = bStr("test torrent")
  root["created by"] = bStr("test suite")
  root["creation date"] = bInt(1700000000)

  let encoded = encode(root)
  let meta = parseTorrent(encoded)

  assert meta.announce == "http://tracker.example.com/announce"
  assert meta.comment == "test torrent"
  assert meta.createdBy == "test suite"
  assert meta.creationDate == 1700000000

  assert meta.info.name == "test_file.txt"
  assert meta.info.pieceLength == 262144
  assert meta.info.totalLength == 1000
  assert meta.info.files.len == 1
  assert meta.info.files[0].path == "test_file.txt"
  assert meta.info.files[0].length == 1000
  assert not meta.info.isPrivate

  # Info hash should be SHA1 of the raw bencoded info dict
  let rawInfo = extractRawValue(encoded, "info")
  let expectedHash = sha1(rawInfo)
  assert meta.info.infoHash == expectedHash

  echo "PASS: single file torrent"

# Multi-file torrent
block testMultiFileTorrent:
  let info = bDict()
  info["name"] = bStr("my_album")
  info["piece length"] = bInt(262144)

  let file1 = bDict()
  file1["length"] = bInt(5000)
  file1["path"] = bList(bStr("track01.mp3"))

  let file2 = bDict()
  file2["length"] = bInt(3000)
  file2["path"] = bList(bStr("subdir"), bStr("track02.mp3"))

  info["files"] = bList(file1, file2)

  # Need ceil(8000/262144) = 1 piece hash
  var fakeHash = ""
  for i in 0 ..< 20:
    fakeHash.add(char(i))
  info["pieces"] = bStr(fakeHash)

  let root = bDict()
  root["announce"] = bStr("http://tracker.example.com/announce")
  root["info"] = info

  let meta = parseTorrent(encode(root))
  assert meta.info.name == "my_album"
  assert meta.info.totalLength == 8000
  assert meta.info.files.len == 2
  assert meta.info.files[0].path == "track01.mp3"
  assert meta.info.files[0].length == 5000
  assert meta.info.files[1].path == "subdir/track02.mp3"
  assert meta.info.files[1].length == 3000

  echo "PASS: multi-file torrent"

# Private flag
block testPrivateFlag:
  let info = bDict()
  info["name"] = bStr("private.txt")
  info["piece length"] = bInt(262144)
  info["length"] = bInt(100)
  var fakeHash = ""
  for i in 0 ..< 20: fakeHash.add(char(i))
  info["pieces"] = bStr(fakeHash)
  info["private"] = bInt(1)

  let root = bDict()
  root["announce"] = bStr("http://private-tracker.example.com/announce")
  root["info"] = info

  let meta = parseTorrent(encode(root))
  assert meta.info.isPrivate

  echo "PASS: private flag"

# Announce list (BEP 12)
block testAnnounceList:
  let info = bDict()
  info["name"] = bStr("test")
  info["piece length"] = bInt(262144)
  info["length"] = bInt(100)
  var fakeHash = ""
  for i in 0 ..< 20: fakeHash.add(char(i))
  info["pieces"] = bStr(fakeHash)

  let root = bDict()
  root["announce"] = bStr("http://primary.example.com/announce")
  root["announce-list"] = bList(
    bList(bStr("http://primary.example.com/announce"), bStr("http://backup.example.com/announce")),
    bList(bStr("udp://tracker2.example.com:6969/announce"))
  )
  root["info"] = info

  let meta = parseTorrent(encode(root))
  assert meta.announceList.len == 2
  assert meta.announceList[0].len == 2
  assert meta.announceList[0][0] == "http://primary.example.com/announce"
  assert meta.announceList[1].len == 1
  assert meta.announceList[1][0] == "udp://tracker2.example.com:6969/announce"

  echo "PASS: announce list"

# Piece count and piece hash
block testPieceHelpers:
  let info = bDict()
  info["name"] = bStr("test")
  info["piece length"] = bInt(100)
  info["length"] = bInt(250)  # 3 pieces: 100, 100, 50
  var piecesStr = ""
  for p in 0 ..< 3:
    for i in 0 ..< 20:
      piecesStr.add(char(p * 20 + i))
  info["pieces"] = bStr(piecesStr)

  let root = bDict()
  root["announce"] = bStr("http://example.com")
  root["info"] = info

  let meta = parseTorrent(encode(root))
  assert meta.info.pieceCount == 3
  assert meta.info.pieceSize(0) == 100
  assert meta.info.pieceSize(1) == 100
  assert meta.info.pieceSize(2) == 50
  assert meta.info.lastPieceLength == 50

  let h0 = meta.info.pieceHash(0)
  assert h0[0] == 0
  let h2 = meta.info.pieceHash(2)
  assert h2[0] == 40

  echo "PASS: piece helpers"

# Info hash encoding
block testInfoHashEncoding:
  let info = bDict()
  info["name"] = bStr("test")
  info["piece length"] = bInt(262144)
  info["length"] = bInt(100)
  var fakeHash = ""
  for i in 0 ..< 20: fakeHash.add(char(i))
  info["pieces"] = bStr(fakeHash)

  let root = bDict()
  root["announce"] = bStr("http://example.com")
  root["info"] = info

  let meta = parseTorrent(encode(root))

  let hex = meta.info.infoHashHex
  assert hex.len == 40
  for c in hex:
    assert c in {'0'..'9', 'a'..'f'}

  let urlEnc = meta.info.infoHashUrlEncoded
  assert urlEnc.len == 60  # 20 * 3 (%XX)
  assert urlEnc.startsWith("%")

  echo "PASS: info hash encoding"

# Error handling
block testMissingInfo:
  let root = bDict()
  root["announce"] = bStr("http://example.com")

  var caught = false
  try:
    discard parseTorrent(encode(root))
  except MetainfoError:
    caught = true
  assert caught
  echo "PASS: missing info dict error"

block testInvalidPiecesLength:
  let info = bDict()
  info["name"] = bStr("test")
  info["piece length"] = bInt(262144)
  info["length"] = bInt(100)
  info["pieces"] = bStr("not_multiple_of_20")

  let root = bDict()
  root["announce"] = bStr("http://example.com")
  root["info"] = info

  var caught = false
  try:
    discard parseTorrent(encode(root))
  except MetainfoError:
    caught = true
  assert caught
  echo "PASS: invalid pieces length error"

echo "ALL METAINFO TESTS PASSED"
