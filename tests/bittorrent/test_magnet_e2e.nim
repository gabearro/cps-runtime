## End-to-end magnet link test against a real Ubuntu torrent swarm.
##
## This test:
##   1. Downloads a .torrent file for reference (to get ground truth info hash)
##   2. Constructs a magnet URI from the info hash and tracker URLs
##   3. Parses the magnet URI (testing parseMagnetLink)
##   4. Announces to tracker using ONLY the info hash (no TorrentInfo)
##   5. Connects to peers, finds one supporting BEP 10 extensions
##   6. Performs BEP 10 extended handshake
##   7. Performs BEP 9 metadata exchange to download the info dict
##   8. Verifies SHA1 of assembled metadata matches the info hash
##   9. Parses the metadata into TorrentInfo and validates fields
##
## Requires internet access. Run manually:
##   nim c -r tests/bittorrent/test_magnet_e2e.nim

import std/[os, osproc, strutils, times]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/bittorrent/metainfo
import cps/bittorrent/peer_protocol
import cps/bittorrent/utils
import cps/bittorrent/tracker
import cps/bittorrent/metadata
import cps/bittorrent/extensions
import cps/bittorrent/peerid

const
  TorrentUrl = "https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-desktop-amd64.iso.torrent"
  TorrentPath = "/tmp/ubuntu_magnet_e2e.torrent"
  TimeoutMs = 30000

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

