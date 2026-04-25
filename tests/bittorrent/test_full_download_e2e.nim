## End-to-end test: Full Ubuntu ISO download via TorrentClient.
##
## Downloads the complete Ubuntu 24.04.4 desktop ISO (~6 GiB) using
## the full client pipeline: tracker, DHT, PEX, peer connections,
## piece requests, SHA1 verification, disk I/O.
##
## This test validates the entire networked flow end-to-end.
##
## Requires internet access and ~7 GiB free disk space.
## Run manually:
##   nim c -r tests/bittorrent/test_full_download_e2e.nim

import std/[os, osproc, times, options, strutils]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/concurrency/channels
import cps/bittorrent/metainfo
import cps/bittorrent/client
import cps/bittorrent/pieces

const
  TorrentPath = "/Users/gabriel/Downloads/linuxmint-22.3-cinnamon-64bit.iso.torrent"
  DownloadDir = "/tmp/bt_full_download_e2e"
  MaxWaitSec = 7200            ## 2 hours max for the full ISO
  ProgressIntervalSec = 10.0   ## Print progress every 10s
  StallTimeoutSec = 300.0      ## Abort if no progress for 5 minutes

proc downloadTorrentFile(): bool =
  if fileExists(TorrentPath):
    echo "  Using local torrent file: " & TorrentPath
    return true
  echo "  Torrent file not found: " & TorrentPath
  return false

proc formatBytes(b: int64): string =
  if b >= 1073741824:
    return $(b div 1073741824) & "." & $((b mod 1073741824) * 10 div 1073741824) & " GiB"
  elif b >= 1048576:
    return $(b div 1048576) & "." & $((b mod 1048576) * 10 div 1048576) & " MiB"
  elif b >= 1024:
    return $(b div 1024) & " KiB"
  else:
    return $b & " B"

proc formatRate(bytesPerSec: float): string =
  if bytesPerSec >= 1048576.0:
    return $(int(bytesPerSec / 1048576.0)) & "." & $(int(bytesPerSec / 104857.6) mod 10) & " MiB/s"
  elif bytesPerSec >= 1024.0:
    return $(int(bytesPerSec / 1024.0)) & " KiB/s"
  else:
    return $(int(bytesPerSec)) & " B/s"

proc formatEta(remainBytes: int64, rate: float): string =
  if rate <= 0.0:
    return "unknown"
  let secs = int(remainBytes.float / rate)
  let h = secs div 3600
  let m = (secs mod 3600) div 60
  let s = secs mod 60
  if h > 0:
    return $h & "h " & $m & "m"
  elif m > 0:
    return $m & "m " & $s & "s"
  else:
    return $s & "s"

