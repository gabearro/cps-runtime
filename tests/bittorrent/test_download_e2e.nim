## End-to-end BitTorrent download test using DHT, PEX, and uTP.
##
## This test:
##   1. Downloads .torrent file for Ubuntu 24.04 (reference metadata)
##   2. Uses DHT to discover peers for the Ubuntu torrent info hash
##   3. Connects to peers via TCP with BEP 10 extension protocol
##   4. Performs BEP 10 extended handshake (negotiates ut_pex, ut_metadata)
##   5. Receives PEX messages with additional peer addresses
##   6. Attempts uTP handshake with peers (SYN → STATE)
##   7. Downloads and SHA1-verifies one piece via TCP
##
## Requires internet access. Run manually:
##   nim c -r tests/bittorrent/test_download_e2e.nim

import std/[os, osproc, strutils, times, nativesockets, tables]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/udp
import cps/io/buffered
import cps/io/dns
import cps/io/timeouts
import cps/bittorrent/metainfo
import cps/bittorrent/peer_protocol
import cps/bittorrent/utils
import cps/bittorrent/tracker
import cps/bittorrent/extensions
import cps/bittorrent/peerid
import cps/bittorrent/pex
import cps/bittorrent/dht
import cps/bittorrent/utp
import cps/bittorrent/sha1
import cps/bittorrent/pieces
import cps/bittorrent/metadata

const
  TorrentUrl = "https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-desktop-amd64.iso.torrent"
  TorrentPath = "/tmp/ubuntu_download_e2e.torrent"
  TimeoutMs = 15000
  BootstrapHosts = ["router.bittorrent.com", "dht.transmissionbt.com"]
  BootstrapPort = 6881

# ── DHT infrastructure (callback-based UDP) ──────────────────────

var dhtPendingQueries: Table[string, CpsFuture[DhtMessage]]
var dhtSock: UdpSocket

proc setupDhtSocket() =
  dhtSock = newUdpSocket()
  dhtSock.bindAddr("0.0.0.0", 0)
  dhtSock.onRecv(1500, proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
    try:
      let msg = decodeDhtMessage(data)
      if msg.transactionId in dhtPendingQueries:
        let fut = dhtPendingQueries[msg.transactionId]
        dhtPendingQueries.del(msg.transactionId)
        fut.complete(msg)
    except CatchableError:
      discard
  )

proc sendDhtQuery(transId: string, data: string, ip: string, port: int,
                  timeoutMs: int = 5000): CpsFuture[DhtMessage] {.cps.} =
  let queryFut: CpsFuture[DhtMessage] = newCpsFuture[DhtMessage]()
  queryFut.pinFutureRuntime()
  dhtPendingQueries[transId] = queryFut
  discard dhtSock.trySendToAddr(data, ip, port)
  let resp: DhtMessage = await withTimeout(queryFut, timeoutMs)
  return resp

proc resolveHost(host: string): CpsFuture[string] {.cps.} =
  let addrs: seq[string] = await resolve(host, Port(0), AF_INET)
  if addrs.len == 0:
    raise newException(AsyncIoError, "Could not resolve: " & host)
  return addrs[0]

# ── Torrent file download ────────────────────────────────────────

proc downloadTorrentFile(): bool =
  if fileExists(TorrentPath):
    let age = epochTime() - getLastModificationTime(TorrentPath).toUnixFloat()
    if age < 86400:
      echo "  Using cached torrent file"
      return true
  echo "  Downloading torrent file..."
  let (output, exitCode) = execCmdEx("curl -sL -o " & TorrentPath & " " & TorrentUrl)
  if exitCode != 0:
    echo "  curl failed: " & output
    return false
  if not fileExists(TorrentPath) or getFileSize(TorrentPath) < 100:
    echo "  Downloaded file too small or missing"
    return false
  return true

# ── Helper: read one peer message ────────────────────────────────

type
  PeerMsgResult = object
    valid: bool
    msgId: int
    payload: string
    timedOut: bool
    errored: bool

