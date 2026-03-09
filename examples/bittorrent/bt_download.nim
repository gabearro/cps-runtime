## BitTorrent download example.
##
## Usage: bt_download <torrent_file> [download_dir]

import std/[os, strutils, times]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/concurrency/channels
import cps/bittorrent/metainfo
import cps/bittorrent/client

proc formatSize(bytes: float): string =
  if bytes < 1024: return $bytes.int & " B"
  elif bytes < 1024*1024: return $(bytes / 1024).formatFloat(ffDecimal, 1) & " KB"
  elif bytes < 1024*1024*1024: return $(bytes / (1024*1024)).formatFloat(ffDecimal, 1) & " MB"
  else: return $(bytes / (1024*1024*1024)).formatFloat(ffDecimal, 2) & " GB"

proc formatSpeed(bytesPerSec: float): string =
  formatSize(bytesPerSec) & "/s"

proc displayLoop(events: AsyncChannel[ClientEvent], torrentName: string): CpsVoidFuture {.cps.} =
  echo "Starting download: " & torrentName
  while true:
    let evt: ClientEvent = await events.recv()
    case evt.kind
    of cekStarted:
      echo "Client started"
    of cekTrackerResponse:
      echo "Tracker: " & $evt.newPeers & " new peers, " &
           $evt.seeders & " seeders, " & $evt.leechers & " leechers"
    of cekPeerConnected:
      echo "  + Peer connected: " & evt.peerAddr
    of cekPeerDisconnected:
      echo "  - Peer disconnected: " & evt.peerAddr
    of cekPieceVerified:
      echo "  Piece " & $evt.pieceIndex & " verified"
    of cekProgress:
      let pct: float = if evt.totalPieces > 0:
        100.0 * evt.completedPieces.float / evt.totalPieces.float
      else:
        0.0
      echo "[" & pct.formatFloat(ffDecimal, 1) & "%] " &
           $evt.completedPieces & "/" & $evt.totalPieces & " pieces | " &
           "DL: " & formatSpeed(evt.downloadRate) & " | " &
           "UL: " & formatSpeed(evt.uploadRate) & " | " &
           $evt.peerCount & " peers"
    of cekCompleted:
      echo ""
      echo "Download complete!"
    of cekError:
      echo "Error: " & evt.errMsg
    of cekStopped:
      echo "Client stopped"
      return

proc main(): CpsVoidFuture {.cps.} =
  let args: seq[string] = commandLineParams()
  if args.len < 1:
    echo "Usage: bt_download <torrent_file> [download_dir]"
    return

  let torrentPath: string = args[0]
  let downloadDir: string = if args.len > 1: args[1] else: getCurrentDir()

  if not fileExists(torrentPath):
    echo "Error: file not found: " & torrentPath
    return

  echo "Parsing torrent: " & torrentPath
  let meta: TorrentMetainfo = parseTorrentFile(torrentPath)
  echo "Name: " & meta.info.name
  echo "Size: " & formatSize(meta.info.totalLength.float)
  echo "Pieces: " & $meta.info.pieceCount & " x " & formatSize(meta.info.pieceLength.float)
  echo "Tracker: " & meta.announce
  if meta.info.files.len > 1:
    echo "Files: " & $meta.info.files.len
    var i: int = 0
    while i < meta.info.files.len and i < 10:
      echo "  " & meta.info.files[i].path & " (" & formatSize(meta.info.files[i].length.float) & ")"
      i += 1
    if meta.info.files.len > 10:
      echo "  ... and " & $(meta.info.files.len - 10) & " more"
  echo ""

  var config: ClientConfig = defaultConfig()
  config.downloadDir = downloadDir

  let client: TorrentClient = newTorrentClient(meta, config)

  # Run display loop and client concurrently
  let displayFut: CpsVoidFuture = displayLoop(client.events, meta.info.name)
  let clientFut: CpsVoidFuture = start(client)

  await displayFut

runCps(main())