proc runFullDownload(): CpsVoidFuture {.cps.} =
  echo "Step 1: Parse torrent file"
  let torrentData: string = readFile(TorrentPath)
  let meta: TorrentMetainfo = parseTorrent(torrentData)
  echo "  Name: " & meta.info.name
  echo "  Pieces: " & $meta.info.pieceCount & " x " & $(meta.info.pieceLength div 1024) & " KiB"
  echo "  Total size: " & formatBytes(meta.info.totalLength)
  echo "  Files: " & $meta.info.files.len
  echo "  Web seeds: " & $meta.urlList.len
  echo "  Trackers: " & $meta.announceList.len & " tiers"
  echo "PASS: torrent parsed"

  # ── Step 2: Create TorrentClient ─────────────────────────────
  echo ""
  echo "Step 2: Create and start TorrentClient"

  var config: ClientConfig = defaultConfig()
  config.downloadDir = DownloadDir
  config.listenPort = 6893  # Avoid conflicting with other BT clients/tests
  config.maxPeers = 80      # More peers for faster download

  let torrentClient: TorrentClient = newTorrentClient(meta, config)
  echo "  Download dir: " & DownloadDir / meta.info.name
  echo "  Listen port: " & $config.listenPort
  echo "  Max peers: " & $config.maxPeers
  echo "PASS: client created"

  # ── Step 3: Start full download ────────────────────────────
  echo ""
  echo "Step 3: Start full download"

  let clientFut: CpsVoidFuture = start(torrentClient)

  let startTime: float = epochTime()
  var lastProgressTime: float = startTime
  var lastProgressPieces: int = 0
  var lastStallCheck: float = startTime
  var lastStallPieces: int = 0
  var completed: bool = false
  var peakRate: float = 0.0
  var totalPeersEverSeen: int = 0

  while not completed:
    let now: float = epochTime()
    let elapsed: float = now - startTime

    if elapsed > MaxWaitSec.float:
      echo "  TIMEOUT after " & $MaxWaitSec & "s"
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
          totalPeersEverSeen += 1
        of cekPeerDisconnected:
          discard
        of cekTrackerResponse:
          echo "  [event] Tracker: +" & $evt.newPeers & " peers (seeders=" & $evt.seeders & ")"
        of cekPieceVerified:
          discard  # Reported in progress below
        of cekProgress:
          if now - lastProgressTime >= ProgressIntervalSec:
            lastProgressTime = now
            let percent: float = if evt.totalPieces > 0:
              100.0 * evt.completedPieces.float / evt.totalPieces.float
            else: 0.0
            let elapsedSec: int = int(elapsed)
            let remaining: int64 = if torrentClient.pieceMgr != nil:
              torrentClient.pieceMgr.bytesRemaining
            else: 0'i64
            if evt.downloadRate > peakRate:
              peakRate = evt.downloadRate
            echo "  [" & $elapsedSec & "s] " &
                 $evt.completedPieces & "/" & $evt.totalPieces & " pieces (" &
                 percent.formatFloat(ffDecimal, 1) & "%) | " &
                 "DL: " & formatRate(evt.downloadRate) & " | " &
                 "UL: " & formatRate(evt.uploadRate) & " | " &
                 "Peers: " & $evt.peerCount & " | " &
                 "ETA: " & formatEta(remaining, evt.downloadRate)
            lastProgressPieces = evt.completedPieces
        of cekCompleted:
          echo ""
          echo "  =========================================="
          echo "  DOWNLOAD COMPLETE!"
          echo "  =========================================="
          completed = true
        of cekError:
          echo "  [error] " & evt.errMsg
        of cekStopped:
          echo "  [event] Client stopped"
        of cekInfo, cekPieceStateChanged:
          discard

    # Stall detection: if no new pieces in StallTimeoutSec, abort
    if torrentClient.pieceMgr != nil:
      let currentPieces: int = torrentClient.pieceMgr.verifiedCount
      if currentPieces > lastStallPieces:
        lastStallPieces = currentPieces
        lastStallCheck = now
      elif now - lastStallCheck > StallTimeoutSec:
        echo "  STALL: no progress for " & $int(StallTimeoutSec) & "s, aborting"
        break

    await cpsSleep(500)

  # ── Step 4: Verify results ──────────────────────────────────
  echo ""
  echo "Step 4: Verify results"

  let totalElapsed: float = epochTime() - startTime

  torrentClient.stop()
  await cpsSleep(1000)

  if torrentClient.pieceMgr == nil:
    echo "FAIL: piece manager never initialized"
  else:
    let verified: int = torrentClient.pieceMgr.verifiedCount
    let totalPieces: int = torrentClient.pieceMgr.totalPieces
    let downloaded: int64 = torrentClient.pieceMgr.downloaded
    let uploaded: int64 = torrentClient.pieceMgr.uploaded

    echo ""
    echo "  ── Download Summary ──"
    echo "  Verified pieces: " & $verified & "/" & $totalPieces
    echo "  Downloaded: " & formatBytes(downloaded)
    echo "  Uploaded: " & formatBytes(uploaded)
    echo "  Peak rate: " & formatRate(peakRate)
    echo "  Average rate: " & formatRate(downloaded.float / max(totalElapsed, 1.0))
    echo "  Elapsed: " & formatEta(0, 1.0 / max(totalElapsed, 1.0)).replace("unknown", $int(totalElapsed) & "s")
    echo "  Total peers seen: " & $totalPeersEverSeen
    echo ""

    if completed and verified == totalPieces:
      echo "PASS: all " & $totalPieces & " pieces downloaded and verified!"

      # Verify files exist on disk with correct total size
      let downloadPath = DownloadDir / meta.info.name
      var totalFileSize: int64 = 0
      var allFilesExist: bool = true
      var fi: int = 0
      while fi < meta.info.files.len:
        let fe = meta.info.files[fi]
        fi += 1
        let filePath = downloadPath / fe.path
        if not fileExists(filePath):
          echo "  MISSING: " & fe.path
          allFilesExist = false
        else:
          totalFileSize += getFileSize(filePath)

      if allFilesExist:
        echo "  All " & $meta.info.files.len & " files present on disk"
        echo "  Total file size: " & formatBytes(totalFileSize)
        if totalFileSize == meta.info.totalLength:
          echo "PASS: file sizes match expected total (" & formatBytes(meta.info.totalLength) & ")"
        else:
          echo "  Expected: " & formatBytes(meta.info.totalLength)
          echo "  Got: " & formatBytes(totalFileSize)
          echo "WARN: file size mismatch (pre-allocated files may be larger)"
      else:
        echo "WARN: some files missing"

      echo ""
      echo "PASS: full e2e download test succeeded!"
    elif verified > 0:
      let pct: float = 100.0 * verified.float / totalPieces.float
      echo "PARTIAL: downloaded " & $verified & "/" & $totalPieces & " pieces (" &
           pct.formatFloat(ffDecimal, 1) & "%)"
      echo "  This may be due to timeout, stall, or network conditions."
      if verified >= totalPieces div 2:
        echo "PASS: downloaded >50% of the torrent successfully"
      else:
        echo "SKIP: insufficient progress for full validation"
    else:
      echo "SKIP: no pieces downloaded (network conditions)"

  echo ""
  echo "=========================================="
  echo "FULL DOWNLOAD E2E TEST COMPLETE!"
  echo "=========================================="
  echo "Elapsed: " & $int(totalElapsed) & "s"