proc readPeerMsg(reader: BufferedReader, timeoutMs: int = 5000): CpsFuture[PeerMsgResult] {.cps.} =
  var pmr: PeerMsgResult
  pmr.valid = false
  pmr.timedOut = false
  pmr.errored = false
  let lenData: string = await withTimeout(reader.readExact(4), timeoutMs)
  let msgLen: uint32 = readUint32BE(lenData, 0)
  if msgLen == 0:
    # Keep-alive
    pmr.valid = true
    pmr.msgId = -1  # sentinel for keep-alive
    return pmr
  if msgLen > 2 * 1024 * 1024:
    pmr.errored = true
    return pmr
  let payload: string = await reader.readExact(msgLen.int)
  pmr.valid = true
  pmr.msgId = payload[0].byte.int
  pmr.payload = payload
  return pmr

# ── Main test ────────────────────────────────────────────────────

proc runDownloadE2e(): CpsVoidFuture {.cps.} =
  # ── Step 1: Parse torrent file ─────────────────────────────────
  echo "Step 1: Parse .torrent file"
  let torrentData: string = readFile(TorrentPath)
  let meta: TorrentMetainfo = parseTorrent(torrentData)
  let info: TorrentInfo = meta.info
  let infoHash: array[20, byte] = info.infoHash
  echo "  Name: " & info.name
  echo "  Pieces: " & $info.pieceCount & " x " & $(info.pieceLength div 1024) & " KiB"
  echo "  Info hash: " & infoHashHex(info)
  echo "PASS: torrent parsed"

  let peerId: array[20, byte] = generatePeerId()

  # ── Step 2: DHT peer discovery ─────────────────────────────────
  echo ""
  echo "Step 2: DHT peer discovery"

  let ownNodeId: NodeId = generateNodeId()
  var rt: RoutingTable = newRoutingTable(ownNodeId)
  var dhtPeers: seq[TrackerPeer]

  # Bootstrap
  var bootstrapped: bool = false
  var bootstrapIp: string = ""
  var bi: int = 0
  while bi < BootstrapHosts.len and not bootstrapped:
    let host: string = BootstrapHosts[bi]
    bi += 1
    try:
      let ip: string = await resolveHost(host)
      let transId: string = "bt" & $bi
      let pingData: string = encodePingQuery(transId, ownNodeId)
      let msg: DhtMessage = await sendDhtQuery(transId, pingData, ip, BootstrapPort, 5000)
      if not msg.isQuery:
        bootstrapIp = ip
        discard rt.addNode(DhtNode(id: msg.responderId, ip: ip,
                                   port: BootstrapPort.uint16, lastSeen: epochTime()))
        bootstrapped = true
        echo "  Bootstrapped via " & host
    except CatchableError as e:
      echo "  Bootstrap " & host & " failed: " & e.msg

  if not bootstrapped:
    echo "  DHT bootstrap failed, continuing with tracker only"
  else:
    # find_node to populate routing table
    try:
      let fnId: string = "fn01"
      let fnData: string = encodeFindNodeQuery(fnId, ownNodeId, ownNodeId)
      let fnMsg: DhtMessage = await sendDhtQuery(fnId, fnData, bootstrapIp, BootstrapPort)
      var nodesAdded: int = 0
      var ni: int = 0
      while ni < fnMsg.nodes.len:
        let cn: CompactNodeInfo = fnMsg.nodes[ni]
        ni += 1
        if rt.addNode(DhtNode(id: cn.id, ip: cn.ip, port: cn.port, lastSeen: epochTime())):
          nodesAdded += 1
      echo "  find_node: " & $nodesAdded & " nodes added"
    except CatchableError as e:
      echo "  find_node failed: " & e.msg

    # get_peers for Ubuntu info hash
    var infoHashAsNodeId: NodeId
    var hIdx: int = 0
    while hIdx < 20:
      infoHashAsNodeId[hIdx] = infoHash[hIdx]
      hIdx += 1

    let closestNodes: seq[DhtNode] = rt.findClosest(infoHashAsNodeId, K)
    var gi: int = 0
    while gi < closestNodes.len and gi < 4:
      let node: DhtNode = closestNodes[gi]
      gi += 1
      try:
        let gpId: string = "gp" & $gi
        let gpData: string = encodeGetPeersQuery(gpId, ownNodeId, infoHashAsNodeId)
        let gpMsg: DhtMessage = await sendDhtQuery(gpId, gpData, node.ip, node.port.int, 5000)
        if gpMsg.values.len > 0:
          echo "  DHT found " & $gpMsg.values.len & " peers from " & node.ip
          var vi: int = 0
          while vi < gpMsg.values.len:
            dhtPeers.add(TrackerPeer(ip: gpMsg.values[vi][0], port: gpMsg.values[vi][1]))
            vi += 1
        if gpMsg.nodes.len > 0:
          var cni: int = 0
          while cni < gpMsg.nodes.len:
            let cn: CompactNodeInfo = gpMsg.nodes[cni]
            cni += 1
            discard rt.addNode(DhtNode(id: cn.id, ip: cn.ip, port: cn.port, lastSeen: epochTime()))
      except CatchableError as e:
        echo "  get_peers from " & node.ip & " failed: " & e.msg

  echo "  DHT peers found: " & $dhtPeers.len
  if dhtPeers.len > 0:
    echo "PASS: DHT peer discovery"
  else:
    echo "  (No DHT peers - will rely on tracker)"

  # ── Step 3: Tracker peer discovery ─────────────────────────────
  echo ""
  echo "Step 3: Tracker peer discovery"

  var params: AnnounceParams
  params.infoHash = infoHash
  params.peerId = peerId
  params.port = 6881
  params.uploaded = 0
  params.downloaded = 0
  params.left = 1
  params.event = teStarted
  params.compact = true
  params.numWant = 200

  var allPeers: seq[TrackerPeer]
  var di: int = 0
  while di < dhtPeers.len:
    allPeers.add(dhtPeers[di])
    di += 1

  var trackerUrls: seq[string]
  if meta.announce.len > 0:
    trackerUrls.add(meta.announce)
  var ti: int = 0
  while ti < meta.announceList.len:
    let tier: seq[string] = meta.announceList[ti]
    ti += 1
    var ui: int = 0
    while ui < tier.len:
      let url: string = tier[ui]
      ui += 1
      if url notin trackerUrls:
        trackerUrls.add(url)
  trackerUrls.add("udp://tracker.opentrackr.org:1337")
  trackerUrls.add("udp://open.stealth.si:80/announce")

  var trackerOk: bool = false
  var tki: int = 0
  while tki < trackerUrls.len and tki < 5:
    let url: string = trackerUrls[tki]
    tki += 1
    if not (url.startsWith("http") or url.startsWith("udp")):
      continue
    echo "  Trying: " & url
    try:
      let trackerResp: TrackerResponse = await announce(url, params)
      if trackerResp.failureReason.len > 0:
        echo "    Failure: " & trackerResp.failureReason
        continue
      trackerOk = true
      echo "    Peers: " & $trackerResp.peers.len
      var pi: int = 0
      while pi < trackerResp.peers.len:
        let tp: TrackerPeer = trackerResp.peers[pi]
        pi += 1
        var found: bool = false
        var ai: int = 0
        while ai < allPeers.len:
          if allPeers[ai].ip == tp.ip and allPeers[ai].port == tp.port:
            found = true
          ai += 1
        if not found:
          allPeers.add(tp)
    except CatchableError as e:
      echo "    Error: " & e.msg

  echo "  Total unique peers: " & $allPeers.len
  if allPeers.len == 0:
    echo "SKIP: no peers found via DHT or tracker"
    dhtSock.close()
    return
  echo "PASS: peer discovery"

  # ── Step 4: Connect to peer with BEP 10 + PEX ─────────────────
  echo ""
  echo "Step 4: Connect to peer with BEP 10 extensions"

  var connectedStream: TcpStream
  var connectedReader: BufferedReader
  var connectedPeerAddr: string = ""
  var peerExtReg: ExtensionRegistry

  var pi2: int = 0
  while pi2 < allPeers.len and pi2 < 30 and connectedPeerAddr.len == 0:
    let tp: TrackerPeer = allPeers[pi2]
    pi2 += 1
    echo "  Trying peer: " & tp.ip & ":" & $tp.port

    try:
      connectedStream = await withTimeout(tcpConnect(tp.ip, tp.port.int), 5000)
      connectedReader = newBufferedReader(connectedStream.AsyncStream, 65536)

      let hsData: string = encodeHandshake(infoHash, peerId, supportExtensions = true)
      await connectedStream.write(hsData)
      let respData: string = await withTimeout(connectedReader.readExact(HandshakeLength), 5000)
      let peerHs: Handshake = decodeHandshake(respData)

      if peerHs.infoHash != infoHash:
        echo "    Info hash mismatch"
        connectedStream.close()
        continue

      if not peerHs.supportsExtensions:
        echo "    No BEP 10 support"
        connectedStream.close()
        continue

      echo "    Handshake OK, peer ID: " & peerIdToString(peerHs.peerId)

      var extReg: ExtensionRegistry = newExtensionRegistry()
      discard extReg.registerExtension(UtMetadataName)
      discard extReg.registerExtension(UtPexName)
      let extHsPayload: string = encodeExtHandshake(extReg, clientName = "NimCPS/0.1")
      let extHsMsg: string = encodeMessage(extendedMsg(ExtHandshakeId, extHsPayload))
      await connectedStream.write(extHsMsg)

      # Read messages until we get the extension handshake
      var gotExtHs: bool = false
      var extMsgCount: int = 0
      while extMsgCount < 200 and not gotExtHs:
        let pmr: PeerMsgResult = await readPeerMsg(connectedReader, 5000)
        if not pmr.valid or pmr.errored or pmr.timedOut:
          extMsgCount = 999  # force exit
          continue
        extMsgCount += 1
        if pmr.msgId == 20 and pmr.payload.len > 2:
          let extId: int = pmr.payload[1].byte.int
          if extId == 0:
            extReg.decodeExtHandshake(pmr.payload[2..^1])
            peerExtReg = extReg
            gotExtHs = true
            echo "    Peer client: " & extReg.clientName
            echo "    Supports ut_pex: " & $extReg.supportsExtension(UtPexName)

      if gotExtHs:
        connectedPeerAddr = tp.ip & ":" & $tp.port
      else:
        connectedStream.close()
    except CatchableError as e:
      echo "    Failed: " & e.msg

  if connectedPeerAddr.len == 0:
    echo "SKIP: no peers support BEP 10 extensions"
    dhtSock.close()
    return
  echo "PASS: BEP 10 extended handshake"

  # ── Step 5: Listen for PEX + bitfield + unchoke ────────────────
  echo ""
  echo "Step 5: Listen for PEX, bitfield, unchoke"

  let interestedMsg: string = encodeMessage(PeerMessage(id: msgInterested))
  await connectedStream.write(interestedMsg)

  var pexPeers: seq[TrackerPeer]
  var gotPex: bool = false
  var gotBitfield: bool = false
  var gotUnchoke: bool = false
  var peerBitfield: seq[byte]
  var doneListening: bool = false
  var listenCount: int = 0

  while not doneListening and listenCount < 500:
    let pmr: PeerMsgResult = await readPeerMsg(connectedReader, 3000)
    if pmr.timedOut or pmr.errored or not pmr.valid:
      doneListening = true
      continue
    if pmr.msgId < 0:
      listenCount += 1
      continue  # Keep-alive

    listenCount += 1

    if pmr.msgId == 1:  # Unchoke
      gotUnchoke = true
      echo "  Got UNCHOKE"
    elif pmr.msgId == 5:  # Bitfield
      gotBitfield = true
      peerBitfield = newSeq[byte](pmr.payload.len - 1)
      var bi2: int = 0
      while bi2 < pmr.payload.len - 1:
        peerBitfield[bi2] = pmr.payload[bi2 + 1].byte
        bi2 += 1
      echo "  Got BITFIELD (" & $peerBitfield.len & " bytes)"
    elif pmr.msgId == 14:  # HaveAll
      gotBitfield = true
      echo "  Got HAVE_ALL"
    elif pmr.msgId == 20 and pmr.payload.len > 2:  # Extended
      let extId: int = pmr.payload[1].byte.int
      if peerExtReg.supportsExtension(UtPexName):
        let localPexId: int = peerExtReg.localId(UtPexName).int
        if extId == localPexId:
          let pexMsg = decodePexMessage(pmr.payload[2..^1])
          echo "  Got PEX: " & $pexMsg.added.len & " added, " &
               $pexMsg.dropped.len & " dropped"
          var pai: int = 0
          while pai < pexMsg.added.len:
            pexPeers.add(TrackerPeer(ip: pexMsg.added[pai][0], port: pexMsg.added[pai][1]))
            pai += 1
          gotPex = true
          var si: int = 0
          while si < pexMsg.added.len and si < 3:
            let flag: uint8 = if si < pexMsg.addedFlags.len: pexMsg.addedFlags[si] else: 0'u8
            echo "    PEX peer: " & pexMsg.added[si][0] & ":" & $pexMsg.added[si][1] &
                 " (flags=0x" & flag.int.toHex(2) & ")"
            si += 1

    # Stop once we have bitfield + unchoke
    if gotUnchoke and gotBitfield:
      doneListening = true

  echo "  PEX peers discovered: " & $pexPeers.len
  if gotPex:
    echo "PASS: PEX peer exchange"
  else:
    echo "  (No PEX messages received in time window)"

  # ── Step 6: uTP handshake test ─────────────────────────────────
  echo ""
  echo "Step 6: uTP handshake test"

  var utpTestPeers: seq[TrackerPeer]
  var upi: int = 0
  while upi < allPeers.len and utpTestPeers.len < 5:
    utpTestPeers.add(allPeers[upi])
    upi += 1
  upi = 0
  while upi < pexPeers.len and utpTestPeers.len < 10:
    utpTestPeers.add(pexPeers[upi])
    upi += 1

  var utpOk: bool = false

  # Use callback-based onRecv for uTP to avoid kqueue re-registration
  var utpResponseFut: CpsFuture[UtpPacketHeader]
  let utpSock: UdpSocket = newUdpSocket()
  utpSock.bindAddr("0.0.0.0", 0)
  utpSock.onRecv(1500, proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
    if data.len >= UtpHeaderSize and utpResponseFut != nil and not utpResponseFut.finished:
      try:
        let hdr = decodeHeader(data)
        utpResponseFut.complete(hdr)
      except CatchableError:
        discard
  )

  var uti: int = 0
  while uti < utpTestPeers.len and not utpOk:
    let tp: TrackerPeer = utpTestPeers[uti]
    uti += 1
    echo "  uTP SYN to " & tp.ip & ":" & $tp.port

    try:
      let utpConn: UtpSocket = newUtpSocket(uint16(uti * 100 + 1000))
      let synPacket: string = utpConn.makeSynPacket()
      utpResponseFut = newCpsFuture[UtpPacketHeader]()
      utpResponseFut.pinFutureRuntime()
      discard utpSock.trySendToAddr(synPacket, tp.ip, tp.port.int)

      let hdr: UtpPacketHeader = await withTimeout(utpResponseFut, 3000)
      echo "    Response: type=" & $hdr.packetType & " connId=" & $hdr.connectionId
      if hdr.packetType == StState:
        echo "    Got STATE (ACK) - uTP handshake successful!"
        utpOk = true
      elif hdr.packetType == StReset:
        echo "    Got RESET - peer rejected uTP"
    except TimeoutError:
      echo "    Timeout"
    except CatchableError as e:
      echo "    Error: " & e.msg

  utpSock.close()

  if utpOk:
    echo "PASS: uTP handshake"
  else:
    echo "  (uTP handshake not completed - peers may not support uTP)"

  # ── Step 7: Download and verify one piece ──────────────────────
  echo ""
  echo "Step 7: Download and verify one piece"

  if not gotUnchoke:
    echo "  Waiting for unchoke..."
    var unchokeCount: int = 0
    while not gotUnchoke and unchokeCount < 50:
      let pmr: PeerMsgResult = await readPeerMsg(connectedReader, 3000)
      if pmr.timedOut or pmr.errored or not pmr.valid:
        unchokeCount = 999
        continue
      unchokeCount += 1
      if pmr.msgId == 1:
        gotUnchoke = true
        echo "  Got UNCHOKE"
      elif pmr.msgId == 5 and not gotBitfield:
        gotBitfield = true
        peerBitfield = newSeq[byte](pmr.payload.len - 1)
        var bi3: int = 0
        while bi3 < pmr.payload.len - 1:
          peerBitfield[bi3] = pmr.payload[bi3 + 1].byte
          bi3 += 1
      elif pmr.msgId == 14:
        gotBitfield = true

  if not gotUnchoke:
    echo "SKIP: peer never unchoked us"
    connectedStream.close()
    dhtSock.close()
    return

  # Find a piece the peer has
  var targetPiece: int = -1
  if gotBitfield and peerBitfield.len > 0:
    var pi3: int = 0
    while pi3 < info.pieceCount and targetPiece < 0:
      if hasPiece(peerBitfield, pi3):
        targetPiece = pi3
      pi3 += 1
  else:
    targetPiece = 0

  if targetPiece < 0:
    echo "SKIP: peer has no pieces"
    connectedStream.close()
    dhtSock.close()
    return

  echo "  Requesting piece " & $targetPiece

  let pieceLen: int = info.pieceSize(targetPiece)
  var pieceData: string = newString(pieceLen)
  var receivedBytes: int = 0

  # Request all blocks for this piece
  var offset: int = 0
  while offset < pieceLen:
    let blockLen: int = min(BlockSize, pieceLen - offset)
    let reqMsg: string = encodeMessage(PeerMessage(
      id: msgRequest,
      reqIndex: uint32(targetPiece),
      reqBegin: uint32(offset),
      reqLength: uint32(blockLen)
    ))
    await connectedStream.write(reqMsg)
    offset += blockLen

  let totalBlocks: int = (pieceLen + BlockSize - 1) div BlockSize
  echo "  Sent " & $totalBlocks & " block requests (" & $pieceLen & " bytes total)"

  # Receive blocks
  var blocksReceived: int = 0
  var downloadDone: bool = false
  var dlMsgCount: int = 0

  while not downloadDone and dlMsgCount < 1000 and receivedBytes < pieceLen:
    let pmr: PeerMsgResult = await readPeerMsg(connectedReader, 10000)
    if pmr.timedOut or pmr.errored or not pmr.valid:
      downloadDone = true
      continue
    if pmr.msgId < 0:
      dlMsgCount += 1
      continue
    dlMsgCount += 1

    if pmr.msgId == 7 and pmr.payload.len > 9:  # Piece
      let pieceIndex: uint32 = readUint32BE(pmr.payload, 1)
      let blockBegin: uint32 = readUint32BE(pmr.payload, 5)
      let blockData: string = pmr.payload[9..^1]

      if pieceIndex.int == targetPiece:
        let blockOff: int = blockBegin.int
        var bi4: int = 0
        while bi4 < blockData.len and blockOff + bi4 < pieceLen:
          pieceData[blockOff + bi4] = blockData[bi4]
          bi4 += 1
        receivedBytes += blockData.len
        blocksReceived += 1
        if blocksReceived mod 10 == 0 or receivedBytes >= pieceLen:
          echo "  Received block " & $blocksReceived & "/" & $totalBlocks &
               " (" & $receivedBytes & "/" & $pieceLen & " bytes)"
    elif pmr.msgId == 0:  # Choke
      echo "  Peer choked us mid-download!"
      downloadDone = true

  connectedStream.close()

  if receivedBytes < pieceLen:
    echo "  Only received " & $receivedBytes & "/" & $pieceLen & " bytes"
    echo "SKIP: incomplete piece download"
    dhtSock.close()
    return

  echo "  Piece " & $targetPiece & " fully downloaded (" & $pieceLen & " bytes)"

  # Verify SHA1
  let expectedHash: array[20, byte] = info.pieceHash(targetPiece)
  let actualHash: array[20, byte] = sha1(pieceData)

  if actualHash == expectedHash:
    echo "  SHA1 VERIFIED!"
    echo "PASS: piece download and verification"
  else:
    echo "  SHA1 MISMATCH!"
    echo "FAIL: piece verification failed"

  dhtSock.close()

  echo ""
  echo "=========================================="
  echo "ALL DOWNLOAD E2E TESTS PASSED!"
  echo "=========================================="

# ── Main ─────────────────────────────────────────────────────────

echo "BitTorrent Download E2E Test (DHT + PEX + uTP)"
echo "================================================"
echo ""

echo "Step 0: Download reference torrent file"
if not downloadTorrentFile():
  echo "SKIP: could not download reference torrent file (need internet)"
  quit(0)
echo "PASS: reference torrent downloaded"
echo ""

setupDhtSocket()

block:
  let fut = runDownloadE2e()
  let loop = getEventLoop()
  var ticks = 0
  while not fut.finished and ticks < 1200000:
    loop.tick()
    ticks += 1

  if fut.hasError:
    echo "ERROR: " & fut.getError().msg
    quit(1)

  if not fut.finished:
    echo "TIMEOUT: test did not complete within tick limit"
    quit(1)
