## Standalone CLI debug runner for the BitTorrent bridge.
## Replicates the same threading model as the SwiftUI GUI bridge
## (event loop thread + main thread polling) without needing the UI.
##
## Usage:
##   nim c -r --mm:atomicArc examples/gui/torrent/cli_debug.nim [torrent-file]
##
## Without arguments, restores the GUI session from:
##   ~/Library/Application Support/CpsTorrent/session.json
##
## With a torrent file argument, loads settings from session.json
## then adds the specified torrent.

import cps/runtime
import cps/transform
import cps/eventloop
import cps/mt/mtruntime
import cps/bittorrent/client
import cps/bittorrent/metainfo
import cps/bittorrent/metadata
import cps/bittorrent/pieces
import cps/bittorrent/peer
import cps/bittorrent/peerid
import cps/bittorrent/extensions
import cps/bittorrent/mse
import cps/concurrency/channels
import cps/concurrency/sync
import cps/io/tcp
import cps/io/udp
import cps/io/nat
import cps/io/streams
import cps/io/timeouts
import cps/bittorrent/utp_stream

import std/[json, os, strutils, times, atomics, posix, tables, sets, math, locks, strformat]

# ============================================================
# Logging (stdout + file)
# ============================================================

var gLogFile: File
var gLogReady: bool = false

proc log(msg: string) =
  let line = "[" & $epochTime() & "] " & msg
  echo line
  if not gLogReady:
    gLogReady = gLogFile.open("/tmp/torrent_cli_debug.log", fmAppend)
  if gLogReady:
    gLogFile.writeLine(line)
    gLogFile.flushFile()

# ============================================================
# Mailbox (same as bridge.nim)
# ============================================================

const MailboxMaxCapacity = 16384

type
  Mailbox[T] = object
    lock: Lock
    pending: seq[T]

proc initMailbox[T](mb: var Mailbox[T]) =
  initLock(mb.lock)
  mb.pending = @[]

proc send[T](mb: var Mailbox[T], item: sink T): bool =
  acquire(mb.lock)
  if mb.pending.len >= MailboxMaxCapacity:
    release(mb.lock)
    return false
  mb.pending.add(move item)
  release(mb.lock)
  true

proc drainAll[T](mb: var Mailbox[T]): seq[T] =
  acquire(mb.lock)
  result = move mb.pending
  mb.pending = @[]
  release(mb.lock)

# ============================================================
# Types (mirrored from bridge)
# ============================================================

type
  PeerSnapshotEntry = object
    address: string
    clientName: string
    flags: string
    progress: float
    downloadRate: float
    uploadRate: float
    downloadedBytes: float
    uploadedBytes: float
    transport: string

  TrackerState = object
    url: string
    status: string
    seeders: int
    leechers: int
    completed: int
    lastAnnounce: string
    nextAnnounce: string
    lastScrape: string
    nextScrape: string
    errorText: string

  UiEventKind = enum
    uiTorrentStarted, uiPieceVerified, uiProgress, uiPeerConnected,
    uiPeerDisconnected, uiCompleted, uiError, uiInfo, uiStopped, uiTrackerResponse,
    uiClientReady, uiClientError, uiTorrentPaused, uiTorrentRemoved,
    uiRechecking, uiNatStatus

  UiEvent = object
    kind: UiEventKind
    torrentId: int
    intParam: int
    intParam2: int
    intParam3: int
    floatParam: float
    floatParam2: float
    floatParam3: float
    floatParam4: float
    floatParam5: float
    floatParam6: float
    text: string
    text2: string
    text3: string
    boolParam: bool
    peerSnapshot: seq[PeerSnapshotEntry]
    pieceMapData: string
    trackerSnapshot: seq[TrackerState]
    fileInfo: seq[tuple[path: string, length: int64]]
    filePriorities: seq[string]
    announceUrls: seq[string]
    downloadDir: string
    protocolPrivate: bool
    protocolDhtEnabled: bool
    protocolPexEnabled: bool
    protocolLsdEnabled: bool
    protocolUtpEnabled: bool
    protocolWebSeedEnabled: bool
    protocolScrapeEnabled: bool
    protocolHolepunchEnabled: bool
    protocolEncryptionMode: string
    protocolUtpPeers: int
    protocolTcpPeers: int
    protocolLsdAnnounces: int
    protocolLsdPeers: int
    protocolLsdLastError: string
    protocolWebSeedBytes: int
    protocolWebSeedFailures: int
    protocolWebSeedActiveUrl: string
    protocolHolepunchAttempts: int
    protocolHolepunchSuccesses: int
    protocolHolepunchLastError: string

  BridgeCommandKind = enum
    cmdAddTorrentFile, cmdAddTorrentMagnet, cmdShutdown

  BridgeCommand = object
    kind: BridgeCommandKind
    intParam: int
    text: string
    text2: string

# ============================================================
# Clone helpers (same as bridge — isolate ARC refs across threads)
# ============================================================

proc cloneStringIsolated(s: string): string =
  if s.len == 0: return ""
  result = newString(s.len)
  copyMem(addr result[0], unsafeAddr s[0], s.len)

proc cloneStringSeqIsolated(src: seq[string]): seq[string] =
  if src.len == 0: return @[]
  result = newSeq[string](src.len)
  for i in 0 ..< src.len:
    result[i] = cloneStringIsolated(src[i])

