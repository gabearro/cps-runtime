## End-to-end BitTorrent validation against a real Ubuntu torrent swarm.
##
## This test:
##   1. Downloads an Ubuntu .torrent file
##   2. Parses it (metainfo)
##   3. Announces to the tracker to get peers
##   4. Connects to a peer, performs BT handshake
##   5. Receives the peer's bitfield
##   6. Sends interested, waits for unchoke
##   7. Requests blocks for one piece
##   8. Verifies the SHA1 of the downloaded piece
##
## Requires internet access. Run manually:
##   nim c -r tests/bittorrent/test_ubuntu_e2e.nim

import std/[os, osproc, strutils, times]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/bittorrent/sha1
import cps/bittorrent/metainfo
import cps/bittorrent/peer_protocol
import cps/bittorrent/utils
import cps/bittorrent/tracker
import cps/bittorrent/pieces
import cps/bittorrent/peerid

const
  ## Use the Ubuntu Desktop torrent (more popular, more seeders)
  TorrentUrl = "https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-desktop-amd64.iso.torrent"
  TorrentPath = "/tmp/ubuntu_desktop_e2e.torrent"
  TimeoutMs = 30000  ## 30s timeout for network operations

proc downloadTorrentFile(): bool =
  ## Download the .torrent file using curl.
  if fileExists(TorrentPath):
    let age = epochTime() - getLastModificationTime(TorrentPath).toUnixFloat()
    if age < 86400:  # Less than 1 day old
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

