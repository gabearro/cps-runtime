## Nim bridge logic for the BitTorrent GUI client.
##
## Connects the SwiftUI GUI to the CPS BitTorrent client via C FFI.
## The bridge runs a background CPS event loop thread for BitTorrent networking,
## communicating with the main (Swift) thread via lock-free mailbox queues.
##
## Threading model:
##   - Main thread (Swift): calls bridgeDispatch(). Owns gTorrents state.
##   - Event loop thread (CPS): runs TorrentClient tasks. Owns gClients table.
##   - Communication: two lock-free mailboxes (Treiber stack + atomic exchange).
##   - Command wake: lock-free atomic pointer (no mutex on reactor callback path).
##   - Under --mm:atomicArc, ref-counted types (strings, seqs) are thread-safe.
##
## Payload contract (ABI v5):
## - 4 bytes: action tag (u32 little-endian)
## - 2 bytes: request field count (u16 little-endian)
## - 2 bytes: reserved
## - repeated fields:
##   - 2 bytes field id, 1 byte type, 1 byte reserved, 4 bytes payload length
##   - N bytes field payload

import std/nativesockets
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
import cps/private/spinlock
import cps/io/tcp
import cps/io/udp
import cps/io/nat
import cps/io/streams
import cps/io/timeouts
import cps/bittorrent/utp_stream

import std/[json, os, strutils, times, atomics, posix, uri, tables, sets, math]

# ============================================================
# Debug logging (lock-free buffered)
# ============================================================
#
# logBridge() is called at high frequency (~20+/sec per torrent) from both
# the event loop thread and CPS tasks. Synchronous writeLine would block
# the caller on every call. Instead, messages are pushed to a lock-free
# Treiber stack and flushed to disk in batches by a periodic timer.
#
# In production builds (without -d:bridgeDebug), logging is compiled out.

const enableBridgeLog* = defined(bridgeDebug) or not defined(release)

var gLogFile: File
var gLogReady: bool = false
# gLogBuffer declared after Mailbox type definition below

# ============================================================
# Lock-free mailbox (Treiber stack with atomic-exchange batch drain)
# ============================================================
#
# Replaces the previous lock-protected Mailbox that used Lock + seq[T].
# The lock could block the reactor thread when contended with workers,
# stalling all I/O processing.
#
# This implementation uses a Treiber stack (lock-free LIFO linked list):
#   - send(): CAS-push a node to the stack head (lock-free, wait-free
#     for single producer, lock-free for multiple producers)
#   - drainAll(): atomic exchange of the head pointer (wait-free),
#     then reverse to restore FIFO order
#
# Nodes are allocated with allocShared0. Under --mm:atomicArc, string/seq
# refcount ops are atomic, so cross-thread value transfer via move is safe.
# Values are moved into nodes via copyMem + zeroMem (equivalent to =sink
# for built-in managed types: string, seq, ref).

const MailboxMaxCapacity = 16384  # Soft cap to prevent runaway growth

type
  MailboxNode[T] = object
    next: ptr MailboxNode[T]
    value: T

  Mailbox[T] = object
    head: Atomic[pointer]   # ptr MailboxNode[T], Treiber stack top
    count: Atomic[int]      # Approximate count for soft capacity check

proc initMailbox[T](mb: var Mailbox[T]) =
  mb.head.store(nil, moRelaxed)
  mb.count.store(0, moRelaxed)

proc send[T](mb: var Mailbox[T], item: sink T): bool =
  ## Producer: push an item.  Lock-free (CAS loop).
  ## Returns false if at capacity (item is destroyed by caller).
  if mb.count.load(moRelaxed) >= MailboxMaxCapacity:
    return false
  let node = cast[ptr MailboxNode[T]](allocShared0(sizeof(MailboxNode[T])))
  copyMem(addr node.value, unsafeAddr item, sizeof(T))
  zeroMem(unsafeAddr item, sizeof(T))
  # CAS-push to Treiber stack
  var oldHead = mb.head.load(moRelaxed)
  while true:
    node.next = cast[ptr MailboxNode[T]](oldHead)
    if mb.head.compareExchangeWeak(oldHead, cast[pointer](node),
                                   moRelease, moRelaxed):
      break
    # oldHead updated by CAS failure — retry
  discard mb.count.fetchAdd(1, moRelaxed)
  true

proc drainAll[T](mb: var Mailbox[T]): seq[T] =
  ## Consumer: atomically take all pending items in FIFO order.
  ## Wait-free (single atomic exchange).
  let head = cast[ptr MailboxNode[T]](mb.head.exchange(nil, moAcquireRelease))
  if head == nil:
    return @[]
  # Count nodes
  var n = 0
  var node = head
  while node != nil:
    inc n
    node = node.next
  # Extract values in reverse (Treiber stack is LIFO, we want FIFO)
  result = newSeq[T](n)
  node = head
  var i = n - 1
  while node != nil:
    let next = node.next
    copyMem(addr result[i], addr node.value, sizeof(T))
    zeroMem(addr node.value, sizeof(T))
    deallocShared(node)
    node = next
    dec i
  discard mb.count.fetchSub(n, moRelaxed)

# ============================================================
# Debug logging: lock-free buffer + periodic flush
# ============================================================

var gLogBuffer: Mailbox[string]
var gPendingSessionSave: Mailbox[string]

proc flushLogBuffer*() =
  ## Flush buffered log messages to disk. Called from timer callback or shutdown.
  if not gLogReady:
    gLogReady = gLogFile.open("/tmp/torrent_bridge_debug.log", fmAppend)
  if not gLogReady:
    # Can't open file — drain and discard to prevent unbounded growth
    discard gLogBuffer.drainAll()
    return
  let lines = gLogBuffer.drainAll()
  for line in lines:
    gLogFile.writeLine(line)
  if lines.len > 0:
    gLogFile.flushFile()

proc logBridge(msg: string) {.inline.} =
  when enableBridgeLog:
    let line = "[" & $epochTime() & "] " & msg
    discard gLogBuffer.send(line)

# ============================================================
# Action tags (must match action declaration order in app.gui)
# ============================================================

const
  tagPoll = 0'u32
  tagStartPoll = 1'u32
  tagAddTorrentFromFile = 2'u32
  tagAddTorrentFromMagnet = 3'u32
  tagRemoveTorrent = 4'u32
  tagPauseTorrent = 5'u32
  tagResumeTorrent = 6'u32
  tagPauseAll = 7'u32
  tagResumeAll = 8'u32
  tagSelectTorrent = 9'u32
  tagSetDetailTab = 10'u32
  tagShowAddTorrent = 11'u32
  tagHideAddTorrent = 12'u32
  tagShowSettings = 13'u32
  tagHideSettings = 14'u32
  tagShowRemoveConfirm = 15'u32
  tagHideRemoveConfirm = 16'u32
  tagConfirmRemove = 17'u32
  tagSaveSettings = 18'u32
  tagSetDownloadDir = 19'u32
  tagSetDhtEnabled = 20'u32
  tagSetFilePriority = 21'u32
  tagTorrentFileSelected = 22'u32
  tagMagnetLinkChanged = 23'u32
  tagToggleRemoveFiles = 24'u32
  tagCopyMagnetLink = 25'u32
  tagOpenInFinder = 26'u32
  tagRecheckTorrent = 27'u32
  tagDropTorrentFile = 28'u32
  tagAppShutdown = 29'u32

const
  bridgeTypeBool = 1'u8
  bridgeTypeInt64 = 2'u8
  bridgeTypeDouble = 3'u8
  bridgeTypeString = 4'u8
  bridgeTypeJson = 5'u8

const
  fldTorrents = 1'u16
  fldSelectedTorrentId = 2'u16
  fldFiles = 3'u16
  fldPeers = 4'u16
  fldTrackers = 5'u16
  fldDetailTab = 6'u16
  fldPieceMapData = 7'u16
  fldShowAddTorrent = 8'u16
  fldAddMagnetLink = 9'u16
  fldAddTorrentPath = 10'u16
  fldShowSettings = 11'u16
  fldDownloadDir = 12'u16
  fldListenPort = 13'u16
  fldMaxDownloadRate = 14'u16
  fldMaxUploadRate = 15'u16
  fldMaxPeers = 16'u16
  fldDhtEnabled = 17'u16
  fldPexEnabled = 18'u16
  fldLsdEnabled = 19'u16
  fldUtpEnabled = 20'u16
  fldWebSeedEnabled = 21'u16
  fldTrackerScrapeEnabled = 22'u16
  fldHolepunchEnabled = 23'u16
  fldEncryptionMode = 24'u16
  fldActionPriority = 25'u16
  fldSettingsTab = 26'u16
  fldStatusDownRate = 27'u16
  fldStatusUpRate = 28'u16
  fldStatusDhtNodes = 29'u16
  fldPollActive = 30'u16
  fldStatusText = 31'u16
  fldShowRemoveConfirm = 32'u16
  fldRemoveDeleteFiles = 33'u16
  fldActionTorrentId = 34'u16
  fldNatProtocol = 35'u16
  fldNatExternalIp = 36'u16
  fldNatGatewayIp = 37'u16
  fldNatLocalIp = 38'u16
  fldNatDoubleNat = 39'u16
  fldNatOuterProtocol = 40'u16
  fldNatOuterGatewayIp = 41'u16
  fldNatPortsForwarded = 42'u16
  fldNatActiveMappings = 43'u16

const
  dmTorrents = 1'u32 shl 0
  dmFiles = 1'u32 shl 1
  dmPeers = 1'u32 shl 2
  dmTrackers = 1'u32 shl 3
  dmPieceMap = 1'u32 shl 4
  dmStatus = 1'u32 shl 5
  dmSelection = 1'u32 shl 6
  dmDialogs = 1'u32 shl 7
  dmSettings = 1'u32 shl 8
  dmNat = 1'u32 shl 9
  dmAll = dmTorrents or dmFiles or dmPeers or dmTrackers or dmPieceMap or
          dmStatus or dmSelection or dmDialogs or dmSettings or dmNat

# ============================================================
# Types
# ============================================================

type
  BridgeCommandKind = enum
    cmdAddTorrentFile, cmdAddTorrentMagnet, cmdRemoveTorrent,
    cmdPauseTorrent, cmdResumeTorrent,
    cmdSaveSettings, cmdSetFilePriority, cmdRecheckTorrent, cmdExecuteEffect,
    cmdShutdown

  BridgeCommand = object
    kind: BridgeCommandKind
    intParam: int
    intParam2: int
    text: string        # path or magnet URI
    text2: string       # torrent file path for resume
    boolParam: bool     # deleteFiles for remove, dhtEnabled for add

  UiEventKind = enum
    uiTorrentStarted, uiPieceVerified, uiProgress, uiPeerConnected,
    uiPeerDisconnected, uiCompleted, uiError, uiInfo, uiStopped, uiTrackerResponse,
    # Lock-free state mutation events (event loop → main thread)
    uiClientReady,      # Client created + started; carries metadata copies
    uiClientError,      # Error creating/starting client
    uiTorrentPaused,    # Client stopped for pause
    uiTorrentRemoved,   # Client stopped for removal
    uiRechecking,       # Piece states reset
    uiNatStatus         # NAT port forwarding status update

  UiEvent = object
    kind: UiEventKind
    torrentId: int
    intParam: int
    intParam2: int
    intParam3: int       # verifiedCount for progress
    floatParam: float
    floatParam2: float
    floatParam3: float   # downloaded bytes
    floatParam4: float   # uploaded bytes
    floatParam5: float   # progress (0.0 - 1.0)
    floatParam6: float   # totalSize (uiProgress, for magnet metadata update)
    text: string
    # Extended fields for lock-free mutation events
    text2: string        # name (uiClientReady), also torrent name update (uiProgress)
    text3: string        # infoHash (uiClientReady), totalPieces as string (uiProgress)
    boolParam: bool      # deleteFiles (uiTorrentRemoved)
    peerSnapshot: seq[PeerSnapshotEntry]  # peer data snapshot (uiProgress)
    pieceMapData: string  # compact piece states (uiProgress)
    filePriorities: seq[string] # file priority snapshot (uiProgress)
    trackerSnapshot: seq[TrackerState] # per-tracker runtime status (uiProgress)
    # Data copied from TorrentClient for main-thread use (uiClientReady)
    fileInfo: seq[tuple[path: string, length: int64]]  # metainfo files
    announceUrls: seq[string]    # all tracker URLs (announce + announceList)
    downloadDir: string          # client config download dir
    # Protocol/runtime telemetry snapshot (uiProgress)
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
    protocolWebSeedBytes: int64
    protocolWebSeedFailures: int
    protocolWebSeedActiveUrl: string
    protocolHolepunchAttempts: int
    protocolHolepunchSuccesses: int
    protocolHolepunchLastError: string

  PeerSnapshotEntry = object
    address: string       # "ip:port"
    clientName: string    # from parsePeerId
    bytesDownloaded: int64
    bytesUploaded: int64
    progress: float       # precomputed from bitfield
    flags: string         # compact flags e.g. "DuSE"
    flagsTooltip: string  # human-readable tooltip for this peer's flags
    source: string        # "Tracker", "DHT", "PEX", "LSD", "Incoming"
    transport: string     # "TCP" or "uTP"

  TorrentStatus = enum
    tsDownloading = "downloading"
    tsSeeding = "seeding"
    tsPaused = "paused"
    tsChecking = "checking"
    tsError = "error"
    tsQueued = "queued"

  TorrentState = object
    id: int
    name: string
    infoHash: string
    status: TorrentStatus
    progress: float
    downloadRate: float
    uploadRate: float
    downloaded: float
    uploaded: float
    totalSize: float
    peerCount: int
    seedCount: int
    eta: string
    addedDate: string
    completedDate: string
    errorText: string
    ratio: float
    pieceCount: int
    verifiedPieces: int
    trackerSeeders: int
    trackerLeechers: int
    trackerCount: int
    dhtNodeCount: int
    paused: bool
    torrentFilePath: string  # path to .torrent file for session persistence
    magnetUri: string        # original magnet URI for session persistence
    hasTrackerResponse: bool # received at least one tracker response
    # Owned copies of client data (safe for main-thread access)
    pieceMapData: string     # compact piece states from event loop
    fileInfo: seq[tuple[path: string, length: int64]]  # metainfo file info
    filePriorities: seq[string]    # per-file priorities (high/normal/skip)
    announceUrls: seq[string]    # all tracker URLs
    trackerStates: seq[TrackerState]  # announce/scrape runtime per tracker
    downloadDir: string          # download directory
    clientActive: bool           # whether client is active (not stopped)
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
    protocolWebSeedBytes: float
    protocolWebSeedFailures: int
    protocolWebSeedActiveUrl: string
    protocolHolepunchAttempts: int
    protocolHolepunchSuccesses: int
    protocolHolepunchLastError: string

  TrackerState = object
    url: string
    status: string      # "working", "updating", "error", "disabled"
    seeders: int
    leechers: int
    completed: int
    lastAnnounce: string
    nextAnnounce: string
    lastScrape: string
    nextScrape: string
    errorText: string

  GUIBridgeBuffer {.bycopy.} = object
    data: ptr uint8
    len: uint32

  GUIBridgeDispatchOutput {.bycopy.} = object
    statePatch: GUIBridgeBuffer
    effects: GUIBridgeBuffer
    emittedActions: GUIBridgeBuffer
    diagnostics: GUIBridgeBuffer

  GUIBridgeFunctionTable {.bycopy.} = object
    abiVersion: uint32
    alloc: proc(size: csize_t): pointer {.cdecl.}
    free: proc(p: pointer) {.cdecl.}
    dispatch: proc(payload: ptr uint8, payloadLen: uint32,
                   outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.}
    getNotifyFd: proc(): int32 {.cdecl.}
    waitShutdown: proc(timeoutMs: int32): int32 {.cdecl.}

const
  guiBridgeAbiVersion = 5'u32

# ============================================================
# Runtime state
# ============================================================

type
  BridgeRuntime* = object
    # Thread-safe mailboxes (initialized in ensureInit)
    eventQueue: Mailbox[UiEvent]       # event loop → main thread
    commandQueue: Mailbox[BridgeCommand]  # main thread → event loop

    eventLoopThread: Thread[void]
    eventLoopRunning: bool
    shutdownComplete: Atomic[bool]
    initialized: bool

    # Torrent state (ONLY modified on main thread via dispatch/processUiEvents)
    torrents: seq[TorrentState]
    selectedTorrentId: int
    nextTorrentId: int
    detailTab: int

    # Per-selected-torrent detail data (populated during Poll on main thread)
    files: seq[tuple[index: int, path: string, size: float, progress: float, priority: string]]
    peers: seq[tuple[address: string, client: string, downloadRate: float,
                     uploadRate: float, progress: float, flags: string,
                     flagsTooltip: string, source: string, transport: string]]
    trackers: seq[TrackerState]
    pieceMapData: string

    # Per-torrent peer snapshots (populated from event queue, read on main thread)
    peerSnapshots: Table[int, seq[PeerSnapshotEntry]]
    # Per-peer rate tracking (smoothed via EMA, keyed by "torrentId:address")
    peerSmoothedRates: Table[string, tuple[down: float, up: float]]
    peerPrevBytes: Table[string, tuple[down: int64, up: int64]]
    lastPeerPollTimes: Table[int, float]  # per-torrent last peer rate computation time
    # Per-torrent rate tracking (smoothed via EMA, keyed by torrentId)
    torrentPrevBytes: Table[int, tuple[down: int64, up: int64, time: float]]
    torrentSmoothedRates: Table[int, tuple[down: float, up: float]]

    # Add torrent form state
    showAddTorrent: bool
    addMagnetLink: string
    addTorrentPath: string

    # Settings state
    showSettings: bool
    downloadDir: string
    listenPort: string
    maxDownloadRate: string
    maxUploadRate: string
    maxPeers: string
    dhtEnabled: bool
    pexEnabled: bool
    lsdEnabled: bool
    utpEnabled: bool
    webSeedEnabled: bool
    trackerScrapeEnabled: bool
    holepunchEnabled: bool
    encryptionMode: string
    actionPriority: string

    # Status bar
    statusDownRate: float
    statusUpRate: float
    statusDhtNodes: int
    statusText: string
    pollActive: bool
    sessionLoaded: bool
    natProtocol: string
    natExternalIp: string
    natGatewayIp: string
    natLocalIp: string
    natDoubleNat: bool
    natOuterProtocol: string
    natOuterGatewayIp: string
    natPortsForwarded: bool
    natActiveMappings: int

    # Remove confirmation
    showRemoveConfirm: bool
    removeDeleteFiles: bool
    actionTorrentId: int

    # Dirty flag (atomic) & notify pipe
    dirty: Atomic[bool]
    dirtyMask: uint32
    lastSaveTime: float
    notifyPipeRead: cint
    notifyPipeWrite: cint
    notifyPending: Atomic[bool]
    # Command notify pipe: main thread writes to wake event loop when commands enqueued
    cmdPipeRead: cint
    cmdPipeWrite: cint
    cmdNotifyPending: Atomic[bool]
    droppedEventCount: Atomic[uint64]
    droppedCommandCount: Atomic[uint64]

