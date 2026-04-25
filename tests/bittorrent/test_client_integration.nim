## Integration tests for the BitTorrent client orchestrator.
##
## Tests the new features: DHT integration, choking algorithm, endgame mode.
## Uses unit-level validation (no network access required).

import std/[tables, times, os, algorithm]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/io/timeouts
import cps/concurrency/channels
import cps/bittorrent/metainfo
import cps/bittorrent/peer_protocol
import cps/bittorrent/pieces
import cps/bittorrent/peer
import cps/bittorrent/extensions
import cps/bittorrent/peerid
import cps/bittorrent/sha1
import cps/bittorrent/utils
import cps/bittorrent/dht
import cps/bittorrent/holepunch
import cps/bittorrent/metadata
import cps/bittorrent/pex
import cps/bittorrent/client

proc makeMetainfoForClientTests(isPrivate = false): TorrentMetainfo =
  ## Build a small deterministic metainfo with two files (1 piece each).
  result.info.name = "client-integration"
  result.info.pieceLength = 16384
  result.info.files = @[
    FileEntry(path: "a.bin", length: 16384),
    FileEntry(path: "b.bin", length: 16384)
  ]
  result.info.totalLength = 32768
  result.info.pieces = newString(40) # 2 pieces * 20-byte SHA1
  result.info.isPrivate = isPrivate
  result.announce = "http://tracker.example/announce"
  result.announceList = @[@["http://tracker.example/announce"]]

proc applyFilePriority(tc: TorrentClient, fileIdx: int, priority: string): CpsVoidFuture {.cps.} =
  await tc.setFilePriority(fileIdx, priority)

proc makeSeedingFixture(pieceCount: int = 16): tuple[meta: TorrentMetainfo, data: string] =
  ## Build deterministic piece-valid metainfo + payload for seeding tests.
  const PieceLen = 16384
  result.meta.info.name = "incoming-seed-regression"
  result.meta.info.pieceLength = PieceLen
  result.meta.info.totalLength = PieceLen * pieceCount
  result.meta.info.files = @[
    FileEntry(path: "payload.bin", length: result.meta.info.totalLength)
  ]

  result.data = newString(result.meta.info.totalLength)
  for i in 0 ..< result.data.len:
    result.data[i] = char((i * 31 + 7) mod 256)

  var piecesRaw = ""
  for p in 0 ..< pieceCount:
    let start = p * PieceLen
    let hash = sha1(result.data[start ..< start + PieceLen])
    for b in hash:
      piecesRaw.add(char(b))
  result.meta.info.pieces = piecesRaw
  result.meta.info.infoHash = sha1(piecesRaw)

proc incomingSeederUploadRegression(): CpsVoidFuture {.cps.} =
  ## Regression: incoming peer should receive availability and download from us.
  let fixture = makeSeedingFixture()
  let tempDir = "/tmp/cps_bt_incoming_seed_" & $epochTime().int64
  var client: TorrentClient = nil
  var clientFut: CpsVoidFuture = nil
  var leecher: TcpStream = nil

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

    leecher = await withTimeout(tcpConnect("127.0.0.1", client.config.listenPort.int), 3000)
    let stream = leecher.AsyncStream
    let reader = newBufferedReader(stream, 65536)

    var leecherId: array[20, byte]
    for i in 0 ..< 20:
      leecherId[i] = byte(0xC0 + i)
    # supportExtensions=false keeps this focused on core BEP 3/6 upload path.
    await stream.write(encodeHandshake(fixture.meta.info.infoHash, leecherId, supportExtensions = false))

    let hsData = await withTimeout(reader.readExact(HandshakeLength), 3000)
    let hs = decodeHandshake(hsData)
    assert hs.infoHash == fixture.meta.info.infoHash

    var allowedPiece = -1
    var sawAvailability = false
    var msgCount = 0
    while msgCount < 64 and (allowedPiece < 0 or not sawAvailability):
      let lenData = await withTimeout(reader.readExact(4), 3000)
      let msgLen = int(readUint32BE(lenData, 0))
      if msgLen == 0:
        inc msgCount
        continue
      let payload = await withTimeout(reader.readExact(msgLen), 3000)
      let msg = decodeMessage(payload)
      case msg.id
      of msgAllowedFast:
        allowedPiece = msg.fastPieceIndex.int
      of msgHaveAll, msgBitfield:
        sawAvailability = true
      else:
        discard
      inc msgCount

    assert sawAvailability, "incoming peer did not receive initial availability message"
    assert allowedPiece >= 0, "did not receive allowed_fast from seeding peer"

    let reqLen = fixture.meta.info.pieceLength
    await stream.write(encodeMessage(requestMsg(uint32(allowedPiece), 0, uint32(reqLen))))

    var receivedPiece = ""
    var gotPiece = false
    var readCount = 0
    while readCount < 32 and not gotPiece:
      let lenData = await withTimeout(reader.readExact(4), 3000)
      let msgLen = int(readUint32BE(lenData, 0))
      if msgLen == 0:
        inc readCount
        continue
      let payload = await withTimeout(reader.readExact(msgLen), 3000)
      let msg = decodeMessage(payload)
      case msg.id
      of msgPiece:
        gotPiece = true
        assert msg.blockIndex.int == allowedPiece
        assert msg.blockBegin == 0
        receivedPiece = msg.blockData
      of msgRejectRequest:
        assert false, "seeding peer rejected a valid allowed_fast request"
      else:
        discard
      inc readCount

    assert gotPiece, "did not receive requested piece block from seeding peer"
    assert receivedPiece.len == reqLen
    let startOff = allowedPiece * reqLen
    let expected = fixture.data[startOff ..< startOff + reqLen]
    assert receivedPiece == expected

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

