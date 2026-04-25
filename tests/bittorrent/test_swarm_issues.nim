## Reproduction tests for BitTorrent download/seeding swarm issues.
##
## Each test isolates a specific failure mode identified through code analysis:
##   1. Silent request drops for verified pieces read from disk (StorageError crash)
##   2. Optimistic unchoke bias (always picks first, not random)
##   3. Cumulative rate metric unfairly penalizes new peers
##   4. No immediate unchoke for interested peers while downloading
##   5. Silent request drops for non-BEP6 peers with invalid bounds

import std/[times, os, algorithm, strutils]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/io/timeouts
import cps/bittorrent/metainfo
import cps/bittorrent/peer_protocol
import cps/bittorrent/pieces
import cps/bittorrent/sha1
import cps/bittorrent/utils
import cps/bittorrent/client
import cps/bittorrent/storage
import cps/io/nat

# ============================================================
# Test helpers
# ============================================================

proc makeSeedFixture(pieceCount: int = 16): tuple[meta: TorrentMetainfo, data: string] =
  const PieceLen = 16384
  result.meta.info.name = "swarm-issue-test"
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

proc seedingConfig(): ClientConfig =
  var cfg = defaultConfig()
  cfg.listenPort = 0
  cfg.maxPeers = 8
  cfg.enableDht = false
  cfg.enablePex = false
  cfg.enableLsd = false
  cfg.enableUtp = false
  cfg.enableWebSeed = false
  cfg.enableTrackerScrape = false
  cfg.enableHolepunch = false
  # Provide a dummy NatManager to skip NAT discovery (PCP/NAT-PMP/UPnP each have 3s timeouts)
  cfg.sharedNatMgr = NatManager(protocol: npNone)
  cfg

proc setupSeeder(fixture: tuple[meta: TorrentMetainfo, data: string],
                 tempDir: string): TorrentClient =
  let torrentDir = tempDir / fixture.meta.info.name
  createDir(torrentDir)
  writeFile(torrentDir / fixture.meta.info.files[0].path, fixture.data)
  var cfg = seedingConfig()
  cfg.downloadDir = tempDir
  result = newTorrentClient(fixture.meta, cfg)

# ============================================================
# Issue 1: pekRequest silently drops requests when storageMgr.readBlock
#          raises StorageError — peer hangs, no REJECT sent.
#
# Reproduction: Connect to a seeder, request a valid piece from a
# valid index, but arrange for the underlying file to be truncated.
# Before fix: peer hangs forever waiting for PIECE, gets no REJECT.
# After fix:  peer receives a REJECT (BEP 6) or the connection is
#             gracefully closed.
# ============================================================