proc clonePeerSnapshotSeqIsolated(src: seq[PeerSnapshotEntry]): seq[PeerSnapshotEntry] =
  if src.len == 0: return @[]
  result = newSeq[PeerSnapshotEntry](src.len)
  for i in 0 ..< src.len:
    result[i] = PeerSnapshotEntry(
      address: cloneStringIsolated(src[i].address),
      clientName: cloneStringIsolated(src[i].clientName),
      flags: cloneStringIsolated(src[i].flags),
      progress: src[i].progress,
      downloadRate: src[i].downloadRate,
      uploadRate: src[i].uploadRate,
      downloadedBytes: src[i].downloadedBytes,
      uploadedBytes: src[i].uploadedBytes,
      transport: cloneStringIsolated(src[i].transport),
    )

proc cloneTrackerSnapshotSeqIsolated(src: seq[TrackerState]): seq[TrackerState] =
  if src.len == 0: return @[]
  result = newSeq[TrackerState](src.len)
  for i in 0 ..< src.len:
    result[i] = TrackerState(
      url: cloneStringIsolated(src[i].url),
      status: cloneStringIsolated(src[i].status),
      seeders: src[i].seeders,
      leechers: src[i].leechers,
      completed: src[i].completed,
      lastAnnounce: cloneStringIsolated(src[i].lastAnnounce),
      nextAnnounce: cloneStringIsolated(src[i].nextAnnounce),
      lastScrape: cloneStringIsolated(src[i].lastScrape),
      nextScrape: cloneStringIsolated(src[i].nextScrape),
      errorText: cloneStringIsolated(src[i].errorText),
    )

proc cloneFileInfoSeqIsolated(src: seq[tuple[path: string, length: int64]]):
    seq[tuple[path: string, length: int64]] =
  if src.len == 0: return @[]
  result = newSeq[tuple[path: string, length: int64]](src.len)
  for i in 0 ..< src.len:
    result[i] = (path: cloneStringIsolated(src[i].path), length: src[i].length)

proc cloneUiEventIsolated(evt: UiEvent): UiEvent =
  result = evt
  result.text = cloneStringIsolated(evt.text)
  result.text2 = cloneStringIsolated(evt.text2)
  result.text3 = cloneStringIsolated(evt.text3)
  result.pieceMapData = cloneStringIsolated(evt.pieceMapData)
  result.filePriorities = cloneStringSeqIsolated(evt.filePriorities)
  result.trackerSnapshot = cloneTrackerSnapshotSeqIsolated(evt.trackerSnapshot)
  result.fileInfo = cloneFileInfoSeqIsolated(evt.fileInfo)
  result.announceUrls = cloneStringSeqIsolated(evt.announceUrls)
  result.downloadDir = cloneStringIsolated(evt.downloadDir)
  result.peerSnapshot = clonePeerSnapshotSeqIsolated(evt.peerSnapshot)
  result.protocolEncryptionMode = cloneStringIsolated(evt.protocolEncryptionMode)
  result.protocolLsdLastError = cloneStringIsolated(evt.protocolLsdLastError)
  result.protocolWebSeedActiveUrl = cloneStringIsolated(evt.protocolWebSeedActiveUrl)
  result.protocolHolepunchLastError = cloneStringIsolated(evt.protocolHolepunchLastError)

proc cloneBridgeCommandIsolated(cmd: BridgeCommand): BridgeCommand =
  result = cmd
  result.text = cloneStringIsolated(cmd.text)
  result.text2 = cloneStringIsolated(cmd.text2)

# ============================================================
# Shared state
# ============================================================

var gEventQueue: Mailbox[UiEvent]
var gCommandQueue: Mailbox[BridgeCommand]
var gCommandWakeLock: Lock
var gCommandWake: CpsVoidFuture
var gDirty: Atomic[bool]
var gShutdownComplete: Atomic[bool]
var gDroppedEventCount: Atomic[uint64]
var gDroppedCommandCount: Atomic[uint64]

# Command notify pipe
var gCmdPipeRead: cint = -1
var gCmdPipeWrite: cint = -1
var gCmdNotifyPending: Atomic[bool]

# Shared resources
var gSharedListener: TcpListener
var gSharedUtpMgr: UtpManager
var gSharedLsdSock: UdpSocket
var gNatMgr: NatManager

# Client table (event loop thread only)
var gClients: Table[int, TorrentClient]

# Settings (loaded from session.json — same as GUI)
var gDownloadDir = "~/Downloads"
var gListenPort = "6881"
var gMaxPeers = "50"
var gDhtEnabled = true
var gPexEnabled = true
var gLsdEnabled = true
var gUtpEnabled = true
var gWebSeedEnabled = true
var gTrackerScrapeEnabled = true
var gHolepunchEnabled = true
var gEncryptionMode = "prefer_encrypted"
var gMaxDownloadRate = "0"
var gMaxUploadRate = "0"

# Torrent tracking (main thread)
var gNextTorrentId = 0

# ============================================================
# Notify pipe
# ============================================================