proc incomingSeederInterestedUnchokeRegression(): CpsVoidFuture {.cps.} =
  ## Regression: fast-capable incoming leecher should see bitfield first,
  ## then fast hints, and receive unchoke+piece after sending interested.
  let fixture = makeSeedingFixture()
  let tempDir = "/tmp/cps_bt_incoming_seed_interest_" & $epochTime().int64
  var client: TorrentClient = nil
  var clientFut: CpsVoidFuture = nil
  var leecher: TcpStream = nil

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

    leecher = await withTimeout(tcpConnect("127.0.0.1", client.config.listenPort.int), 3000)
    let stream = leecher.AsyncStream
    let reader = newBufferedReader(stream, 65536)

    var leecherId: array[20, byte]
    for i in 0 ..< 20:
      leecherId[i] = byte(0xD0 + i)
    await stream.write(encodeHandshake(fixture.meta.info.infoHash, leecherId, supportExtensions = true))

    let hsData = await withTimeout(reader.readExact(HandshakeLength), 3000)
    let hs = decodeHandshake(hsData)
    assert hs.infoHash == fixture.meta.info.infoHash

    var allowedPieces: seq[int]
    var sawBitfield = false
    var sawFastHint = false
    var msgCount = 0
    while msgCount < 96 and (not sawBitfield or not sawFastHint or allowedPieces.len == 0):
      let lenData = await withTimeout(reader.readExact(4), 3000)
      let msgLen = int(readUint32BE(lenData, 0))
      if msgLen == 0:
        inc msgCount
        continue
      let payload = await withTimeout(reader.readExact(msgLen), 3000)
      let msg = decodeMessage(payload)
      case msg.id
      of msgBitfield:
        sawBitfield = true
      of msgHaveAll, msgHaveNone:
        sawFastHint = true
      of msgAllowedFast:
        allowedPieces.add(msg.fastPieceIndex.int)
      else:
        discard
      inc msgCount

    assert sawBitfield, "incoming peer did not receive bitfield availability"
    assert sawFastHint, "incoming peer did not receive have_all/have_none fast hint"
    assert allowedPieces.len > 0, "did not receive allowed_fast hints"

    var requestPiece = -1
    var pi = 0
    while pi < fixture.meta.info.pieceCount:
      if pi notin allowedPieces:
        requestPiece = pi
        break
      inc pi
    assert requestPiece >= 0, "expected at least one non-allowed_fast piece"

    await stream.write(encodeMessage(interestedMsg()))

    let reqLen = fixture.meta.info.pieceLength
    var gotUnchoke = false
    var sentRequest = false
    var gotPiece = false
    var receivedPiece = ""
    var readCount = 0

    while readCount < 96 and not gotPiece:
      let lenData = await withTimeout(reader.readExact(4), 3000)
      let msgLen = int(readUint32BE(lenData, 0))
      if msgLen == 0:
        inc readCount
        continue
      let payload = await withTimeout(reader.readExact(msgLen), 3000)
      let msg = decodeMessage(payload)
      case msg.id
      of msgUnchoke:
        gotUnchoke = true
        if not sentRequest:
          await stream.write(encodeMessage(requestMsg(uint32(requestPiece), 0, uint32(reqLen))))
          sentRequest = true
      of msgPiece:
        if msg.blockIndex.int == requestPiece and msg.blockBegin == 0:
          gotPiece = true
          receivedPiece = msg.blockData
      of msgRejectRequest:
        if msg.reqIndex.int == requestPiece and msg.reqBegin == 0:
          assert false, "seeding peer rejected non-allowed-fast request after unchoke"
      else:
        discard
      inc readCount

    assert gotUnchoke, "seeding peer did not unchoke after interested"
    assert sentRequest, "did not send request after unchoke"
    assert gotPiece, "did not receive requested non-allowed-fast piece block"
    assert receivedPiece.len == reqLen
    let startOff = requestPiece * reqLen
    let expected = fixture.data[startOff ..< startOff + reqLen]
    assert receivedPiece == expected

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

