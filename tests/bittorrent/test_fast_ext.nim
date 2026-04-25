## Tests for BEP 6: Fast Extension and BEP 11: PEX and BEP 14: LSD.

import std/[strutils, os, times]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/io/timeouts
import cps/bittorrent/peer_protocol
import cps/bittorrent/fast_extension
import cps/bittorrent/utils
import cps/bittorrent/pex
import cps/bittorrent/lsd
import cps/bittorrent/metainfo
import cps/bittorrent/sha1
import cps/bittorrent/client

proc makeSeedFixture(pieceCount: int = 16): tuple[meta: TorrentMetainfo, data: string] =
  ## Build deterministic metainfo + payload so client starts directly in seeding.
  const PieceLen = 16384
  result.meta.info.name = "fast-ext-compat"
  result.meta.info.pieceLength = PieceLen
  result.meta.info.totalLength = PieceLen * pieceCount
  result.meta.info.files = @[
    FileEntry(path: "payload.bin", length: result.meta.info.totalLength)
  ]

  result.data = newString(result.meta.info.totalLength)
  for i in 0 ..< result.data.len:
    result.data[i] = char((i * 17 + 5) mod 256)

  var piecesRaw = ""
  for p in 0 ..< pieceCount:
    let start = p * PieceLen
    let hash = sha1(result.data[start ..< start + PieceLen])
    for b in hash:
      piecesRaw.add(char(b))
  result.meta.info.pieces = piecesRaw
  result.meta.info.infoHash = sha1(piecesRaw)

proc encodeHandshakeFastMode(infoHash: array[20, byte], peerId: array[20, byte],
                             fastSupported: bool): string =
  ## Handshake builder that controls Fast Extension advertisement explicitly.
  result = newStringOfCap(HandshakeLength)
  result.add(char(19))
  result.add(ProtocolString)
  var reserved: array[8, byte]
  if fastSupported:
    reserved[7] = reserved[7] or 0x04
  for b in reserved:
    result.add(char(b))
  for b in infoHash:
    result.add(char(b))
  for b in peerId:
    result.add(char(b))

proc observeInitialAvailability(fastSupported: bool): CpsFuture[MessageId] {.cps.} =
  ## Connect to a local seeding client and capture the first availability message.
  let fixture = makeSeedFixture()
  let tempDir = "/tmp/cps_bt_fast_compat_" & $epochTime().int64
  var client: TorrentClient = nil
  var clientFut: CpsVoidFuture = nil
  var leecher: TcpStream = nil
  var observed: MessageId = msgChoke
  var foundAvailability = false

  try:
    createDir(tempDir)
    let torrentDir = tempDir / fixture.meta.info.name
    createDir(torrentDir)
    writeFile(torrentDir / fixture.meta.info.files[0].path, fixture.data)

    var cfg = defaultConfig()
    cfg.downloadDir = tempDir
    cfg.listenPort = 0
    cfg.maxPeers = 8
    cfg.enableDht = false
    cfg.enablePex = false
    cfg.enableLsd = false
    cfg.enableUtp = false
    cfg.enableWebSeed = false
    cfg.enableTrackerScrape = false
    cfg.enableHolepunch = false

    client = newTorrentClient(fixture.meta, cfg)
    clientFut = start(client)

    var ready = false
    var spins = 0
    while spins < 200:
      if client.state == csSeeding and client.config.listenPort > 0:
        ready = true
        break
      await cpsSleep(50)
      inc spins
    assert ready, "seeding client did not become ready"

    leecher = await withTimeout(tcpConnect("127.0.0.1", client.config.listenPort.int), 10000)
    let stream = leecher.AsyncStream
    let reader = newBufferedReader(stream, 65536)

    var leecherId: array[20, byte]
    for i in 0 ..< 20:
      leecherId[i] = byte(0xA0 + i)
    await stream.write(encodeHandshakeFastMode(fixture.meta.info.infoHash, leecherId, fastSupported))

    let hsData = await withTimeout(reader.readExact(HandshakeLength), 10000)
    let hs = decodeHandshake(hsData)
    assert hs.infoHash == fixture.meta.info.infoHash

    var msgCount = 0
    while msgCount < 64:
      let lenData = await withTimeout(reader.readExact(4), 10000)
      let msgLen = int(readUint32BE(lenData, 0))
      if msgLen == 0:
        inc msgCount
        continue
      let payload = await withTimeout(reader.readExact(msgLen), 10000)
      let msg = decodeMessage(payload)
      case msg.id
      of msgHaveAll, msgHaveNone, msgBitfield:
        observed = msg.id
        foundAvailability = true
        break
      else:
        discard
      inc msgCount
    assert foundAvailability, "did not observe an availability message"

  finally:
    if leecher != nil:
      leecher.close()
    if client != nil:
      client.stop()
      await cpsSleep(200)
    if clientFut != nil and not clientFut.finished:
      clientFut.cancel()
    if dirExists(tempDir):
      removeDir(tempDir)
  return observed