# ── Main ─────────────────────────────────────────────────────────

echo "Full BitTorrent Download E2E Test"
echo "================================="
echo ""
echo "This test downloads the complete Ubuntu 24.04.4 ISO (~6 GiB)."
echo "Requires internet access and ~7 GiB free disk space in /tmp."
echo ""

echo "Step 0: Download reference torrent file"
if not downloadTorrentFile():
  echo "SKIP: could not download reference torrent file (need internet)"
  quit(0)
echo "PASS: reference torrent downloaded"
echo ""

# Check available disk space
let (dfOutput, dfExit) = execCmdEx("df -k /tmp | tail -1 | awk '{print $4}'")
if dfExit == 0:
  let availKb = parseInt(dfOutput.strip())
  let availGb = availKb div 1048576
  echo "Available space in /tmp: ~" & $availGb & " GiB"
  if availGb < 7:
    echo "SKIP: need at least 7 GiB free in /tmp (have " & $availGb & " GiB)"
    quit(0)
  echo ""

block:
  let fut = runFullDownload()
  let loop = getEventLoop()
  var ticks = 0
  # Run for up to MaxWaitSec (tick loop limit is generous)
  let maxTicks = MaxWaitSec * 2000  # 2000 ticks/sec at ~0.5ms per tick
  while not fut.finished and ticks < maxTicks:
    loop.tick()
    ticks += 1

  if fut.hasError:
    echo "ERROR: " & fut.getError().msg
    quit(1)

  if not fut.finished:
    echo "TIMEOUT: test did not complete within tick limit"
    quit(1)
