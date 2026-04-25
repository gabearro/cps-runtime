## Debug test: detailed analysis of peer connection failures.
## Tracks errors, peer counts, and download progress with categorization.

import cps/runtime
import cps/transform
import cps/eventloop
import cps/concurrency/channels
import cps/bittorrent/client
import cps/bittorrent/metainfo
import std/[os, strutils, times, tables]

type
  ErrorStats = object
    connRefused: int
    timedOut: int
    shortReads: int
    infoHashMismatch: int
    trackerErrors: int
    dhtMessages: int
    otherErrors: seq[string]

proc categorize(msg: string, stats: var ErrorStats) =
  if msg.startsWith("DHT") or msg.startsWith("  DHT"):
    stats.dhtMessages += 1
  elif "Connection failed: 61" in msg:
    stats.connRefused += 1
  elif "Operation timed out" in msg or "timed out" in msg:
    stats.timedOut += 1
  elif "of 68 bytes" in msg:
    stats.shortReads += 1
  elif "info hash mismatch" in msg:
    stats.infoHashMismatch += 1
  elif msg.startsWith("tracker"):
    stats.trackerErrors += 1
  else:
    if stats.otherErrors.len < 30:
      var isDup = false
      for e in stats.otherErrors:
        if e == msg:
          isDup = true
          break
      if not isDup:
        stats.otherErrors.add(msg)

proc debugConnections(): CpsVoidFuture {.cps.} =
  let path = "/Users/gabriel/Downloads/linuxmint-22.3-cinnamon-64bit.iso.torrent"
  if not fileExists(path):
    echo "Torrent file not found: ", path
    return

  let metainfo = parseTorrentFile(path)
  echo "=== Connection Debug Test ==="
  echo "Torrent: ", metainfo.info.name
  echo "Pieces: ", metainfo.info.pieceCount
  echo "Size: ", metainfo.info.totalLength div (1024 * 1024), " MiB"
  echo "Tracker: ", metainfo.announce
  echo ""

  let config = ClientConfig(
    downloadDir: "/tmp/torrent_conn_debug",
    listenPort: 16882,
    maxPeers: 50,
    downloadBandwidth: 0,
    uploadBandwidth: 0
  )
  let tc = newTorrentClient(metainfo, config)

  discard spawn tc.start()

  var stats: ErrorStats
  var totalErrors = 0
  var totalPieces = 0
  var maxPeers = 0
  let startTime = epochTime()
  let testDuration = 60.0

  while epochTime() - startTime < testDuration:
    let evt = await tc.events.recv()
    let elapsed = epochTime() - startTime
    let ts = formatFloat(elapsed, ffDecimal, 1)

    case evt.kind
    of cekStarted:
      echo "[", ts, "s] Client started"

    of cekTrackerResponse:
      echo "[", ts, "s] Tracker: ", evt.newPeers, " new peers (",
           evt.seeders, " seeders, ", evt.leechers, " leechers)"

    of cekError:
      totalErrors += 1
      categorize(evt.errMsg, stats)
      # Only print interesting errors (not conn refused / timeout spam)
      if "Connection failed: 61" notin evt.errMsg and
         "Operation timed out" notin evt.errMsg and
         not evt.errMsg.startsWith("DHT") and
         not evt.errMsg.startsWith("  DHT"):
        echo "[", ts, "s] ERROR: ", evt.errMsg

    of cekPieceVerified:
      totalPieces += 1
      if totalPieces mod 10 == 0 or totalPieces <= 5:
        echo "[", ts, "s] Pieces verified: ", totalPieces

    of cekProgress:
      if evt.peerCount > maxPeers:
        maxPeers = evt.peerCount
      echo "[", ts, "s] Progress: ", evt.completedPieces, "/", evt.totalPieces,
           " peers=", evt.peerCount,
           " dl=", formatFloat(evt.downloadRate / (1024 * 1024), ffDecimal, 2), " MB/s",
           " ul=", formatFloat(evt.uploadRate / 1024, ffDecimal, 1), " KB/s",
           " dht=", tc.dhtNodeCount

    of cekPeerConnected:
      echo "[", ts, "s] Peer connected: ", evt.peerAddr
    of cekPeerDisconnected:
      echo "[", ts, "s] Peer disconnected: ", evt.peerAddr

    of cekCompleted:
      echo "[", ts, "s] COMPLETED!"
      break
    of cekStopped:
      echo "[", ts, "s] STOPPED"
      break
    of cekInfo, cekPieceStateChanged:
      discard

  echo ""
  echo "=== Results after ", formatFloat(epochTime() - startTime, ffDecimal, 1), "s ==="
  echo "Pieces verified: ", totalPieces
  echo "Max concurrent peers: ", maxPeers
  echo "DHT nodes: ", tc.dhtNodeCount
  echo "Current peers: ", tc.connectedPeerCount
  echo ""
  echo "Error breakdown (", totalErrors, " total):"
  echo "  Connection refused: ", stats.connRefused
  echo "  Operation timed out: ", stats.timedOut
  echo "  Handshake short read: ", stats.shortReads
  echo "  Info hash mismatch: ", stats.infoHashMismatch
  echo "  Tracker errors: ", stats.trackerErrors
  echo "  DHT status msgs: ", stats.dhtMessages
  echo "  Other unique errors (", stats.otherErrors.len, "):"
  for e in stats.otherErrors:
    echo "    - ", e

  tc.stop()
  echo "Done."

runCps(debugConnections())