# === BEP 6: Fast Extension ===

block: # fast extension message encoding/decoding
  let msg = suggestPieceMsg(42)
  assert msg.id == msgSuggestPiece
  assert msg.fastPieceIndex == 42
  let encoded = encodeMessage(msg)
  let lenBytes = readUint32BE(encoded, 0)
  assert lenBytes == 5  # 1 byte id + 4 bytes index
  echo "PASS: suggest piece message"

block: # have all message
  let msg = haveAllMsg()
  assert msg.id == msgHaveAll
  let encoded = encodeMessage(msg)
  let lenBytes = readUint32BE(encoded, 0)
  assert lenBytes == 1  # Just the message ID
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgHaveAll
  echo "PASS: have all message"

block: # have none message
  let msg = haveNoneMsg()
  assert msg.id == msgHaveNone
  let encoded = encodeMessage(msg)
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgHaveNone
  echo "PASS: have none message"

block: # reject request message
  let msg = rejectRequestMsg(10, 16384, 16384)
  assert msg.id == msgRejectRequest
  let encoded = encodeMessage(msg)
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgRejectRequest
  assert decoded.reqIndex == 10
  assert decoded.reqBegin == 16384
  assert decoded.reqLength == 16384
  echo "PASS: reject request message"

block: # allowed fast message
  let msg = allowedFastMsg(7)
  assert msg.id == msgAllowedFast
  let encoded = encodeMessage(msg)
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgAllowedFast
  assert decoded.fastPieceIndex == 7
  echo "PASS: allowed fast message"

block: # fast extension bit in reserved bytes
  var reserved: array[8, byte]
  assert not supportsFastExtension(reserved)
  setFastExtensionBit(reserved)
  assert supportsFastExtension(reserved)
  assert reserved[7] == 0x04
  echo "PASS: fast extension bit in reserved bytes"

block: # allowed fast set generation
  var infoHash: array[20, byte]
  for i in 0 ..< 20:
    infoHash[i] = byte(i)

  let fastSet = generateAllowedFastSet(infoHash, "192.168.1.100", 1000, 10)
  assert fastSet.len == 10, "generates requested number of pieces"

  # All indices should be valid
  for idx in fastSet:
    assert idx < 1000, "index within range"

  # All indices should be unique
  for i in 0 ..< fastSet.len:
    for j in i+1 ..< fastSet.len:
      assert fastSet[i] != fastSet[j], "no duplicates"

  # Same input should give same output (deterministic)
  let fastSet2 = generateAllowedFastSet(infoHash, "192.168.1.100", 1000, 10)
  assert fastSet == fastSet2, "deterministic"

  # Different IP (/24 different) should give different result
  let fastSet3 = generateAllowedFastSet(infoHash, "10.0.0.100", 1000, 10)
  assert fastSet != fastSet3, "different IP gives different set"
  echo "PASS: allowed fast set generation"

# === BEP 11: PEX ===