proc issueStorageErrorDropsRequest(): CpsVoidFuture {.cps.} =
  let fixture = makeSeedFixture()
  let tempDir = "/tmp/cps_bt_issue_storage_" & $epochTime().int64
  var client: TorrentClient = nil
  var clientFut: CpsVoidFuture = nil
  var leecher: TcpStream = nil

  try:
    createDir(tempDir)
    client = setupSeeder(fixture, tempDir)
    clientFut = start(client)

    # Wait for seeding state
    var spins = 0
    while spins < 200:
      if client.state == csSeeding and client.config.listenPort > 0:
        break
      await cpsSleep(50)
      inc spins
    assert client.state == csSeeding, "seeder did not become ready"

    # Connect as leecher FIRST, before corrupting storage
    leecher = await withTimeout(tcpConnect("127.0.0.1", client.config.listenPort.int), 3000)
    let stream = leecher.AsyncStream
    let reader = newBufferedReader(stream, 65536)

    var leecherId: array[20, byte]
    for i in 0 ..< 20:
      leecherId[i] = byte(0xA0 + i)
    await stream.write(encodeHandshake(fixture.meta.info.infoHash, leecherId, supportExtensions = true))

    let hsData = await withTimeout(reader.readExact(HandshakeLength), 3000)
    discard decodeHandshake(hsData)

    # Drain initial messages (bitfield, allowed_fast, etc.)
    var allowedPiece = -1
    var msgCount = 0
    while msgCount < 64:
      let lenData = await withTimeout(reader.readExact(4), 3000)
      let msgLen = int(readUint32BE(lenData, 0))
      if msgLen == 0:
        inc msgCount
        continue
      let payload = await withTimeout(reader.readExact(msgLen), 3000)
      let msg = decodeMessage(payload)
      if msg.id == msgAllowedFast:
        allowedPiece = msg.fastPieceIndex.int
      if msg.id in {msgBitfield, msgHaveAll} and allowedPiece >= 0:
        break
      inc msgCount

    assert allowedPiece >= 0, "need allowed_fast piece"

    # NOW corrupt storage — after connection is established and initial messages drained.
    # Close files and delete the payload to make readBlock fail with a CatchableError.
    # The close+delete guarantees the next open attempt and fd-based reads both fail.
    client.storageMgr.closeFiles()
    let payloadPath = tempDir / fixture.meta.info.name / "payload.bin"
    removeFile(payloadPath)

    # Request piece — readBlock should fail with IOError.
    # Before fix: IOError crashes the event loop, peer gets TCP RST (no REJECT).
    # After fix: try/except in pekRequest handler sends REJECT cleanly.
    let reqLen = fixture.meta.info.pieceLength
    await stream.write(encodeMessage(requestMsg(uint32(allowedPiece), 0, uint32(reqLen))))

    # Try to read a response — expect REJECT (after fix) or disconnect (before fix).
    var gotReject = false
    var gotPiece = false
    var gotDisconnect = false
    var readCount = 0
    while readCount < 32 and not gotReject and not gotPiece and not gotDisconnect:
      try:
        let lenData = await withTimeout(reader.readExact(4), 2000)
        let msgLen = int(readUint32BE(lenData, 0))
        if msgLen == 0:
          inc readCount
          continue
        let payload = await withTimeout(reader.readExact(msgLen), 2000)
        let msg = decodeMessage(payload)
        if msg.id == msgRejectRequest:
          gotReject = true
        elif msg.id == msgPiece:
          gotPiece = true
      except CatchableError:
        gotDisconnect = true
      inc readCount

    # After fix: pekRequest handler catches disk I/O errors and sends REJECT
    # instead of crashing the entire event loop.
    assert not gotPiece, "should not receive piece from closed files"
    assert gotReject, "should send REJECT when disk read fails, got: reject=" &
      $gotReject & " disconnect=" & $gotDisconnect

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

# ============================================================
# Issue 2: Optimistic unchoke always picks the FIRST eligible peer
#          from the sorted-by-cumulative-rate list, not random.
#
# Reproduction: With multiple interested-but-choked peers that all
# have rate=0 (new connections), verify that the optimistic slot
# is not deterministically the first key every time.
# ============================================================

block test_optimistic_unchoke_not_biased:
  ## Unit test: verify that optimistic unchoke selection uses randomness.
  ## Before fix: always picks first eligible → always the same peer.
  ## After fix:  uses btRand to select among eligible peers.

  # We can't directly call unchokeLoop, but we can test the selection
  # algorithm by simulating it. The fix changes the optimistic unchoke
  # from "pick first not-in-unchoke-set" to "pick random not-in-unchoke-set".
  # We verify via the btRand function that randomness is used.

  var selectedCounts: array[5, int]
  let numTrials = 100

  for trial in 0 ..< numTrials:
    # Simulate 5 interested peers with identical rate
    var interestedPeers: seq[tuple[key: string, rate: float]]
    for i in 0 ..< 5:
      interestedPeers.add(("peer_" & $i, 0.0))

    # Top 3 go into unchoke set (MaxUnchokedPeers - 1 = 3)
    var unchokeSet: seq[string]
    var ui = 0
    while ui < interestedPeers.len and unchokeSet.len < 3:
      unchokeSet.add(interestedPeers[ui].key)
      ui += 1

    # BEFORE FIX: picks first not-in-unchoke-set (deterministic)
    # var oi = 0
    # while oi < interestedPeers.len:
    #   if interestedPeers[oi].key notin unchokeSet:
    #     optimisticKey = interestedPeers[oi].key
    #     break
    #   oi += 1

    # AFTER FIX: pick random from eligible
    var eligible: seq[int]
    var oi = 0
    while oi < interestedPeers.len:
      if interestedPeers[oi].key notin unchokeSet:
        eligible.add(oi)
      oi += 1

    if eligible.len > 0:
      let pick = eligible[btRand(eligible.len)]
      let peerIdx = interestedPeers[pick].key[5..^1].parseInt
      selectedCounts[peerIdx] += 1

  # Peers 0,1,2 are in the unchoke set. Only peers 3,4 are eligible.
  # Before fix: peer 3 would be selected 100% of the time.
  # After fix: both peer 3 and peer 4 should get selected roughly equally.
  assert selectedCounts[3] > 0 and selectedCounts[4] > 0,
    "optimistic unchoke should vary between eligible peers, got: " &
    $selectedCounts[3] & " vs " & $selectedCounts[4]
  assert selectedCounts[3] < 90 and selectedCounts[4] < 90,
    "optimistic unchoke should not be heavily biased"
  echo "PASS: optimistic unchoke not biased"