proc makeDhtStopFixture(): TorrentMetainfo =
  ## Minimal metainfo for DHT stop/shutdown regression testing.
  result.info.name = "dht-stop-regression"
  result.info.pieceLength = 16384
  result.info.files = @[FileEntry(path: "payload.bin", length: 16384)]
  result.info.totalLength = 16384
  result.info.pieces = newString(20)
  result.info.infoHash = sha1(result.info.pieces)
  result.announce = ""
  result.announceList = @[]

proc dhtStopRegression(): CpsVoidFuture {.cps.} =
  ## Regression: stopping while DHT workers are running should finish promptly.
  let tempDir = "/tmp/cps_bt_dht_stop_" & $epochTime().int64
  try:
    createDir(tempDir)
    let meta = makeDhtStopFixture()
    var iter = 0
    while iter < 4:
      var cfg = defaultConfig()
      cfg.downloadDir = tempDir
      cfg.listenPort = 0
      cfg.maxPeers = 16
      cfg.enableDht = true
      cfg.enablePex = false
      cfg.enableLsd = false
      cfg.enableUtp = false
      cfg.enableWebSeed = false
      cfg.enableTrackerScrape = false
      cfg.enableHolepunch = false

      let client = newTorrentClient(meta, cfg)
      let clientFut = start(client)

      await cpsSleep(120)
      client.stop()
      await withTimeout(clientFut, 2000)
      assert client.state == csStopped, "client should reach csStopped after stop()"
      iter += 1
  finally:
    if dirExists(tempDir):
      removeDir(tempDir)

# === Endgame mode tests ===

block test_endgame_detection_not_yet:
  ## Not in endgame when many pieces remain.
  var info: TorrentInfo
  info.pieceLength = 262144
  info.totalLength = 262144 * 100
  info.name = "test"
  info.files = @[FileEntry(path: "test", length: info.totalLength)]
  info.pieces = newString(20 * 100)
  let pm = newPieceManager(info)
  assert not pm.inEndgame(), "not endgame with 100 pieces remaining"
  echo "PASS: endgame not triggered early"

block test_endgame_detection_few_pieces_all_requested:
  ## In endgame when <= 5 pieces remain and all blocks requested.
  var info: TorrentInfo
  info.pieceLength = 16384  # 1 block per piece
  info.totalLength = 16384 * 3
  info.name = "test"
  info.files = @[FileEntry(path: "test", length: info.totalLength)]
  info.pieces = newString(20 * 3)
  let pm = newPieceManager(info)
  # Mark first 2 pieces as verified (simulate download progress)
  for blk in pm.pieces[0].blocks.mitems:
    blk.state = bsReceived
  pm.pieces[0].state = psComplete
  pm.completedCount += 1
  pm.pieces[0].receivedBytes = 16384
  discard pm.verifyPiece(0)  # will fail SHA1 check but that's ok
  # Manually set verified for testing
  pm.pieces[0].state = psVerified
  pm.verifiedCount = 1

  pm.pieces[1].state = psVerified
  pm.verifiedCount = 2

  # Piece 2 has all blocks requested (but not received)
  for blk in pm.pieces[2].blocks.mitems:
    blk.state = bsRequested

  assert pm.piecesRemaining == 1
  assert pm.inEndgame(), "endgame with 1 piece remaining, all requested"
  echo "PASS: endgame detection works"