proc runE2eTest(): CpsVoidFuture {.cps.} =
  ## Main e2e test as a CPS proc.
  echo "Step 1: Parse torrent file"
  let data: string = readFile(TorrentPath)
  let meta: TorrentMetainfo = parseTorrent(data)
  let info: TorrentInfo = meta.info

  echo "  Name: " & info.name
  echo "  Pieces: " & $info.pieceCount
  echo "  Piece length: " & $(info.pieceLength div 1024) & " KiB"
  echo "  Total size: " & $(info.totalLength div (1024 * 1024)) & " MiB"
  echo "  Info hash: " & infoHashHex(info)
  echo "  Files: " & $info.files.len
  assert info.pieceCount > 0, "torrent must have pieces"
  assert info.pieceLength > 0, "piece length must be > 0"
  assert info.totalLength > 0, "total length must be > 0"
  echo "PASS: torrent parsing"

  echo ""
  echo "Step 2: Announce to tracker"
  let peerId: array[20, byte] = generatePeerId()

  # Collect tracker URLs
  var trackerUrls: seq[string]
  if meta.announce.len > 0:
    trackerUrls.add(meta.announce)
  var tierIdx: int = 0
  while tierIdx < meta.announceList.len:
    let tier: seq[string] = meta.announceList[tierIdx]
    tierIdx += 1
    var urlIdx: int = 0
    while urlIdx < tier.len:
      let tUrl: string = tier[urlIdx]
      urlIdx += 1
      if tUrl notin trackerUrls:
        trackerUrls.add(tUrl)

  echo "  Trackers: " & $trackerUrls.len
  var dispIdx: int = 0
  while dispIdx < trackerUrls.len:
    echo "    " & trackerUrls[dispIdx]
    dispIdx += 1

  var announceParams: AnnounceParams = defaultAnnounceParams(info, peerId, 6881)
  announceParams.numWant = 200  # Request many peers

  var allPeers: seq[TrackerPeer]
  var trackerOk: bool = false
  var ti: int = 0
  while ti < trackerUrls.len:
    let url: string = trackerUrls[ti]
    ti += 1
    # Skip non-HTTP(S) trackers (e.g., UDP)
    if not url.startsWith("http"):
      echo "  Skipping non-HTTP: " & url
      continue
    echo "  Trying: " & url
    try:
      let trackerResp: TrackerResponse = await announce(url, announceParams)
      if trackerResp.failureReason.len > 0:
        echo "    Failure: " & trackerResp.failureReason
        continue
      trackerOk = true
      echo "    Seeders: " & $trackerResp.complete
      echo "    Leechers: " & $trackerResp.incomplete
      echo "    Peers: " & $trackerResp.peers.len
      # Collect all unique peers
      var pi2: int = 0
      while pi2 < trackerResp.peers.len:
        let tp: TrackerPeer = trackerResp.peers[pi2]
        pi2 += 1
        var found: bool = false
        var ai: int = 0
        while ai < allPeers.len:
          if allPeers[ai].ip == tp.ip and allPeers[ai].port == tp.port:
            found = true
            break
          ai += 1
        if not found:
          allPeers.add(tp)
    except CatchableError as e:
      echo "    Error: " & e.msg

  echo "  Total unique peers: " & $allPeers.len

  if not trackerOk or allPeers.len == 0:
    echo "SKIP: could not reach tracker or get peers (network issue)"
    return

  echo "PASS: tracker announce"

  echo ""
  echo "Step 3: Connect to peer and handshake"

  var peerStream: TcpStream
  var peerReader: BufferedReader
  var connectedPeerIp: string = ""
  var connectedPeerPort: uint16 = 0
  var pi: int = 0
  while pi < allPeers.len and pi < 20:  # Try up to 20 peers
    let tp: TrackerPeer = allPeers[pi]
    pi += 1
    echo "  Trying peer: " & tp.ip & ":" & $tp.port
    try:
      peerStream = await tcpConnect(tp.ip, tp.port.int)
      connectedPeerIp = tp.ip
      connectedPeerPort = tp.port
      echo "    Connected!"
      break
    except CatchableError as e:
      echo "    Failed: " & e.msg

  if connectedPeerIp.len == 0:
    echo "SKIP: could not connect to any peer"
    return

  peerReader = newBufferedReader(peerStream.AsyncStream, 65536)

  # Send handshake
  let hsData: string = encodeHandshake(info.infoHash, peerId)
  await peerStream.write(hsData)

  # Read handshake response
  let respData: string = await peerReader.readExact(HandshakeLength)
  let hs: Handshake = decodeHandshake(respData)
  assert hs.infoHash == info.infoHash, "info hash mismatch in handshake"
  echo "  Handshake OK, peer ID: " & peerIdToString(hs.peerId)
  echo "  Extensions: " & $hs.supportsExtensions

  echo "PASS: peer handshake"

  echo ""
  echo "Step 4: Exchange bitfield and get unchoked"

  # Read messages until we get bitfield + unchoke (or timeout)
  var peerBitfield: seq[byte]
  var gotBitfield: bool = false
  var gotUnchoke: bool = false
  var sentInterested: bool = false
  let deadline: float = epochTime() + (TimeoutMs.float / 1000.0)

  # Send interested right away (peer is likely a seeder)
  let intMsg: string = encodeMessage(interestedMsg())
  await peerStream.write(intMsg)
  sentInterested = true
  echo "  Sent interested"

  var msgCount: int = 0
  while epochTime() < deadline and msgCount < 100:
    if gotUnchoke:
      break  # We got unchoked, ready to request

    # Read message length
    let lenData: string = await peerReader.readExact(4)
    let msgLen: uint32 = readUint32BE(lenData, 0)

    if msgLen == 0:
      # Keep-alive
      continue

    if msgLen > 2 * 1024 * 1024:
      echo "  Message too large: " & $msgLen
      break

    let payload: string = await peerReader.readExact(msgLen.int)
    let msgId: int = payload[0].byte.int
    msgCount += 1

    case msgId
    of 0:  # Choke
      gotUnchoke = false
      echo "  Got choke"
    of 1:  # Unchoke
      gotUnchoke = true
      echo "  Got unchoke!"
    of 5:  # Bitfield
      peerBitfield = cast[seq[byte]](payload[1..^1])
      gotBitfield = true
      let peerPieces: int = countPieces(peerBitfield, info.pieceCount)
      echo "  Got bitfield: peer has " & $peerPieces & "/" & $info.pieceCount & " pieces"
    of 14:  # HaveAll (BEP 6)
      gotBitfield = true
      peerBitfield = newBitfield(info.pieceCount)
      var idx: int = 0
      while idx < info.pieceCount:
        setPiece(peerBitfield, idx)
        idx += 1
      echo "  Got HaveAll: peer is a complete seed"
    of 20:  # Extended message - ignore
      discard
    else:
      echo "  Got message type " & $msgId

  if not gotUnchoke:
    echo "SKIP: peer did not unchoke us"
    peerStream.close()
    return

  if not gotBitfield:
    # Some seeders (e.g., Canonical's servers) don't send bitfield.
    # If we got unchoked, assume full seed.
    echo "  No bitfield received - assuming full seed"
    peerBitfield = newBitfield(info.pieceCount)
    var bfIdx: int = 0
    while bfIdx < info.pieceCount:
      setPiece(peerBitfield, bfIdx)
      bfIdx += 1
    gotBitfield = true

  echo "PASS: bitfield and unchoke"

  echo ""
  echo "Step 5: Download and verify one piece"

  # BEP 16: Super-seeder only sends Have for specific pieces it wants us to download.
  # Drain all initial Haves before selecting which piece to request.
  echo "  Draining Have messages from peer..."
  var haveCount: int = 0
  var offeredPieces: seq[int]
  var drainDone: bool = false
  try:
    while not drainDone:
      let drainLen: string = await peerReader.readExact(4)
      let drainMsgLen: uint32 = readUint32BE(drainLen, 0)
      if drainMsgLen == 0:
        # Keep-alive: peer is done sending Haves
        echo "  Peer sent keep-alive after " & $haveCount & " Have messages"
        drainDone = true
        continue
      let drainPayload: string = await peerReader.readExact(drainMsgLen.int)
      let drainMsgId: int = drainPayload[0].byte.int
      if drainMsgId == 4:  # Have
        let haveIdx: int = readUint32BE(drainPayload, 1).int
        if haveIdx < info.pieceCount:
          setPiece(peerBitfield, haveIdx)
          offeredPieces.add(haveIdx)
        haveCount += 1
      elif drainMsgId == 5:  # Bitfield
        peerBitfield = cast[seq[byte]](drainPayload[1..^1])
        gotBitfield = true
        echo "  Got bitfield"
        drainDone = true
      elif drainMsgId == 14:  # HaveAll
        peerBitfield = newBitfield(info.pieceCount)
        var fillIdx: int = 0
        while fillIdx < info.pieceCount:
          setPiece(peerBitfield, fillIdx)
          fillIdx += 1
        echo "  Got HaveAll"
        drainDone = true
      elif drainMsgId == 0:  # Choke
        echo "  Got choked during Have drain!"
        drainDone = true
      elif drainMsgId == 1:  # Unchoke (redundant)
        discard
      else:
        echo "  Got unexpected message type " & $drainMsgId & " during drain"
        drainDone = true
  except CatchableError as e:
    echo "  Connection error during Have drain: " & e.msg
    peerStream.close()
    return

  echo "  Super-seeder offered " & $offeredPieces.len & " pieces"

  # Pick a piece the peer offered (for super-seeders) or scan bitfield
  var targetPiece: int = -1
  if offeredPieces.len > 0:
    targetPiece = offeredPieces[0]
  else:
    var idx2: int = 0
    while idx2 < info.pieceCount:
      if hasPiece(peerBitfield, idx2):
        targetPiece = idx2
        break
      idx2 += 1

  if targetPiece < 0:
    echo "SKIP: peer has no pieces we can download"
    peerStream.close()
    return

  let pieceLen: int = info.pieceSize(targetPiece)
  echo "  Downloading piece " & $targetPiece & " (" & $pieceLen & " bytes)"

  # Pipeline requests
  let pipelineSize: int = 5
  var pieceData: string = newString(pieceLen)
  var receivedBlocks: int = 0
  var totalBlocks: int = (pieceLen + BlockSize - 1) div BlockSize
  var requestedUpTo: int = 0
  var requestedCount: int = 0
  var inFlight: int = 0

  echo "  Total blocks: " & $totalBlocks

  # Send initial batch
  try:
    while requestedUpTo < pieceLen and inFlight < pipelineSize:
      let blockLen: int = min(BlockSize, pieceLen - requestedUpTo)
      let reqMsg: string = encodeMessage(requestMsg(
        uint32(targetPiece), uint32(requestedUpTo), uint32(blockLen)))
      await peerStream.write(reqMsg)
      requestedUpTo += blockLen
      requestedCount += 1
      inFlight += 1
  except CatchableError as e:
    echo "  Error sending requests: " & e.msg
    peerStream.close()
    return

  echo "  Sent initial " & $inFlight & " requests"

  # Receive blocks and send more requests as responses arrive
  let dlDeadline: float = epochTime() + (TimeoutMs.float / 1000.0)
  var downloadOk: bool = true
  var dlDone: bool = false
  try:
    while not dlDone and receivedBlocks < totalBlocks and epochTime() < dlDeadline:
      let lenData2: string = await peerReader.readExact(4)
      let msgLen2: uint32 = readUint32BE(lenData2, 0)

      if msgLen2 == 0:
        continue  # Keep-alive

      if msgLen2 > 2 * 1024 * 1024:
        echo "  Message too large: " & $msgLen2
        downloadOk = false
        dlDone = true
        continue

      let payload2: string = await peerReader.readExact(msgLen2.int)
      let msgId2: int = payload2[0].byte.int

      if msgId2 == 7:  # Piece
        let blkIndex: int = readUint32BE(payload2, 1).int
        let blkBegin: int = readUint32BE(payload2, 5).int
        let blkData: string = payload2[9..^1]

        if blkIndex == targetPiece and blkBegin + blkData.len <= pieceLen:
          copyMem(addr pieceData[blkBegin], unsafeAddr blkData[0], blkData.len)
          receivedBlocks += 1
          inFlight -= 1
          if receivedBlocks mod 4 == 0 or receivedBlocks == totalBlocks:
            echo "  Received " & $receivedBlocks & "/" & $totalBlocks & " blocks"

          # Pipeline: send next request
          if requestedUpTo < pieceLen and inFlight < pipelineSize:
            let blockLen2: int = min(BlockSize, pieceLen - requestedUpTo)
            let reqMsg2: string = encodeMessage(requestMsg(
              uint32(targetPiece), uint32(requestedUpTo), uint32(blockLen2)))
            await peerStream.write(reqMsg2)
            requestedUpTo += blockLen2
            requestedCount += 1
            inFlight += 1
      elif msgId2 == 0:  # Choke
        echo "  Got choked during download!"
        downloadOk = false
        dlDone = true
      elif msgId2 == 1:  # Unchoke
        echo "  Got unchoke (re-unchoke)"
      elif msgId2 == 16:  # RejectRequest (BEP 6)
        echo "  Request rejected"
        inFlight -= 1
      else:
        echo "  Got message type " & $msgId2 & " during download"
  except CatchableError as e:
    echo "  Download connection error: " & e.msg
    downloadOk = false

  peerStream.close()

  if not downloadOk or receivedBlocks < totalBlocks:
    echo "SKIP: only received " & $receivedBlocks & "/" & $totalBlocks & " blocks"
    return

  echo "  All blocks received"

  # Verify SHA1
  echo ""
  echo "Step 6: Verify piece SHA1"
  let expectedHash: array[20, byte] = info.pieceHash(targetPiece)
  let actualHash: array[20, byte] = sha1(pieceData)

  var expectedHex: string = ""
  var actualHex: string = ""
  for b in expectedHash:
    expectedHex.add(b.int.toHex(2).toLowerAscii())
  for b in actualHash:
    actualHex.add(b.int.toHex(2).toLowerAscii())

  echo "  Expected: " & expectedHex
  echo "  Actual:   " & actualHex
  assert actualHash == expectedHash, "SHA1 mismatch! Piece data is corrupt."
  echo "PASS: SHA1 verification - piece " & $targetPiece & " is valid!"

  echo ""
  echo "=========================================="
  echo "ALL E2E VALIDATION STEPS PASSED!"
  echo "=========================================="

# Main
echo "BitTorrent E2E Validation Test"
echo "=============================="
echo ""

echo "Step 0: Download torrent file"
if not downloadTorrentFile():
  echo "SKIP: could not download torrent file (need internet)"
  quit(0)
echo "PASS: torrent file downloaded"
echo ""

block:
  let fut = runE2eTest()
  let loop = getEventLoop()
  var ticks = 0
  while not fut.finished and ticks < 300000:
    loop.tick()
    ticks += 1

  if fut.hasError:
    echo "ERROR: " & fut.getError().msg
    quit(1)

  if not fut.finished:
    echo "TIMEOUT: test did not complete"
    quit(1)