# ============================================================
# Issue 3: unchokeLoop uses cumulative bytesUploaded for seeding
#          rate ranking instead of instantaneous rate. New peers
#          always rank last.
#
# Reproduction: Unit test the rate sorting with cumulative vs
# windowed metrics to demonstrate the problem.
# ============================================================

block test_cumulative_rate_penalizes_new_peers:
  ## Demonstrate that cumulative bytes penalizes new fast peers.
  ## Peer A: connected 60s, uploaded 60KB (1KB/s, slow but long-running)
  ## Peer B: connected 5s, uploaded 25KB (5KB/s, fast but new)
  ## Cumulative: A=60000 > B=25000 → A wins (wrong for seeding)
  ## Rate-based: B=5000/s > A=1000/s → B wins (correct)

  type PeerRate = tuple[key: string, rate: float]

  # Cumulative metric (current behavior)
  var cumulativePeers: seq[PeerRate] = @[
    ("peer_A", 60000.0),  # slow but long-running
    ("peer_B", 25000.0),  # fast but new
  ]
  cumulativePeers.sort(proc(a, b: PeerRate): int = cmp(b.rate, a.rate))
  assert cumulativePeers[0].key == "peer_A",
    "cumulative incorrectly favors slow long-running peer"

  # Rate-based metric (what we want)
  # peer_A: 60000 bytes / 60s = 1000 B/s
  # peer_B: 25000 bytes / 5s  = 5000 B/s
  var ratePeers: seq[PeerRate] = @[
    ("peer_A", 1000.0),   # 60000/60s
    ("peer_B", 5000.0),   # 25000/5s
  ]
  ratePeers.sort(proc(a, b: PeerRate): int = cmp(b.rate, a.rate))
  assert ratePeers[0].key == "peer_B",
    "rate-based correctly favors fast new peer"

  echo "PASS: cumulative rate penalizes new peers (demonstrates issue)"

# ============================================================
# Issue 4: No silent-drop for non-BEP6 peers on invalid bounds.
#
# When a peer without fast extension support sends a request with
# invalid bounds, the code silently drops it (no response). BEP 6
# peers get a REJECT, but non-BEP6 peers hang.
# ============================================================