block test_endgame_not_when_unrequested_blocks:
  ## Not in endgame when there are still unrequested blocks.
  var info: TorrentInfo
  info.pieceLength = 32768  # 2 blocks per piece
  info.totalLength = 32768 * 3
  info.name = "test"
  info.files = @[FileEntry(path: "test", length: info.totalLength)]
  info.pieces = newString(20 * 3)
  let pm = newPieceManager(info)

  pm.pieces[0].state = psVerified
  pm.verifiedCount = 1
  pm.pieces[1].state = psVerified
  pm.verifiedCount = 2

  # Piece 2: first block requested, second block empty
  pm.pieces[2].blocks[0].state = bsRequested
  # blocks[1] is still bsEmpty

  assert not pm.inEndgame(), "not endgame when unrequested blocks exist"
  echo "PASS: endgame requires all blocks requested"

block test_endgame_blocks:
  ## getEndgameBlocks returns requested (not received) blocks.
  var info: TorrentInfo
  info.pieceLength = 32768  # 2 blocks per piece
  info.totalLength = 32768 * 2
  info.name = "test"
  info.files = @[FileEntry(path: "test", length: info.totalLength)]
  info.pieces = newString(20 * 2)
  let pm = newPieceManager(info)

  pm.pieces[0].state = psVerified
  pm.verifiedCount = 1

  # Piece 1: all blocks requested
  for blk in pm.pieces[1].blocks.mitems:
    blk.state = bsRequested

  var bf = newBitfield(2)
  setPiece(bf, 0)
  setPiece(bf, 1)

  let blocks = pm.getEndgameBlocks(bf, 10)
  assert blocks.len == 2, "got " & $blocks.len & " endgame blocks"
  assert blocks[0].pieceIdx == 1
  assert blocks[0].offset == 0
  assert blocks[1].pieceIdx == 1
  assert blocks[1].offset == 16384
  echo "PASS: endgame blocks returned correctly"

# === Choking algorithm data structure tests ===

block test_peer_rate_sorting:
  ## PeerRate sorting by rate descending.
  type PeerRate = tuple[key: string, rate: float]
  var peers: seq[PeerRate] = @[
    ("a", 100.0),
    ("b", 500.0),
    ("c", 200.0),
    ("d", 50.0)
  ]
  peers.sort(proc(a, b: PeerRate): int = cmp(b.rate, a.rate))
  assert peers[0].key == "b", "highest rate first"
  assert peers[1].key == "c"
  assert peers[2].key == "a"
  assert peers[3].key == "d", "lowest rate last"
  echo "PASS: peer rate sorting"

# === DHT routing table integration tests ===

block test_dht_routing_table_in_client:
  ## Verify DHT routing table works as expected for client integration.
  let nodeId = generateNodeId()
  var rt = newRoutingTable(nodeId)

  # Add some nodes
  for i in 0 ..< 10:
    var id: NodeId
    id[0] = byte(i + 1)
    discard rt.addNode(DhtNode(
      id: id, ip: "10.0.0." & $i, port: 6881, lastSeen: epochTime()
    ))

  assert rt.totalNodes() > 0, "nodes added to routing table"

  # Find closest to our info hash
  var target: NodeId
  target[0] = 0x05
  let closest = rt.findClosest(target, 3)
  assert closest.len > 0, "found closest nodes"
  echo "PASS: DHT routing table integration"

# === Extension registry with holepunch ===

block test_extension_registry_holepunch:
  ## Extension registry correctly registers ut_holepunch.
  var reg = newExtensionRegistry()
  discard reg.registerExtension(UtMetadataName)
  discard reg.registerExtension(UtPexName)
  discard reg.registerExtension(UtHolepunchName)

  assert reg.supportsExtension(UtHolepunchName) == false  # Not yet received from peer
  let localId = reg.localId(UtHolepunchName)
  assert localId > 0, "holepunch has local ID"

  # Simulate peer extension handshake that also supports holepunch
  let payload = encodeExtHandshake(reg)
  var peerReg = newExtensionRegistry()
  discard peerReg.registerExtension(UtMetadataName)
  discard peerReg.registerExtension(UtPexName)
  discard peerReg.registerExtension(UtHolepunchName)
  peerReg.decodeExtHandshake(payload)

  assert peerReg.supportsExtension(UtHolepunchName), "peer supports holepunch"
  echo "PASS: extension registry holepunch"