proc notifyEventLoop() =
  if gCmdPipeWrite < 0: return
  if gCmdNotifyPending.exchange(true, moAcquireRelease): return
  var buf: array[1, byte] = [1'u8]
  while true:
    let n = posix.write(gCmdPipeWrite, addr buf[0], 1)
    if n == 1: return
    if osLastError().int == EINTR: continue
    return

proc drainCommandNotifyPipe() =
  if gCmdPipeRead < 0: return
  var buf: array[64, byte]
  while true:
    let n = posix.read(gCmdPipeRead, addr buf[0], buf.len)
    if n > 0: continue
    if n < 0:
      let err = osLastError()
      if err.int == EINTR: continue
    break

proc enqueueCommand(cmd: sink BridgeCommand) =
  if not gCommandQueue.send(cloneBridgeCommandIsolated(cmd)):
    discard gDroppedCommandCount.fetchAdd(1'u64, moRelaxed)
    return
  notifyEventLoop()

proc pushEvent(evt: sink UiEvent) =
  if not gEventQueue.send(cloneUiEventIsolated(evt)):
    discard gDroppedEventCount.fetchAdd(1'u64, moRelaxed)
    return
  gDirty.store(true, moRelease)

# ============================================================
# Formatting helpers
# ============================================================

proc formatTimestamp(ts: float): string =
  if ts <= 0: return ""
  try:
    let t = fromUnixFloat(ts)
    t.format("yyyy-MM-dd HH:mm:ss")
  except:
    ""

proc formatBytes(bytes: float): string =
  if bytes < 1024: return &"{bytes:.0f} B"
  if bytes < 1024 * 1024: return &"{bytes / 1024:.1f} KB"
  if bytes < 1024 * 1024 * 1024: return &"{bytes / (1024 * 1024):.1f} MB"
  return &"{bytes / (1024 * 1024 * 1024):.2f} GB"

proc formatRate(bytesPerSec: float): string =
  if bytesPerSec < 1: return "0 B/s"
  formatBytes(bytesPerSec) & "/s"

proc parseEncryptionMode(modeStr: string): EncryptionMode =
  case modeStr
  of "disabled", "prefer_plaintext": emPreferPlaintext
  of "require_encrypted": emRequireEncrypted
  else: emPreferEncrypted

proc encryptionModeLabel(mode: EncryptionMode): string =
  case mode
  of emPreferPlaintext: "disabled"
  of emPreferEncrypted: "prefer_encrypted"
  of emRequireEncrypted: "require_encrypted"
  of emForceRc4: "force_rc4"

# ============================================================
# JSON helpers (same as bridge)
# ============================================================

proc jStr(node: JsonNode, key: string, default: string): string =
  if node.hasKey(key) and node[key].kind == JString:
    node[key].str
  else: default

proc jBool(node: JsonNode, key: string, default: bool): bool =
  if node.hasKey(key) and node[key].kind == JBool:
    node[key].bval
  else: default

# ============================================================
# Session file (same path as GUI)
# ============================================================

const
  sessionDir = "~/Library/Application Support/CpsTorrent"
  sessionFile = sessionDir / "session.json"

proc loadSettings() =
  ## Load settings from the GUI session file.
  let path = sessionFile.expandTilde
  if not fileExists(path):
    log "[SESSION] No session file at " & path
    return

  try:
    let data = parseJson(readFile(path))
    if data.hasKey("settings"):
      let s = data["settings"]
      gDownloadDir = jStr(s, "downloadDir", gDownloadDir)
      gListenPort = jStr(s, "listenPort", gListenPort)
      gMaxDownloadRate = jStr(s, "maxDownloadRate", gMaxDownloadRate)
      gMaxUploadRate = jStr(s, "maxUploadRate", gMaxUploadRate)
      gMaxPeers = jStr(s, "maxPeers", gMaxPeers)
      gDhtEnabled = jBool(s, "dhtEnabled", gDhtEnabled)
      gPexEnabled = jBool(s, "pexEnabled", gPexEnabled)
      gLsdEnabled = jBool(s, "lsdEnabled", gLsdEnabled)
      gUtpEnabled = jBool(s, "utpEnabled", gUtpEnabled)
      gWebSeedEnabled = jBool(s, "webSeedEnabled", gWebSeedEnabled)
      gTrackerScrapeEnabled = jBool(s, "trackerScrapeEnabled", gTrackerScrapeEnabled)
      gHolepunchEnabled = jBool(s, "holepunchEnabled", gHolepunchEnabled)
      gEncryptionMode = jStr(s, "encryptionMode", gEncryptionMode)

    log "[SESSION] Settings loaded:"
    log "  downloadDir: " & gDownloadDir
    log "  listenPort: " & gListenPort
    log "  maxPeers: " & gMaxPeers
    log "  dht: " & $gDhtEnabled & " pex: " & $gPexEnabled &
      " lsd: " & $gLsdEnabled & " utp: " & $gUtpEnabled
    log "  webSeed: " & $gWebSeedEnabled & " scrape: " & $gTrackerScrapeEnabled &
      " holepunch: " & $gHolepunchEnabled
    log "  encryption: " & gEncryptionMode
  except CatchableError as e:
    log "[SESSION] Error loading settings: " & e.msg

type
  SessionTorrent = object
    path: string
    magnetUri: string
    paused: bool
    name: string

proc loadSessionTorrents(): seq[SessionTorrent] =
  ## Load torrent entries from the GUI session file.
  let path = sessionFile.expandTilde
  if not fileExists(path):
    return @[]

  try:
    let data = parseJson(readFile(path))
    if data.hasKey("torrents"):
      for entry in data["torrents"]:
        let torrentPath = jStr(entry, "path", "")
        let magnetUri = jStr(entry, "magnetUri", "")
        let wasPaused = jBool(entry, "paused", false)
        let name = jStr(entry, "name", "")
        if torrentPath.len > 0 or magnetUri.len > 0:
          result.add(SessionTorrent(
            path: torrentPath,
            magnetUri: magnetUri,
            paused: wasPaused,
            name: name,
          ))
    log "[SESSION] Found " & $result.len & " torrents in session"
  except CatchableError as e:
    log "[SESSION] Error loading torrents: " & e.msg

# ============================================================
# Peer snapshot builder (same as bridge)
# ============================================================

const PopCountTable = block:
  var t: array[256, uint8]
  for i in 0 .. 255:
    var n = i
    var count: uint8 = 0
    while n != 0:
      count += uint8(n and 1)
      n = n shr 1
    t[i] = count
  t

proc bitfieldPopcount(bitfield: openArray[byte], totalPieces: int): int =
  let fullBytes = totalPieces div 8
  for i in 0 ..< min(fullBytes, bitfield.len):
    result += PopCountTable[bitfield[i].int].int
  let remaining = totalPieces mod 8
  if remaining > 0 and fullBytes < bitfield.len:
    let lastByte = bitfield[fullBytes].int
    for bit in 0 ..< remaining:
      if (lastByte and (1 shl (7 - bit))) != 0:
        inc result

proc buildPeerSnapshotEntry(peer: PeerConn, totalPieces: int): PeerSnapshotEntry =
  let info = parsePeerId(peer.remotePeerId)
  var flags = ""
  if not peer.peerChoking and peer.amInterested:
    flags.add("D")
  elif peer.amInterested:
    flags.add("d")
  if not peer.amChoking and peer.peerInterested:
    flags.add("U")
  elif peer.peerInterested:
    flags.add("u")
  if peer.pexHasUtp or peer.transport == ptUtp:
    flags.add("T")
  if peer.mseEncrypted:
    flags.add("E")

  var peerProgress = 0.0
  if peer.isSuperSeeder:
    peerProgress = 1.0
  elif peer.peerBitfield.len > 0 and totalPieces > 0:
    let have = bitfieldPopcount(peer.peerBitfield, totalPieces)
    peerProgress = have.float / totalPieces.float

  PeerSnapshotEntry(
    address: peer.ip & ":" & $peer.port,
    clientName: info.clientName,
    flags: flags,
    progress: peerProgress,
    downloadRate: 0.0,
    uploadRate: 0.0,
    downloadedBytes: peer.bytesDownloaded.float,
    uploadedBytes: peer.bytesUploaded.float,
    transport: (if peer.transport == ptUtp: "uTP" else: "TCP"),
  )

# ============================================================
# Shared TCP/uTP resources
# ============================================================

proc ensureSharedResources() =
  let port = (try: parseUInt(gListenPort).uint16 except: 6881'u16)
  if gSharedListener == nil:
    try:
      gSharedListener = tcpListen("0.0.0.0", port.int)
    except CatchableError:
      try:
        gSharedListener = tcpListen("0.0.0.0", 0)
      except CatchableError:
        discard
  if gSharedUtpMgr == nil:
    try:
      gSharedUtpMgr = newUtpManager(port.int)
      gSharedUtpMgr.start()
    except CatchableError:
      try:
        gSharedUtpMgr = newUtpManager(0)
        gSharedUtpMgr.start()
      except CatchableError:
        discard

proc buildConfig(): ClientConfig =
  ensureSharedResources()
  ClientConfig(
    downloadDir: gDownloadDir.expandTilde,
    listenPort: (try: parseUInt(gListenPort).uint16 except: 6881'u16),
    maxPeers: (try: parseInt(gMaxPeers) except: 50),
    maxDownloadRate: (try: parseInt(gMaxDownloadRate) * 1024 except: 0),
    maxUploadRate: (try: parseInt(gMaxUploadRate) * 1024 except: 0),
    enableDht: gDhtEnabled,
    enablePex: gPexEnabled,
    enableLsd: gLsdEnabled,
    enableUtp: gUtpEnabled,
    enableWebSeed: gWebSeedEnabled,
    enableTrackerScrape: gTrackerScrapeEnabled,
    enableHolepunch: gHolepunchEnabled,
    encryptionMode: parseEncryptionMode(gEncryptionMode),
    sharedListener: gSharedListener,
    sharedUtpMgr: gSharedUtpMgr,
    sharedLsdSock: gSharedLsdSock,
    sharedNatMgr: gNatMgr
  )

# ============================================================
# drainClientEvents (same logic as bridge)
# ============================================================

proc drainClientEvents(torrentId: int, client: TorrentClient): CpsVoidFuture {.cps.} =
  log "[DRAIN] Started draining events for torrent " & $torrentId
  while client.state != csStopped:
    let evt = await client.events.recv()
    log "[DRAIN] Event: " & $evt.kind & " for torrent " & $torrentId
    case evt.kind
    of cekStarted:
      pushEvent(UiEvent(kind: uiTorrentStarted, torrentId: torrentId))
    of cekPieceVerified:
      pushEvent(UiEvent(kind: uiPieceVerified, torrentId: torrentId,
                        intParam: evt.pieceIndex))
    of cekProgress:
      # Snapshot all mutable client fields under mtx to prevent data races
      # with CPS tasks (trackerLoop, eventLoop, etc.) running on MT workers.
      var downloaded: float
      var uploaded: float
      var progress: float
      var totalSize: float
      var verifiedCount: int
      var dhtNodes: int
      var totalPieces: int
      var utpPeers = 0
      var tcpPeers = 0
      var peerSnap: seq[PeerSnapshotEntry]
      var pmData = ""
      var fInfoSnap: seq[tuple[path: string, length: int64]]
      var fPrioSnap: seq[string]
      var trackerSnap: seq[TrackerState]
      var snapName = ""
      var snapDhtEnabled = false
      var snapLsdAnnounces = 0
      var snapLsdPeers = 0
      var snapLsdLastError = ""
      var snapWebSeedBytes: int64 = 0
      var snapWebSeedFailures = 0
      var snapWebSeedActiveUrl = ""
      var snapHolepunchAttempts = 0
      var snapHolepunchSuccesses = 0
      var snapHolepunchLastError = ""

      await lock(client.mtx)
      try:
        if client.pieceMgr != nil:
          downloaded = client.pieceMgr.downloaded.float
          uploaded = client.pieceMgr.uploaded.float
          verifiedCount = client.pieceMgr.verifiedCount
          progress = client.pieceMgr.progress
          totalPieces = client.pieceMgr.totalPieces
          totalSize = client.metainfo.info.totalLength.float
        dhtNodes = client.dhtNodeCount
        snapName = client.metainfo.info.name
        snapDhtEnabled = client.config.enableDht and client.dhtEnabled
        snapLsdAnnounces = client.lsdAnnounceCount
        snapLsdPeers = client.lsdPeersDiscovered
        snapLsdLastError = client.lsdLastError
        snapWebSeedBytes = client.webSeedBytes
        snapWebSeedFailures = client.webSeedFailures
        snapWebSeedActiveUrl = client.webSeedActiveUrl
        snapHolepunchAttempts = client.holepunchAttempts
        snapHolepunchSuccesses = client.holepunchSuccesses
        snapHolepunchLastError = client.holepunchLastError

        for p in client.activePeers:
          if p.transport == ptUtp: inc utpPeers
          else: inc tcpPeers
          peerSnap.add(buildPeerSnapshotEntry(p, totalPieces))

        if client.pieceMgr != nil:
          pmData = newString(client.pieceMgr.totalPieces)
          var pi = 0
          while pi < client.pieceMgr.totalPieces:
            case client.pieceMgr.pieces[pi].state
            of psEmpty: pmData[pi] = '0'
            of psPartial: pmData[pi] = '1'
            of psComplete: pmData[pi] = '2'
            of psVerified: pmData[pi] = '3'
            of psFailed: pmData[pi] = '4'
            pi += 1

        if client.metainfo.info.files.len > 0:
          for i, f in client.metainfo.info.files:
            fInfoSnap.add((path: f.path, length: f.length))
            var pr = client.filePriorities.getOrDefault(i, "normal")
            if client.selectedFiles.len > 0 and i notin client.selectedFiles and
               i notin client.filePriorities:
              pr = "skip"
            fPrioSnap.add(pr)

        var trackerUrls: seq[string] = @[]
        var seenTrackerUrls = initHashSet[string]()
        if client.metainfo.announce.len > 0:
          trackerUrls.add(client.metainfo.announce)
          seenTrackerUrls.incl(client.metainfo.announce)
        for tier in client.metainfo.announceList:
          for url in tier:
            if url.len > 0 and url notin seenTrackerUrls:
              trackerUrls.add(url)
              seenTrackerUrls.incl(url)
        for url in trackerUrls:
          let tr = client.trackerRuntime.getOrDefault(url, TrackerRuntime(
            url: url,
            status: if client.state == csStopped: "disabled" else: "updating"
          ))
          trackerSnap.add(TrackerState(
            url: url,
            status: tr.status,
            seeders: tr.seeders,
            leechers: tr.leechers,
            completed: tr.completed,
            lastAnnounce: formatTimestamp(tr.lastAnnounce),
            nextAnnounce: formatTimestamp(tr.nextAnnounce),
            lastScrape: formatTimestamp(tr.lastScrape),
            nextScrape: formatTimestamp(tr.nextScrape),
            errorText: tr.errorText
          ))
        var trKeys: seq[string]
        for trk in client.trackerRuntime.keys:
          trKeys.add(trk)
        var trki = 0
        while trki < trKeys.len:
          let url = trKeys[trki]
          trki += 1
          if url.len > 0 and url notin seenTrackerUrls:
            if url in client.trackerRuntime:
              let tr = client.trackerRuntime[url]
              seenTrackerUrls.incl(url)
              trackerSnap.add(TrackerState(
                url: url,
                status: tr.status,
                seeders: tr.seeders,
                leechers: tr.leechers,
                completed: tr.completed,
                lastAnnounce: formatTimestamp(tr.lastAnnounce),
                nextAnnounce: formatTimestamp(tr.nextAnnounce),
                lastScrape: formatTimestamp(tr.lastScrape),
                nextScrape: formatTimestamp(tr.nextScrape),
                errorText: tr.errorText
              ))
      finally:
        unlock(client.mtx)

      pushEvent(UiEvent(kind: uiProgress, torrentId: torrentId,
                        intParam: evt.completedPieces, intParam2: evt.peerCount,
                        intParam3: verifiedCount,
                        floatParam: evt.downloadRate, floatParam2: evt.uploadRate,
                        floatParam3: downloaded, floatParam4: uploaded,
                        floatParam5: progress, floatParam6: totalSize,
                        text: $dhtNodes,
                        text2: snapName,
                        text3: $totalPieces,
                        peerSnapshot: move peerSnap,
                        pieceMapData: move pmData,
                        fileInfo: move fInfoSnap,
                        filePriorities: move fPrioSnap,
                        trackerSnapshot: move trackerSnap,
                        protocolPrivate: client.isPrivate,
                        protocolDhtEnabled: snapDhtEnabled,
                        protocolPexEnabled: client.config.enablePex and not client.isPrivate,
                        protocolLsdEnabled: client.config.enableLsd and not client.isPrivate,
                        protocolUtpEnabled: client.config.enableUtp,
                        protocolWebSeedEnabled: client.config.enableWebSeed,
                        protocolScrapeEnabled: client.config.enableTrackerScrape,
                        protocolHolepunchEnabled: client.config.enableHolepunch and not client.isPrivate,
                        protocolEncryptionMode: encryptionModeLabel(client.config.encryptionMode),
                        protocolUtpPeers: utpPeers,
                        protocolTcpPeers: tcpPeers,
                        protocolLsdAnnounces: snapLsdAnnounces,
                        protocolLsdPeers: snapLsdPeers,
                        protocolLsdLastError: snapLsdLastError,
                        protocolWebSeedBytes: snapWebSeedBytes,
                        protocolWebSeedFailures: snapWebSeedFailures,
                        protocolWebSeedActiveUrl: snapWebSeedActiveUrl,
                        protocolHolepunchAttempts: snapHolepunchAttempts,
                        protocolHolepunchSuccesses: snapHolepunchSuccesses,
                        protocolHolepunchLastError: snapHolepunchLastError))
    of cekPeerConnected:
      pushEvent(UiEvent(kind: uiPeerConnected, torrentId: torrentId,
                        text: evt.peerAddr))
    of cekPeerDisconnected:
      pushEvent(UiEvent(kind: uiPeerDisconnected, torrentId: torrentId,
                        text: evt.peerAddr))
    of cekCompleted:
      pushEvent(UiEvent(kind: uiCompleted, torrentId: torrentId))
    of cekError:
      pushEvent(UiEvent(kind: uiError, torrentId: torrentId,
                        text: evt.errMsg))
    of cekInfo:
      pushEvent(UiEvent(kind: uiInfo, torrentId: torrentId,
                        text: evt.errMsg))
    of cekStopped:
      pushEvent(UiEvent(kind: uiStopped, torrentId: torrentId))
    of cekTrackerResponse:
      pushEvent(UiEvent(kind: uiTrackerResponse, torrentId: torrentId,
                        intParam: evt.seeders, intParam2: evt.leechers))

# ============================================================
# Start client (same logic as bridge)
# ============================================================

proc startClientFromFile(torrentId: int, path: string) =
  let metainfo = parseTorrentFile(path)
  log "[EVENT LOOP] Parsed: " & metainfo.info.name &
    " (" & formatBytes(metainfo.info.totalLength.float) & ", " &
    $metainfo.info.pieceCount & " pieces)"
  let config = buildConfig()
  let tc = newTorrentClient(metainfo, config)
  gClients[torrentId] = tc

  var aUrls: seq[string]
  if metainfo.announce.len > 0:
    aUrls.add(metainfo.announce)
  for tier in metainfo.announceList:
    for url in tier:
      if url notin aUrls:
        aUrls.add(url)

  log "[EVENT LOOP] Trackers (" & $aUrls.len & "):"
  for url in aUrls:
    log "  " & url

  var fInfo: seq[tuple[path: string, length: int64]]
  for f in metainfo.info.files:
    fInfo.add((path: f.path, length: f.length))

  pushEvent(UiEvent(kind: uiClientReady, torrentId: torrentId,
                    text2: metainfo.info.name,
                    text3: metainfo.info.infoHashHex,
                    floatParam: metainfo.info.totalLength.float,
                    intParam: metainfo.info.pieceCount,
                    intParam2: max(1, aUrls.len),
                    fileInfo: fInfo,
                    announceUrls: aUrls,
                    downloadDir: config.downloadDir))

  discard spawn tc.start()
  discard spawn drainClientEvents(torrentId, tc)

# ============================================================
# Command processor (event loop thread)
# ============================================================

proc commandProcessor(): CpsVoidFuture {.cps.} =
  log "[CMD] Command processor starting"

  # NAT discovery
  try:
    ensureSharedResources()
    gNatMgr = newNatManager()
    await discover(gNatMgr)
    if gNatMgr.protocol != npNone:
      let listenPort = if gSharedListener != nil: gSharedListener.localPort().uint16
                       else: (try: parseUInt(gListenPort).uint16 except: 6881'u16)
      try:
        discard await addMapping(gNatMgr, mpTcp, listenPort, listenPort, 7200)
      except CatchableError:
        discard
      if gSharedUtpMgr != nil:
        try:
          let utpPort: uint16 = gSharedUtpMgr.port.uint16
          discard await addMapping(gNatMgr, mpUdp, utpPort, utpPort, 7200)
        except CatchableError:
          discard
      let natRenewalFut = startRenewal(gNatMgr)
      log "[NAT] " & $gNatMgr.protocol &
        " ext=" & getExternalIp(gNatMgr) &
        " gw=" & gNatMgr.gatewayIp
    else:
      log "[NAT] No NAT gateway found"
  except CatchableError as e:
    log "[NAT] Discovery failed: " & e.msg

  # Command pipe
  if gCmdPipeRead >= 0:
    let loop = getEventLoop()
    loop.registerRead(gCmdPipeRead, proc() =
      drainCommandNotifyPipe()
      {.cast(gcsafe).}:
        acquire(gCommandWakeLock)
        let waiter = gCommandWake
        release(gCommandWakeLock)
        if waiter != nil and not waiter.finished:
          waiter.complete()
    )

  log "[CMD] Ready, waiting for commands..."
  while true:
    var commands = gCommandQueue.drainAll()
    if commands.len == 0:
      if gCmdPipeRead < 0:
        await cpsSleep(100)
        continue

      let waitFut = newCpsVoidFuture()
      waitFut.pinFutureRuntime()
      acquire(gCommandWakeLock)
      gCommandWake = waitFut
      release(gCommandWakeLock)

      commands = gCommandQueue.drainAll()
      if commands.len == 0:
        await waitFut
        commands = gCommandQueue.drainAll()
        if commands.len == 0:
          continue

    acquire(gCommandWakeLock)
    gCommandWake = nil
    release(gCommandWakeLock)

    for cmd in commands:
      case cmd.kind
      of cmdAddTorrentFile:
        try:
          log "[CMD] Adding torrent: " & cmd.text & " (id=" & $cmd.intParam & ")"
          startClientFromFile(cmd.intParam, cmd.text)
        except CatchableError as e:
          log "[CMD] ERROR: " & e.msg
          pushEvent(UiEvent(kind: uiClientError, torrentId: cmd.intParam,
                            text: e.msg))
      of cmdAddTorrentMagnet:
        log "[CMD] Magnet links not yet supported in CLI debug mode"
      of cmdShutdown:
        log "[CMD] Shutdown"
        return

# ============================================================
# Event loop thread
# ============================================================

proc eventLoopMain() {.thread.} =
  {.cast(gcsafe).}:
    log "[EVENT LOOP] Thread started (MT runtime: 4 workers, 6 blocking)"
    let loop = initMtRuntime(numWorkers = 4, numBlockingThreads = 6)
    var crashCount = 0
    while true:
      try:
        runCps(commandProcessor())
        log "[EVENT LOOP] Exiting normally"
        break
      except Exception as e:
        inc crashCount
        log "[EVENT LOOP] CRASH #" & $crashCount & ": " & e.msg &
          " (" & $e.name & ")\n" & getStackTrace(e)
        if crashCount >= 5:
          log "[EVENT LOOP] Too many crashes"
          break
        sleep(500)
    shutdownMtRuntime(loop)
    gShutdownComplete.store(true, moRelease)

# ============================================================
# Main thread: poll events and print status
# ============================================================

proc main() =
  echo "=== CPS BitTorrent CLI Debug Runner ==="
  echo "  Session: " & sessionFile.expandTilde
  echo "  Log: /tmp/torrent_cli_debug.log"
  echo ""

  # Initialize mailboxes and pipes
  initMailbox[UiEvent](gEventQueue)
  initMailbox[BridgeCommand](gCommandQueue)
  initLock(gCommandWakeLock)
  gDirty.store(false, moRelaxed)
  gShutdownComplete.store(false, moRelaxed)
  gDroppedEventCount.store(0'u64, moRelaxed)
  gDroppedCommandCount.store(0'u64, moRelaxed)
  gCmdNotifyPending.store(false, moRelaxed)

  var cmdFds: array[2, cint]
  if posix.pipe(cmdFds) == 0:
    gCmdPipeRead = cmdFds[0]
    gCmdPipeWrite = cmdFds[1]
    discard fcntl(gCmdPipeRead, F_SETFL,
      fcntl(gCmdPipeRead, F_GETFL) or O_NONBLOCK)
    discard fcntl(gCmdPipeWrite, F_SETFL,
      fcntl(gCmdPipeWrite, F_GETFL) or O_NONBLOCK)

  # Load settings from session file (same as GUI)
  loadSettings()

  # Determine what torrents to run
  var torrentsToStart: seq[tuple[id: int, path: string]] = @[]

  if paramCount() >= 1:
    # Explicit torrent file on command line
    let torrentPath = paramStr(1)
    # Optional --dl /path for download directory override
    if paramCount() >= 3 and paramStr(2) == "--dl":
      gDownloadDir = paramStr(3)
      log "[MAIN] Download dir override: " & gDownloadDir
    if not fileExists(torrentPath):
      echo "Error: file not found: " & torrentPath
      quit(1)
    let tid = gNextTorrentId
    inc gNextTorrentId
    torrentsToStart.add((id: tid, path: torrentPath))
    log "[MAIN] Will start torrent from CLI arg: " & torrentPath
  else:
    # Restore from session (same as GUI)
    let sessionTorrents = loadSessionTorrents()
    for st in sessionTorrents:
      if st.paused:
        log "[MAIN] Skipping paused torrent: " & st.name
        continue
      if st.path.len > 0 and fileExists(st.path):
        let tid = gNextTorrentId
        inc gNextTorrentId
        torrentsToStart.add((id: tid, path: st.path))
        log "[MAIN] Will restore: " & st.name & " (" & st.path & ")"
      elif st.magnetUri.len > 0:
        log "[MAIN] Skipping magnet (not supported in CLI): " & st.name
      else:
        log "[MAIN] Skipping (file not found): " & st.name & " (" & st.path & ")"

  if torrentsToStart.len == 0:
    echo "No torrents to start. Provide a .torrent file or ensure session.json has active torrents."
    quit(0)

  echo "Starting " & $torrentsToStart.len & " torrent(s)..."
  echo "Press Ctrl+C to stop."
  echo ""

  # Start event loop thread
  var elThread: Thread[void]
  createThread(elThread, eventLoopMain)

  # Give the event loop a moment to initialize
  sleep(100)

  # Enqueue commands to start torrents (same as GUI's loadSession)
  for t in torrentsToStart:
    enqueueCommand(BridgeCommand(kind: cmdAddTorrentFile,
                                  text: t.path, intParam: t.id))

  # Track state per torrent
  type TorrentInfo = object
    name: string
    progress: float
    dlRate: float
    ulRate: float
    downloaded: float
    uploaded: float
    peers: int
    dhtNodes: int
    utpPeers: int
    tcpPeers: int
    holepunchAttempts: int
    holepunchSuccesses: int
    trackerStates: seq[TrackerState]

  var torrentInfo: Table[int, TorrentInfo]
  var lastPrintTime = 0.0

  # Poll loop
  while not gShutdownComplete.load(moAcquire):
    let events = gEventQueue.drainAll()
    for i in 0 ..< events.len:
      let evt = events[i]
      case evt.kind
      of uiClientReady:
        torrentInfo[evt.torrentId] = TorrentInfo(name: evt.text2)
        log "[UI] Ready: " & evt.text2 & " hash=" & evt.text3 &
          " size=" & formatBytes(evt.floatParam) &
          " pieces=" & $evt.intParam &
          " trackers=" & $evt.intParam2

      of uiClientError:
        log "[UI] ERROR: " & evt.text

      of uiTorrentStarted:
        log "[UI] Started torrent " & $evt.torrentId

      of uiPieceVerified:
        discard  # too noisy

      of uiProgress:
        if evt.torrentId in torrentInfo:
          var info = torrentInfo[evt.torrentId]
          info.dlRate = evt.floatParam
          info.ulRate = evt.floatParam2
          info.downloaded = evt.floatParam3
          info.uploaded = evt.floatParam4
          info.progress = evt.floatParam5
          info.peers = evt.intParam2
          info.dhtNodes = (try: parseInt(evt.text) except: 0)
          info.utpPeers = evt.protocolUtpPeers
          info.tcpPeers = evt.protocolTcpPeers
          info.holepunchAttempts = evt.protocolHolepunchAttempts
          info.holepunchSuccesses = evt.protocolHolepunchSuccesses
          if evt.text2.len > 0 and evt.text2 != "unknown":
            info.name = evt.text2

          # Check tracker state changes
          if evt.trackerSnapshot.len > 0:
            var changed = evt.trackerSnapshot.len != info.trackerStates.len
            if not changed:
              for j in 0 ..< evt.trackerSnapshot.len:
                if evt.trackerSnapshot[j].status != info.trackerStates[j].status or
                   evt.trackerSnapshot[j].errorText != info.trackerStates[j].errorText:
                  changed = true
                  break
            if changed:
              info.trackerStates = evt.trackerSnapshot
              for ts in info.trackerStates:
                var line = "[TRACKER] " & ts.url & " → " & ts.status
                if ts.seeders > 0 or ts.leechers > 0:
                  line.add " (S:" & $ts.seeders & " L:" & $ts.leechers & ")"
                if ts.errorText.len > 0:
                  line.add " err: " & ts.errorText
                log line

          torrentInfo[evt.torrentId] = info

      of uiPeerConnected:
        log "[UI] Peer+: " & evt.text

      of uiPeerDisconnected:
        log "[UI] Peer-: " & evt.text

      of uiCompleted:
        log "[UI] COMPLETED torrent " & $evt.torrentId

      of uiError:
        log "[UI] Error: " & evt.text

      of uiInfo:
        log "[UI] Info: " & evt.text

      of uiStopped:
        log "[UI] Stopped torrent " & $evt.torrentId

      of uiTrackerResponse:
        log "[UI] Tracker: seeders=" & $evt.intParam & " leechers=" & $evt.intParam2

      of uiTorrentPaused, uiTorrentRemoved, uiRechecking, uiNatStatus:
        discard

    # Periodic summary
    let now = epochTime()
    if now - lastPrintTime >= 2.0 and torrentInfo.len > 0:
      lastPrintTime = now
      for tid, info in torrentInfo:
        if info.progress > 0 or info.dlRate > 0 or info.peers > 0:
          log &"[STATUS] [{info.name}] {info.progress * 100:.1f}% " &
            &"DL:{formatRate(info.dlRate)} UL:{formatRate(info.ulRate)} " &
            &"Down:{formatBytes(info.downloaded)} Up:{formatBytes(info.uploaded)} " &
            &"Peers:{info.peers} (uTP:{info.utpPeers} TCP:{info.tcpPeers}) DHT:{info.dhtNodes}" &
            (if info.holepunchAttempts > 0: &" HP:{info.holepunchSuccesses}/{info.holepunchAttempts}" else: "")

    sleep(50)

  joinThread(elThread)
  let dropped = gDroppedEventCount.load(moRelaxed)
  if dropped > 0:
    log "[MAIN] WARNING: " & $dropped & " events dropped"
  log "[MAIN] Done."

main()