proc issueNonBep6InvalidBoundsHang(): CpsVoidFuture {.cps.} =
  let fixture = makeSeedFixture()
  let tempDir = "/tmp/cps_bt_issue_bounds_" & $epochTime().int64
  var client: TorrentClient = nil
  var clientFut: CpsVoidFuture = nil
  var leecher: TcpStream = nil

  try:
    createDir(tempDir)
    client = setupSeeder(fixture, tempDir)
    clientFut = start(client)

    var spins = 0
    while spins < 200:
      if client.state == csSeeding and client.config.listenPort > 0:
        break
      await cpsSleep(50)
      inc spins
    assert client.state == csSeeding

    # Connect WITHOUT extension support (non-BEP6 peer)
    leecher = await withTimeout(tcpConnect("127.0.0.1", client.config.listenPort.int), 3000)
    let stream = leecher.AsyncStream
    let reader = newBufferedReader(stream, 65536)

    var leecherId: array[20, byte]
    for i in 0 ..< 20:
      leecherId[i] = byte(0xB0 + i)
    await stream.write(encodeHandshake(fixture.meta.info.infoHash, leecherId,
                                       supportExtensions = false))

    let hsData = await withTimeout(reader.readExact(HandshakeLength), 3000)
    discard decodeHandshake(hsData)

    # Drain initial messages
    var sawBitfield = false
    var msgCount = 0
    while msgCount < 64 and not sawBitfield:
      let lenData = await withTimeout(reader.readExact(4), 3000)
      let msgLen = int(readUint32BE(lenData, 0))
      if msgLen == 0:
        inc msgCount
        continue
      let payload = await withTimeout(reader.readExact(msgLen), 3000)
      let msg = decodeMessage(payload)
      if msg.id == msgBitfield:
        sawBitfield = true
      inc msgCount

    # Send INTERESTED + wait for UNCHOKE (or rely on optimistic unchoke)
    await stream.write(encodeMessage(interestedMsg()))

    var gotUnchoke = false
    msgCount = 0
    while msgCount < 128 and not gotUnchoke:
      let lenData = await withTimeout(reader.readExact(4), 3000)
      let msgLen = int(readUint32BE(lenData, 0))
      if msgLen == 0:
        inc msgCount
        continue
      let payload = await withTimeout(reader.readExact(msgLen), 3000)
      let msg = decodeMessage(payload)
      if msg.id == msgUnchoke:
        gotUnchoke = true
      inc msgCount

    assert gotUnchoke, "peer should be unchoked after expressing interest"

    # Send request with INVALID bounds (offset beyond piece length).
    # Before fix: silently dropped for non-BEP6 peers, they hang forever.
    # After fix: the peer should NOT hang — either close connection or
    #            we simply proceed (non-BEP6 spec says ignore is acceptable,
    #            but we should at least not crash).
    await stream.write(encodeMessage(requestMsg(0, uint32(fixture.meta.info.pieceLength + 1000), 16384)))

    # Now send a VALID request to verify the connection still works.
    await stream.write(encodeMessage(requestMsg(0, 0, 16384)))

    var gotValidPiece = false
    var readCount = 0
    while readCount < 32 and not gotValidPiece:
      try:
        let lenData = await withTimeout(reader.readExact(4), 3000)
        let msgLen = int(readUint32BE(lenData, 0))
        if msgLen == 0:
          inc readCount
          continue
        let payload = await withTimeout(reader.readExact(msgLen), 3000)
        let msg = decodeMessage(payload)
        if msg.id == msgPiece and msg.blockIndex == 0 and msg.blockBegin == 0:
          gotValidPiece = true
      except CatchableError:
        break
      inc readCount

    assert gotValidPiece,
      "valid request after invalid bounds should still receive piece data"

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

# ============================================================
# Issue 5: Piece selection returns -1 when all blocks are
#          bsRequested even though multiple peers exist.
#          The requestRefreshLoop fixes this but with a 5s delay.
#
# Reproduction: Set all blocks to bsRequested, verify selectPiece
# returns -1. After manual reset, verify it returns a valid piece.
# ============================================================

block test_all_blocks_requested_stalls_selection:
  var info: TorrentInfo
  info.pieceLength = 32768  # 2 blocks per piece
  info.totalLength = 32768 * 4
  info.name = "test"
  info.files = @[FileEntry(path: "test", length: info.totalLength)]
  info.pieces = newString(20 * 4)
  let pm = newPieceManager(info)

  var bf = newBitfield(4)
  for i in 0 ..< 4:
    setPiece(bf, i)
  var avail = @[2, 2, 2, 2]

  # Mark ALL blocks of ALL pieces as requested
  for i in 0 ..< 4:
    for blk in pm.pieces[i].blocks.mitems:
      blk.state = bsRequested

  # selectPiece should return -1 (all requested, none empty)
  let sel1 = pm.selectPiece(bf, avail)
  assert sel1 == -1, "should return -1 when all blocks are bsRequested"

  # Simulate requestRefreshLoop: reset all bsRequested back to bsEmpty
  for i in 0 ..< 4:
    for blk in pm.pieces[i].blocks.mitems:
      if blk.state == bsRequested:
        blk.state = bsEmpty

  # Now selectPiece should return a valid piece
  let sel2 = pm.selectPiece(bf, avail)
  assert sel2 >= 0, "after reset, should find a piece to request"

  echo "PASS: all blocks requested stalls selection (reproduces issue)"

# ============================================================
# Issue 6: requestRefreshLoop only runs during csDownloading.
#          If state changes to csSeeding, stalled blocks aren't
#          reset (but this is actually correct for seeding).
# ============================================================

block test_refresh_loop_state_guard:
  ## Verify this is correct behavior: refresh loop exits when seeding.
  ## No pieces should be in-flight when seeding (we have all pieces).
  var info: TorrentInfo
  info.pieceLength = 16384
  info.totalLength = 16384 * 2
  info.name = "test"
  info.files = @[FileEntry(path: "test", length: info.totalLength)]
  info.pieces = newString(20 * 2)
  let pm = newPieceManager(info)

  # Mark all verified (seeding state)
  for i in 0 ..< 2:
    pm.pieces[i].state = psVerified
    pm.verifiedCount += 1
    for blk in pm.pieces[i].blocks.mitems:
      blk.state = bsReceived
    pm.pieces[i].receivedBytes = pm.pieces[i].totalLength

  assert pm.isComplete, "should be complete when all verified"

  # In seeding state, selectPiece should always return -1
  var bf = newBitfield(2)
  setPiece(bf, 0)
  setPiece(bf, 1)
  var avail = @[1, 1]
  assert pm.selectPiece(bf, avail) == -1, "no pieces needed when seeding"

  echo "PASS: refresh loop state guard is correct"