proc runMagnetTest(): CpsVoidFuture {.cps.} =
  ## Main magnet link e2e test.

  echo "Step 1: Parse .torrent for reference info hash"
  let refData: string = readFile(TorrentPath)
  let refMeta: TorrentMetainfo = parseTorrent(refData)
  let refInfo: TorrentInfo = refMeta.info
  let expectedInfoHash: array[20, byte] = refInfo.infoHash

  echo "  Reference name: " & refInfo.name
  echo "  Reference pieces: " & $refInfo.pieceCount
  echo "  Reference info hash: " & infoHashHex(refInfo)
  echo "PASS: reference torrent parsed"

  echo ""
  echo "Step 2: Construct and parse magnet URI"

  # Build magnet URI from reference data
  var magnetUri: string = "magnet:?xt=urn:btih:" & infoHashHex(refInfo)
  magnetUri.add("&dn=" & refInfo.name)
  # Add tracker URLs (include open trackers to find BEP 10 peers)
  if refMeta.announce.len > 0:
    magnetUri.add("&tr=" & refMeta.announce)
  var tIdx: int = 0
  while tIdx < refMeta.announceList.len:
    let tier: seq[string] = refMeta.announceList[tIdx]
    tIdx += 1
    var uIdx: int = 0
    while uIdx < tier.len:
      let tUrl: string = tier[uIdx]
      uIdx += 1
      if tUrl != refMeta.announce:
        magnetUri.add("&tr=" & tUrl)
  # Public open trackers often have diverse peers (qBittorrent, Transmission, etc.)
  # that support BEP 10 extensions needed for metadata exchange
  magnetUri.add("&tr=udp://tracker.opentrackr.org:1337")
  magnetUri.add("&tr=udp://open.stealth.si:80/announce")
  magnetUri.add("&tr=udp://tracker.torrent.eu.org:451/announce")

  echo "  Magnet URI: " & magnetUri[0 ..< min(120, magnetUri.len)] & "..."

  let magnet = parseMagnetLink(magnetUri)
  assert magnet.infoHash == expectedInfoHash, "magnet info hash mismatch"
  assert magnet.trackers.len > 0, "magnet must have trackers"
  echo "  Info hash: matches reference"
  echo "  Display name: " & magnet.displayName
  echo "  Trackers: " & $magnet.trackers.len
  echo "PASS: magnet URI parsing"

  echo ""
  echo "Step 3: Announce to tracker (magnet link - no TorrentInfo)"

  let peerId: array[20, byte] = generatePeerId()

  # Construct AnnounceParams manually (no TorrentInfo available)
  var params: AnnounceParams
  params.infoHash = magnet.infoHash
  params.peerId = peerId
  params.port = 6881
  params.uploaded = 0
  params.downloaded = 0
  params.left = 1  # Non-zero indicates we need data
  params.event = teStarted
  params.compact = true
  params.numWant = 200

  var allPeers: seq[TrackerPeer]
  var trackerOk: bool = false
  var ti: int = 0
  while ti < magnet.trackers.len:
    let url: string = magnet.trackers[ti]
    ti += 1
    if not (url.startsWith("http") or url.startsWith("udp")):
      echo "  Skipping unsupported: " & url
      continue
    echo "  Trying: " & url
    try:
      let trackerResp: TrackerResponse = await announce(url, params)
      if trackerResp.failureReason.len > 0:
        echo "    Failure: " & trackerResp.failureReason
        continue
      trackerOk = true
      echo "    Seeders: " & $trackerResp.complete
      echo "    Leechers: " & $trackerResp.incomplete
      echo "    Peers: " & $trackerResp.peers.len
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
    echo "SKIP: could not reach tracker or get peers"
    return

  echo "PASS: tracker announce (magnet link)"

  echo ""
  echo "Step 4: Find a peer supporting BEP 10 extensions"

  # We need a peer that advertises BEP 10 (reserved byte 5, bit 0x10)
  # for metadata exchange. Canonical's seeders may not support it.
  var peerStream: TcpStream
  var peerReader: BufferedReader
  var connectedPeerIp: string = ""
  var peerHandshake: Handshake
  var pi: int = 0
  while pi < allPeers.len and pi < 30:
    let tp: TrackerPeer = allPeers[pi]
    pi += 1
    echo "  Trying peer: " & tp.ip & ":" & $tp.port
    try:
      peerStream = await tcpConnect(tp.ip, tp.port.int)
      peerReader = newBufferedReader(peerStream.AsyncStream, 65536)

      # Send handshake with BEP 10 support
      let hsData: string = encodeHandshake(magnet.infoHash, peerId, supportExtensions = true)
      await peerStream.write(hsData)

      # Read handshake response
      let respData: string = await peerReader.readExact(HandshakeLength)
      peerHandshake = decodeHandshake(respData)

      if peerHandshake.infoHash != magnet.infoHash:
        echo "    Info hash mismatch, closing"
        peerStream.close()
        continue

      echo "    Handshake OK, peer ID: " & peerIdToString(peerHandshake.peerId)
      echo "    Supports extensions: " & $peerHandshake.supportsExtensions

      if peerHandshake.supportsExtensions:
        connectedPeerIp = tp.ip
        echo "    Found BEP 10 peer!"
        break
      else:
        echo "    No BEP 10 support, trying next peer"
        peerStream.close()
    except CatchableError as e:
      echo "    Failed: " & e.msg

  if connectedPeerIp.len == 0:
    echo "SKIP: no peers support BEP 10 extensions (cannot do metadata exchange)"
    return

  echo "PASS: found BEP 10 peer"

  echo ""
  echo "Step 5: BEP 10 extended handshake"

  # Register ut_metadata extension locally
  var extReg: ExtensionRegistry = newExtensionRegistry()
  let localMetaId: ExtensionId = extReg.registerExtension(UtMetadataName)
  echo "  Local ut_metadata ID: " & $localMetaId

  # Send our extended handshake
  let extHsPayload: string = encodeExtHandshake(extReg, clientName = "NimCPS/0.1")
  let extHsMsg: string = encodeMessage(extendedMsg(ExtHandshakeId, extHsPayload))
  await peerStream.write(extHsMsg)
  echo "  Sent BEP 10 handshake"

  # Read messages until we get the peer's extended handshake
  var gotExtHandshake: bool = false
  var remoteMetaId: ExtensionId = 0
  var metadataSize: int = 0
  let deadline: float = epochTime() + (TimeoutMs.float / 1000.0)
  var msgCount: int = 0

  while epochTime() < deadline and msgCount < 200 and not gotExtHandshake:
    let lenData: string = await peerReader.readExact(4)
    let msgLen: uint32 = readUint32BE(lenData, 0)

    if msgLen == 0:
      continue  # Keep-alive

    if msgLen > 2 * 1024 * 1024:
      echo "  Message too large: " & $msgLen
      break

    let payload: string = await peerReader.readExact(msgLen.int)
    let msgId: int = payload[0].byte.int
    msgCount += 1

    if msgId == 20:  # Extended message
      let extId: int = payload[1].byte.int
      let extPayload: string = payload[2..^1]
      if extId == 0:  # Extended handshake
        extReg.decodeExtHandshake(extPayload)
        remoteMetaId = extReg.remoteId(UtMetadataName)
        metadataSize = extReg.metadataSize
        echo "  Peer client: " & extReg.clientName
        echo "  Remote ut_metadata ID: " & $remoteMetaId
        echo "  Metadata size: " & $metadataSize & " bytes"
        gotExtHandshake = true
    elif msgId == 5:  # Bitfield - ignore
      discard
    elif msgId == 14:  # HaveAll - ignore
      discard
    elif msgId == 4:  # Have - ignore
      discard
    elif msgId == 1:  # Unchoke - nice but not needed for metadata
      discard
    else:
      discard  # Ignore other messages

  if not gotExtHandshake:
    echo "SKIP: peer did not send extended handshake"
    peerStream.close()
    return

  if remoteMetaId == 0:
    echo "SKIP: peer does not support ut_metadata"
    peerStream.close()
    return

  if metadataSize <= 0:
    echo "SKIP: peer reports metadata size 0"
    peerStream.close()
    return

  echo "PASS: BEP 10 extended handshake"

  echo ""
  echo "Step 6: BEP 9 metadata exchange"

  # Initialize metadata exchange
  let metaExchange: MetadataExchange = newMetadataExchange(magnet.infoHash)
  metaExchange.initFromSize(metadataSize)
  echo "  Metadata pieces: " & $metaExchange.numPieces

  # Request all metadata pieces
  var reqIdx: int = 0
  while reqIdx < metaExchange.numPieces:
    let reqPayload: string = encodeMetadataRequest(reqIdx)
    let reqMsg: string = encodeMessage(extendedMsg(remoteMetaId.uint8, reqPayload))
    await peerStream.write(reqMsg)
    reqIdx += 1
  echo "  Sent " & $metaExchange.numPieces & " metadata requests"

  # Receive metadata pieces
  let metaDeadline: float = epochTime() + (TimeoutMs.float / 1000.0)
  var allReceived: bool = false
  var rejectCount: int = 0

  while epochTime() < metaDeadline and not allReceived:
    let lenData2: string = await peerReader.readExact(4)
    let msgLen2: uint32 = readUint32BE(lenData2, 0)

    if msgLen2 == 0:
      continue

    if msgLen2 > 2 * 1024 * 1024:
      echo "  Message too large: " & $msgLen2
      break

    let payload2: string = await peerReader.readExact(msgLen2.int)
    let msgId2: int = payload2[0].byte.int

    if msgId2 == 20:  # Extended message
      let extId2: int = payload2[1].byte.int
      let extPayload2: string = payload2[2..^1]

      # Check if this is a ut_metadata message to us
      if extId2 == localMetaId.int:
        let metaMsg = decodeMetadataMsg(extPayload2)
        if metaMsg.msgType == mtData:
          echo "  Received metadata piece " & $metaMsg.piece &
               " (" & $metaMsg.data.len & " bytes)"
          allReceived = metaExchange.receivePiece(metaMsg.piece, metaMsg.data)
        elif metaMsg.msgType == mtReject:
          echo "  Peer rejected metadata piece " & $metaMsg.piece
          rejectCount += 1
          if rejectCount >= metaExchange.numPieces:
            echo "  All pieces rejected"
            break

  peerStream.close()

  if not allReceived:
    echo "SKIP: did not receive all metadata pieces"
    return

  echo "  All " & $metaExchange.numPieces & " metadata pieces received"
  echo "PASS: metadata download"

  echo ""
  echo "Step 7: Verify metadata SHA1"

  let assembled: string = metaExchange.assembleAndVerify()
  if assembled.len == 0:
    echo "FAIL: metadata SHA1 does not match info hash!"
    assert false, "metadata SHA1 mismatch"
    return

  echo "  Metadata size: " & $assembled.len & " bytes"
  echo "  SHA1 verified against info hash!"
  echo "PASS: metadata SHA1 verification"

  echo ""
  echo "Step 8: Parse metadata and validate"

  let info: TorrentInfo = parseRawInfoDict(assembled, magnet.infoHash)
  echo "  Name: " & info.name
  echo "  Pieces: " & $info.pieceCount
  echo "  Piece length: " & $(info.pieceLength div 1024) & " KiB"
  echo "  Total size: " & $(info.totalLength div (1024 * 1024)) & " MiB"
  echo "  Files: " & $info.files.len

  # Validate against reference
  assert info.name == refInfo.name, "name mismatch: " & info.name & " != " & refInfo.name
  assert info.pieceCount == refInfo.pieceCount, "piece count mismatch"
  assert info.pieceLength == refInfo.pieceLength, "piece length mismatch"
  assert info.totalLength == refInfo.totalLength, "total length mismatch"
  assert info.files.len == refInfo.files.len, "file count mismatch"
  echo "  All fields match reference torrent!"
  echo "PASS: metadata parsing and validation"

  echo ""
  echo "=========================================="
  echo "ALL MAGNET LINK E2E STEPS PASSED!"
  echo "=========================================="

# Main
echo "Magnet Link E2E Integration Test"
echo "================================="
echo ""

echo "Step 0: Download reference torrent file"
if not downloadTorrentFile():
  echo "SKIP: could not download reference torrent file (need internet)"
  quit(0)
echo "PASS: reference torrent downloaded"
echo ""

block:
  let fut = runMagnetTest()
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