block: # PEX peer encoding/decoding
  var peers: seq[tuple[ip: string, port: uint16]]
  peers.add(("192.168.1.1", 6881'u16))
  peers.add(("10.0.0.1", 51413'u16))

  let encoded = encodeCompactPeers(peers)
  assert encoded.len == 12  # 6 bytes per peer

  let decoded = decodeCompactPeers(encoded)
  assert decoded.len == 2
  assert decoded[0].ip == "192.168.1.1"
  assert decoded[0].port == 6881
  assert decoded[1].ip == "10.0.0.1"
  assert decoded[1].port == 51413
  echo "PASS: PEX peer encoding/decoding"

block: # PEX message round-trip
  var added: seq[tuple[ip: string, port: uint16]]
  added.add(("1.2.3.4", 6881'u16))
  added.add(("5.6.7.8", 51413'u16))
  let flags = @[0x01'u8, 0x02'u8]  # encryption, seed

  var dropped: seq[tuple[ip: string, port: uint16]]
  dropped.add(("9.10.11.12", 6881'u16))

  let encoded = encodePexMessage(added, flags, dropped)
  let decoded = decodePexMessage(encoded)

  assert decoded.added.len == 2
  assert decoded.added[0].ip == "1.2.3.4"
  assert decoded.added[1].port == 51413
  assert decoded.addedFlags.len == 2
  assert decoded.addedFlags[0] == 0x01
  assert decoded.addedFlags[1] == 0x02
  assert decoded.dropped.len == 1
  assert decoded.dropped[0].ip == "9.10.11.12"
  echo "PASS: PEX message round-trip"

# === BEP 14: LSD ===

block: # LSD announce encoding
  var infoHash: array[20, byte]
  for i in 0 ..< 20:
    infoHash[i] = byte(i * 10)
  let encoded = encodeLsdAnnounce(infoHash, 6881, "mycookie")
  assert encoded.startsWith("BT-SEARCH * HTTP/1.1\r\n")
  assert "Port: 6881\r\n" in encoded
  assert "cookie: mycookie\r\n" in encoded
  assert "Infohash: " in encoded
  echo "PASS: LSD announce encoding"

block: # LSD announce decoding
  var infoHash: array[20, byte]
  for i in 0 ..< 20:
    infoHash[i] = byte(i)
  let encoded = encodeLsdAnnounce(infoHash, 12345, "testcookie")
  let decoded = decodeLsdAnnounce(encoded)

  assert decoded.len == 1
  assert decoded[0].port == 12345
  assert decoded[0].cookie == "testcookie"
  assert decoded[0].infoHash == infoHash
  echo "PASS: LSD announce decoding"

block: # LSD announce round-trip
  var hash1: array[20, byte]
  hash1[0] = 0xAB
  hash1[19] = 0xCD
  let msg = encodeLsdAnnounce(hash1, 6881)
  let announces = decodeLsdAnnounce(msg)
  assert announces.len == 1
  assert announces[0].infoHash[0] == 0xAB
  assert announces[0].infoHash[19] == 0xCD
  assert announces[0].port == 6881
  echo "PASS: LSD announce round-trip"

block: # port and extended message constructors
  let portM = portMsg(6881)
  assert portM.id == msgPort
  assert portM.dhtPort == 6881
  let encoded = encodeMessage(portM)
  let payload = encoded[4..^1]
  let decoded = decodeMessage(payload)
  assert decoded.id == msgPort
  assert decoded.dhtPort == 6881

  let extM = extendedMsg(5, "hello")
  assert extM.id == msgExtended
  assert extM.extId == 5
  assert extM.extPayload == "hello"
  echo "PASS: port and extended message constructors"

block: # non-fast peers must receive bitfield instead of have_all/have_none
  let availability = runCps(observeInitialAvailability(false))
  assert availability == msgBitfield
  echo "PASS: non-fast peers get bitfield availability"

block: # fast peers get HAVE_ALL from a seeder (BEP 6)
  let availability = runCps(observeInitialAvailability(true))
  assert availability == msgHaveAll
  echo "PASS: fast peers get HAVE_ALL from seeder"

echo "ALL FAST EXT / PEX / LSD TESTS PASSED"