block test_extension_registry_remote_id_reverse_lookup:
  ## Incoming ext IDs are remote IDs, which can differ from our local IDs.
  var localReg = newExtensionRegistry()
  discard localReg.registerExtension(UtMetadataName)   # local 1
  discard localReg.registerExtension(UtPexName)        # local 2
  discard localReg.registerExtension(UtHolepunchName)  # local 3

  var remoteReg = newExtensionRegistry()
  discard remoteReg.registerExtension(UtPexName)        # remote 1
  discard remoteReg.registerExtension(UtHolepunchName)  # remote 2
  discard remoteReg.registerExtension(UtMetadataName)    # remote 3
  let remotePayload = encodeExtHandshake(remoteReg)
  localReg.decodeExtHandshake(remotePayload)

  let remoteHpId = remoteReg.localId(UtHolepunchName)
  assert localReg.remoteId(UtHolepunchName) == remoteHpId
  assert localReg.lookupRemoteName(remoteHpId) == UtHolepunchName
  assert localReg.lookupLocalName(remoteHpId) != UtHolepunchName
  echo "PASS: extension registry remote reverse lookup"

# === Piece selection with rarest-first ===

block test_rarest_first_selection:
  ## Rarest-first piece selection prefers pieces with fewer peers.
  var info: TorrentInfo
  info.pieceLength = 16384
  info.totalLength = 16384 * 5
  info.name = "test"
  info.files = @[FileEntry(path: "test", length: info.totalLength)]
  info.pieces = newString(20 * 5)
  let pm = newPieceManager(info)

  # Peer has all pieces
  var bf = newBitfield(5)
  for i in 0 ..< 5:
    setPiece(bf, i)

  # Availability: piece 2 is rarest (1 peer has it), piece 0 is most common (5 peers)
  var avail = @[5, 3, 1, 4, 2]

  let selected = pm.selectPiece(bf, avail)
  assert selected == 2, "rarest piece selected: " & $selected
  echo "PASS: rarest-first piece selection"

block test_partial_piece_preferred:
  ## Partially downloaded pieces are preferred over new ones.
  var info: TorrentInfo
  info.pieceLength = 32768
  info.totalLength = 32768 * 3
  info.name = "test"
  info.files = @[FileEntry(path: "test", length: info.totalLength)]
  info.pieces = newString(20 * 3)
  let pm = newPieceManager(info)

  # Make piece 1 partially downloaded
  pm.pieces[1].blocks[0].state = bsReceived
  pm.pieces[1].receivedBytes = 16384
  pm.pieces[1].state = psPartial

  var bf = newBitfield(3)
  for i in 0 ..< 3:
    setPiece(bf, i)

  var avail = @[1, 5, 1]  # Piece 1 is most common but partial

  let selected = pm.selectPiece(bf, avail)
  assert selected == 1, "partial piece preferred: " & $selected
  echo "PASS: partial piece preferred"

# === Piece cancel after verification (endgame) ===

block test_pieces_remaining_count:
  var info: TorrentInfo
  info.pieceLength = 16384
  info.totalLength = 16384 * 10
  info.name = "test"
  info.files = @[FileEntry(path: "test", length: info.totalLength)]
  info.pieces = newString(20 * 10)
  let pm = newPieceManager(info)

  assert pm.piecesRemaining() == 10

  pm.pieces[0].state = psVerified
  pm.verifiedCount = 1
  assert pm.piecesRemaining() == 9

  pm.pieces[1].state = psVerified
  pm.verifiedCount = 2
  assert pm.piecesRemaining() == 8
  echo "PASS: pieces remaining count"

block test_private_torrent_forced_protocol_gating:
  ## BEP 27: private torrents must force decentralized protocol toggles off.
  var cfg = defaultConfig()
  cfg.enableDht = true
  cfg.enablePex = true
  cfg.enableLsd = true
  cfg.enableHolepunch = true
  let tc = newTorrentClient(makeMetainfoForClientTests(isPrivate = true), cfg)
  assert tc.isPrivate
  assert not tc.dhtEnabled
  assert not tc.config.enableDht
  assert not tc.config.enablePex
  assert not tc.config.enableLsd
  assert not tc.config.enableHolepunch
  echo "PASS: private torrent protocol gating"