proc initRuntimeDefaults*(runtime: var BridgeRuntime) =
  runtime.selectedTorrentId = -1
  runtime.nextTorrentId = 0
  runtime.detailTab = 0
  runtime.pieceMapData = ""
  # lastPeerPollTimes is a Table, initialized empty by default
  runtime.showAddTorrent = false
  runtime.addMagnetLink = ""
  runtime.addTorrentPath = ""
  runtime.showSettings = false
  runtime.downloadDir = "~/Downloads"
  runtime.listenPort = "6881"
  runtime.maxDownloadRate = "0"
  runtime.maxUploadRate = "0"
  runtime.maxPeers = "50"
  runtime.dhtEnabled = true
  runtime.pexEnabled = true
  runtime.lsdEnabled = true
  runtime.utpEnabled = true
  runtime.webSeedEnabled = true
  runtime.trackerScrapeEnabled = true
  runtime.holepunchEnabled = true
  runtime.encryptionMode = "prefer_encrypted"
  runtime.actionPriority = "normal"
  runtime.statusDownRate = 0.0
  runtime.statusUpRate = 0.0
  runtime.statusDhtNodes = 0
  runtime.statusText = ""
  runtime.pollActive = false
  runtime.sessionLoaded = false
  runtime.natProtocol = "Discovering..."
  runtime.natExternalIp = ""
  runtime.natGatewayIp = ""
  runtime.natLocalIp = ""
  runtime.natDoubleNat = false
  runtime.natOuterProtocol = ""
  runtime.natOuterGatewayIp = ""
  runtime.natPortsForwarded = false
  runtime.natActiveMappings = 0
  runtime.showRemoveConfirm = false
  runtime.removeDeleteFiles = false
  runtime.actionTorrentId = -1
  runtime.dirtyMask = dmAll
  runtime.lastSaveTime = 0.0
  runtime.notifyPipeRead = -1
  runtime.notifyPipeWrite = -1
  runtime.cmdPipeRead = -1
  runtime.cmdPipeWrite = -1

var gRuntime: BridgeRuntime
initRuntimeDefaults(gRuntime)

template gEventQueue: untyped = gRuntime.eventQueue
template gCommandQueue: untyped = gRuntime.commandQueue
template gEventLoopThread: untyped = gRuntime.eventLoopThread
template gEventLoopRunning: untyped = gRuntime.eventLoopRunning
template gShutdownComplete: untyped = gRuntime.shutdownComplete
template gInitialized: untyped = gRuntime.initialized
template gTorrents: untyped = gRuntime.torrents
template gSelectedTorrentId: untyped = gRuntime.selectedTorrentId
template gNextTorrentId: untyped = gRuntime.nextTorrentId
template gDetailTab: untyped = gRuntime.detailTab
template gFiles: untyped = gRuntime.files
template gPeers: untyped = gRuntime.peers
template gTrackers: untyped = gRuntime.trackers
template gPieceMapData: untyped = gRuntime.pieceMapData
template gPeerSnapshots: untyped = gRuntime.peerSnapshots
template gPeerSmoothedRates: untyped = gRuntime.peerSmoothedRates
template gPeerPrevBytes: untyped = gRuntime.peerPrevBytes
template gLastPeerPollTimes: untyped = gRuntime.lastPeerPollTimes
template gTorrentPrevBytes: untyped = gRuntime.torrentPrevBytes
template gTorrentSmoothedRates: untyped = gRuntime.torrentSmoothedRates
template gShowAddTorrent: untyped = gRuntime.showAddTorrent
template gAddMagnetLink: untyped = gRuntime.addMagnetLink
template gAddTorrentPath: untyped = gRuntime.addTorrentPath
template gShowSettings: untyped = gRuntime.showSettings
template gDownloadDir: untyped = gRuntime.downloadDir
template gListenPort: untyped = gRuntime.listenPort
template gMaxDownloadRate: untyped = gRuntime.maxDownloadRate
template gMaxUploadRate: untyped = gRuntime.maxUploadRate
template gMaxPeers: untyped = gRuntime.maxPeers
template gDhtEnabled: untyped = gRuntime.dhtEnabled
template gPexEnabled: untyped = gRuntime.pexEnabled
template gLsdEnabled: untyped = gRuntime.lsdEnabled
template gUtpEnabled: untyped = gRuntime.utpEnabled
template gWebSeedEnabled: untyped = gRuntime.webSeedEnabled
template gTrackerScrapeEnabled: untyped = gRuntime.trackerScrapeEnabled
template gHolepunchEnabled: untyped = gRuntime.holepunchEnabled
template gEncryptionMode: untyped = gRuntime.encryptionMode
template gActionPriority: untyped = gRuntime.actionPriority
template gStatusDownRate: untyped = gRuntime.statusDownRate
template gStatusUpRate: untyped = gRuntime.statusUpRate
template gStatusDhtNodes: untyped = gRuntime.statusDhtNodes
template gStatusText: untyped = gRuntime.statusText
template gPollActive: untyped = gRuntime.pollActive
template gSessionLoaded: untyped = gRuntime.sessionLoaded
template gNatProtocol: untyped = gRuntime.natProtocol
template gNatExternalIp: untyped = gRuntime.natExternalIp
template gNatGatewayIp: untyped = gRuntime.natGatewayIp
template gNatLocalIp: untyped = gRuntime.natLocalIp
template gNatDoubleNat: untyped = gRuntime.natDoubleNat
template gNatOuterProtocol: untyped = gRuntime.natOuterProtocol
template gNatOuterGatewayIp: untyped = gRuntime.natOuterGatewayIp
template gNatPortsForwarded: untyped = gRuntime.natPortsForwarded
template gNatActiveMappings: untyped = gRuntime.natActiveMappings
template gShowRemoveConfirm: untyped = gRuntime.showRemoveConfirm
template gRemoveDeleteFiles: untyped = gRuntime.removeDeleteFiles
template gActionTorrentId: untyped = gRuntime.actionTorrentId
template gDirty: untyped = gRuntime.dirty
template gDirtyMask: untyped = gRuntime.dirtyMask
template gLastSaveTime: untyped = gRuntime.lastSaveTime
template gNotifyPipeRead: untyped = gRuntime.notifyPipeRead
template gNotifyPipeWrite: untyped = gRuntime.notifyPipeWrite
template gNotifyPending: untyped = gRuntime.notifyPending
template gCmdPipeRead: untyped = gRuntime.cmdPipeRead
template gCmdPipeWrite: untyped = gRuntime.cmdPipeWrite
template gCmdNotifyPending: untyped = gRuntime.cmdNotifyPending
template gDroppedEventCount: untyped = gRuntime.droppedEventCount
template gDroppedCommandCount: untyped = gRuntime.droppedCommandCount

var

  # Event loop thread's private client table.
  # Accessed from CPS tasks (synchronized via AsyncMutex on each TorrentClient).
  # NOT threadvar: with MT runtime, CPS continuations run on the scheduler worker,
  # not the reactor thread, so threadvar would give each thread a separate (nil) copy.
  gClients: Table[int, TorrentClient]

  # Shared resources across all torrents (created once, reused).
  # Avoids fd exhaustion when running multiple concurrent torrents.
  gSharedListener: TcpListener
  gSharedUtpMgr: UtpManager
  gSharedLsdSock: UdpSocket
  gNatMgr: NatManager

  # Command-wake handshake between reactor I/O callback and CPS worker.
  # Lock-free: atomic pointer stores the CpsVoidFuture (cast to pointer).
  # The worker's local variable keeps the future alive (ref count >= 1)
  # while the reactor callback only reads and completes — no ARC interaction.
  gCommandWakePtr: Atomic[pointer]  # cast[pointer](CpsVoidFuture) or nil

proc parseEncryptionMode(modeStr: string): EncryptionMode
proc encryptionModeLabel(mode: EncryptionMode): string
proc enqueueCommand(cmd: sink BridgeCommand)

proc markDirty(mask: uint32) {.inline.} =
  gDirtyMask = gDirtyMask or mask

# ============================================================
# JSON helpers
# ============================================================

proc jStr(node: JsonNode, key: string, default: string): string =
  if node.hasKey(key) and node[key].kind == JString:
    node[key].str
  else: default

proc jInt(node: JsonNode, key: string, default: int): int =
  if node.hasKey(key) and node[key].kind == JInt:
    int(node[key].num)
  else: default

proc jFloat(node: JsonNode, key: string, default: float): float =
  if node.hasKey(key):
    if node[key].kind == JFloat: node[key].fnum
    elif node[key].kind == JInt: float(node[key].num)
    else: default
  else: default

proc jBool(node: JsonNode, key: string, default: bool): bool =
  if node.hasKey(key) and node[key].kind == JBool:
    node[key].bval
  else: default

# ============================================================
# Session persistence
# ============================================================

const
  sessionDir = "~/Library/Application Support/CpsTorrent"
  sessionFile = sessionDir / "session.json"

proc buildSessionJson(): string =
  ## Serialize current session state to a JSON string (in-memory, no I/O).
  ## Called on the main thread where gTorrents/gSettings are owned.
  var data = newJObject()

  var settings = newJObject()
  settings["downloadDir"] = %gDownloadDir
  settings["listenPort"] = %gListenPort
  settings["maxDownloadRate"] = %gMaxDownloadRate
  settings["maxUploadRate"] = %gMaxUploadRate
  settings["maxPeers"] = %gMaxPeers
  settings["dhtEnabled"] = %gDhtEnabled
  settings["pexEnabled"] = %gPexEnabled
  settings["lsdEnabled"] = %gLsdEnabled
  settings["utpEnabled"] = %gUtpEnabled
  settings["webSeedEnabled"] = %gWebSeedEnabled
  settings["trackerScrapeEnabled"] = %gTrackerScrapeEnabled
  settings["holepunchEnabled"] = %gHolepunchEnabled
  settings["encryptionMode"] = %gEncryptionMode
  data["settings"] = settings

  var torrents = newJArray()
  for ts in gTorrents:
    if ts.torrentFilePath.len > 0 or ts.magnetUri.len > 0:
      var entry = newJObject()
      entry["path"] = %ts.torrentFilePath
      entry["magnetUri"] = %ts.magnetUri
      entry["paused"] = %(ts.paused or ts.status == tsPaused)
      entry["downloadDir"] = %gDownloadDir
      entry["addedDate"] = %ts.addedDate
      entry["name"] = %ts.name
      torrents.add(entry)
  data["torrents"] = torrents
  result = $data

proc writeSessionToDisk(jsonStr: string) =
  ## Write serialized session JSON to disk. Called from blocking pool thread
  ## or synchronously during shutdown.
  try:
    let dir = sessionDir.expandTilde
    if not dirExists(dir):
      createDir(dir)
    writeFile(sessionFile.expandTilde, jsonStr)
  except CatchableError as e:
    logBridge "[SESSION] Write error: " & e.msg

proc saveSession() =
  ## Queue session data for async write to disk.
  ## JSON serialization happens here on the main thread (fast, in-memory).
  ## Disk I/O is deferred to the event loop's sessionSaveLoop via Mailbox.
  ## Multiple rapid saves coalesce — only the latest is written.
  try:
    let jsonStr = buildSessionJson()
    discard gPendingSessionSave.send(jsonStr)
    logBridge "[SESSION] Queued save (" & $gTorrents.len & " torrents)"
  except CatchableError as e:
    logBridge "[SESSION] Save error: " & e.msg

proc flushSessionSave() =
  ## Synchronous flush of any pending session save. Called during shutdown
  ## when the event loop may no longer be running.
  let pending = gPendingSessionSave.drainAll()
  if pending.len > 0:
    writeSessionToDisk(pending[^1])

proc loadSession() =
  ## Load saved session and re-add torrents.
  if gSessionLoaded:
    logBridge "[SESSION] Load skipped (already loaded)"
    return
  gSessionLoaded = true

  let path = sessionFile.expandTilde
  if not fileExists(path):
    logBridge "[SESSION] No session file found"
    return

  try:
    let data = parseJson(readFile(path))
    var restoredCount = 0

    # Restore settings
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

    # Restore torrents
    if data.hasKey("torrents"):
      for entry in data["torrents"]:
        let torrentPath = jStr(entry, "path", "")
        let magnetUri = jStr(entry, "magnetUri", "")
        let wasPaused = jBool(entry, "paused", false)
        var existingIdx = -1
        if torrentPath.len > 0:
          for i in 0 ..< gTorrents.len:
            if gTorrents[i].torrentFilePath == torrentPath:
              existingIdx = i
              break
        elif magnetUri.len > 0:
          for i in 0 ..< gTorrents.len:
            if gTorrents[i].magnetUri == magnetUri:
              existingIdx = i
              break

        if existingIdx >= 0:
          if not wasPaused and not gTorrents[existingIdx].clientActive:
            if torrentPath.len > 0 and fileExists(torrentPath):
              enqueueCommand(BridgeCommand(kind: cmdAddTorrentFile,
                text: torrentPath, intParam: gTorrents[existingIdx].id))
            elif magnetUri.len > 0 and magnetUri.startsWith("magnet:"):
              enqueueCommand(BridgeCommand(kind: cmdAddTorrentMagnet,
                text: magnetUri, intParam: gTorrents[existingIdx].id))
          continue

        if torrentPath.len > 0 and fileExists(torrentPath):
          # Restore from .torrent file
          let torrentId = gNextTorrentId
          inc gNextTorrentId
          let savedName = jStr(entry, "name", extractFilename(torrentPath))
          let savedDate = jStr(entry, "addedDate", "")
          let addedDate = if savedDate.len > 0: savedDate
                          else: fromUnixFloat(epochTime()).local.format("yyyy-MM-dd HH:mm")
          gTorrents.add(TorrentState(
            id: torrentId,
            name: savedName,
            status: if wasPaused: tsPaused else: tsDownloading,
            addedDate: addedDate,
            torrentFilePath: torrentPath,
            paused: wasPaused,
          ))
          if not wasPaused:
            enqueueCommand(BridgeCommand(kind: cmdAddTorrentFile,
              text: torrentPath, intParam: torrentId))
            gTorrents[^1].clientActive = true
          inc restoredCount
          logBridge "[SESSION] Restored torrent: " & extractFilename(torrentPath) &
            (if wasPaused: " (paused)" else: "")

        elif magnetUri.len > 0 and magnetUri.startsWith("magnet:"):
          # Restore from magnet link
          let torrentId = gNextTorrentId
          inc gNextTorrentId
          let savedName = jStr(entry, "name", "Loading metadata...")
          let savedDate = jStr(entry, "addedDate", "")
          let addedDate = if savedDate.len > 0: savedDate
                          else: fromUnixFloat(epochTime()).local.format("yyyy-MM-dd HH:mm")
          gTorrents.add(TorrentState(
            id: torrentId,
            name: savedName,
            status: if wasPaused: tsPaused else: tsDownloading,
            addedDate: addedDate,
            magnetUri: magnetUri,
            paused: wasPaused,
          ))
          if not wasPaused:
            enqueueCommand(BridgeCommand(kind: cmdAddTorrentMagnet,
              text: magnetUri, intParam: torrentId))
            gTorrents[^1].clientActive = true
          inc restoredCount
          logBridge "[SESSION] Restored magnet: " & savedName &
            (if wasPaused: " (paused)" else: "")

        else:
          logBridge "[SESSION] Skipped missing file: " & torrentPath

    gDirty.store(true, moRelease)
    logBridge "[SESSION] Loaded session with " & $restoredCount & " restored torrents (" &
      $gTorrents.len & " total in state)"
  except CatchableError as e:
    logBridge "[SESSION] Load error: " & e.msg

# ============================================================
# Notify pipe
# ============================================================

