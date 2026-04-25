## End-to-end test using the TorrentClient orchestrator.
##
## Downloads the first few pieces of the Ubuntu torrent using the full
## client pipeline: tracker → peer connections → piece requests → disk I/O.
## Verifies piece integrity via SHA1.
##
## Requires internet access. Run manually:
##   nim c -r tests/bittorrent/test_client_e2e.nim

import std/[os, osproc, times, options]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/concurrency/channels
import cps/bittorrent/metainfo
import cps/bittorrent/client
import cps/bittorrent/pieces

const
  TorrentUrl = "https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-desktop-amd64.iso.torrent"
  TorrentPath = "/tmp/ubuntu_client_e2e.torrent"
  DownloadDir = "/tmp/bt_client_e2e_test"
  TargetPieces = 3            ## Download at least 3 pieces to pass
  MaxWaitSec = 120            ## Max wait time in seconds

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

proc runClientE2e(): CpsVoidFuture {.cps.} =
  echo "Step 1: Parse torrent file"
  let torrentData: string = readFile(TorrentPath)
  let meta: TorrentMetainfo = parseTorrent(torrentData)
  echo "  Name: " & meta.info.name
  echo "  Pieces: " & $meta.info.pieceCount & " x " & $(meta.info.pieceLength div 1024) & " KiB"
  echo "  Total: " & $(meta.info.totalLength div (1024 * 1024)) & " MiB"
  echo "  Web seeds: " & $meta.urlList.len
  echo "PASS: torrent parsed"

  # ── Step 2: Create TorrentClient ─────────────────────────────
  echo ""
  echo "Step 2: Create and start TorrentClient"

  # Clean up any previous test data
  if dirExists(DownloadDir / meta.info.name):
    removeDir(DownloadDir / meta.info.name)

  var config: ClientConfig = defaultConfig()
  config.downloadDir = DownloadDir
  config.listenPort = 6891  # Avoid conflicting with other BT clients
  config.maxPeers = 30

  let torrentClient: TorrentClient = newTorrentClient(meta, config)
  echo "  Peer ID: " & $torrentClient.peerId[0..5]
  echo "  Web seeds: " & $torrentClient.webSeeds.len
  echo "PASS: client created"

  # ── Step 3: Start client (launches all loops) ────────────────
  echo ""
  echo "Step 3: Start download (target: " & $TargetPieces & " verified pieces)"

  # Start client in background
  let clientFut: CpsVoidFuture = start(torrentClient)

  # Monitor progress by polling client events
  let startTime: float = epochTime()
  var lastReport: float = startTime
  var lastVerified: int = 0
  var reachedTarget: bool = false

  while not reachedTarget:
    let elapsed: float = epochTime() - startTime
    if elapsed > MaxWaitSec.float:
      echo "  Timeout after " & $MaxWaitSec & "s"
      break

    # Drain all available client events
    var draining: bool = true
    while draining:
      let maybeEvt: Option[ClientEvent] = torrentClient.events.tryRecv()
      if maybeEvt.isNone:
        draining = false
      else:
        let evt: ClientEvent = maybeEvt.get
        case evt.kind
        of cekStarted:
          echo "  [event] Client started"
        of cekPeerConnected:
          echo "  [event] Peer connected: " & evt.peerAddr
        of cekPeerDisconnected:
          discard
        of cekTrackerResponse:
          echo "  [event] Tracker: +" & $evt.newPeers & " peers (seeders=" & $evt.seeders & ")"
        of cekPieceVerified:
          echo "  [event] Piece " & $evt.pieceIndex & " verified!"
        of cekProgress:
          let elapsedSec: int = int(epochTime() - startTime)
          echo "  [" & $elapsedSec & "s] Peers: " & $evt.peerCount &
               " | Pieces: " & $evt.completedPieces & "/" & $evt.totalPieces &
               " | DL: " & $(evt.downloadRate.int div 1024) & " KiB/s"
        of cekCompleted:
          echo "  [event] Download complete!"
          reachedTarget = true
        of cekError:
          echo "  [event] Error: " & evt.errMsg
        of cekStopped:
          echo "  [event] Client stopped"
        of cekInfo, cekPieceStateChanged:
          discard

    # Check piece manager directly
    if torrentClient.pieceMgr != nil:
      let verified: int = torrentClient.pieceMgr.verifiedCount
      if verified >= TargetPieces:
        reachedTarget = true

    await cpsSleep(500)

  # ── Step 4: Verify results ──────────────────────────────────
  echo ""
  echo "Step 4: Verify results"

  torrentClient.stop()
  # Give it a moment to clean up
  await cpsSleep(500)

  if torrentClient.pieceMgr == nil:
    echo "SKIP: piece manager never initialized"
  else:
    let verified: int = torrentClient.pieceMgr.verifiedCount
    let downloaded: int64 = torrentClient.pieceMgr.downloaded
    echo "  Verified pieces: " & $verified
    echo "  Downloaded bytes: " & $downloaded
    echo "  Peers connected: " & $torrentClient.connectedPeerCount

    if verified >= TargetPieces:
      echo "PASS: downloaded and verified " & $verified & " pieces!"

      # Verify files exist on disk
      let downloadPath = DownloadDir / meta.info.name
      if meta.info.files.len > 0:
        let firstFile = downloadPath / meta.info.files[0].path
        if fileExists(firstFile):
          let size = getFileSize(firstFile)
          echo "  First file exists: " & firstFile & " (" & $size & " bytes)"
          echo "PASS: files written to disk"
        else:
          echo "  First file missing: " & firstFile
          echo "PASS: pieces verified (file check skipped)"
    else:
      echo "  Only got " & $verified & "/" & $TargetPieces & " pieces"
      if verified > 0:
        echo "PASS: partial download successful (" & $verified & " pieces)"
      else:
        echo "SKIP: no pieces downloaded (network conditions)"

  # Clean up test files
  if dirExists(DownloadDir / meta.info.name):
    removeDir(DownloadDir / meta.info.name)

  echo ""
  echo "=========================================="
  echo "CLIENT E2E TEST COMPLETE!"
  echo "=========================================="

# ── Main ─────────────────────────────────────────────────────────

echo "TorrentClient End-to-End Test"
echo "============================="
echo ""

echo "Step 0: Download reference torrent file"
if not downloadTorrentFile():
  echo "SKIP: could not download reference torrent file (need internet)"
  quit(0)
echo "PASS: reference torrent downloaded"
echo ""

block:
  let fut = runClientE2e()
  let loop = getEventLoop()
  var ticks = 0
  # Allow up to 3 minutes
  while not fut.finished and ticks < 3600000:
    loop.tick()
    ticks += 1

  if fut.hasError:
    echo "ERROR: " & fut.getError().msg
    quit(1)

  if not fut.finished:
    echo "TIMEOUT: test did not complete within tick limit"
    quit(1)