block test_file_priority_scheduler_masks:
  ## BEP 53: file priorities should drive selected/high-priority masks.
  let tc = newTorrentClient(makeMetainfoForClientTests(), defaultConfig())
  assert tc.selectedPiecesMask.len == 2
  assert tc.selectedPiecesMask[0] and tc.selectedPiecesMask[1]
  assert not tc.highPriorityPiecesMask[0]
  assert not tc.highPriorityPiecesMask[1]

  runCps(applyFilePriority(tc, 1, "skip"))
  assert tc.selectedPiecesMask[0]
  assert not tc.selectedPiecesMask[1]
  assert not tc.highPriorityPiecesMask[0]
  assert not tc.highPriorityPiecesMask[1]

  runCps(applyFilePriority(tc, 0, "high"))
  assert tc.selectedPiecesMask[0]
  assert not tc.selectedPiecesMask[1]
  assert tc.highPriorityPiecesMask[0]
  assert not tc.highPriorityPiecesMask[1]

  runCps(applyFilePriority(tc, 1, "normal"))
  assert tc.selectedPiecesMask[0]
  assert tc.selectedPiecesMask[1]
  assert tc.highPriorityPiecesMask[0]
  assert not tc.highPriorityPiecesMask[1]
  echo "PASS: file priority scheduler masks"

block test_incoming_seeder_upload_regression:
  runCps(incomingSeederUploadRegression())
  echo "PASS: incoming seeding upload regression"

block test_incoming_seeder_interested_unchoke_regression:
  runCps(incomingSeederInterestedUnchokeRegression())
  echo "PASS: incoming seeding interested/unchoke regression"

block test_dht_stop_regression:
  runCps(dhtStopRegression())
  echo "PASS: DHT stop regression"

block test_dht_pending_key_includes_endpoint:
  ## Regression: dhtPendingQueries was keyed by transactionId only, allowing
  ## a spoofed response from a different endpoint to match. Now uses composite key.
  let key1 = dhtPendingKey("\x00\x01", "192.168.1.1", 6881)
  let key2 = dhtPendingKey("\x00\x01", "192.168.1.2", 6881)
  let key3 = dhtPendingKey("\x00\x01", "192.168.1.1", 6882)
  let key4 = dhtPendingKey("\x00\x02", "192.168.1.1", 6881)
  # Same transId but different endpoints => different keys
  assert key1 != key2, "different IP should produce different key"
  assert key1 != key3, "different port should produce different key"
  assert key1 != key4, "different transId should produce different key"
  # Same everything => same key
  let key1b = dhtPendingKey("\x00\x01", "192.168.1.1", 6881)
  assert key1 == key1b, "identical inputs should produce identical key"
  echo "PASS: DHT pending key includes sender endpoint"

block test_allowed_fast_set_separation:
  ## Regression: allowedFastSet mixed inbound (remote told us) and outbound
  ## (we told remote) pieces. Now they are separate fields.
  var peer: PeerConn
  new(peer)
  peer.peerSupportsFastExt = true

  # Simulate remote peer sending us ALLOWED_FAST for pieces 3, 7
  peer.allowedFastSet.add(3'u32)
  peer.allowedFastSet.add(7'u32)

  # Simulate us sending ALLOWED_FAST for pieces 0, 1 to remote
  peer.outboundAllowedFast.add(0'u32)
  peer.outboundAllowedFast.add(1'u32)

  # Inbound set: pieces remote allows us to request while choked
  assert 3'u32 in peer.allowedFastSet
  assert 7'u32 in peer.allowedFastSet
  assert 0'u32 notin peer.allowedFastSet
  assert 1'u32 notin peer.allowedFastSet

  # Outbound set: pieces we allow remote to request while choked
  assert 0'u32 in peer.outboundAllowedFast
  assert 1'u32 in peer.outboundAllowedFast
  assert 3'u32 notin peer.outboundAllowedFast
  assert 7'u32 notin peer.outboundAllowedFast
  echo "PASS: allowedFastSet inbound/outbound separation"

echo ""
echo "All client integration tests passed!"