proc notifySwift() =
  ## Coalesced pipe write to wake Swift's DispatchSource.
  if gNotifyPipeWrite < 0: return
  if gNotifyPending.exchange(true, moAcquireRelease): return
  var buf: array[1, byte] = [1'u8]
  while true:
    let n = posix.write(gNotifyPipeWrite, addr buf[0], 1)
    if n == 1: return
    if osLastError().int == EINTR: continue
    return

proc notifyEventLoop() =
  ## Coalesced pipe write to wake the event loop when commands are enqueued.
  ## Called from the main thread (Swift dispatch).
  ## Command processing waits on this pipe from the MT runtime reactor.
  if gCmdPipeWrite < 0: return
  if gCmdNotifyPending.exchange(true, moAcquireRelease): return
  var buf: array[1, byte] = [1'u8]
  while true:
    let n = posix.write(gCmdPipeWrite, addr buf[0], 1)
    if n == 1: return
    if osLastError().int == EINTR: continue
    return

# ============================================================
# Event queue helpers — deep clone for cross-thread isolation
# ============================================================
#
# Even though --mm:atomicArc makes refcount ops atomic, we deep-clone
# payloads before enqueueing to avoid sharing ARC-managed references
# across threads.  This sidesteps subtle lifetime issues when a
# TorrentClient field is mutated or freed while the main thread still
# holds a refcounted alias via an in-flight UiEvent.

proc cloneStringIsolated(s: string): string =
  if s.len == 0:
    return ""
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
    let e = src[i]
    result[i] = PeerSnapshotEntry(
      address: cloneStringIsolated(e.address),
      clientName: cloneStringIsolated(e.clientName),
      bytesDownloaded: e.bytesDownloaded,
      bytesUploaded: e.bytesUploaded,
      progress: e.progress,
      flags: cloneStringIsolated(e.flags),
      flagsTooltip: cloneStringIsolated(e.flagsTooltip),
      source: cloneStringIsolated(e.source),
      transport: cloneStringIsolated(e.transport)
    )

proc cloneTrackerSnapshotSeqIsolated(src: seq[TrackerState]): seq[TrackerState] =
  if src.len == 0: return @[]
  result = newSeq[TrackerState](src.len)
  for i in 0 ..< src.len:
    let t = src[i]
    result[i] = TrackerState(
      url: cloneStringIsolated(t.url),
      status: cloneStringIsolated(t.status),
      seeders: t.seeders,
      leechers: t.leechers,
      completed: t.completed,
      lastAnnounce: cloneStringIsolated(t.lastAnnounce),
      nextAnnounce: cloneStringIsolated(t.nextAnnounce),
      lastScrape: cloneStringIsolated(t.lastScrape),
      nextScrape: cloneStringIsolated(t.nextScrape),
      errorText: cloneStringIsolated(t.errorText)
    )

proc cloneFileInfoSeqIsolated(src: seq[tuple[path: string, length: int64]]):
    seq[tuple[path: string, length: int64]] =
  if src.len == 0: return @[]
  result = newSeq[tuple[path: string, length: int64]](src.len)
  for i in 0 ..< src.len:
    result[i] = (path: cloneStringIsolated(src[i].path), length: src[i].length)

proc cloneUiEventIsolated(evt: sink UiEvent): UiEvent =
  ## Under --mm:atomicArc, string/seq refcount ops are atomic, so cross-thread
  ## sharing is safe. Move the event directly instead of deep-cloning every
  ## string field. This eliminates ~500 allocShared+copyMem calls per progress
  ## event when 100 peers are connected.
  result = move evt

proc cloneBridgeCommandIsolated(cmd: sink BridgeCommand): BridgeCommand =
  result = move cmd

proc enqueueCommand(cmd: sink BridgeCommand) =
  ## Main-thread -> event-loop queue transfer with isolated payload.
  if not gCommandQueue.send(cloneBridgeCommandIsolated(cmd)):
    discard gDroppedCommandCount.fetchAdd(1'u64, moRelaxed)
    return
  notifyEventLoop()

proc pushEvent(evt: sink UiEvent) =
  ## Push a UI event and mark state dirty.
  if not gEventQueue.send(cloneUiEventIsolated(evt)):
    discard gDroppedEventCount.fetchAdd(1'u64, moRelaxed)
    return
  gDirty.store(true, moRelease)
  notifySwift()

# ============================================================
# Formatting helpers
# ============================================================

proc formatRate(bytesPerSec: float): string =
  if bytesPerSec < 1: "0 B/s"
  elif bytesPerSec < 1024: $(int(bytesPerSec)) & " B/s"
  elif bytesPerSec < 1024 * 1024:
    formatFloat(bytesPerSec / 1024, ffDecimal, 1) & " KB/s"
  elif bytesPerSec < 1024 * 1024 * 1024:
    formatFloat(bytesPerSec / (1024 * 1024), ffDecimal, 1) & " MB/s"
  else:
    formatFloat(bytesPerSec / (1024 * 1024 * 1024), ffDecimal, 2) & " GB/s"

proc formatBytes(bytes: float): string =
  if bytes < 0: "0 B"
  elif bytes < 1024: $(int(bytes)) & " B"
  elif bytes < 1024 * 1024:
    formatFloat(bytes / 1024, ffDecimal, 1) & " KB"
  elif bytes < 1024 * 1024 * 1024:
    formatFloat(bytes / (1024 * 1024), ffDecimal, 1) & " MB"
  elif bytes < 1024 * 1024 * 1024 * 1024:
    formatFloat(bytes / (1024 * 1024 * 1024), ffDecimal, 2) & " GB"
  else:
    formatFloat(bytes / (1024 * 1024 * 1024 * 1024), ffDecimal, 2) & " TB"

proc formatEta(bytesRemaining: float, rate: float): string =
  if rate < 1: return ""
  let seconds = bytesRemaining / rate
  if seconds < 0 or seconds > 365 * 86400: return "∞"
  let totalSec = int(seconds)
  if totalSec < 60: return $totalSec & "s"
  elif totalSec < 3600: return $(totalSec div 60) & "m"
  elif totalSec < 86400:
    let h = totalSec div 3600
    let m = (totalSec mod 3600) div 60
    return $h & "h " & $m & "m"
  else:
    let d = totalSec div 86400
    let h = (totalSec mod 86400) div 3600
    return $d & "d " & $h & "h"

proc formatPercent(progress: float): string =
  if progress >= 1.0: "100%"
  elif progress <= 0.0: "0%"
  else: formatFloat(progress * 100, ffDecimal, 1) & "%"

proc formatTimestamp(t: float): string =
  if t <= 0: return ""
  let dt = fromUnixFloat(t).local
  dt.format("yyyy-MM-dd HH:mm")

# ============================================================
# Torrent state lookup
# ============================================================

proc findTorrentIdx(id: int): int =
  for i in 0 ..< gTorrents.len:
    if gTorrents[i].id == id:
      return i
  return -1

proc findTorrentById(id: int): ptr TorrentState =
  for i in 0 ..< gTorrents.len:
    if gTorrents[i].id == id:
      return addr gTorrents[i]
  return nil

# ============================================================
# Piece map encoding
# ============================================================

proc buildPieceMapData(ts: TorrentState): string =
  ## Return the piece map data snapshot (built on event loop thread).
  ts.pieceMapData

# ============================================================
# Build peer info from snapshot (no cross-thread access)
# ============================================================

proc buildPeerInfoFromSnapshot(torrentId: int) =
  ## Build gPeers from the stored peer snapshot (populated by event queue).
  ## No cross-thread data access — snapshot was built on the event loop thread.
  ## Uses adaptive EMA smoothing (~2s time constant) for stable per-peer rate display.
  ##
  ## IMPORTANT: This proc may be called every GUI poll (~16ms), but snapshots
  ## only update every ~500ms (from progressLoop). We detect whether the snapshot
  ## has new data by comparing byte counts. If unchanged, we reuse existing
  ## smoothed rates without updating prev bytes or timestamps. This prevents
  ## the delta from being "consumed" on stale polls and producing zero rates.
  gPeers.setLen(0)

  if not gPeerSnapshots.hasKey(torrentId):
    return

  let snapshot = gPeerSnapshots[torrentId]
  let now = epochTime()

  # Detect if any peer has new byte data since last rate computation
  var hasNewData = false
  for entry in snapshot:
    let key = $torrentId & ":" & entry.address
    if not gPeerPrevBytes.hasKey(key):
      hasNewData = true
      break
    let prev = gPeerPrevBytes[key]
    if entry.bytesDownloaded != prev.down or entry.bytesUploaded != prev.up:
      hasNewData = true
      break

  # Use per-torrent poll time so switching torrents doesn't skew dt
  let lastTime = gLastPeerPollTimes.getOrDefault(torrentId, 0.0)
  let elapsed = if lastTime > 0 and hasNewData: now - lastTime else: 2.0
  let dt = max(elapsed, 0.1)

  # Adaptive alpha: ~2s time constant, consistent regardless of poll interval
  let alpha = max(0.05, min(0.8, 1.0 - exp(-dt / 2.0)))

  # Track which peers are still present (for cleanup of stale rate entries)
  var activePeerKeys: HashSet[string]

  for entry in snapshot:
    let key = $torrentId & ":" & entry.address
    activePeerKeys.incl(key)

    var downRate, upRate: float

    if hasNewData:
      # New snapshot data: compute fresh rates from byte deltas
      downRate = 0.0
      upRate = 0.0
      if gPeerPrevBytes.hasKey(key):
        let prev = gPeerPrevBytes[key]
        let downDelta = entry.bytesDownloaded - prev.down
        let upDelta = entry.bytesUploaded - prev.up
        if downDelta > 0: downRate = downDelta.float / dt
        if upDelta > 0: upRate = upDelta.float / dt

      # Apply adaptive EMA smoothing for stable display
      let instantDl = downRate
      let instantUl = upRate
      if gPeerSmoothedRates.hasKey(key):
        let prev = gPeerSmoothedRates[key]
        downRate = alpha * downRate + (1.0 - alpha) * prev.down
        upRate = alpha * upRate + (1.0 - alpha) * prev.up

      # Snap to zero when traffic truly stops
      if instantDl == 0.0 and downRate < 100.0:
        downRate = 0.0
      if instantUl == 0.0 and upRate < 100.0:
        upRate = 0.0
      gPeerSmoothedRates[key] = (down: downRate, up: upRate)

      # Store current bytes for next delta
      gPeerPrevBytes[key] = (down: entry.bytesDownloaded, up: entry.bytesUploaded)
    else:
      # Same snapshot data: reuse existing smoothed rates
      let rates = gPeerSmoothedRates.getOrDefault(key, (down: 0.0, up: 0.0))
      downRate = rates.down
      upRate = rates.up

    gPeers.add((
      address: entry.address,
      client: entry.clientName,
      downloadRate: downRate,
      uploadRate: upRate,
      progress: entry.progress,
      flags: entry.flags,
      flagsTooltip: entry.flagsTooltip,
      source: entry.source,
      transport: entry.transport
    ))

  if hasNewData:
    gLastPeerPollTimes[torrentId] = now

  # Clean up stale rate entries for peers that disconnected
  var staleKeys: seq[string]
  for key in gPeerSmoothedRates.keys:
    if key notin activePeerKeys:
      staleKeys.add(key)
  for key in staleKeys:
    gPeerSmoothedRates.del(key)
    gPeerPrevBytes.del(key)

# ============================================================
# Build file info for selected torrent
# ============================================================

proc buildFileInfo(ts: TorrentState) =
  gFiles.setLen(0)
  for i in 0 ..< ts.fileInfo.len:
    let f = ts.fileInfo[i]
    var fileProgress = ts.progress  # Simplified: use overall progress
    let pr = if i < ts.filePriorities.len and ts.filePriorities[i].len > 0:
      ts.filePriorities[i]
    else:
      "normal"
    gFiles.add((
      index: i,
      path: f.path,
      size: f.length.float,
      progress: fileProgress,
      priority: pr
    ))

# ============================================================
# Build tracker info for selected torrent
# ============================================================

proc buildTrackerInfo(ts: TorrentState) =
  gTrackers.setLen(0)
  let isActive = ts.clientActive and not ts.paused
  if ts.trackerStates.len > 0:
    logBridge "[TRACKER] ts.trackerStates.len=" & $ts.trackerStates.len & " for torrent " & $ts.id
    for tr in ts.trackerStates:
      var tracker = tr
      if not isActive:
        tracker.status = "disabled"
      gTrackers.add(tracker)
    return

  # Fallback for torrents that haven't emitted tracker runtime yet.
  let trackerStatus = if not isActive: "disabled"
                      elif ts.hasTrackerResponse: "working"
                      else: "updating"
  for url in ts.announceUrls:
    gTrackers.add(TrackerState(
      url: url,
      status: trackerStatus,
      seeders: ts.trackerSeeders,
      leechers: ts.trackerLeechers,
      completed: 0,
      lastAnnounce: "",
      nextAnnounce: "",
      lastScrape: "",
      nextScrape: "",
      errorText: ""
    ))

# ============================================================
# Peer snapshot builder (called on event loop thread)
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
  ## Count set bits in a bitfield using byte-level popcount lookup table.
  let fullBytes = totalPieces div 8
  for i in 0 ..< min(fullBytes, bitfield.len):
    result += PopCountTable[bitfield[i].int].int
  # Handle trailing bits in the last partial byte
  let remaining = totalPieces mod 8
  if remaining > 0 and fullBytes < bitfield.len:
    let lastByte = bitfield[fullBytes].int
    for bit in 0 ..< remaining:
      if (lastByte and (1 shl (7 - bit))) != 0:
        inc result

# Lightweight raw peer data for fast copy under lock.
# All formatting (parsePeerId, bitfieldPopcount, flag building) happens OUTSIDE the lock.
type
  RawPeerData = object
    ip: string
    port: uint16
    remotePeerId: array[20, byte]
    peerChoking, amInterested, amChoking, peerInterested: bool
    markedSeedAt: float
    peerUploadOnly, isSuperSeeder, pexHasUtp, pexHasHolepunch: bool
    mseEncrypted: bool
    remoteListenPort: uint16
    priority: uint32
    peerBitfield: seq[byte]
    bytesDownloaded, bytesUploaded: int64
    source: PeerSource
    transport: TransportKind
    supportsMetadata, supportsPex, supportsDontHave, supportsHolepunch: bool

  RawTrackerData = object
    url: string
    status: string
    seeders, leechers, completed: int
    lastAnnounce, nextAnnounce: float
    lastScrape, nextScrape: float
    errorText: string

proc copyRawPeerData(peer: PeerConn): RawPeerData =
  ## Fast field-by-field copy of peer data under lock. No formatting, no allocation-heavy ops.
  RawPeerData(
    ip: peer.ip,
    port: peer.port,
    remotePeerId: peer.remotePeerId,
    peerChoking: peer.peerChoking,
    amInterested: peer.amInterested,
    amChoking: peer.amChoking,
    peerInterested: peer.peerInterested,
    markedSeedAt: peer.markedSeedAt,
    peerUploadOnly: peer.peerUploadOnly,
    isSuperSeeder: peer.isSuperSeeder,
    pexHasUtp: peer.pexHasUtp,
    pexHasHolepunch: peer.pexHasHolepunch,
    mseEncrypted: peer.mseEncrypted,
    remoteListenPort: peer.remoteListenPort,
    priority: peer.priority,
    peerBitfield: peer.peerBitfield,
    bytesDownloaded: peer.bytesDownloaded,
    bytesUploaded: peer.bytesUploaded,
    source: peer.source,
    transport: peer.transport,
    supportsMetadata: peer.extensions.supportsExtension("ut_metadata"),
    supportsPex: peer.extensions.supportsExtension("ut_pex"),
    supportsDontHave: peer.extensions.supportsExtension("lt_donthave"),
    supportsHolepunch: peer.extensions.supportsExtension("ut_holepunch")
  )

proc buildPeerSnapshotFromRaw(raw: RawPeerData, totalPieces: int): PeerSnapshotEntry =
  ## Expensive formatting: parsePeerId, bitfieldPopcount, flag strings.
  ## Called OUTSIDE the lock.
  let info = parsePeerId(raw.remotePeerId)
  var flags = ""
  var tips: seq[string]
  if not raw.peerChoking and raw.amInterested:
    flags.add("D"); tips.add("D - Downloading")
  elif raw.amInterested:
    flags.add("d"); tips.add("d - Interested but choked")
  if not raw.amChoking and raw.peerInterested:
    flags.add("U"); tips.add("U - Uploading")
  elif raw.peerInterested:
    flags.add("u"); tips.add("u - Peer interested, choked")
  if raw.markedSeedAt > 0.0 or raw.peerUploadOnly:
    flags.add("S"); tips.add("S - Seed")
  if raw.peerUploadOnly:
    flags.add("O"); tips.add("O - Upload-only (BEP 21)")
  if raw.isSuperSeeder:
    flags.add("s"); tips.add("s - Super seeder (BEP 16)")
  if raw.pexHasUtp or raw.transport == ptUtp:
    flags.add("T"); tips.add("T - uTP capable")
  if raw.pexHasHolepunch or raw.supportsHolepunch:
    flags.add("H"); tips.add("H - Holepunch capable (BEP 55)")
  if raw.mseEncrypted:
    flags.add("E"); tips.add("E - Encrypted")
  if raw.remoteListenPort > 0:
    tips.add("Ext listen port p=" & $raw.remoteListenPort)
  tips.add("BEP40 priority: " & $raw.priority)
  if raw.supportsMetadata:
    tips.add("ut_metadata")
  if raw.supportsPex:
    tips.add("ut_pex")
  if raw.supportsDontHave:
    tips.add("lt_donthave")

  var peerProgress = 0.0
  if raw.isSuperSeeder:
    peerProgress = 1.0
  elif raw.peerBitfield.len > 0 and totalPieces > 0:
    let have = bitfieldPopcount(raw.peerBitfield, totalPieces)
    peerProgress = have.float / totalPieces.float

  let sourceStr = case raw.source
    of srcTracker: "Tracker"
    of srcDht: "DHT"
    of srcPex: "PEX"
    of srcLsd: "LSD"
    of srcIncoming: "Incoming"
    of srcHolepunch: "Holepunch"
    of srcUnknown: ""

  PeerSnapshotEntry(
    address: formatPeerAddr(raw.ip, raw.port),
    clientName: info.clientName,
    bytesDownloaded: raw.bytesDownloaded,
    bytesUploaded: raw.bytesUploaded,
    progress: peerProgress,
    flags: flags,
    flagsTooltip: if tips.len > 0: tips.join("\n") else: "No active flags",
    source: sourceStr,
    transport: if raw.transport == ptUtp: "uTP" else: "TCP"
  )

proc buildPeerSnapshotEntry(peer: PeerConn, totalPieces: int): PeerSnapshotEntry =
  buildPeerSnapshotFromRaw(copyRawPeerData(peer), totalPieces)

# ============================================================
# Event loop: drain client events (CPS task, runs on event loop thread)
# ============================================================

proc drainClientEvents(torrentId: int, client: TorrentClient): CpsVoidFuture {.cps.} =
  ## CPS task to drain events from a TorrentClient and push to UI event queue.
  ##
  ## KEY DESIGN: The lock critical section copies ONLY raw scalar/seq data.
  ## All expensive formatting (parsePeerId, bitfieldPopcount, formatTimestamp,
  ## flag building, string concatenation) happens OUTSIDE the lock. This
  ## minimizes lock hold time so eventLoop/unchokeLoop/connectLoop aren't
  ## starved of the mutex while we build GUI snapshots.
  logBridge "[DRAIN] Started draining events for torrent " & $torrentId
  var progressCount = 0
  while client.state != csStopped:
    let evt = await client.events.recv()
    if evt.kind == cekError or evt.kind == cekInfo:
      logBridge "[DRAIN] Event: " & $evt.kind & " for torrent " & $torrentId & " msg='" & evt.errMsg & "'"
    case evt.kind
    of cekStarted:
      pushEvent(UiEvent(kind: uiTorrentStarted, torrentId: torrentId))
    of cekPieceVerified:
      pushEvent(UiEvent(kind: uiPieceVerified, torrentId: torrentId,
                        intParam: evt.pieceIndex))
    of cekProgress:
      progressCount += 1
      # ---- Raw data containers (populated under lock) ----
      # NOTE: All seq vars MUST have explicit initializers (= @[]) or be move'd
      # at the end. CPS env fields are NOT re-initialized per loop iteration —
      # only vars with explicit initializers generate re-initialization code
      # in the step function. Without this, seqs accumulate across iterations.
      var downloaded: float
      var uploaded: float
      var progress: float
      var verifiedCount: int
      var dhtNodes: int
      var totalPieces: int
      var totalSize: float
      var utpPeers = 0
      var tcpPeers = 0
      var rawPeers: seq[RawPeerData] = @[]  # Raw peer fields (formatted outside lock)
      var pmData = ""
      var fInfoSnap: seq[tuple[path: string, length: int64]] = @[]
      var fPrioSnap: seq[string] = @[]
      var rawTrackers: seq[RawTrackerData] = @[]  # Raw tracker fields (timestamps formatted outside lock)
      var snapFileInfo = (progressCount mod 5) == 1 or progressCount <= 2
      var snapTrackers = (progressCount mod 5) == 1 or progressCount <= 2
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
      var snapIsPrivate = false
      var snapEnablePex = false
      var snapEnableLsd = false
      var snapEnableUtp = false
      var snapEnableWebSeed = false
      var snapEnableTrackerScrape = false
      var snapEnableHolepunch = false
      var snapEncryptionMode = emPreferEncrypted
      var snapClientStopped = false

      # Read DHT node count outside client.mtx — dhtNodeCount() has its own lock
      dhtNodes = client.dhtNodeCount

      # ============================================================
      # Lock-free reads: counters, config, and state (no mutation, same
      # event loop thread — CPS tasks don't preempt between await points)
      # ============================================================
      if client.pieceMgr != nil:
        downloaded = client.pieceMgr.downloaded.float
        uploaded = client.pieceMgr.uploaded.float
        verifiedCount = client.pieceMgr.verifiedCount
        progress = client.pieceMgr.progress
        totalPieces = client.pieceMgr.totalPieces
        totalSize = client.metainfo.info.totalLength.float
      snapName = client.metainfo.info.name
      snapDhtEnabled = client.config.enableDht and client.dhtEnabled
      snapIsPrivate = client.isPrivate
      snapEnablePex = client.config.enablePex
      snapEnableLsd = client.config.enableLsd
      snapEnableUtp = client.config.enableUtp
      snapEnableWebSeed = client.config.enableWebSeed
      snapEnableTrackerScrape = client.config.enableTrackerScrape
      snapEnableHolepunch = client.config.enableHolepunch
      snapEncryptionMode = client.config.encryptionMode
      snapLsdAnnounces = client.lsdAnnounceCount
      snapLsdPeers = client.lsdPeersDiscovered
      snapLsdLastError = client.lsdLastError
      snapWebSeedBytes = client.webSeedBytes
      snapWebSeedFailures = client.webSeedFailures
      snapWebSeedActiveUrl = client.webSeedActiveUrl
      snapHolepunchAttempts = client.holepunchAttempts
      snapHolepunchSuccesses = client.holepunchSuccesses
      snapHolepunchLastError = client.holepunchLastError
      snapClientStopped = client.state == csStopped

      # Copy file info (immutable metainfo, no lock needed)
      if snapFileInfo and client.metainfo.info.files.len > 0:
        for i, f in client.metainfo.info.files:
          fInfoSnap.add((path: f.path, length: f.length))
          var pr = client.filePriorities.getOrDefault(i, "normal")
          if client.selectedFiles.len > 0 and i notin client.selectedFiles and
             i notin client.filePriorities:
            pr = "skip"
          fPrioSnap.add(pr)

      # ============================================================
      # LOCK: peer data + piece states (mutated by handlePeerEvent)
      # ============================================================
      await lock(client.mtx)
      try:
        # Copy raw peer data (just field values, no parsePeerId/bitfieldPopcount)
        for p in client.activePeers:
          if p.transport == ptUtp:
            inc utpPeers
          else:
            inc tcpPeers
          rawPeers.add(copyRawPeerData(p))

        # Copy piece states (simple byte-per-piece, no string formatting)
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
      finally:
        unlock(client.mtx)

      # Tracker snapshot under dedicated trackerLock (independent of main mtx)
      if snapTrackers:
        withSpinLock(client.trackerLock):
          var seenTrackerUrls = initHashSet[string]()
          if client.metainfo.announce.len > 0:
            seenTrackerUrls.incl(client.metainfo.announce)
            let tr = client.trackerRuntime.getOrDefault(client.metainfo.announce, TrackerRuntime(
              url: client.metainfo.announce,
              status: if snapClientStopped: "disabled" else: "updating"
            ))
            rawTrackers.add(RawTrackerData(url: client.metainfo.announce,
              status: tr.status, seeders: tr.seeders, leechers: tr.leechers,
              completed: tr.completed, lastAnnounce: tr.lastAnnounce,
              nextAnnounce: tr.nextAnnounce, lastScrape: tr.lastScrape,
              nextScrape: tr.nextScrape, errorText: tr.errorText))
          for tier in client.metainfo.announceList:
            for url in tier:
              if url.len > 0 and url notin seenTrackerUrls:
                seenTrackerUrls.incl(url)
                let tr = client.trackerRuntime.getOrDefault(url, TrackerRuntime(
                  url: url,
                  status: if snapClientStopped: "disabled" else: "updating"
                ))
                rawTrackers.add(RawTrackerData(url: url,
                  status: tr.status, seeders: tr.seeders, leechers: tr.leechers,
                  completed: tr.completed, lastAnnounce: tr.lastAnnounce,
                  nextAnnounce: tr.nextAnnounce, lastScrape: tr.lastScrape,
                  nextScrape: tr.nextScrape, errorText: tr.errorText))
          # Also check trackerRuntime for URLs not in metainfo
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
                rawTrackers.add(RawTrackerData(url: url,
                  status: tr.status, seeders: tr.seeders, leechers: tr.leechers,
                  completed: tr.completed, lastAnnounce: tr.lastAnnounce,
                  nextAnnounce: tr.nextAnnounce, lastScrape: tr.lastScrape,
                  nextScrape: tr.nextScrape, errorText: tr.errorText))

      # ============================================================
      # OUTSIDE LOCK: expensive formatting (parsePeerId, bitfieldPopcount,
      # formatTimestamp, flag building, string concatenation)
      # ============================================================

      # Format peer snapshots (parsePeerId, bitfieldPopcount, flag strings)
      var peerSnap: seq[PeerSnapshotEntry]
      if rawPeers.len > 0:
        peerSnap = newSeq[PeerSnapshotEntry](rawPeers.len)
        var rpi = 0
        while rpi < rawPeers.len:
          peerSnap[rpi] = buildPeerSnapshotFromRaw(rawPeers[rpi], totalPieces)
          rpi += 1

      # Format tracker snapshots (formatTimestamp x4 per tracker)
      var trackerSnap: seq[TrackerState]
      if rawTrackers.len > 0:
        trackerSnap = newSeq[TrackerState](rawTrackers.len)
        var rti = 0
        while rti < rawTrackers.len:
          let rt = rawTrackers[rti]
          trackerSnap[rti] = TrackerState(
            url: rt.url,
            status: rt.status,
            seeders: rt.seeders,
            leechers: rt.leechers,
            completed: rt.completed,
            lastAnnounce: formatTimestamp(rt.lastAnnounce),
            nextAnnounce: formatTimestamp(rt.nextAnnounce),
            lastScrape: formatTimestamp(rt.lastScrape),
            nextScrape: formatTimestamp(rt.nextScrape),
            errorText: rt.errorText
          )
          rti += 1

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
                        protocolPrivate: snapIsPrivate,
                        protocolDhtEnabled: snapDhtEnabled,
                        protocolPexEnabled: snapEnablePex and not snapIsPrivate,
                        protocolLsdEnabled: snapEnableLsd and not snapIsPrivate,
                        protocolUtpEnabled: snapEnableUtp,
                        protocolWebSeedEnabled: snapEnableWebSeed,
                        protocolScrapeEnabled: snapEnableTrackerScrape,
                        protocolHolepunchEnabled: snapEnableHolepunch and not snapIsPrivate,
                        protocolEncryptionMode: encryptionModeLabel(snapEncryptionMode),
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
# Event loop: build config from current settings
# ============================================================

proc ensureSharedResources() =
  ## Create shared TCP listener, uTP manager, and LSD socket once.
  ## Called on the event loop thread before creating each client.
  ## Tries dual-stack IPv6 first (accepts both IPv4 and IPv6), falls back to IPv4.
  let port = (try: parseUInt(gListenPort).uint16 except: 6881'u16)
  if gSharedListener == nil:
    # Try dual-stack IPv6 listener first
    try:
      gSharedListener = tcpListen("::", port.int, domain = AF_INET6, dualStack = true)
    except CatchableError:
      try:
        gSharedListener = tcpListen("0.0.0.0", port.int)
      except CatchableError:
        try:
          gSharedListener = tcpListen("0.0.0.0", 0)
        except CatchableError:
          logBridge "[SHARED] Failed to create TCP listener"
  if gSharedUtpMgr == nil:
    # Try dual-stack IPv6 uTP manager first
    try:
      let utpPort = if gSharedListener != nil: gSharedListener.localPort() else: 0
      gSharedUtpMgr = newUtpManager(utpPort, AF_INET6)
      gSharedUtpMgr.start()
    except CatchableError:
      try:
        let utpPort = if gSharedListener != nil: gSharedListener.localPort() else: 0
        gSharedUtpMgr = newUtpManager(utpPort)
        gSharedUtpMgr.start()
      except CatchableError:
        try:
          gSharedUtpMgr = newUtpManager(0)
          gSharedUtpMgr.start()
        except CatchableError:
          logBridge "[SHARED] Failed to create uTP manager"

proc parseEncryptionMode(modeStr: string): EncryptionMode =
  case modeStr.toLowerAscii
  of "prefer_plaintext":
    emPreferPlaintext
  of "require_encrypted":
    emRequireEncrypted
  of "force_rc4":
    emForceRc4
  else:
    emPreferEncrypted

proc encryptionModeLabel(mode: EncryptionMode): string =
  case mode
  of emPreferPlaintext: "prefer_plaintext"
  of emRequireEncrypted: "require_encrypted"
  of emForceRc4: "force_rc4"
  of emPreferEncrypted: "prefer_encrypted"

proc buildConfig(): ClientConfig =
  ## Build a ClientConfig from the current (snapshot-synced) settings.
  ## Settings are read-only from the event loop's perspective — they're
  ## set by syncFromSnapshot on the main thread and only read here.
  ## Includes shared resources to avoid per-torrent socket creation.
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
# Event loop: start client from torrent file (shared by add + resume)
# ============================================================

proc startClientFromFile(torrentId: int, path: string): CpsVoidFuture {.cps.} =
  ## Parse a .torrent file, create a client, register it, notify the UI,
  ## and spawn CPS tasks. Called on the event loop thread.
  ## File I/O and bencode parsing are offloaded to the blocking pool to avoid
  ## stalling the reactor. TorrentMetainfo is a value type — safe to move
  ## across threads under --mm:atomicArc.
  let metainfo: TorrentMetainfo = await spawnBlocking(proc(): TorrentMetainfo =
    {.cast(gcsafe).}:
      parseTorrent(readFile(path))
  )
  logBridge "[EVENT LOOP] Parsed torrent: " & metainfo.info.name &
    " pieces=" & $metainfo.info.pieceCount &
    " totalSize=" & $metainfo.info.totalLength
  let config = buildConfig()
  let tc = newTorrentClient(metainfo, config)
  gClients[torrentId] = tc

  var trackerCount = metainfo.announceList.len
  if metainfo.announce.len > 0:
    trackerCount = max(1, trackerCount)

  # Build file info and announce URLs to copy to main thread
  var fInfo: seq[tuple[path: string, length: int64]]
  for f in metainfo.info.files:
    fInfo.add((path: f.path, length: f.length))
  var aUrls: seq[string]
  if metainfo.announce.len > 0:
    aUrls.add(metainfo.announce)
  for tier in metainfo.announceList:
    for url in tier:
      if url notin aUrls:
        aUrls.add(url)

  pushEvent(UiEvent(kind: uiClientReady, torrentId: torrentId,
                    text2: metainfo.info.name,
                    text3: metainfo.info.infoHashHex,
                    floatParam: metainfo.info.totalLength.float,
                    intParam: metainfo.info.pieceCount,
                    intParam2: trackerCount,
                    fileInfo: fInfo,
                    announceUrls: aUrls,
                    downloadDir: config.downloadDir))

  discard spawn tc.start()
  discard spawn drainClientEvents(torrentId, tc)

# ============================================================
# Event loop: shared accept loops (dispatch incoming by info hash)
# ============================================================

proc snapshotClientIds(): seq[int] =
  ## Snapshot client IDs for iteration inside CPS code paths.
  for clientId in gClients.keys:
    result.add(clientId)

proc findClientByInfoHash(infoHash: array[20, byte]): TorrentClient =
  ## Look up the client whose torrent matches the given info hash.
  ## Returns nil if no match. Only called from event loop thread.
  let ids = snapshotClientIds()
  var i = 0
  while i < ids.len:
    let id = ids[i]
    i += 1
    if id in gClients:
      let tc = gClients[id]
      if tc.metainfo.info.infoHash == infoHash:
        return tc
  nil

proc collectInfoHashes(): seq[array[20, byte]] =
  ## Collect info hashes of all active clients. Event loop thread only.
  let ids = snapshotClientIds()
  var i = 0
  while i < ids.len:
    let id = ids[i]
    i += 1
    if id in gClients:
      let tc = gClients[id]
      if tc.state in {csDownloading, csSeeding}:
        result.add(tc.metainfo.info.infoHash)

proc sharedTcpAcceptLoop(): CpsVoidFuture {.cps.} =
  ## Single accept loop for the shared TCP listener. Dispatches incoming
  ## connections to the correct torrent client based on info hash.
  if gSharedListener == nil:
    return
  while true:
    let tcpStream: TcpStream = await gSharedListener.accept()
    let stream: AsyncStream = tcpStream.AsyncStream
    let remoteEp = tcpStream.peerEndpoint()
    let remoteIp = if remoteEp.ip.len > 0: remoteEp.ip else: "incoming"
    let remotePort = remoteEp.port

    # Peek at first byte to detect plain BT vs MSE handshake
    try:
      let firstByte: string = await readExactRaw(stream, 1)
      if firstByte[0].byte == 19:
        # Plain BT handshake: read remaining 47 bytes to get info hash (at offset 28)
        let restHeader: string = await readExactRaw(stream, 47)
        let headerData: string = firstByte & restHeader
        # Info hash is at bytes 28-48 of the 68-byte handshake
        var peerInfoHash: array[20, byte]
        copyMem(addr peerInfoHash[0], unsafeAddr headerData[28], 20)
        let targetClient: TorrentClient = findClientByInfoHash(peerInfoHash)
        if targetClient == nil:
          stream.close()
          continue
        # Wrap stream with prefix so runIncoming re-reads the handshake
        let prefixed: PrefixedStream = newPrefixedStream(stream, headerData)
        targetClient.handleIncomingPeer(prefixed.AsyncStream, remoteIp, remotePort, ptTcp)
      else:
        # MSE handshake: read full DH public key
        let restOfDh: string = await readExactRaw(stream, DhKeyLen - 1)
        let yaData: string = firstByte & restOfDh
        let hashes: seq[array[20, byte]] = collectInfoHashes()
        if hashes.len == 0:
          stream.close()
          continue
        let mseRes: MseResult = await withTimeout(
          mseRespondMulti(stream, hashes, yaData), 5000)
        let mseClient: TorrentClient = findClientByInfoHash(mseRes.matchedInfoHash)
        if mseClient == nil:
          mseRes.stream.close()
          continue
        # After MSE, the BT handshake comes through the (possibly encrypted) stream.
        # If there's an initial payload (IA), prepend it.
        if mseRes.initialPayload.len > 0:
          let mseStream: PrefixedStream = newPrefixedStream(
            mseRes.stream, mseRes.initialPayload)
          mseClient.handleIncomingPeer(mseStream.AsyncStream, remoteIp, remotePort, ptTcp)
        else:
          mseClient.handleIncomingPeer(mseRes.stream, remoteIp, remotePort, ptTcp)
    except CatchableError:
      stream.close()

proc sharedUtpAcceptLoop(): CpsVoidFuture {.cps.} =
  ## Single accept loop for the shared uTP manager. Dispatches incoming
  ## connections to the correct torrent client based on info hash.
  if gSharedUtpMgr == nil:
    return
  while true:
    let utpStream: UtpStream = await utpAccept(gSharedUtpMgr)
    let utpAsAsync: AsyncStream = utpStream.AsyncStream

    try:
      let utpFirstByte: string = await readExactRaw(utpAsAsync, 1)
      if utpFirstByte[0].byte == 19:
        # Plain BT handshake
        let utpRestHeader: string = await readExactRaw(utpAsAsync, 47)
        let utpHeaderData: string = utpFirstByte & utpRestHeader
        var utpInfoHash: array[20, byte]
        copyMem(addr utpInfoHash[0], unsafeAddr utpHeaderData[28], 20)
        let utpClient: TorrentClient = findClientByInfoHash(utpInfoHash)
        if utpClient == nil:
          utpAsAsync.close()
          continue
        let utpPrefixed: PrefixedStream = newPrefixedStream(utpAsAsync, utpHeaderData)
        utpClient.handleIncomingPeer(utpPrefixed.AsyncStream,
          utpStream.remoteIp, utpStream.remotePort.uint16, ptUtp)
      else:
        # MSE handshake over uTP: read full DH public key and route by matched
        # info hash.
        let utpRestDh: string = await readExactRaw(utpAsAsync, DhKeyLen - 1)
        let utpYaData: string = utpFirstByte & utpRestDh
        let hashes: seq[array[20, byte]] = collectInfoHashes()
        if hashes.len == 0:
          utpAsAsync.close()
          continue
        let mseRes: MseResult = await withTimeout(
          mseRespondMulti(utpAsAsync, hashes, utpYaData), 5000)
        let mseClient: TorrentClient = findClientByInfoHash(mseRes.matchedInfoHash)
        if mseClient == nil:
          mseRes.stream.close()
          continue
        if mseRes.initialPayload.len > 0:
          let mseStream: PrefixedStream = newPrefixedStream(
            mseRes.stream, mseRes.initialPayload)
          mseClient.handleIncomingPeer(mseStream.AsyncStream,
            utpStream.remoteIp, utpStream.remotePort.uint16, ptUtp)
        else:
          mseClient.handleIncomingPeer(mseRes.stream,
            utpStream.remoteIp, utpStream.remotePort.uint16, ptUtp)
    except CatchableError:
      utpAsAsync.close()

proc drainCommandNotifyPipe() =
  if gCmdPipeRead < 0:
    return
  var buf: array[64, byte]
  while true:
    let n = posix.read(gCmdPipeRead, addr buf[0], buf.len)
    if n > 0:
      continue
    if n < 0:
      let err = osLastError()
      if err.int == EINTR:
        continue
    break
  # Clear coalescing flag after any read attempt from the command wake pipe.
  gCmdNotifyPending.store(false, moRelease)

# ============================================================
# Event loop: command processor (CPS task, runs on event loop thread)
# ============================================================

proc logFlushLoop(): CpsVoidFuture {.cps.} =
  ## Periodically flush buffered log messages to disk.
  ## Runs as an independent CPS task for the lifetime of the event loop.
  while true:
    await cpsSleep(500)
    flushLogBuffer()

proc sessionSaveLoop(): CpsVoidFuture {.cps.} =
  ## Periodically drain pending session saves and write to disk.
  ## Multiple rapid saveSession() calls coalesce — only the latest is written.
  ## Disk I/O runs on the blocking pool via spawnBlocking.
  while true:
    await cpsSleep(1000)
    let pending = gPendingSessionSave.drainAll()
    if pending.len > 0:
      let jsonStr = pending[^1]
      await spawnBlocking(proc() {.gcsafe.} =
        writeSessionToDisk(jsonStr)
      )

proc recheckTask(torrentId: int, tc: TorrentClient): CpsVoidFuture {.cps.} =
  ## Recheck all pieces as an independent task so the command processor isn't blocked.
  await tc.recheckAllPieces()

proc setFilePriorityTask(fileIdx: int, priority: string,
                         tc: TorrentClient): CpsVoidFuture {.cps.} =
  ## Set file priority as an independent task so the command processor isn't blocked.
  await tc.setFilePriority(fileIdx, priority)

proc runEffect(kindOrd: int, payload: string) =
  ## Execute a shell-based side effect. Called from blocking pool thread.
  ## kindOrd: 0 = copy text to clipboard, 1 = open path in Finder.
  if kindOrd == 0:
    discard execShellCmd("printf %s " & quoteShell(payload) & " | pbcopy")
  elif kindOrd == 1:
    discard execShellCmd("open " & quoteShell(payload))

proc executeEffectTask(kindOrd: int, payload: string): CpsVoidFuture {.cps.} =
  ## Execute a shell-based side effect (copy to clipboard, open in Finder)
  ## on the blocking pool so the main thread isn't stalled by process fork+wait.
  await spawnBlocking(proc() =
    {.cast(gcsafe).}:
      runEffect(kindOrd, payload)
  )

proc resumeTorrentDelayed(torrentId: int, path: string): CpsVoidFuture {.cps.} =
  ## Resume a torrent after a delay for old client cleanup.
  ## Spawned as an independent task so the command processor isn't blocked.
  await cpsSleep(2000)
  try:
    await startClientFromFile(torrentId, path)
    logBridge "[RESUME] Resumed torrent id=" & $torrentId
  except CatchableError as e:
    logBridge "[RESUME] ERROR: " & e.msg
    pushEvent(UiEvent(kind: uiClientError, torrentId: torrentId,
                      text: e.msg))

proc commandProcessor(): CpsVoidFuture {.cps.} =
  ## Main command processor running on the event loop thread.
  ## Drains commands from the lock-free command queue and processes them.
  ## Uses gClients table (private to this thread) for client management.
  ## All state mutations flow back to the main thread via pushEvent.

  # Discover NAT gateway and forward ports (best-effort, non-blocking).
  # Done once at startup; shared across all torrent clients via ClientConfig.
  try:
    ensureSharedResources()
    gNatMgr = newNatManager()
    await discover(gNatMgr)
    if gNatMgr.protocol != npNone:
      let listenPort = if gSharedListener != nil: gSharedListener.localPort().uint16
                       else: (try: parseUInt(gListenPort).uint16 except: 6881'u16)
      # Forward TCP listen port
      try:
        discard await addMapping(gNatMgr, mpTcp, listenPort, listenPort, 7200)
      except CatchableError:
        discard
      # Forward uTP/UDP port
      if gSharedUtpMgr != nil:
        try:
          let utpPort: uint16 = gSharedUtpMgr.port.uint16
          discard await addMapping(gNatMgr, mpUdp, utpPort, utpPort, 7200)
        except CatchableError:
          discard
      # Start renewal loop
      let natRenewalFut = startRenewal(gNatMgr)
      let extIp = getExternalIp(gNatMgr)
      logBridge "[NAT] Discovered " & $gNatMgr.protocol &
        (if extIp.len > 0: ", external IP: " & extIp else: "")
      # Notify UI of NAT status
      var natEvt = UiEvent(kind: uiNatStatus,
                           boolParam: true)
      natEvt.text = (case gNatMgr.protocol
        of npNatPmp: "NAT-PMP"
        of npPcp: "PCP"
        of npUpnpIgd: "UPnP IGD"
        of npNone: "Not available")
      natEvt.text2 = extIp
      natEvt.text3 = gNatMgr.gatewayIp
      natEvt.downloadDir = gNatMgr.localIp  # reuse field for localIp
      natEvt.intParam = gNatMgr.mappings.len
      if gNatMgr.doubleNat:
        natEvt.intParam2 = 1  # doubleNat flag
        if gNatMgr.outerMgr != nil and gNatMgr.outerMgr.protocol != npNone:
          natEvt.pieceMapData = (case gNatMgr.outerMgr.protocol
            of npNatPmp: "NAT-PMP"
            of npPcp: "PCP"
            of npUpnpIgd: "UPnP IGD"
            of npNone: "Not available")
          natEvt.floatParam = 1.0  # outer forwarded marker
          if gNatMgr.outerMgr.gatewayIp.len > 0:
            # Encode outer gateway in peerSnapshot (reuse field)
            natEvt.peerSnapshot = @[PeerSnapshotEntry(address: gNatMgr.outerMgr.gatewayIp)]
      pushEvent(natEvt)
    else:
      logBridge "[NAT] No NAT gateway found"
      pushEvent(UiEvent(kind: uiNatStatus, text: "Not available"))
  except CatchableError as natErr:
    logBridge "[NAT] Discovery failed: " & natErr.msg
    pushEvent(UiEvent(kind: uiNatStatus, text: "Not available"))

  # Start shared accept loops to dispatch incoming connections by info hash.
  # These run for the lifetime of the event loop thread.
  discard spawn sharedTcpAcceptLoop()
  discard spawn sharedUtpAcceptLoop()

  # Start periodic log flusher (batches disk writes every 500ms)
  when enableBridgeLog:
    discard spawn logFlushLoop()

  # Start periodic session saver (drains mailbox every 1s, writes via spawnBlocking)
  discard spawn sessionSaveLoop()

  if gCmdPipeRead >= 0:
    # Keep the command notify pipe armed for the whole processor lifetime.
    # The callback runs on the reactor thread; gCommandWakePtr is an atomic
    # pointer — no lock needed. The worker's local var keeps the future alive.
    let loop = getEventLoop()
    loop.registerRead(gCmdPipeRead, proc() =
      drainCommandNotifyPipe()
      {.cast(gcsafe).}:
        let waiterPtr = gCommandWakePtr.load(moAcquire)
        if waiterPtr != nil:
          let waiter = cast[CpsVoidFuture](waiterPtr)
          if not waiter.finished:
            waiter.complete()
    )

  logBridge "[CMD] Command processor ready"
  while true:
    var commands = gCommandQueue.drainAll()
    if commands.len == 0:
      if gCmdPipeRead < 0:
        await cpsSleep(10)
        continue

      # Publish a waiter future before re-checking the queue so we can't miss
      # a pipe callback that races with the next command enqueue.
      # Lock-free: worker's local var keeps the future alive; reactor callback
      # reads the atomic pointer and calls complete() without any lock.
      let waitFut = newCpsVoidFuture()
      waitFut.pinFutureRuntime()
      gCommandWakePtr.store(cast[pointer](waitFut), moRelease)

      commands = gCommandQueue.drainAll()
      if commands.len == 0:
        await waitFut
        commands = gCommandQueue.drainAll()
        if commands.len == 0:
          gCommandWakePtr.store(nil, moRelease)
          continue

    gCommandWakePtr.store(nil, moRelease)
    if commands.len > 0:
      logBridge "[CMD] Processing " & $commands.len & " commands"

    for cmd in commands:
      case cmd.kind
      of cmdAddTorrentFile:
        try:
          logBridge "[EVENT LOOP] cmdAddTorrentFile path='" & cmd.text & "' id=" & $cmd.intParam
          await startClientFromFile(cmd.intParam, cmd.text)
          logBridge "[EVENT LOOP] TorrentClient started, draining events"
        except CatchableError as e:
          logBridge "[EVENT LOOP] ERROR adding torrent: " & e.msg
          pushEvent(UiEvent(kind: uiClientError, torrentId: cmd.intParam,
                            text: e.msg))

      of cmdAddTorrentMagnet:
        try:
          let parsed = parseMagnetLink(cmd.text)
          let config = buildConfig()
          let tc = newMagnetClient(parsed.infoHash, parsed.trackers,
                                   parsed.displayName, config, parsed.selectedFiles)

          let torrentId = cmd.intParam
          gClients[torrentId] = tc

          let name = if parsed.displayName.len > 0:
            parsed.displayName else: "Magnet: " & $parsed.infoHash[0..3]
          var hashHex = ""
          for b in parsed.infoHash: hashHex.add(b.toHex(2).toLowerAscii)

          # For magnet links, file info and announce URLs come later via metadata exchange.
          # Announce URLs from the magnet link are available now.
          var magnetAnnounce: seq[string]
          for tUrl in parsed.trackers:
            if tUrl notin magnetAnnounce:
              magnetAnnounce.add(tUrl)

          pushEvent(UiEvent(kind: uiClientReady, torrentId: torrentId,
                            text2: name,
                            text3: hashHex,
                            intParam2: parsed.trackers.len,
                            announceUrls: magnetAnnounce,
                            downloadDir: config.downloadDir))

          discard spawn tc.start()
          discard spawn drainClientEvents(torrentId, tc)

        except CatchableError as e:
          pushEvent(UiEvent(kind: uiClientError, torrentId: cmd.intParam,
                            text: e.msg))

      of cmdPauseTorrent:
        let tc = gClients.getOrDefault(cmd.intParam)
        if tc != nil:
          tc.stop()
          gClients.del(cmd.intParam)
        pushEvent(UiEvent(kind: uiTorrentPaused, torrentId: cmd.intParam))

      of cmdResumeTorrent:
        let torrentPath = cmd.text2
        let torrentId = cmd.intParam
        if torrentPath.len > 0:
          discard spawn resumeTorrentDelayed(torrentId, torrentPath)

      of cmdRemoveTorrent:
        let tc = gClients.getOrDefault(cmd.intParam)
        if tc != nil:
          tc.stop()
          gClients.del(cmd.intParam)
        pushEvent(UiEvent(kind: uiTorrentRemoved, torrentId: cmd.intParam,
                          boolParam: cmd.boolParam))

      of cmdSaveSettings:
        # Apply live protocol toggles/encryption to active clients.
        let ids = snapshotClientIds()
        var idi = 0
        while idi < ids.len:
          let clientId = ids[idi]
          inc idi
          if clientId in gClients:
            let tc = gClients[clientId]
            tc.config.enableDht = gDhtEnabled
            tc.config.enablePex = gPexEnabled
            tc.config.enableLsd = gLsdEnabled
            tc.config.enableUtp = gUtpEnabled
            tc.config.enableWebSeed = gWebSeedEnabled
            tc.config.enableTrackerScrape = gTrackerScrapeEnabled
            tc.config.enableHolepunch = gHolepunchEnabled
            tc.config.encryptionMode = parseEncryptionMode(gEncryptionMode)

      of cmdSetFilePriority:
        let tc = gClients.getOrDefault(cmd.intParam)
        if tc != nil:
          discard spawn setFilePriorityTask(cmd.intParam2, cmd.text, tc)

      of cmdRecheckTorrent:
        let tc = gClients.getOrDefault(cmd.intParam)
        if tc != nil and tc.pieceMgr != nil:
          discard spawn recheckTask(cmd.intParam, tc)
        pushEvent(UiEvent(kind: uiRechecking, torrentId: cmd.intParam))

      of cmdExecuteEffect:
        discard spawn executeEffectTask(cmd.intParam, cmd.text)

      of cmdShutdown:
        # Stop all clients and exit event loop
        let ids = snapshotClientIds()
        var idi = 0
        while idi < ids.len:
          let clientId = ids[idi]
          inc idi
          if clientId in gClients:
            let c = gClients[clientId]
            c.stop()
        gClients.clear()
        # Shut down shared NAT manager (deletes port mappings)
        if gNatMgr != nil:
          try:
            await shutdown(gNatMgr)
          except CatchableError:
            discard
          gNatMgr = nil
        return

# ============================================================
# Process UI events from the event loop thread (runs on main thread)
# ============================================================

proc processUiEvents(): bool =
  ## Drain event queue and update main-thread state.
  ## Returns true if any state changes occurred.
  ## Lock-free — uses atomic-exchange batch drain + atomic dirty flag.
  var handledAny = false
  var eventDirtyMask = 0'u32
  var drainRounds = 0
  while drainRounds < 3:
    drainRounds += 1
    var events = gEventQueue.drainAll()
    let wasDirty = gDirty.exchange(false, moAcquireRelease)
    if events.len == 0 and not wasDirty:
      break

    # Coalesce progress events: when multiple uiProgress events exist for
    # the same torrent, only process the last one.  Earlier snapshots are
    # stale and processing them is wasted work that blocks the main thread.
    var lastProgressIdx: Table[int, int]  # torrentId -> last index in events
    for i in 0 ..< events.len:
      if events[i].kind == uiProgress:
        lastProgressIdx[events[i].torrentId] = i

    handledAny = true
    for i in 0 ..< events.len:
      if events[i].kind == uiProgress and i != lastProgressIdx.getOrDefault(events[i].torrentId, i):
        continue  # Skip superseded progress event
      let evt = addr events[i]
      let dirtyForEvent = case evt.kind
        of uiClientReady: dmTorrents or dmFiles or dmTrackers or dmSelection
        of uiClientError, uiTorrentPaused, uiRechecking,
           uiTorrentStarted, uiPieceVerified, uiCompleted,
           uiError, uiInfo, uiStopped: dmTorrents or dmStatus
        of uiTrackerResponse: dmTorrents or dmTrackers or dmStatus
        of uiProgress: dmTorrents or dmPeers or dmPieceMap or dmStatus
        of uiPeerConnected, uiPeerDisconnected: dmTorrents or dmPeers or dmStatus
        of uiTorrentRemoved: dmTorrents or dmFiles or dmPeers or dmTrackers or dmPieceMap or
          dmSelection or dmStatus
        of uiNatStatus: dmNat
      case evt.kind

      # --- Lock-free mutation events (state changes from event loop) ---
      of uiClientReady:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          gTorrents[idx].name = evt.text2
          gTorrents[idx].infoHash = evt.text3
          gTorrents[idx].totalSize = evt.floatParam
          gTorrents[idx].pieceCount = evt.intParam
          gTorrents[idx].status = tsDownloading
          gTorrents[idx].trackerCount = evt.intParam2
          gTorrents[idx].fileInfo = evt.fileInfo
          gTorrents[idx].filePriorities.setLen(evt.fileInfo.len)
          for i in 0 ..< gTorrents[idx].filePriorities.len:
            if gTorrents[idx].filePriorities[i].len == 0:
              gTorrents[idx].filePriorities[i] = "normal"
          gTorrents[idx].announceUrls = evt.announceUrls
          gTorrents[idx].downloadDir = evt.downloadDir
          gTorrents[idx].clientActive = true

      of uiClientError:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          gTorrents[idx].status = tsError
          gTorrents[idx].errorText = evt.text

      of uiTorrentPaused:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          gTorrents[idx].status = tsPaused
          gTorrents[idx].paused = true
          gTorrents[idx].clientActive = false

      of uiTorrentRemoved:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          gTorrents.delete(idx)
          gPeerSnapshots.del(evt.torrentId)
          # Clean up per-peer rate tracking tables for this torrent
          let prefix = $evt.torrentId & ":"
          var staleKeys: seq[string]
          for key in gPeerSmoothedRates.keys:
            if key.startsWith(prefix): staleKeys.add(key)
          for key in staleKeys:
            gPeerSmoothedRates.del(key)
            gPeerPrevBytes.del(key)
          gTorrentPrevBytes.del(evt.torrentId)
          gTorrentSmoothedRates.del(evt.torrentId)
          gLastPeerPollTimes.del(evt.torrentId)
          if gSelectedTorrentId == evt.torrentId:
            gSelectedTorrentId = -1

      of uiRechecking:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          gTorrents[idx].status = tsChecking

      of uiNatStatus:
        gNatProtocol = evt.text
        gNatExternalIp = evt.text2
        gNatGatewayIp = evt.text3
        gNatLocalIp = evt.downloadDir  # reused field
        gNatPortsForwarded = evt.boolParam
        gNatActiveMappings = evt.intParam
        gNatDoubleNat = evt.intParam2 == 1
        if gNatDoubleNat:
          gNatOuterProtocol = evt.pieceMapData
          if evt.peerSnapshot.len > 0:
            gNatOuterGatewayIp = evt.peerSnapshot[0].address
          else:
            gNatOuterGatewayIp = ""
        else:
          gNatOuterProtocol = ""
          gNatOuterGatewayIp = ""

      # --- Standard torrent client events ---
      of uiTorrentStarted:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          # Don't override "seeding" — client may start in seeding mode (100% complete)
          if gTorrents[idx].status != tsSeeding:
            gTorrents[idx].status = tsDownloading

      of uiPieceVerified:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          inc gTorrents[idx].verifiedPieces
          if gTorrents[idx].pieceCount > 0:
            gTorrents[idx].progress = min(1.0,
              gTorrents[idx].verifiedPieces.float / gTorrents[idx].pieceCount.float)

      of uiProgress:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          # Use progressLoop's pre-computed EMA-smoothed rates directly.
          # These are based on PieceManager.downloaded/uploaded (monotonic
          # counters), so they're immune to peer churn causing sum drops.
          gTorrents[idx].downloadRate = evt.floatParam
          gTorrents[idx].uploadRate = evt.floatParam2
          gTorrents[idx].peerCount = evt.intParam2
          gTorrents[idx].downloaded = evt.floatParam3
          gTorrents[idx].uploaded = evt.floatParam4
          gTorrents[idx].verifiedPieces = evt.intParam3
          gTorrents[idx].progress = evt.floatParam5
          gTorrents[idx].dhtNodeCount = (try: parseInt(evt.text) except: 0)

          # Update pieceCount / totalSize / name from metadata (magnet link support).
          # These fields are 0/"Loading metadata..." until BEP 9 metadata exchange completes.
          let newPieceCount = (try: parseInt(evt.text3) except: 0)
          if newPieceCount > 0 and gTorrents[idx].pieceCount == 0:
            gTorrents[idx].pieceCount = newPieceCount
            logBridge "[PROGRESS] Metadata arrived for torrent " & $evt.torrentId &
              ": pieceCount=" & $newPieceCount & " totalSize=" & $evt.floatParam6
          if newPieceCount > 0:
            gTorrents[idx].pieceCount = newPieceCount
          if evt.floatParam6 > 0 and gTorrents[idx].totalSize == 0:
            gTorrents[idx].totalSize = evt.floatParam6
          if evt.text2.len > 0 and evt.text2 != "unknown" and
             (gTorrents[idx].name == "Loading metadata..." or
              gTorrents[idx].name.startsWith("Magnet:")):
            gTorrents[idx].name = evt.text2

          # Detect seeding: progress == 1.0 means all pieces verified
          if evt.floatParam5 >= 1.0 and gTorrents[idx].status == tsDownloading:
            gTorrents[idx].status = tsSeeding
            gTorrents[idx].eta = ""
            if gTorrents[idx].completedDate.len == 0:
              gTorrents[idx].completedDate = formatTimestamp(epochTime())

          # Update ETA
          if gTorrents[idx].status != tsSeeding:
            let remaining = gTorrents[idx].totalSize - gTorrents[idx].downloaded
            gTorrents[idx].eta = formatEta(remaining, gTorrents[idx].downloadRate)
          # Update ratio
          if gTorrents[idx].downloaded > 0:
            gTorrents[idx].ratio = gTorrents[idx].uploaded / gTorrents[idx].downloaded
          # Store peer snapshot and piece map (race-free: built on event loop thread)
          gPeerSnapshots[evt.torrentId] = move evt.peerSnapshot
          if evt.pieceMapData.len > 0:
            gTorrents[idx].pieceMapData = evt.pieceMapData
          # Update file info when metadata arrives (magnet links) — mark dirty only on change
          if evt.fileInfo.len > 0 and gTorrents[idx].fileInfo.len == 0:
            gTorrents[idx].fileInfo = evt.fileInfo
            eventDirtyMask = eventDirtyMask or dmFiles
          if evt.filePriorities.len > 0:
            gTorrents[idx].filePriorities = evt.filePriorities
            eventDirtyMask = eventDirtyMask or dmFiles
          if evt.trackerSnapshot.len > 0:
            if evt.trackerSnapshot.len != gTorrents[idx].trackerStates.len:
              eventDirtyMask = eventDirtyMask or dmTrackers
            else:
              var trackerChanged = false
              var ti = 0
              while ti < evt.trackerSnapshot.len:
                if evt.trackerSnapshot[ti].status != gTorrents[idx].trackerStates[ti].status or
                   evt.trackerSnapshot[ti].seeders != gTorrents[idx].trackerStates[ti].seeders or
                   evt.trackerSnapshot[ti].leechers != gTorrents[idx].trackerStates[ti].leechers or
                   evt.trackerSnapshot[ti].errorText != gTorrents[idx].trackerStates[ti].errorText:
                  trackerChanged = true
                  break
                ti += 1
              if trackerChanged:
                eventDirtyMask = eventDirtyMask or dmTrackers
            gTorrents[idx].trackerStates = evt.trackerSnapshot

          gTorrents[idx].protocolPrivate = evt.protocolPrivate
          gTorrents[idx].protocolDhtEnabled = evt.protocolDhtEnabled
          gTorrents[idx].protocolPexEnabled = evt.protocolPexEnabled
          gTorrents[idx].protocolLsdEnabled = evt.protocolLsdEnabled
          gTorrents[idx].protocolUtpEnabled = evt.protocolUtpEnabled
          gTorrents[idx].protocolWebSeedEnabled = evt.protocolWebSeedEnabled
          gTorrents[idx].protocolScrapeEnabled = evt.protocolScrapeEnabled
          gTorrents[idx].protocolHolepunchEnabled = evt.protocolHolepunchEnabled
          gTorrents[idx].protocolEncryptionMode = evt.protocolEncryptionMode
          gTorrents[idx].protocolUtpPeers = evt.protocolUtpPeers
          gTorrents[idx].protocolTcpPeers = evt.protocolTcpPeers
          gTorrents[idx].protocolLsdAnnounces = evt.protocolLsdAnnounces
          gTorrents[idx].protocolLsdPeers = evt.protocolLsdPeers
          gTorrents[idx].protocolLsdLastError = evt.protocolLsdLastError
          gTorrents[idx].protocolWebSeedBytes = evt.protocolWebSeedBytes.float
          gTorrents[idx].protocolWebSeedFailures = evt.protocolWebSeedFailures
          gTorrents[idx].protocolWebSeedActiveUrl = evt.protocolWebSeedActiveUrl
          gTorrents[idx].protocolHolepunchAttempts = evt.protocolHolepunchAttempts
          gTorrents[idx].protocolHolepunchSuccesses = evt.protocolHolepunchSuccesses
          gTorrents[idx].protocolHolepunchLastError = evt.protocolHolepunchLastError

      of uiPeerConnected:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          inc gTorrents[idx].peerCount

      of uiPeerDisconnected:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0 and gTorrents[idx].peerCount > 0:
          dec gTorrents[idx].peerCount

      of uiCompleted:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          gTorrents[idx].status = tsSeeding
          gTorrents[idx].progress = 1.0
          gTorrents[idx].completedDate = formatTimestamp(epochTime())
          gTorrents[idx].eta = ""

      of uiError:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          gTorrents[idx].errorText = evt.text

      of uiInfo:
        gStatusText = evt.text

      of uiStopped:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          if not gTorrents[idx].paused:
            gTorrents[idx].status = tsError

      of uiTrackerResponse:
        let idx = findTorrentIdx(evt.torrentId)
        if idx >= 0:
          gTorrents[idx].trackerSeeders = evt.intParam
          gTorrents[idx].trackerLeechers = evt.intParam2
          gTorrents[idx].seedCount = evt.intParam
          gTorrents[idx].hasTrackerResponse = true
      eventDirtyMask = eventDirtyMask or dirtyForEvent

  result = handledAny
  if eventDirtyMask != 0'u32:
    markDirty(eventDirtyMask)

  # Update global status bar
  gStatusDownRate = 0.0
  gStatusUpRate = 0.0
  gStatusDhtNodes = 0
  for ts in gTorrents:
    gStatusDownRate += ts.downloadRate
    gStatusUpRate += ts.uploadRate
    gStatusDhtNodes += ts.dhtNodeCount

# ============================================================
# Alloc / Free / Blob helpers
# ============================================================

proc bridgeAlloc(size: csize_t): pointer {.cdecl.} =
  if size <= 0: return nil
  allocShared(size)

proc bridgeFree(p: pointer) {.cdecl.} =
  if p != nil: deallocShared(p)

proc writeBlob(value: openArray[byte]): GUIBridgeBuffer =
  if value.len == 0:
    return GUIBridgeBuffer(data: nil, len: 0)
  let mem = cast[ptr uint8](bridgeAlloc(value.len.csize_t))
  if mem == nil:
    return GUIBridgeBuffer(data: nil, len: 0)
  copyMem(mem, unsafeAddr value[0], value.len)
  GUIBridgeBuffer(data: mem, len: value.len.uint32)

proc writeBlob(text: string): GUIBridgeBuffer =
  ## String overload — copies directly into shared memory, avoiding an
  ## intermediate seq[byte] allocation.
  if text.len == 0:
    return GUIBridgeBuffer(data: nil, len: 0)
  let mem = cast[ptr uint8](bridgeAlloc(text.len.csize_t))
  if mem == nil:
    return GUIBridgeBuffer(data: nil, len: 0)
  copyMem(mem, unsafeAddr text[0], text.len)
  GUIBridgeBuffer(data: mem, len: text.len.uint32)

proc copyBlob(value: GUIBridgeBuffer): seq[byte] =
  if value.data == nil or value.len == 0'u32:
    return @[]
  result = newSeq[byte](value.len.int)
  copyMem(addr result[0], value.data, value.len.int)

proc freeBlob(value: var GUIBridgeBuffer) =
  if value.data != nil:
    bridgeFree(value.data)
    value.data = nil
    value.len = 0'u32

type BridgeDispatchTestResult* = object
  status*: int32
  statePatch*: seq[byte]
  effects*: seq[byte]
  emittedActions*: seq[byte]
  diagnostics*: string

proc dispatch*(runtime: var BridgeRuntime, payload: ptr uint8, payloadLen: uint32,
               outp: ptr GUIBridgeDispatchOutput): int32

proc newTestRuntime*(): BridgeRuntime =
  result = default(BridgeRuntime)
  initRuntimeDefaults(result)

proc bridgeDispatch(payload: ptr uint8, payloadLen: uint32,
                    outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.}

proc dispatchTest*(runtime: var BridgeRuntime,
                   payload: openArray[byte]): BridgeDispatchTestResult =
  ## Test helper: dispatch a raw payload and return copied output blobs.
  var outBuf = GUIBridgeDispatchOutput(
    statePatch: GUIBridgeBuffer(data: nil, len: 0),
    effects: GUIBridgeBuffer(data: nil, len: 0),
    emittedActions: GUIBridgeBuffer(data: nil, len: 0),
    diagnostics: GUIBridgeBuffer(data: nil, len: 0)
  )
  let payloadPtr =
    if payload.len == 0: nil
    else: cast[ptr uint8](unsafeAddr payload[0])
  result.status = dispatch(runtime, payloadPtr, payload.len.uint32, addr outBuf)
  result.statePatch = copyBlob(outBuf.statePatch)
  result.effects = copyBlob(outBuf.effects)
  result.emittedActions = copyBlob(outBuf.emittedActions)
  let diagBytes = copyBlob(outBuf.diagnostics)
  if diagBytes.len > 0:
    result.diagnostics = newString(diagBytes.len)
    copyMem(addr result.diagnostics[0], unsafeAddr diagBytes[0], diagBytes.len)
  else:
    result.diagnostics = ""
  freeBlob(outBuf.statePatch)
  freeBlob(outBuf.effects)
  freeBlob(outBuf.emittedActions)
  freeBlob(outBuf.diagnostics)

proc bridgeDispatchForTest*(payload: openArray[byte]): BridgeDispatchTestResult =
  ## Backward-compatible helper for existing tests.
  result = dispatchTest(gRuntime, payload)

proc injectEvent*(runtime: var BridgeRuntime, evt: sink UiEvent): bool =
  ## Test hook: inject an event into the runtime queue.
  discard addr runtime
  if not gEventQueue.send(cloneUiEventIsolated(evt)):
    return false
  gDirty.store(true, moRelease)
  true

proc bridgeResetForTest*() =
  ## Resets main-thread bridge state. Intended for unit tests that do not
  ## start the event loop thread.
  gTorrents = @[]
  gSelectedTorrentId = -1
  gNextTorrentId = 0
  gDetailTab = 0
  gFiles = @[]
  gPeers = @[]
  gTrackers = @[]
  gPieceMapData = ""
  gPeerSnapshots.clear()
  gPeerSmoothedRates.clear()
  gPeerPrevBytes.clear()
  gLastPeerPollTimes.clear()
  gTorrentPrevBytes.clear()
  gTorrentSmoothedRates.clear()

  gShowAddTorrent = false
  gAddMagnetLink = ""
  gAddTorrentPath = ""
  gShowSettings = false
  gDownloadDir = "~/Downloads"
  gListenPort = "6881"
  gMaxDownloadRate = "0"
  gMaxUploadRate = "0"
  gMaxPeers = "50"
  gDhtEnabled = true
  gPexEnabled = true
  gLsdEnabled = true
  gUtpEnabled = true
  gWebSeedEnabled = true
  gTrackerScrapeEnabled = true
  gHolepunchEnabled = true
  gEncryptionMode = "prefer_encrypted"
  gActionPriority = "normal"

  gStatusDownRate = 0.0
  gStatusUpRate = 0.0
  gStatusDhtNodes = 0
  gStatusText = ""
  gPollActive = false
  gSessionLoaded = false

  gNatProtocol = "Discovering..."
  gNatExternalIp = ""
  gNatGatewayIp = ""
  gNatLocalIp = ""
  gNatDoubleNat = false
  gNatOuterProtocol = ""
  gNatOuterGatewayIp = ""
  gNatPortsForwarded = false
  gNatActiveMappings = 0

  gShowRemoveConfirm = false
  gRemoveDeleteFiles = false
  gActionTorrentId = -1

  gDirty.store(false, moRelaxed)
  gDirtyMask = dmAll
  gNotifyPending.store(false, moRelaxed)
  gDroppedEventCount.store(0'u64, moRelaxed)
  gDroppedCommandCount.store(0'u64, moRelaxed)

# ============================================================
# Payload decoding
# ============================================================

proc decodeLeU32(data: ptr UncheckedArray[uint8], offset: int): uint32 =
  uint32(data[offset]) or
  (uint32(data[offset + 1]) shl 8) or
  (uint32(data[offset + 2]) shl 16) or
  (uint32(data[offset + 3]) shl 24)

proc decodeLeU16(data: ptr UncheckedArray[uint8], offset: int): uint16 =
  uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)

proc decodeActionTag(payload: ptr uint8, payloadLen: uint32): uint32 =
  if payload == nil or payloadLen < 4:
    return high(uint32)
  decodeLeU32(cast[ptr UncheckedArray[uint8]](payload), 0)

type
  RequestField = object
    fieldId: uint16
    valueType: uint8
    payload: seq[byte]

  PatchField = object
    fieldId: uint16
    valueType: uint8
    payload: seq[byte]

proc appendLeU16(dst: var seq[byte], value: uint16) {.inline.} =
  dst.add byte(value and 0xFF'u16)
  dst.add byte((value shr 8) and 0xFF'u16)

proc appendLeU32(dst: var seq[byte], value: uint32) {.inline.} =
  dst.add byte(value and 0xFF'u32)
  dst.add byte((value shr 8) and 0xFF'u32)
  dst.add byte((value shr 16) and 0xFF'u32)
  dst.add byte((value shr 24) and 0xFF'u32)

proc bytesFromString(value: string): seq[byte] =
  if value.len == 0:
    return @[]
  result = newSeq[byte](value.len)
  copyMem(addr result[0], unsafeAddr value[0], value.len)

proc encodeInt64Bytes(value: int64): seq[byte] =
  let bits = cast[uint64](value)
  result = newSeq[byte](8)
  for i in 0 ..< 8:
    result[i] = byte((bits shr (8 * i)) and 0xFF'u64)

proc encodeDoubleBytes(value: float): seq[byte] =
  let bits = cast[uint64](value)
  result = newSeq[byte](8)
  for i in 0 ..< 8:
    result[i] = byte((bits shr (8 * i)) and 0xFF'u64)

proc decodeInt64Bytes(payload: openArray[byte], default: int64 = 0'i64): int64 =
  if payload.len < 8:
    return default
  var bits: uint64 = 0
  for i in 0 ..< 8:
    bits = bits or (uint64(payload[i]) shl (8 * i))
  cast[int64](bits)

proc decodeDoubleBytes(payload: openArray[byte], default: float = 0.0): float =
  if payload.len < 8:
    return default
  var bits: uint64 = 0
  for i in 0 ..< 8:
    bits = bits or (uint64(payload[i]) shl (8 * i))
  cast[float](bits)

proc decodeStringBytes(payload: openArray[byte]): string =
  if payload.len == 0:
    return ""
  result = newString(payload.len)
  copyMem(addr result[0], unsafeAddr payload[0], payload.len)

proc decodeRequestFields(payload: ptr uint8, payloadLen: uint32): seq[RequestField] =
  if payload == nil or payloadLen < 8:
    return @[]
  let arr = cast[ptr UncheckedArray[uint8]](payload)
  let fieldCount = decodeLeU16(arr, 4).int
  var offset = 8
  for _ in 0 ..< fieldCount:
    if offset + 7 >= payloadLen.int:
      break
    let fieldId = decodeLeU16(arr, offset)
    let valueType = arr[offset + 2]
    let valueLen = decodeLeU32(arr, offset + 4).int
    offset += 8
    if valueLen < 0 or offset + valueLen > payloadLen.int:
      break
    var payloadBytes: seq[byte]
    if valueLen > 0:
      payloadBytes = newSeq[byte](valueLen)
      copyMem(addr payloadBytes[0], addr arr[offset], valueLen)
    result.add(RequestField(fieldId: fieldId, valueType: valueType, payload: payloadBytes))
    offset += valueLen

type DecodedRequest = object
  actionTag: uint32
  malformed: bool

proc decodeRequestEnvelope(payload: ptr uint8, payloadLen: uint32): DecodedRequest =
  result.actionTag = decodeActionTag(payload, payloadLen)
  if payload == nil or payloadLen < 8:
    result.malformed = payload != nil or payloadLen != 0
    return
  let arr = cast[ptr UncheckedArray[uint8]](payload)
  let fieldCount = decodeLeU16(arr, 4).int
  var offset = 8
  var consumed = 0
  while consumed < fieldCount:
    if offset + 7 >= payloadLen.int:
      result.malformed = true
      return
    let valueLen = decodeLeU32(arr, offset + 4).int
    offset += 8
    if valueLen < 0 or offset + valueLen > payloadLen.int:
      result.malformed = true
      return
    offset += valueLen
    inc consumed
  if offset != payloadLen.int:
    # Treat trailing bytes as malformed to keep deterministic frame handling.
    result.malformed = true

proc syncFromRequestFields(payload: ptr uint8, payloadLen: uint32) =
  let fields = decodeRequestFields(payload, payloadLen)
  for field in fields:
    case field.fieldId
    of fldAddMagnetLink:
      if field.valueType == bridgeTypeString:
        gAddMagnetLink = decodeStringBytes(field.payload)
    of fldAddTorrentPath:
      if field.valueType == bridgeTypeString:
        gAddTorrentPath = decodeStringBytes(field.payload)
    of fldDownloadDir:
      if field.valueType == bridgeTypeString:
        gDownloadDir = decodeStringBytes(field.payload)
    of fldListenPort:
      if field.valueType == bridgeTypeString:
        gListenPort = decodeStringBytes(field.payload)
    of fldMaxDownloadRate:
      if field.valueType == bridgeTypeString:
        gMaxDownloadRate = decodeStringBytes(field.payload)
    of fldMaxUploadRate:
      if field.valueType == bridgeTypeString:
        gMaxUploadRate = decodeStringBytes(field.payload)
    of fldMaxPeers:
      if field.valueType == bridgeTypeString:
        gMaxPeers = decodeStringBytes(field.payload)
    of fldDhtEnabled:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        gDhtEnabled = field.payload[0] != 0
    of fldPexEnabled:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        gPexEnabled = field.payload[0] != 0
    of fldLsdEnabled:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        gLsdEnabled = field.payload[0] != 0
    of fldUtpEnabled:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        gUtpEnabled = field.payload[0] != 0
    of fldWebSeedEnabled:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        gWebSeedEnabled = field.payload[0] != 0
    of fldTrackerScrapeEnabled:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        gTrackerScrapeEnabled = field.payload[0] != 0
    of fldHolepunchEnabled:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        gHolepunchEnabled = field.payload[0] != 0
    of fldEncryptionMode:
      if field.valueType == bridgeTypeString:
        gEncryptionMode = decodeStringBytes(field.payload)
    of fldActionPriority:
      if field.valueType == bridgeTypeString:
        gActionPriority = decodeStringBytes(field.payload)
    of fldRemoveDeleteFiles:
      if field.valueType == bridgeTypeBool and field.payload.len > 0:
        gRemoveDeleteFiles = field.payload[0] != 0
    of fldActionTorrentId:
      if field.valueType == bridgeTypeInt64:
        gActionTorrentId = decodeInt64Bytes(field.payload, gActionTorrentId.int64).int
    of fldSelectedTorrentId:
      if field.valueType == bridgeTypeInt64:
        gSelectedTorrentId = decodeInt64Bytes(field.payload, gSelectedTorrentId.int64).int
    of fldDetailTab:
      if field.valueType == bridgeTypeInt64:
        gDetailTab = decodeInt64Bytes(field.payload, gDetailTab.int64).int
    else:
      discard

# ============================================================
# Build patch
# ============================================================

proc addPatchField(fields: var seq[PatchField], fieldId: uint16, valueType: uint8,
                   payload: seq[byte]) =
  if fieldId == 0'u16:
    return
  fields.add PatchField(fieldId: fieldId, valueType: valueType, payload: payload)

proc addPatchBoolField(fields: var seq[PatchField], fieldId: uint16, value: bool) =
  addPatchField(fields, fieldId, bridgeTypeBool, @[if value: 1'u8 else: 0'u8])

proc addPatchIntField(fields: var seq[PatchField], fieldId: uint16, value: int) =
  addPatchField(fields, fieldId, bridgeTypeInt64, encodeInt64Bytes(value.int64))

proc addPatchFloatField(fields: var seq[PatchField], fieldId: uint16, value: float) =
  addPatchField(fields, fieldId, bridgeTypeDouble, encodeDoubleBytes(value))

proc addPatchStringField(fields: var seq[PatchField], fieldId: uint16, value: string) =
  addPatchField(fields, fieldId, bridgeTypeString, bytesFromString(value))

# ============================================================
# Streaming JSON writer — builds JSON strings directly without
# intermediate JsonNode allocations. Eliminates ~1200 heap allocs
# per poll cycle compared to newJObject/newJArray/% approach.
# ============================================================

type
  JsonWriter = object
    buf: string
    needsComma: bool  # track whether next value needs a leading comma

proc initJsonWriter(capacity: int = 4096): JsonWriter =
  result.buf = newStringOfCap(capacity)
  result.needsComma = false

proc sep(w: var JsonWriter) {.inline.} =
  if w.needsComma: w.buf.add ','
  w.needsComma = true

proc beginArray(w: var JsonWriter) {.inline.} =
  w.sep()
  w.buf.add '['
  w.needsComma = false

proc endArray(w: var JsonWriter) {.inline.} =
  w.buf.add ']'
  w.needsComma = true

proc beginObject(w: var JsonWriter) {.inline.} =
  w.sep()
  w.buf.add '{'
  w.needsComma = false

proc endObject(w: var JsonWriter) {.inline.} =
  w.buf.add '}'
  w.needsComma = true

proc key(w: var JsonWriter, k: string) {.inline.} =
  w.sep()
  w.buf.add '"'
  w.buf.add k  # keys are all ASCII literals — no escaping needed
  w.buf.add '"'
  w.buf.add ':'
  w.needsComma = false

proc writeString(w: var JsonWriter, v: string) {.inline.} =
  w.sep()
  w.buf.add '"'
  for c in v:
    case c
    of '"': w.buf.add "\\\""
    of '\\': w.buf.add "\\\\"
    of '\n': w.buf.add "\\n"
    of '\r': w.buf.add "\\r"
    of '\t': w.buf.add "\\t"
    of '\0'..'\x08', '\x0b', '\x0c', '\x0e'..'\x1f':
      w.buf.add "\\u00"
      const hexChars = "0123456789abcdef"
      w.buf.add hexChars[c.ord shr 4]
      w.buf.add hexChars[c.ord and 0xf]
    else:
      w.buf.add c
  w.buf.add '"'

proc writeInt(w: var JsonWriter, v: int) {.inline.} =
  w.sep()
  w.buf.addInt v

proc writeFloat(w: var JsonWriter, v: float) {.inline.} =
  w.sep()
  w.buf.addFloat v

proc writeBool(w: var JsonWriter, v: bool) {.inline.} =
  w.sep()
  w.buf.add(if v: "true" else: "false")

proc finish(w: var JsonWriter): string {.inline.} =
  move w.buf

proc addPatchJsonStringField(fields: var seq[PatchField], fieldId: uint16, value: string) =
  addPatchField(fields, fieldId, bridgeTypeJson, bytesFromString(value))

proc buildPatchBinary(includeEditableFields: bool, dirtyMask: uint32): seq[byte] =
  var fields: seq[PatchField] = @[]

  if (dirtyMask and dmTorrents) != 0:
    var w = initJsonWriter(gTorrents.len * 512)
    w.beginArray()
    for ts in gTorrents:
      w.beginObject()
      w.key("id"); w.writeInt(ts.id)
      w.key("name"); w.writeString(ts.name)
      w.key("infoHash"); w.writeString(ts.infoHash)
      w.key("state"); w.writeString($ts.status)
      w.key("progress"); w.writeFloat(ts.progress)
      w.key("downloadRate"); w.writeFloat(ts.downloadRate)
      w.key("uploadRate"); w.writeFloat(ts.uploadRate)
      w.key("downloaded"); w.writeFloat(ts.downloaded)
      w.key("uploaded"); w.writeFloat(ts.uploaded)
      w.key("totalSize"); w.writeFloat(ts.totalSize)
      w.key("peerCount"); w.writeInt(ts.peerCount)
      w.key("seedCount"); w.writeInt(ts.seedCount)
      w.key("eta"); w.writeString(ts.eta)
      w.key("addedDate"); w.writeString(ts.addedDate)
      w.key("completedDate"); w.writeString(ts.completedDate)
      w.key("errorText"); w.writeString(ts.errorText)
      w.key("ratio"); w.writeFloat(ts.ratio)
      w.key("pieceCount"); w.writeInt(ts.pieceCount)
      w.key("verifiedPieces"); w.writeInt(ts.verifiedPieces)
      w.key("trackerCount"); w.writeInt(ts.trackerCount)
      w.key("protocolPrivate"); w.writeBool(ts.protocolPrivate)
      w.key("protocolDhtEnabled"); w.writeBool(ts.protocolDhtEnabled)
      w.key("protocolPexEnabled"); w.writeBool(ts.protocolPexEnabled)
      w.key("protocolLsdEnabled"); w.writeBool(ts.protocolLsdEnabled)
      w.key("protocolUtpEnabled"); w.writeBool(ts.protocolUtpEnabled)
      w.key("protocolWebSeedEnabled"); w.writeBool(ts.protocolWebSeedEnabled)
      w.key("protocolScrapeEnabled"); w.writeBool(ts.protocolScrapeEnabled)
      w.key("protocolHolepunchEnabled"); w.writeBool(ts.protocolHolepunchEnabled)
      w.key("protocolEncryptionMode"); w.writeString(ts.protocolEncryptionMode)
      w.key("protocolUtpPeers"); w.writeInt(ts.protocolUtpPeers)
      w.key("protocolTcpPeers"); w.writeInt(ts.protocolTcpPeers)
      w.key("protocolLsdAnnounces"); w.writeInt(ts.protocolLsdAnnounces)
      w.key("protocolLsdPeers"); w.writeInt(ts.protocolLsdPeers)
      w.key("protocolLsdLastError"); w.writeString(ts.protocolLsdLastError)
      w.key("protocolWebSeedBytes"); w.writeFloat(ts.protocolWebSeedBytes)
      w.key("protocolWebSeedFailures"); w.writeInt(ts.protocolWebSeedFailures)
      w.key("protocolWebSeedActiveUrl"); w.writeString(ts.protocolWebSeedActiveUrl)
      w.key("protocolHolepunchAttempts"); w.writeInt(ts.protocolHolepunchAttempts)
      w.key("protocolHolepunchSuccesses"); w.writeInt(ts.protocolHolepunchSuccesses)
      w.key("protocolHolepunchLastError"); w.writeString(ts.protocolHolepunchLastError)
      w.endObject()
    w.endArray()
    addPatchJsonStringField(fields, fldTorrents, w.finish())

  if (dirtyMask and dmFiles) != 0:
    var w = initJsonWriter(gFiles.len * 128)
    w.beginArray()
    for f in gFiles:
      w.beginObject()
      w.key("index"); w.writeInt(f.index)
      w.key("path"); w.writeString(f.path)
      w.key("size"); w.writeFloat(f.size)
      w.key("progress"); w.writeFloat(f.progress)
      w.key("priority"); w.writeString(f.priority)
      w.endObject()
    w.endArray()
    addPatchJsonStringField(fields, fldFiles, w.finish())

  if (dirtyMask and dmPeers) != 0:
    var w = initJsonWriter(gPeers.len * 192)
    w.beginArray()
    for p in gPeers:
      w.beginObject()
      w.key("address"); w.writeString(p.address)
      w.key("client"); w.writeString(p.client)
      w.key("downloadRate"); w.writeFloat(p.downloadRate)
      w.key("uploadRate"); w.writeFloat(p.uploadRate)
      w.key("progress"); w.writeFloat(p.progress)
      w.key("flags"); w.writeString(p.flags)
      w.key("flagsTooltip"); w.writeString(p.flagsTooltip)
      w.key("source"); w.writeString(p.source)
      w.key("transport"); w.writeString(p.transport)
      w.endObject()
    w.endArray()
    addPatchJsonStringField(fields, fldPeers, w.finish())

  if (dirtyMask and dmTrackers) != 0:
    var w = initJsonWriter(gTrackers.len * 256)
    w.beginArray()
    for t in gTrackers:
      w.beginObject()
      w.key("url"); w.writeString(t.url)
      w.key("status"); w.writeString(t.status)
      w.key("seeders"); w.writeInt(t.seeders)
      w.key("leechers"); w.writeInt(t.leechers)
      w.key("completed"); w.writeInt(t.completed)
      w.key("lastAnnounce"); w.writeString(t.lastAnnounce)
      w.key("nextAnnounce"); w.writeString(t.nextAnnounce)
      w.key("lastScrape"); w.writeString(t.lastScrape)
      w.key("nextScrape"); w.writeString(t.nextScrape)
      w.key("errorText"); w.writeString(t.errorText)
      w.endObject()
    w.endArray()
    addPatchJsonStringField(fields, fldTrackers, w.finish())

  if (dirtyMask and dmPieceMap) != 0:
    addPatchStringField(fields, fldPieceMapData, gPieceMapData)

  if (dirtyMask and dmStatus) != 0:
    addPatchFloatField(fields, fldStatusDownRate, gStatusDownRate)
    addPatchFloatField(fields, fldStatusUpRate, gStatusUpRate)
    addPatchIntField(fields, fldStatusDhtNodes, gStatusDhtNodes)
    addPatchStringField(fields, fldStatusText, gStatusText)
    addPatchBoolField(fields, fldPollActive, gPollActive)

  if (dirtyMask and dmSelection) != 0:
    addPatchIntField(fields, fldSelectedTorrentId, gSelectedTorrentId)
    addPatchIntField(fields, fldDetailTab, gDetailTab)
    addPatchIntField(fields, fldActionTorrentId, gActionTorrentId)

  if (dirtyMask and dmNat) != 0:
    addPatchStringField(fields, fldNatProtocol, gNatProtocol)
    addPatchStringField(fields, fldNatExternalIp, gNatExternalIp)
    addPatchStringField(fields, fldNatGatewayIp, gNatGatewayIp)
    addPatchStringField(fields, fldNatLocalIp, gNatLocalIp)
    addPatchBoolField(fields, fldNatDoubleNat, gNatDoubleNat)
    addPatchStringField(fields, fldNatOuterProtocol, gNatOuterProtocol)
    addPatchStringField(fields, fldNatOuterGatewayIp, gNatOuterGatewayIp)
    addPatchBoolField(fields, fldNatPortsForwarded, gNatPortsForwarded)
    addPatchIntField(fields, fldNatActiveMappings, gNatActiveMappings)

  if (dirtyMask and dmSettings) != 0:
    addPatchStringField(fields, fldDownloadDir, gDownloadDir)
    addPatchStringField(fields, fldListenPort, gListenPort)
    addPatchStringField(fields, fldMaxDownloadRate, gMaxDownloadRate)
    addPatchStringField(fields, fldMaxUploadRate, gMaxUploadRate)
    addPatchStringField(fields, fldMaxPeers, gMaxPeers)
    addPatchBoolField(fields, fldDhtEnabled, gDhtEnabled)
    addPatchBoolField(fields, fldPexEnabled, gPexEnabled)
    addPatchBoolField(fields, fldLsdEnabled, gLsdEnabled)
    addPatchBoolField(fields, fldUtpEnabled, gUtpEnabled)
    addPatchBoolField(fields, fldWebSeedEnabled, gWebSeedEnabled)
    addPatchBoolField(fields, fldTrackerScrapeEnabled, gTrackerScrapeEnabled)
    addPatchBoolField(fields, fldHolepunchEnabled, gHolepunchEnabled)
    addPatchStringField(fields, fldEncryptionMode, gEncryptionMode)
    addPatchStringField(fields, fldActionPriority, gActionPriority)

  if includeEditableFields and (dirtyMask and dmDialogs) != 0:
    addPatchBoolField(fields, fldShowAddTorrent, gShowAddTorrent)
    addPatchStringField(fields, fldAddMagnetLink, gAddMagnetLink)
    addPatchStringField(fields, fldAddTorrentPath, gAddTorrentPath)
    addPatchBoolField(fields, fldShowSettings, gShowSettings)
    addPatchBoolField(fields, fldShowRemoveConfirm, gShowRemoveConfirm)
    addPatchBoolField(fields, fldRemoveDeleteFiles, gRemoveDeleteFiles)

  let count = min(fields.len, int(high(uint16)))
  appendLeU16(result, count.uint16)
  appendLeU16(result, 0'u16)
  for i in 0 ..< count:
    let f = fields[i]
    appendLeU16(result, f.fieldId)
    result.add f.valueType
    result.add 0'u8
    appendLeU32(result, f.payload.len.uint32)
    if f.payload.len > 0:
      result.add f.payload

# ============================================================
# Sync from snapshot
# ============================================================

proc syncFromSnapshot(payload: ptr uint8, payloadLen: uint32) =
  syncFromRequestFields(payload, payloadLen)

# ============================================================
# Init
# ============================================================

proc ensureInit() =
  if not gInitialized:
    initRuntimeDefaults(gRuntime)
    initMailbox[UiEvent](gEventQueue)
    initMailbox[BridgeCommand](gCommandQueue)
    initMailbox[string](gLogBuffer)
    initMailbox[string](gPendingSessionSave)
    gCommandWakePtr.store(nil, moRelaxed)
    # Create notification pipe (non-blocking)
    var fds: array[2, cint]
    if posix.pipe(fds) == 0:
      gNotifyPipeRead = fds[0]
      gNotifyPipeWrite = fds[1]
      discard fcntl(gNotifyPipeRead, F_SETFL,
        fcntl(gNotifyPipeRead, F_GETFL) or O_NONBLOCK)
      discard fcntl(gNotifyPipeWrite, F_SETFL,
        fcntl(gNotifyPipeWrite, F_GETFL) or O_NONBLOCK)
    gNotifyPending.store(false)
    # Create command notify pipe (main thread → event loop wake)
    var cmdFds: array[2, cint]
    if posix.pipe(cmdFds) == 0:
      gCmdPipeRead = cmdFds[0]
      gCmdPipeWrite = cmdFds[1]
      discard fcntl(gCmdPipeRead, F_SETFL,
        fcntl(gCmdPipeRead, F_GETFL) or O_NONBLOCK)
      discard fcntl(gCmdPipeWrite, F_SETFL,
        fcntl(gCmdPipeWrite, F_GETFL) or O_NONBLOCK)
    gCmdNotifyPending.store(false)
    gShutdownComplete.store(false)
    gDroppedEventCount.store(0'u64, moRelaxed)
    gDroppedCommandCount.store(0'u64, moRelaxed)
    gDirty.store(true, moRelaxed)
    gDirtyMask = dmAll
    gInitialized = true

# ============================================================
# Event loop thread
# ============================================================

proc eventLoopMain() {.thread.} =
  {.cast(gcsafe).}:
    logBridge "[EVENT LOOP] Thread started (MT runtime)"
    # Initialize MT runtime on this thread:
    #   - This thread becomes the reactor (handles I/O + timers via selector)
    #   - 4 worker threads trampoline CPS continuations (synchronized via AsyncMutex)
    #   - 6 blocking pool threads for spawnBlocking (SHA1 verification, disk I/O)
    let loop = initMtRuntime(numWorkers = 0, numBlockingThreads = 0)
    var crashCount = 0
    while true:
      try:
        runCps(commandProcessor())
        logBridge "[EVENT LOOP] Thread exiting normally"
        break
      except Exception as e:
        inc crashCount
        logBridge "[EVENT LOOP] CRASH #" & $crashCount & ": " & e.msg & " (" & $e.name & ")\n" & getStackTrace(e)
        if crashCount >= 5:
          logBridge "[EVENT LOOP] Too many crashes, giving up"
          break
        # Brief pause before retrying. Uses os.sleep (not cpsSleep) because the
        # CPS event loop is not running during crash recovery — there is no
        # selector or timer infrastructure to drive cpsSleep. 100ms is enough
        # to prevent tight crash loops while allowing fast recovery.
        sleep(100)
    shutdownMtRuntime(loop)
    flushSessionSave()  # Write any pending session data before thread exits
    flushLogBuffer()  # Drain remaining log messages before thread exits
    gEventLoopRunning = false
    gShutdownComplete.store(true, moRelease)

proc ensureEventLoop() =
  if not gEventLoopRunning:
    gEventLoopRunning = true
    createThread(gEventLoopThread, eventLoopMain)

# ============================================================
# Action names (for diagnostics)
# ============================================================

proc actionName(tag: uint32): string =
  case tag
  of tagPoll: "Poll"
  of tagStartPoll: "StartPoll"
  of tagAddTorrentFromFile: "AddTorrentFromFile"
  of tagAddTorrentFromMagnet: "AddTorrentFromMagnet"
  of tagRemoveTorrent: "RemoveTorrent"
  of tagPauseTorrent: "PauseTorrent"
  of tagResumeTorrent: "ResumeTorrent"
  of tagPauseAll: "PauseAll"
  of tagResumeAll: "ResumeAll"
  of tagSelectTorrent: "SelectTorrent"
  of tagSetDetailTab: "SetDetailTab"
  of tagShowAddTorrent: "ShowAddTorrent"
  of tagHideAddTorrent: "HideAddTorrent"
  of tagShowSettings: "ShowSettings"
  of tagHideSettings: "HideSettings"
  of tagShowRemoveConfirm: "ShowRemoveConfirm"
  of tagHideRemoveConfirm: "HideRemoveConfirm"
  of tagConfirmRemove: "ConfirmRemove"
  of tagSaveSettings: "SaveSettings"
  of tagSetDownloadDir: "SetDownloadDir"
  of tagSetDhtEnabled: "SetDhtEnabled"
  of tagSetFilePriority: "SetFilePriority"
  of tagTorrentFileSelected: "TorrentFileSelected"
  of tagMagnetLinkChanged: "MagnetLinkChanged"
  of tagToggleRemoveFiles: "ToggleRemoveFiles"
  of tagCopyMagnetLink: "CopyMagnetLink"
  of tagOpenInFinder: "OpenInFinder"
  of tagRecheckTorrent: "RecheckTorrent"
  of tagDropTorrentFile: "DropTorrentFile"
  of tagAppShutdown: "AppShutdown"
  else: "Unknown"

# ============================================================
# Update selected torrent detail data (runs on main thread)
# ============================================================

proc clearDetailState() =
  gFiles.setLen(0)
  gPeers.setLen(0)
  gTrackers.setLen(0)
  gPieceMapData = ""

proc updateSelectedTorrentDetail() =
  if gSelectedTorrentId < 0:
    clearDetailState()
    return

  let idx = findTorrentIdx(gSelectedTorrentId)
  if idx < 0:
    clearDetailState()
    return

  let ts = gTorrents[idx]
  # Peer info comes from the event-queue snapshot (no cross-thread access).
  # File/tracker info reads immutable metainfo data (safe).
  # Piece map reads single-byte enums (benign race).
  # Each function wrapped independently; `except Exception` catches Defects
  # which would otherwise cross the C FFI boundary and crash Swift.
  try: buildFileInfo(ts)
  except Exception: discard
  buildPeerInfoFromSnapshot(ts.id)  # uses stored snapshot, no data race
  try: buildTrackerInfo(ts)
  except Exception: discard
  try: gPieceMapData = buildPieceMapData(ts)
  except Exception: discard

# ============================================================
# Dispatch pipeline types (decode -> domain -> effects -> patch)
# ============================================================

type
  BridgeErrorKind* = enum
    beDecodeError
    beDomainError
    beEffectError
    beInternalInvariantError

  BridgeEffectKind* = enum
    effCopyText
    effOpenPath

  BridgeEffectIntent* = object
    kind*: BridgeEffectKind
    payload*: string

  DomainResult = object
    pollSkipped: bool
    effectIntents: seq[BridgeEffectIntent]
    diagnostics: seq[string]


# ============================================================
# Dispatch (runs on main thread, called by Swift)
# ============================================================

proc bridgeDispatch(payload: ptr uint8, payloadLen: uint32,
                    outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.} =
  ## Top-level wrapper: catch ALL exceptions (including Defect) to prevent
  ## them from crossing the C FFI boundary into Swift (undefined behavior).
  try:
    return dispatch(gRuntime, payload, payloadLen, outp)
  except Exception as e:
    logBridge "[BRIDGE] UNHANDLED EXCEPTION: " & e.msg & " (" & $e.name & ")"
    if outp != nil:
      outp[].statePatch = writeBlob(@[])
      outp[].effects = writeBlob(@[])
      outp[].emittedActions = writeBlob(@[])
      outp[].diagnostics = writeBlob("Error: " & e.msg)
    return -1

proc addTorrentFileEntry(path: string): int =
  ## Create a TorrentState entry from a .torrent file path, push the
  ## command to the event loop, and return the new torrent ID.
  let torrentId = gNextTorrentId
  inc gNextTorrentId
  gTorrents.add(TorrentState(
    id: torrentId,
    name: extractFilename(path),
    status: tsDownloading,
    addedDate: formatTimestamp(epochTime()),
    torrentFilePath: path,
  ))
  gSelectedTorrentId = torrentId
  enqueueCommand(BridgeCommand(kind: cmdAddTorrentFile,
    text: path, intParam: torrentId))
  torrentId

proc dispatch*(runtime: var BridgeRuntime, payload: ptr uint8, payloadLen: uint32,
               outp: ptr GUIBridgeDispatchOutput): int32 =
  # Migration shim: runtime object API is exposed; singleton runtime is still
  # the active backing store for this cutover.
  discard addr runtime
  ensureInit()

  let request = decodeRequestEnvelope(payload, payloadLen)
  let actionTag = request.actionTag
  if request.malformed:
    if outp != nil:
      outp[].statePatch = writeBlob(@[])
      outp[].effects = writeBlob(@[])
      outp[].emittedActions = writeBlob(@[])
      outp[].diagnostics = writeBlob("DecodeError(malformed_request_frame)")
    return 0'i32
  syncFromSnapshot(payload, payloadLen)

  if actionTag != tagPoll:
    logBridge "bridgeDispatch tag=" & $actionTag & " (" & actionName(actionTag) & ")"

  var domain = DomainResult(
    pollSkipped: false,
    effectIntents: @[],
    diagnostics: @[]
  )

  case actionTag
  of tagPoll:
    # Auto-recover event loop if it crashed
    ensureEventLoop()
    let hadEvents = processUiEvents()
    # Update detail data only when the selected torrent has new data
    if gSelectedTorrentId >= 0 and hadEvents:
      let oldPieceMap = gPieceMapData
      updateSelectedTorrentDetail()
      if gPieceMapData != oldPieceMap:
        markDirty(dmPieceMap)
    # Skip patch only when nothing changed at all
    if not hadEvents and gDirtyMask == 0'u32:
      domain.pollSkipped = true
    # Periodic session save (every 30s) to survive crashes/force-quit
    if gTorrents.len > 0:
      let now = epochTime()
      if now - gLastSaveTime > 30.0:
        gLastSaveTime = now
        saveSession()

  of tagStartPoll:
    if not gPollActive:
      gPollActive = true
      ensureEventLoop()
      loadSession()
    else:
      ensureEventLoop()

  of tagAddTorrentFromFile:
    ensureEventLoop()
    let path = gAddTorrentPath.strip()
    logBridge "[BRIDGE] AddTorrentFromFile path='" & path & "'"
    if path.len == 0:
      gStatusText = "No torrent file selected"
    else:
      let torrentId = addTorrentFileEntry(path)
      gShowAddTorrent = false
      gStatusText = "Adding torrent..."
      logBridge "[BRIDGE] Created torrent id=" & $torrentId & " name=" & extractFilename(path)
      saveSession()

  of tagAddTorrentFromMagnet:
    ensureEventLoop()
    let uri = gAddMagnetLink.strip()
    if uri.len == 0 or not uri.startsWith("magnet:"):
      gStatusText = "Invalid magnet link"
    else:
      let torrentId = gNextTorrentId
      inc gNextTorrentId
      gTorrents.add(TorrentState(
        id: torrentId,
        name: "Loading metadata...",
        status: tsDownloading,
        addedDate: formatTimestamp(epochTime()),
        magnetUri: uri,
      ))
      gSelectedTorrentId = torrentId
      gShowAddTorrent = false
      gStatusText = "Adding magnet link (DHT peer discovery)..."
      enqueueCommand(BridgeCommand(kind: cmdAddTorrentMagnet,
        text: uri, intParam: torrentId))
      saveSession()

  of tagRemoveTorrent, tagConfirmRemove:
    if gActionTorrentId >= 0:
      ensureEventLoop()
      enqueueCommand(BridgeCommand(kind: cmdRemoveTorrent,
        intParam: gActionTorrentId, boolParam: gRemoveDeleteFiles))
      gShowRemoveConfirm = false
      saveSession()

  of tagPauseTorrent:
    if gActionTorrentId >= 0:
      ensureEventLoop()
      enqueueCommand(BridgeCommand(kind: cmdPauseTorrent,
        intParam: gActionTorrentId))

  of tagResumeTorrent:
    if gActionTorrentId >= 0:
      ensureEventLoop()
      let idx = findTorrentIdx(gActionTorrentId)
      if idx >= 0 and gTorrents[idx].paused:
        gTorrents[idx].paused = false
        gTorrents[idx].status = tsDownloading
        enqueueCommand(BridgeCommand(kind: cmdResumeTorrent,
          intParam: gActionTorrentId,
          text2: gTorrents[idx].torrentFilePath))

  of tagPauseAll:
    ensureEventLoop()
    # Send individual pause commands for each active torrent
    for ts in gTorrents:
      if ts.status in {tsDownloading, tsSeeding}:
        enqueueCommand(BridgeCommand(kind: cmdPauseTorrent,
          intParam: ts.id))

  of tagResumeAll:
    ensureEventLoop()
    # Send individual resume commands for each paused torrent
    for i in 0 ..< gTorrents.len:
      if gTorrents[i].paused and gTorrents[i].torrentFilePath.len > 0:
        gTorrents[i].paused = false
        gTorrents[i].status = tsDownloading
        enqueueCommand(BridgeCommand(kind: cmdResumeTorrent,
          intParam: gTorrents[i].id,
          text2: gTorrents[i].torrentFilePath))

  of tagSelectTorrent:
    gDetailTab = 0
    updateSelectedTorrentDetail()

  of tagSetDetailTab:
    updateSelectedTorrentDetail()

  of tagShowAddTorrent:
    gShowAddTorrent = true
    gAddMagnetLink = ""
    gAddTorrentPath = ""

  of tagHideAddTorrent:
    gShowAddTorrent = false

  of tagShowSettings:
    gShowSettings = true

  of tagHideSettings:
    gShowSettings = false

  of tagShowRemoveConfirm:
    gShowRemoveConfirm = true
    gRemoveDeleteFiles = false

  of tagHideRemoveConfirm:
    gShowRemoveConfirm = false

  of tagSaveSettings:
    ensureEventLoop()
    enqueueCommand(BridgeCommand(kind: cmdSaveSettings))
    gShowSettings = false
    gStatusText = "Settings saved"

  of tagDropTorrentFile:
    # Direct drop — path comes from snapshot (set by reducer)
    ensureEventLoop()
    let path = gAddTorrentPath.strip()
    logBridge "[BRIDGE] DropTorrentFile path='" & path & "'"
    if path.len > 0:
      discard addTorrentFileEntry(path)
      gStatusText = "Adding torrent..."

  of tagSetFilePriority:
    if gSelectedTorrentId >= 0 and gActionTorrentId >= 0:
      let idx = findTorrentIdx(gSelectedTorrentId)
      if idx >= 0:
        if gTorrents[idx].filePriorities.len < gTorrents[idx].fileInfo.len:
          gTorrents[idx].filePriorities.setLen(gTorrents[idx].fileInfo.len)
          for i in 0 ..< gTorrents[idx].filePriorities.len:
            if gTorrents[idx].filePriorities[i].len == 0:
              gTorrents[idx].filePriorities[i] = "normal"
        if gActionTorrentId < gTorrents[idx].filePriorities.len:
          gTorrents[idx].filePriorities[gActionTorrentId] = gActionPriority
      ensureEventLoop()
      enqueueCommand(BridgeCommand(kind: cmdSetFilePriority,
        intParam: gSelectedTorrentId,
        intParam2: gActionTorrentId,
        text: gActionPriority))
      updateSelectedTorrentDetail()

  of tagSetDownloadDir, tagSetDhtEnabled, tagMagnetLinkChanged,
     tagToggleRemoveFiles, tagTorrentFileSelected:
    discard  # State already synced from snapshot

  of tagCopyMagnetLink:
    if gActionTorrentId >= 0:
      let idx = findTorrentIdx(gActionTorrentId)
      if idx >= 0:
        let ts = gTorrents[idx]
        let magnet = "magnet:?xt=urn:btih:" & ts.infoHash &
                     "&dn=" & encodeUrl(ts.name)
        domain.effectIntents.add(BridgeEffectIntent(kind: effCopyText, payload: magnet))
        gStatusText = "Magnet link copied"

  of tagOpenInFinder:
    if gActionTorrentId >= 0:
      let idx = findTorrentIdx(gActionTorrentId)
      if idx >= 0 and gTorrents[idx].downloadDir.len > 0:
        let dir = gTorrents[idx].downloadDir
        domain.effectIntents.add(BridgeEffectIntent(kind: effOpenPath, payload: dir))

  of tagRecheckTorrent:
    if gActionTorrentId >= 0:
      ensureEventLoop()
      enqueueCommand(BridgeCommand(kind: cmdRecheckTorrent,
        intParam: gActionTorrentId))

  of tagAppShutdown:
    logBridge "[BRIDGE] AppShutdown"
    saveSession()
    ensureEventLoop()
    enqueueCommand(BridgeCommand(kind: cmdShutdown))

  else:
    discard

  if actionTag != tagPoll:
    markDirty(dmAll)

  # Build response
  var patchBytes: seq[byte] = @[]
  var dirtyEmitted = 0'u32
  # Enqueue effects to event loop for async execution on blocking pool.
  # This avoids blocking the main thread on process fork+wait.
  for intent in domain.effectIntents:
    enqueueCommand(BridgeCommand(kind: cmdExecuteEffect,
      intParam: intent.kind.ord, text: intent.payload))

  if not domain.pollSkipped and gDirtyMask != 0'u32:
    dirtyEmitted = gDirtyMask
    patchBytes = buildPatchBinary(actionTag != tagPoll, dirtyEmitted)
    gDirtyMask = gDirtyMask and not dirtyEmitted

  let droppedEvents = gDroppedEventCount.exchange(0'u64, moAcquireRelease)
  let droppedCommands = gDroppedCommandCount.exchange(0'u64, moAcquireRelease)
  var diagnosticsText = actionName(actionTag)
  if droppedEvents > 0'u64 or droppedCommands > 0'u64:
    diagnosticsText.add " drops(events="
    diagnosticsText.add $droppedEvents
    diagnosticsText.add ",commands="
    diagnosticsText.add $droppedCommands
    diagnosticsText.add ")"
  if domain.diagnostics.len > 0:
    diagnosticsText.add " "
    diagnosticsText.add domain.diagnostics.join("; ")

  # Reset notify flag AFTER all processing is complete (patch built).
  # This prevents events arriving during buildPatchBinary from triggering
  # redundant pipe writes that get blocked by dispatchInFlight on Swift side,
  # causing bursty update patterns.
  gNotifyPending.store(false, moRelease)

  if outp != nil:
    outp[].statePatch = writeBlob(patchBytes)
    outp[].effects = writeBlob(@[])
    outp[].emittedActions = writeBlob(@[])
    outp[].diagnostics = writeBlob(diagnosticsText)

  0'i32

# ============================================================
# FFI export
# ============================================================

proc bridgeGetNotifyFd(): int32 {.cdecl.} =
  ensureInit()
  gNotifyPipeRead.int32

proc bridgeWaitShutdown(timeoutMs: int32): int32 {.cdecl.} =
  if not gEventLoopRunning:
    flushSessionSave()
    flushLogBuffer()
    return 0
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    if gShutdownComplete.load(moAcquire):
      joinThread(gEventLoopThread)
      gEventLoopRunning = false
      flushSessionSave()
      flushLogBuffer()
      return 0
    sleep(10)
  flushSessionSave()
  flushLogBuffer()
  return 1

var gBridgeTable = GUIBridgeFunctionTable(
  abiVersion: guiBridgeAbiVersion,
  alloc: bridgeAlloc,
  free: bridgeFree,
  dispatch: bridgeDispatch,
  getNotifyFd: bridgeGetNotifyFd,
  waitShutdown: bridgeWaitShutdown
)

proc gui_bridge_get_table(): ptr GUIBridgeFunctionTable {.cdecl, exportc, dynlib.} =
  addr gBridgeTable