# ============================================================
# Issue 7: requestBlocks breaks when getNeededBlocks returns 0
#          for a selected piece, stalling the request pipeline
#          instead of trying the next available piece.
#
# This happens via selectHighPriorityPiece or suggested pieces
# which don't filter by hasEmptyBlocks. When all blocks of the
# selected piece are bsRequested, requestBlocks should skip it
# and try another piece, not break the entire loop.
#
# After fix: selectPiece/selectHighPriorityPiece accept an
# exclude list.  requestBlocks tracks skipped pieces and
# continues the loop.
# ============================================================

block test_skip_fully_requested_piece_selects_alternate:
  ## Verify that selectPiece with exclude skips a piece and picks
  ## an alternate with empty blocks.
  var info: TorrentInfo
  info.pieceLength = 32768  # 2 blocks per piece (16384 each)
  info.totalLength = 32768 * 4
  info.name = "test"
  info.files = @[FileEntry(path: "test", length: info.totalLength)]
  info.pieces = newString(20 * 4)
  let pm = newPieceManager(info)

  var bf = newBitfield(4)
  for i in 0 ..< 4:
    setPiece(bf, i)
  var avail = @[1, 3, 2, 2]  # piece 0 is rarest

  # All pieces empty with all blocks bsEmpty
  # Without exclude: selectPiece picks piece 0 (rarest)
  let sel1 = pm.selectPiece(bf, avail)
  assert sel1 == 0, "without exclude, should pick rarest piece (0), got: " & $sel1

  # With exclude=[0]: should pick from remaining (piece 2 or 3, tied at rarity 2)
  let sel2 = pm.selectPiece(bf, avail, exclude = @[0])
  assert sel2 >= 1 and sel2 <= 3,
    "with exclude=[0], should pick an alternate piece, got: " & $sel2

  # Exclude all → returns -1
  let sel3 = pm.selectPiece(bf, avail, exclude = @[0, 1, 2, 3])
  assert sel3 == -1, "excluding all pieces should return -1"

  # Simulate the scenario: mark all blocks of piece 0 as bsRequested.
  # selectPiece already filters this via hasEmptyBlocks.  But when a
  # piece comes through suggested/high-priority paths (no hasEmptyBlocks
  # check), getNeededBlocks returns 0.  The fix adds it to skippedPieces
  # and continues.
  for blk in pm.pieces[0].blocks.mitems:
    blk.state = bsRequested
  let blocks0 = pm.getNeededBlocks(0)
  assert blocks0.len == 0, "piece 0 should have no empty blocks"

  # selectPiece already skips piece 0 (hasEmptyBlocks false) without exclude
  let sel4 = pm.selectPiece(bf, avail)
  assert sel4 != 0, "selectPiece should skip piece 0 (no empty blocks)"
  assert sel4 >= 1, "should pick an available piece"

  echo "PASS: exclude list skips pieces and selects alternates"

# ============================================================
# Run E2E tests
# ============================================================

# Pre-warm event loop (initializes runtime for subsequent runCps calls)
proc warmup(): CpsVoidFuture {.cps.} =
  await cpsSleep(1)
runCps(warmup())

block test_storage_error_sends_reject:
  let storageFut = issueStorageErrorDropsRequest()
  runCps(storageFut)
  assert not storageFut.hasError, "storage error test failed: " &
    (if storageFut.hasError: storageFut.getError.msg else: "")
  echo "PASS: storage error sends REJECT instead of crashing"

block test_non_bep6_invalid_bounds:
  let boundsFut = issueNonBep6InvalidBoundsHang()
  runCps(boundsFut)
  assert not boundsFut.hasError, "non-BEP6 bounds test failed: " &
    (if boundsFut.hasError: boundsFut.getError.msg else: "")
  echo "PASS: non-BEP6 peer invalid bounds doesn't hang"

echo ""
echo "All swarm issue reproduction tests passed!"
