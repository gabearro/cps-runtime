## Debug test: load a torrent and run client to observe DHT and errors.

import cps/runtime
import cps/transform
import cps/eventloop
import cps/concurrency/channels
import cps/bittorrent/client
import cps/bittorrent/metainfo
import std/[os, strutils, times]

proc debugClient(): CpsVoidFuture {.cps.} =
  let path = "/Users/gabriel/Downloads/linuxmint-22.3-cinnamon-64bit.iso.torrent"
  if not fileExists(path):
    echo "Torrent file not found: ", path
    return

  let metainfo = parseTorrentFile(path)
  echo "Loaded: ", metainfo.info.name
  echo "Pieces: ", metainfo.info.pieceCount
  echo "Total size: ", metainfo.info.totalLength
  echo "Trackers: ", metainfo.announce
  echo "Is private: ", metainfo.info.isPrivate

  let config = ClientConfig(
    downloadDir: "/tmp/torrent_debug_test",
    listenPort: 16881,  # Use non-standard port to avoid conflicts
    maxPeers: 50,
    downloadBandwidth: 0,
    uploadBandwidth: 0
  )
  let tc = newTorrentClient(metainfo, config)
  echo "DHT enabled: ", tc.dhtEnabled

  # Start client in background
  discard spawn tc.start()

  # Drain events for 30 seconds
  let startTime = epochTime()
  while epochTime() - startTime < 30:
    let evt = await tc.events.recv()
    let elapsed = formatFloat(epochTime() - startTime, ffDecimal, 1)
    case evt.kind
    of cekStarted:
      echo "[", elapsed, "s] Started"
    of cekPieceVerified:
      echo "[", elapsed, "s] Piece verified: ", evt.pieceIndex
    of cekProgress:
      echo "[", elapsed, "s] Progress: ", evt.completedPieces, "/", evt.totalPieces,
           " peers=", evt.peerCount,
           " dl=", formatFloat(evt.downloadRate / 1024, ffDecimal, 1), " KB/s",
           " ul=", formatFloat(evt.uploadRate / 1024, ffDecimal, 1), " KB/s"
      echo "  DHT nodes: ", tc.dhtNodeCount
    of cekPeerConnected:
      echo "[", elapsed, "s] Peer connected: ", evt.peerAddr
    of cekPeerDisconnected:
      echo "[", elapsed, "s] Peer disconnected: ", evt.peerAddr
    of cekError:
      echo "[", elapsed, "s] ERROR: ", evt.errMsg
    of cekTrackerResponse:
      echo "[", elapsed, "s] Tracker response: ", evt.newPeers, " new peers, ",
           evt.seeders, " seeders, ", evt.leechers, " leechers"
    of cekCompleted:
      echo "[", elapsed, "s] Completed!"
    of cekStopped:
      echo "[", elapsed, "s] Stopped"
      break
    of cekInfo, cekPieceStateChanged:
      discard

  echo "\nFinal state: ", tc.state
  echo "DHT nodes: ", tc.dhtNodeCount
  echo "Connected peers: ", tc.connectedPeerCount
  tc.stop()
  echo "Stopped client"

runCps(debugClient())
