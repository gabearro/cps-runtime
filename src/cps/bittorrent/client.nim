## BitTorrent client orchestrator.
##
## Manages tracker communication, peer connections, piece downloading,
## and disk I/O. This is the top-level API for the BitTorrent client.

import std/[tables, sets, times, os, algorithm, nativesockets, strutils, math, atomics, deques]
import ../private/spinlock
import ../runtime
import ../transform
import ../eventloop
import ../mt/mtruntime
import ../io/streams
import ../io/tcp
import ../io/udp
import ../io/dns
import ../io/timeouts
import ../io/nat
import ../concurrency/channels
import ../concurrency/sync
import bencode
import metainfo
import tracker
import peer_protocol
import pieces
import peer
import storage
import utp_stream
import extensions
import metadata
import pex
import peerid
import dht
import holepunch
import fast_extension
import webseed
import lsd
import utils
import mse
import sha1 as sha1mod
import peer_priority
import ratelimit

const
  IPPROTO_IPV6_C {.importc: "IPPROTO_IPV6", header: "<netinet/in.h>".}: cint = 0
  IPV6_V6ONLY_C {.importc: "IPV6_V6ONLY", header: "<netinet/in.h>".}: cint = 0

proc setsockoptRaw(s: SocketHandle, level, optname: cint, optval: pointer,
                   optlen: SockLen): cint {.importc: "setsockopt", header: "<sys/socket.h>".}

template btDebug(args: varargs[string, `$`]) =
  ## Debug logging for BitTorrent client. No-op unless compiled with -d:btDebug.
  when defined(btDebug):
    var msg = ""
    for a in args:
      msg.add(a)
    stderr.writeLine(msg)
    stderr.flushFile()

# Lock-free Treiber stack nodes for reactor → CPS message handoff.
# Reactor callback pushes parsed messages; CPS drain loop pops and processes.
type
  DhtRecvNode = object
    next: ptr DhtRecvNode
    msg: DhtMessage
    srcAddr: Sockaddr_storage
    addrLen: SockLen

  LsdRecvNode = object
    next: ptr LsdRecvNode
    data: string
    srcAddr: Sockaddr_storage
    addrLen: SockLen

const
  MaxPeers* = 200              ## Maximum simultaneous active peer connections
  MinPeers* = 20              ## Try to maintain at least this many peers
  MaxHalfOpen* = 50           ## Maximum concurrent connection attempts
  MaxPerIp* = 1               ## Max connections to the same IP (prevent DHT spam)
  ReannounceIntervalMs* = 20000  ## Re-announce to tracker every 20s if low on peers
  UnchokeIntervalMs* = 10000    ## Re-evaluate choking every 10s
  MaxUnchokedPeers* = 4        ## Max peers to unchoke simultaneously
  StaleRequestTimeoutSec* = 30.0  ## Reclaim requests from peers silent for >30s
  UtpReconnectCooldownSec* = 300.0  ## 5-minute cooldown between uTP reconnect attempts per peer
  MaxPendingPeers* = 200          ## Maximum queued peers waiting to connect
  PeerBackoffSec* = 60.0          ## Backoff for peers that failed (connect or handshake)

type
  ClientState* = enum
    csIdle
    csStarting
    csDownloading
    csSeeding
    csStopping
    csStopped

  UtpReconnectSnapshot* = object
    ## Transferable peer state saved before uTP reconnection.
    ## Restored on successful reconnect to avoid re-exchanging
    ## bitfield, extensions, and interest state.
    peerBitfield*: seq[byte]
    extensions*: ExtensionRegistry
    remotePeerId*: array[20, byte]
    peerInterested*: bool
    amInterested*: bool
    peerUploadOnly*: bool
    isSuperSeeder*: bool
    source*: PeerSource
    bytesDownloaded*: int64
    bytesUploaded*: int64
    connectedAt*: float
    priority*: uint32
    pexFlags*: uint8

  ClientConfig* = object
    downloadDir*: string
    listenPort*: uint16
    maxPeers*: int
    uploadBandwidth*: int      ## Total upload bandwidth in bytes/sec (0 = auto-detect)
    downloadBandwidth*: int    ## Total download bandwidth in bytes/sec (0 = auto-detect)
    bandwidthPercent*: int     ## Percentage of bandwidth to use (1-100, default 80)
    enableDht*: bool
    enablePex*: bool
    enableLsd*: bool
    enableUtp*: bool
    enableWebSeed*: bool
    enableTrackerScrape*: bool
    enableHolepunch*: bool
    encryptionMode*: EncryptionMode
    sharedListener*: TcpListener    ## Shared TCP listener (nil = create own)
    sharedUtpMgr*: UtpManager       ## Shared uTP manager (nil = create own)
    sharedLsdSock*: UdpSocket       ## Shared LSD socket (nil = create own)
    sharedNatMgr*: NatManager       ## Shared NAT manager (nil = create own)
    enableRacing*: bool              ## Enable block racing (request from multiple peers)
    maxRacersPerBlock*: int          ## Max concurrent requesters per block (default 3)
    raceSlowPeerSec*: float          ## Race blocks from peers silent > N seconds (default 5.0)
    enableOptimisticVerification*: bool  ## Use peer consensus as fast verification proxy
    optimisticMinAgreePeers*: int        ## Min total peers that must agree (default 2)
    optimisticMinAgreeBlocks*: int       ## Min absolute number of agreed blocks needed (default 3)

  PendingPeer = tuple[ip: string, port: uint16, source: PeerSource, pexFlags: uint8]

  TrackerRuntime* = object
    url*: string
    status*: string        ## working | updating | error | disabled
    seeders*: int
    leechers*: int
    completed*: int
    lastAnnounce*: float
    nextAnnounce*: float
    lastScrape*: float
    nextScrape*: float
    errorText*: string

  TorrentClient* = ref object
    config*: ClientConfig
    metainfo*: TorrentMetainfo
    state*: ClientState
    peerId*: array[20, byte]
    pieceMgr*: PieceManager
    storageMgr*: StorageManager
    events*: AsyncChannel[ClientEvent]
    peers: Table[string, PeerConn]  ## addr -> PeerConn
    peerKeysCached: seq[string]    ## Shadow list of peers keys (avoids table iterator assertion in MT)
    peerEvents: AsyncChannel[PeerEvent]
    availability: seq[int]     ## Per-piece availability count
    connectedPeerCount*: int   ## Active (handshaked) peers
    halfOpenCount*: int         ## Connection attempts in progress
    pendingPeers: seq[PendingPeer]  ## Peers waiting to be connected
    startTime: float
    listener: TcpListener
    # BEP 10/9: Extension protocol & metadata exchange
    localExtensions: ExtensionRegistry
    rawInfoDict*: string       ## Raw bencoded info dict (for serving metadata)
    metadataExchange*: MetadataExchange  ## For magnet link downloads
    isPrivate*: bool           ## BEP 27: private torrent flag
    # BEP 11: PEX
    lastPexPeers: seq[CompactPeer]  ## For computing deltas (IPv4)
    lastPexPeers6: seq[CompactPeer]  ## For computing deltas (IPv6)
    # BEP 55: cached peer hints from inbound PEX
    pexPeerFlags: Table[string, uint8]  ## canonical peer key -> added.f flags
    hp*: HolepunchState              ## BEP 55: consolidated holepunch bookkeeping
    nextConnGeneration: uint32                    ## monotonic counter for peer connection identity
    # BEP 5: DHT
    dhtNodeId: NodeId
    dhtRoutingTable: RoutingTable    ## IPv4 nodes
    dhtRoutingTable6: RoutingTable   ## IPv6 nodes (BEP 32)
    dhtSock: UdpSocket
    dhtPendingQueries: Table[string, CpsFuture[DhtMessage]]
    dhtTransIdCounter: int
    dhtEnabled*: bool
    dhtSecret: string              ## Current token generation secret
    dhtPrevSecret: string          ## Previous secret (for token rotation)
    dhtPeerStore: DhtPeerStore     ## Store peers we've learned about
    dhtTokenCache: Table[string, string]  ## ip:port → token from get_peers responses
    # Choking algorithm state
    lastUnchokeTime: float
    optimisticPeerKey: string  ## Current optimistic unchoke peer
    # BEP 29: uTP transport
    utpMgr*: UtpManager
    # BEP 19: Web seeds
    webSeeds*: seq[WebSeed]
    # BEP 14: LSD
    lsdSock: UdpSocket
    # NAT port forwarding
    natMgr*: NatManager
    # Connection backoff: track recently-failed peers to avoid hammering
    failedPeers: Table[string, float]  ## addr -> last failure time
    failedIps: Table[string, tuple[count: int, lastFail: float]]  ## IP-level failure tracking
    # Seeder eviction: addresses of peers evicted as seeders (prevents reconnection)
    knownSeeders: HashSet[string]
    # PEX peer discovery counter: total unique peers received via PEX (monotonically increasing)
    pexPeersReceived*: int
    # Internal stop signal used to interrupt sleeps promptly during shutdown.
    stopSignal: CpsVoidFuture
    # Runtime protocol stats (surfaced by GUI bridge)
    lsdAnnounceCount*: int
    lsdPeersDiscovered*: int
    lsdLastError*: string
    trackerRuntime*: Table[string, TrackerRuntime]
    webSeedBytes*: int64
    webSeedFailures*: int
    webSeedActiveUrl*: string
    # BEP 53 file selection state
    selectedFiles*: HashSet[int]
    selectedPiecesMask*: seq[bool]   ## true = piece selected for download
    highPriorityPiecesMask*: seq[bool] ## true = piece should be prioritized
    filePriorities*: Table[int, string]  ## index -> high | normal | skip
    # Global bandwidth limiter (may be shared across torrents)
    bandwidthLimiter*: BandwidthLimiter
    # Per-torrent wire byte counters (for accurate per-torrent rate display)
    wireDownloaded*: int64
    wireUploaded*: int64
    # Optimistic verification: background SHA1 queue
    optimisticVerifyQueue*: Deque[int]  ## Piece indices awaiting background SHA1 confirmation
    # MT synchronization
    mtx*: AsyncMutex              ## Protects shared mutable state across CPS tasks
    trackerLock*: SpinLock        ## Protects trackerRuntime table (non-suspending reads/writes)
    dhtSpinLock: SpinLock         ## Protects DHT state (CPS tasks only — reactor uses lock-free buffer)
    dhtRecvHead: Atomic[pointer]  ## Lock-free Treiber stack for reactor → CPS DHT message handoff
    lsdRecvHead: Atomic[pointer]  ## Lock-free Treiber stack for reactor → CPS LSD packet handoff
    # uTP reconnection state
    utpReconnectCooldown: Table[string, float]        ## peer key → last uTP reconnect attempt time
    utpReconnectInProgress: HashSet[string]            ## peer keys currently being reconnected via uTP
    utpReconnectState: Table[string, UtpReconnectSnapshot] ## peer key → saved state for restoration

  ClientEventKind* = enum
    cekStarted
    cekPieceVerified
    cekProgress
    cekPeerConnected
    cekPeerDisconnected
    cekCompleted
    cekError
    cekInfo              ## Informational status messages (DHT, etc.)
    cekStopped
    cekTrackerResponse
    cekPieceStateChanged ## Piece state update (optimistic→verified/failed) without counter change

  ClientEvent* = object
    case kind*: ClientEventKind
    of cekStarted, cekCompleted, cekStopped:
      discard
    of cekPieceVerified:
      pieceIndex*: int
      pieceState*: PieceState  ## State at time of event (psOptimistic or psVerified)
    of cekProgress:
      completedPieces*: int
      totalPieces*: int
      downloadRate*: float  ## bytes/sec
      uploadRate*: float
      peerCount*: int
    of cekPeerConnected, cekPeerDisconnected:
      peerAddr*: string
    of cekError, cekInfo:
      errMsg*: string
    of cekTrackerResponse:
      newPeers*: int
      seeders*: int
      leechers*: int
    of cekPieceStateChanged:
      changedPieceIndex*: int
      changedPieceState*: PieceState

proc defaultConfig*(): ClientConfig =
  ClientConfig(
    downloadDir: getCurrentDir(),
    listenPort: 6881,
    maxPeers: MaxPeers,
    uploadBandwidth: 0,
    downloadBandwidth: 0,
    bandwidthPercent: 80,
    enableDht: true,
    enablePex: true,
    enableLsd: true,
    enableUtp: true,
    enableWebSeed: true,
    enableTrackerScrape: true,
    enableHolepunch: true,
    encryptionMode: emPreferEncrypted,
    enableRacing: true,
    maxRacersPerBlock: 10,
    raceSlowPeerSec: 5.0,
    enableOptimisticVerification: true,
    optimisticMinAgreePeers: 2,
    optimisticMinAgreeBlocks: 3
  )

proc buildSelectedPiecesMask(client: TorrentClient)
proc applyPrivateProtocolGating(client: TorrentClient)
proc initClientCommon(client: TorrentClient, config: ClientConfig)

proc newTorrentClient*(metainfo: TorrentMetainfo,
                       config: ClientConfig = defaultConfig()): TorrentClient =
  let pm = newPieceManager(metainfo.info, config.maxRacersPerBlock,
                           config.enableOptimisticVerification)
  # Set up extension registry
  var extReg = newExtensionRegistry()
  discard extReg.registerExtension(UtMetadataName)   # BEP 9
  discard extReg.registerExtension(UtPexName)         # BEP 11
  discard extReg.registerExtension(UtHolepunchName)   # BEP 55
  discard extReg.registerExtension(ExtUploadOnly)      # BEP 21
  discard extReg.registerExtension(ExtLtDontHave)      # BEP 54

  let dhtId = generateNodeId()

  # Collect web seeds from metainfo
  var seeds: seq[WebSeed]
  for url in metainfo.urlList:
    seeds.add(newWebSeed(url))
  for url in metainfo.httpSeeds:
    seeds.add(newWebSeed(url))

  result = TorrentClient(
    config: config,
    metainfo: metainfo,
    state: csIdle,
    peerId: generatePeerId(),
    pieceMgr: pm,
    events: newAsyncChannel[ClientEvent](),  # Unbounded — must never block handlePeerEvent
    peerEvents: newAsyncChannel[PeerEvent](),  # Unbounded — must never block peer read loops
    availability: newSeq[int](metainfo.info.pieceCount),
    localExtensions: extReg,
    isPrivate: metainfo.info.isPrivate,
    dhtNodeId: dhtId,
    dhtRoutingTable: newRoutingTable(dhtId),
    dhtRoutingTable6: newRoutingTable(dhtId),
    dhtEnabled: not metainfo.info.isPrivate and config.enableDht,
    webSeeds: seeds,
    pexPeerFlags: initTable[string, uint8](),
    hp: initHolepunchState(),
    trackerRuntime: initTable[string, TrackerRuntime](),
    stopSignal: newCpsVoidFuture(),
    selectedFiles: initHashSet[int](),
    filePriorities: initTable[int, string](),
    utpReconnectCooldown: initTable[string, float](),
    utpReconnectInProgress: initHashSet[string](),
    utpReconnectState: initTable[string, UtpReconnectSnapshot]()
  )
  initClientCommon(result, config)
  # Extract raw info dict for BEP 9 metadata serving
  result.rawInfoDict = metainfo.rawInfoDict
  result.applyPrivateProtocolGating()
  result.buildSelectedPiecesMask()

proc newMagnetClient*(infoHash: array[20, byte],
                      trackers: seq[string],
                      displayName: string = "",
                      config: ClientConfig = defaultConfig(),
                      selectedFiles: seq[int] = @[]): TorrentClient =
  ## Create a client from a magnet link (no metadata yet).
  var extReg = newExtensionRegistry()
  discard extReg.registerExtension(UtMetadataName)
  discard extReg.registerExtension(UtPexName)
  discard extReg.registerExtension(UtHolepunchName)

  let dhtId = generateNodeId()

  result = TorrentClient(
    config: config,
    state: csIdle,
    peerId: generatePeerId(),
    events: newAsyncChannel[ClientEvent](),  # Unbounded — must never block handlePeerEvent
    peerEvents: newAsyncChannel[PeerEvent](),  # Unbounded — must never block peer read loops
    localExtensions: extReg,
    metadataExchange: newMetadataExchange(infoHash),
    dhtNodeId: dhtId,
    dhtRoutingTable: newRoutingTable(dhtId),
    dhtRoutingTable6: newRoutingTable(dhtId),
    dhtEnabled: config.enableDht,
    pexPeerFlags: initTable[string, uint8](),
    hp: initHolepunchState(),
    trackerRuntime: initTable[string, TrackerRuntime](),
    stopSignal: newCpsVoidFuture(),
    selectedFiles: initHashSet[int](),
    filePriorities: initTable[int, string](),
    utpReconnectCooldown: initTable[string, float](),
    utpReconnectInProgress: initHashSet[string](),
    utpReconnectState: initTable[string, UtpReconnectSnapshot]()
  )
  initClientCommon(result, config)
  # For magnet links, privacy is unknown until metadata arrives.
  # Set up a minimal metainfo with just the info hash and trackers
  result.metainfo.info.infoHash = infoHash
  result.metainfo.info.name = if displayName.len > 0: displayName else: "unknown"
  for idx in selectedFiles:
    result.selectedFiles.incl(idx)
  if trackers.len > 0:
    result.metainfo.announce = trackers[0]
    for url in trackers:
      result.metainfo.announceList.add(@[url])

proc peerKey(ip: string, port: uint16): string =
  formatPeerAddr(ip, port)

proc resetStopSignal(client: TorrentClient) =
  client.stopSignal = newCpsVoidFuture()
  client.stopSignal.pinFutureRuntime()

# ---------------------------------------------------------------------------
# Lock-free Treiber stack push/drain for reactor → CPS handoff.
# Reactor callbacks push parsed messages without any lock or syscall.
# CPS drain loops pop via atomic exchange (wait-free).
# ---------------------------------------------------------------------------

proc pushDhtRecv(client: TorrentClient, msg: DhtMessage, srcAddr: Sockaddr_storage, addrLen: SockLen) =
  ## Lock-free push of a parsed DHT message to the Treiber stack.
  ## Called from reactor callback — no lock, no syscall.
  let node = cast[ptr DhtRecvNode](allocShared0(sizeof(DhtRecvNode)))
  {.cast(gcsafe).}:
    copyMem(addr node.msg, unsafeAddr msg, sizeof(DhtMessage))
    zeroMem(unsafeAddr msg, sizeof(DhtMessage))
  node.srcAddr = srcAddr
  node.addrLen = addrLen
  var oldHead = client.dhtRecvHead.load(moRelaxed)
  while true:
    node.next = cast[ptr DhtRecvNode](oldHead)
    if client.dhtRecvHead.compareExchangeWeak(oldHead, cast[pointer](node),
                                               moRelease, moRelaxed):
      break

proc drainDhtRecv(client: TorrentClient): seq[tuple[msg: DhtMessage, srcAddr: Sockaddr_storage, addrLen: SockLen]] =
  ## Lock-free drain of all buffered DHT messages (wait-free atomic exchange).
  ## Returns items in FIFO order (reverses Treiber stack LIFO).
  let head = cast[ptr DhtRecvNode](client.dhtRecvHead.exchange(nil, moAcquireRelease))
  if head == nil:
    return @[]
  var n = 0
  var node = head
  while node != nil:
    inc n
    node = node.next
  result = newSeq[tuple[msg: DhtMessage, srcAddr: Sockaddr_storage, addrLen: SockLen]](n)
  node = head
  var i = n - 1
  while node != nil:
    let next = node.next
    copyMem(addr result[i].msg, addr node.msg, sizeof(DhtMessage))
    zeroMem(addr node.msg, sizeof(DhtMessage))
    result[i].srcAddr = node.srcAddr
    result[i].addrLen = node.addrLen
    deallocShared(node)
    node = next
    dec i

proc pushLsdRecv(client: TorrentClient, data: sink string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
  ## Lock-free push of an LSD packet to the Treiber stack.
  let node = cast[ptr LsdRecvNode](allocShared0(sizeof(LsdRecvNode)))
  copyMem(addr node.data, unsafeAddr data, sizeof(string))
  zeroMem(unsafeAddr data, sizeof(string))
  node.srcAddr = srcAddr
  node.addrLen = addrLen
  var oldHead = client.lsdRecvHead.load(moRelaxed)
  while true:
    node.next = cast[ptr LsdRecvNode](oldHead)
    if client.lsdRecvHead.compareExchangeWeak(oldHead, cast[pointer](node),
                                               moRelease, moRelaxed):
      break

proc drainLsdRecv(client: TorrentClient): seq[tuple[data: string, srcAddr: Sockaddr_storage, addrLen: SockLen]] =
  ## Lock-free drain of all buffered LSD packets.
  let head = cast[ptr LsdRecvNode](client.lsdRecvHead.exchange(nil, moAcquireRelease))
  if head == nil:
    return @[]
  var n = 0
  var node = head
  while node != nil:
    inc n
    node = node.next
  result = newSeq[tuple[data: string, srcAddr: Sockaddr_storage, addrLen: SockLen]](n)
  node = head
  var i = n - 1
  while node != nil:
    let next = node.next
    copyMem(addr result[i].data, addr node.data, sizeof(string))
    zeroMem(addr node.data, sizeof(string))
    result[i].srcAddr = node.srcAddr
    result[i].addrLen = node.addrLen
    deallocShared(node)
    node = next
    dec i

proc signalStop(client: TorrentClient) {.inline.} =
  if client.stopSignal != nil and not client.stopSignal.finished:
    client.stopSignal.complete()

proc sleepOrStop(client: TorrentClient, ms: int): CpsVoidFuture {.inline.} =
  ## Sleep for `ms` unless the client stop signal fires first.
  sleepOrSignal(ms, client.stopSignal)

# ---------------------------------------------------------------------------
# Extracted helpers — reduce duplication across the 4800+ line orchestrator.
# ---------------------------------------------------------------------------

proc setPeer(client: TorrentClient, key: string, peer: PeerConn) =
  ## Insert or replace a peer, keeping the cached key list in sync.
  if key notin client.peers:
    client.peerKeysCached.add(key)
  client.peers[key] = peer

proc delPeer(client: TorrentClient, key: string) =
  ## Remove a peer, keeping the cached key list in sync.
  client.peers.del(key)
  let idx = client.peerKeysCached.find(key)
  if idx >= 0:
    client.peerKeysCached.del(idx)  # O(1) swap-delete

proc snapshotPeerKeys(client: TorrentClient): seq[string] =
  ## Snapshot peer keys without iterating the hash table (MT-safe).
  result = client.peerKeysCached  # value copy

proc safeTableKeys[K, V](t: Table[K, V]): seq[K] =
  ## Collect table keys tolerating concurrent modification in MT mode.
  ## Falls back to a partial snapshot if the table changes mid-iteration.
  result = newSeqOfCap[K](t.len)
  try:
    for k in t.keys:
      result.add(k)
  except Exception:
    discard  # partial snapshot

proc removeActiveRequest(peer: PeerConn, pieceIdx: int, offset: int): bool =
  ## Remove a block from activeRequests and decrement pendingRequests.
  ## Returns true if found and removed.
  var i = 0
  while i < peer.activeRequests.len:
    if peer.activeRequests[i].pieceIdx == pieceIdx and
       peer.activeRequests[i].offset == offset:
      peer.activeRequests.del(i)
      peer.pendingRequests = max(0, peer.pendingRequests - 1)
      return true
    i += 1
  false

proc hasActiveRequest(peer: PeerConn, pieceIdx: int, offset: int): bool =
  ## Check if peer has an active request for a specific block.
  var i = 0
  while i < peer.activeRequests.len:
    if peer.activeRequests[i].pieceIdx == pieceIdx and
       peer.activeRequests[i].offset == offset:
      return true
    i += 1
  false

proc collectTrackerUrls(metainfo: TorrentMetainfo): seq[string] =
  ## Collect unique, non-empty tracker URLs from announce + announceList.
  if metainfo.announce.len > 0:
    result.add(metainfo.announce)
  for tier in metainfo.announceList:
    for url in tier:
      if url.len > 0 and url notin result:
        result.add(url)

proc restoreVerifiedPieces(client: TorrentClient, verified: seq[bool]) =
  ## Bulk-restore verified piece state from on-disk verification results.
  var vi = 0
  while vi < verified.len:
    if verified[vi]:
      var bj = 0
      while bj < client.pieceMgr.pieces[vi].blocks.len:
        client.pieceMgr.pieces[vi].blocks[bj].state = bsReceived
        bj += 1
      client.pieceMgr.pieces[vi].receivedBytes = client.pieceMgr.pieces[vi].totalLength
      client.pieceMgr.pieces[vi].state = psVerified
      client.pieceMgr.completedCount += 1
      client.pieceMgr.verifiedCount += 1
      client.pieceMgr.downloaded += int64(client.pieceMgr.pieces[vi].totalLength)
    vi += 1

proc initClientCommon(client: TorrentClient, config: ClientConfig) =
  ## Shared initialization for torrent file and magnet link clients.
  client.bandwidthLimiter = newBandwidthLimiter(
    uploadBps = config.uploadBandwidth,
    downloadBps = config.downloadBandwidth,
    percent = config.bandwidthPercent
  )
  client.mtx = newAsyncMutex()
  initSpinLock(client.trackerLock)
  initSpinLock(client.dhtSpinLock)
  client.dhtRecvHead.store(nil, moRelaxed)
  client.lsdRecvHead.store(nil, moRelaxed)

proc peerIpFromKey(key: string): string =
  if key.len == 0:
    return ""
  if key[0] == '[':
    let rb = key.find(']')
    if rb > 1:
      return key[1 ..< rb]
    return key
  let c = key.rfind(':')
  if c > 0:
    return key[0 ..< c]
  key

proc peerPortFromKey(key: string): uint16 =
  if key.len == 0:
    return 0
  if key[0] == '[':
    let rb = key.find(']')
    if rb >= 0 and rb + 2 < key.len and key[rb + 1] == ':':
      return uint16(safeParseInt(key[rb + 2 .. ^1], 0))
    return 0
  let c = key.rfind(':')
  if c > 0 and c + 1 < key.len:
    return uint16(safeParseInt(key[c + 1 .. ^1], 0))
  0

proc isPublicIpv4(ip: string): bool =
  ## True only for globally routable IPv4 addresses.
  ## Rejects: empty, IPv6, private (RFC 1918), CGNAT, link-local,
  ## loopback (127.x), 0.0.0.0/8, multicast (224+), broadcast.
  if ip.len == 0:
    return false
  if ip.contains(':'):
    return false
  if ip.count('.') != 3:
    return false
  let parts = ip.split('.')
  if parts.len != 4:
    return false
  var a: int
  try:
    a = parseInt(parts[0])
  except ValueError:
    return false
  # 0.0.0.0/8 (current network)
  if a == 0: return false
  # 127.0.0.0/8 (loopback)
  if a == 127: return false
  # 224.0.0.0/4 (multicast) and 240.0.0.0/4 (reserved/broadcast)
  if a >= 224: return false
  not isPrivateIp(ip)

proc isPublicIpv6(ip: string): bool =
  ## True only for globally routable IPv6 addresses.
  ## Rejects: loopback (::1), link-local (fe80::/10), multicast (ff00::/8),
  ## unique-local (fc00::/7), unspecified (::), and non-IPv6.
  if ip.len == 0 or ':' notin ip:
    return false
  try:
    let words = parseIpv6Words(ip)
    # Unspecified (::)
    var allZero = true
    for w in words:
      if w != 0: allZero = false
    if allZero: return false
    # Loopback (::1)
    var isLoopback = true
    for i in 0 ..< 7:
      if words[i] != 0: isLoopback = false
    if isLoopback and words[7] == 1: return false
    # Link-local (fe80::/10)
    if (words[0] and 0xFFC0'u16) == 0xFE80'u16: return false
    # Unique-local (fc00::/7)
    if (words[0] and 0xFE00'u16) == 0xFC00'u16: return false
    # Multicast (ff00::/8)
    if (words[0] and 0xFF00'u16) == 0xFF00'u16: return false
    return true
  except CatchableError:
    return false

proc isRoutableIp(ip: string): bool =
  ## True for globally routable IPv4 or IPv6 addresses.
  if ':' in ip:
    isPublicIpv6(ip)
  else:
    isPublicIpv4(ip)

proc isOwnAddress(client: TorrentClient, ip: string, port: uint16): bool =
  ## True if ip:port matches our own listen address (self-connection guard).
  ## Checks listen port against known local/external IPs, loopback addresses,
  ## and IPv4-mapped IPv6 forms to catch dual-stack self-connections via PEX.
  if port != client.config.listenPort:
    return false
  # Loopback addresses (always self)
  if ip == "127.0.0.1" or ip == "::1" or ip == "::ffff:127.0.0.1":
    return true
  # NAT manager knows our local and external IPv4
  if client.natMgr != nil:
    if client.natMgr.localIp.len > 0 and
       (ip == client.natMgr.localIp or ip == "::ffff:" & client.natMgr.localIp):
      return true
    if client.natMgr.externalIp.len > 0 and
       (ip == client.natMgr.externalIp or ip == "::ffff:" & client.natMgr.externalIp):
      return true
  false

proc closePeerStream(client: TorrentClient, key: string) =
  ## Close a peer's stream safely (non-CPS helper to avoid field access in CPS env).
  if key in client.peers:
    client.peers[key].closeStream()

proc shouldAcceptDhtNode(client: TorrentClient, nodeId: NodeId, ip: string): bool =
  ## Accept DHT nodes permissively. BEP 42 secure node IDs are optional;
  ## most real DHT nodes don't implement BEP 42, so strict enforcement
  ## starves the routing table and prevents finding the swarm.
  ## We still generate BEP 42-compliant IDs for ourselves.
  if not isPublicIpv4(ip):
    return true
  # Reject zero/all-ones node IDs (clearly invalid)
  var allZero = true
  var allOnes = true
  for b in nodeId:
    if b != 0: allZero = false
    if b != 0xFF: allOnes = false
  if allZero or allOnes:
    return false
  return true

proc encodeLtDonthave(pieceIdx: int): string =
  ## libtorrent lt_donthave payload: 4-byte piece index (big-endian).
  var payload = ""
  payload.writeUint32BE(uint32(pieceIdx))
  payload

proc decodeLtDonthave(payload: string): int =
  if payload.len < 4:
    return -1
  int(readUint32BE(payload, 0))

proc queuePeerIfNeeded(client: TorrentClient, ip: string, port: uint16,
                       source: PeerSource, pexFlags: uint8 = 0'u8): bool =
  ## Queue a peer for connection. Rejects invalid ports, non-routable IPs
  ## (except LSD which discovers local peers), and enforces MaxPendingPeers cap.
  if port == 0:
    return false  # Invalid port
  if client.isOwnAddress(ip, port):
    return false  # Self-connection — our own listen address
  if client.pendingPeers.len >= MaxPendingPeers:
    return false  # Queue full — drop new peers to bound memory
  # LSD discovers local network peers — skip routable IP check for that source
  if source != srcLsd and not isRoutableIp(ip):
    return false  # Non-routable IP — would fail to connect
  let pKey = peerKey(ip, port)
  if pKey in client.peers:
    return false
  # Skip known seeders when seeding — prevents re-queuing evicted seeders
  # that tracker/DHT/PEX keep rediscovering (the main source of churn).
  if client.state == csSeeding and pKey in client.knownSeeders:
    return false
  if pKey in client.failedPeers:
    if epochTime() - client.failedPeers[pKey] < PeerBackoffSec:
      return false  # In backoff
  var i = 0
  while i < client.pendingPeers.len:
    if client.pendingPeers[i].ip == ip and client.pendingPeers[i].port == port:
      return false
    inc i
  client.pendingPeers.add((ip: ip, port: port, source: source, pexFlags: pexFlags))
  true

proc processPexPeers(client: TorrentClient, peers: seq[CompactPeer],
                     flags: seq[uint8], relayKey: string) =
  ## Process PEX added peers — shared logic for IPv4 and IPv6 (BEP 11).
  var pidx = 0
  while pidx < peers.len:
    let added = peers[pidx]
    let pFlags = if pidx < flags.len: flags[pidx] else: 0'u8
    pidx += 1
    let pk = peerKey(added.ip, added.port)
    if pk in client.pexPeerFlags:
      client.pexPeerFlags[pk] = client.pexPeerFlags[pk] or pFlags
    else:
      client.pexPeerFlags[pk] = pFlags
    if (pFlags and uint8(pexHolepunch)) != 0:
      client.hp.recordRelay(pk, relayKey)
    if pk notin client.peers:
      if client.queuePeerIfNeeded(added.ip, added.port, srcPex, pFlags):
        client.pexPeersReceived += 1

proc findConnectedPeerByEndpoint(client: TorrentClient, ip: string, port: uint16): PeerConn =
  ## Find an active peer using either transport port or advertised ext-handshake port.
  ## Only returns peers in psActive state to avoid stale/connecting entries blocking lookups.
  if ip.len == 0 or port == 0:
    return nil
  let direct = peerKey(ip, port)
  if direct in client.peers:
    let p = client.peers[direct]
    if p.state == psActive:
      return p
  let fpKeys = client.snapshotPeerKeys()
  var fpi = 0
  while fpi < fpKeys.len:
    let fk = fpKeys[fpi]
    fpi += 1
    if fk notin client.peers:
      continue
    let p = client.peers[fk]
    if p.state == psActive and p.ip == ip:
      if p.port == port or p.remoteListenPort == port:
        return p
  nil

proc isPeerQueued(client: TorrentClient, ip: string, port: uint16): bool =
  var i = 0
  while i < client.pendingPeers.len:
    if client.pendingPeers[i].ip == ip and client.pendingPeers[i].port == port:
      return true
    inc i
  false

proc isSelectedPiece(client: TorrentClient, pieceIdx: int): bool =
  if pieceIdx < 0:
    return false
  if client.selectedPiecesMask.len == 0:
    return true
  if pieceIdx >= client.selectedPiecesMask.len:
    return false
  client.selectedPiecesMask[pieceIdx]

proc isHighPriorityPiece(client: TorrentClient, pieceIdx: int): bool =
  if pieceIdx < 0:
    return false
  if pieceIdx >= client.highPriorityPiecesMask.len:
    return false
  client.highPriorityPiecesMask[pieceIdx]

proc buildSelectedPiecesMask(client: TorrentClient) =
  if client.pieceMgr == nil:
    client.selectedPiecesMask.setLen(0)
    client.highPriorityPiecesMask.setLen(0)
    return
  client.selectedPiecesMask = newSeq[bool](client.pieceMgr.totalPieces)
  client.highPriorityPiecesMask = newSeq[bool](client.pieceMgr.totalPieces)
  # Default: select all pieces when no file filter is active.
  if client.selectedFiles.len == 0 and client.filePriorities.len == 0:
    for i in 0 ..< client.selectedPiecesMask.len:
      client.selectedPiecesMask[i] = true
      client.highPriorityPiecesMask[i] = false
    return

  let pieceLen = client.metainfo.info.pieceLength
  var fileStart: int64 = 0
  for fi in 0 ..< client.metainfo.info.files.len:
    let f = client.metainfo.info.files[fi]
    let priority = client.filePriorities.getOrDefault(fi, "normal")
    var selected = client.selectedFiles.len == 0 or fi in client.selectedFiles
    if priority == "skip":
      selected = false
    let isHigh = selected and priority == "high"
    if selected:
      let startPiece = int(fileStart div int64(pieceLen))
      let endOff = fileStart + f.length - 1
      if endOff >= fileStart:
        let endPiece = int(endOff div int64(pieceLen))
        for pi in startPiece .. min(endPiece, client.selectedPiecesMask.len - 1):
          client.selectedPiecesMask[pi] = true
          if isHigh:
            client.highPriorityPiecesMask[pi] = true
    fileStart += f.length

proc applyPrivateProtocolGating(client: TorrentClient) =
  ## BEP 27: private torrents must disable decentralized/discovery extensions.
  if not client.isPrivate:
    return
  client.dhtEnabled = false
  client.config.enableDht = false
  client.config.enablePex = false
  client.config.enableLsd = false
  client.config.enableHolepunch = false

proc sortPendingPeersByPriority(client: TorrentClient, ourIp: string) =
  ## BEP 40: canonical peer priority ordering for connection attempts.
  client.pendingPeers.sort(proc(left, right: PendingPeer): int =
    try:
      cmp(peerPriority(ourIp, left.ip), peerPriority(ourIp, right.ip))
    except Exception:
      0
  )

iterator activePeers*(client: TorrentClient): PeerConn =
  ## Public iterator over active peer connections (for GUI bridge).
  ## Snapshots keys to avoid table-mutation-during-iteration assertions.
  let apKeys = client.snapshotPeerKeys()
  var api = 0
  while api < apKeys.len:
    let ak = apKeys[api]
    api += 1
    if ak in client.peers:
      let peer = client.peers[ak]
      if peer.state == psActive:
        yield peer

proc dhtNodeCount*(client: TorrentClient): int =
  ## Number of nodes in the DHT routing table.
  withSpinLock(client.dhtSpinLock):
    result = client.dhtRoutingTable.totalNodes

const
  IpFailBackoffSec = 120.0      ## Backoff for IPs with multiple failed connections
  IpFailThreshold = 5           ## Number of failed connections before IP-level backoff
  HolepunchDirectUtpTimeoutMs = 8000 ## Give rendezvous attempts longer than normal uTP fallback

proc addPeer(client: TorrentClient, ip: string, port: uint16,
             source: PeerSource = srcUnknown,
             pexFlags: uint8 = 0'u8,
             bypassBackoff: bool = false,
             utpConnectTimeoutMs: int = UtpFallbackTimeoutMs): CpsFuture[bool] {.cps.} =
  let key = peerKey(ip, port)
  if key in client.peers:
    return false
  if client.connectedPeerCount >= client.config.maxPeers and not bypassBackoff:
    return false
  if client.halfOpenCount >= MaxHalfOpen and not bypassBackoff:
    return false
  # Per-IP limit: prevent DHT/PEX spam from a single IP (bypassed for holepunch)
  if not bypassBackoff:
    var ipCount: int = 0
    let ipCheckKeys = client.snapshotPeerKeys()
    var ipci = 0
    while ipci < ipCheckKeys.len:
      let pk = ipCheckKeys[ipci]
      ipci += 1
      if peerIpFromKey(pk) == ip:
        ipCount += 1
        if ipCount >= MaxPerIp:
          return false
  if not bypassBackoff:
    # IP-level backoff: skip IPs that have failed multiple times
    if ip in client.failedIps:
      let ipFail = client.failedIps[ip]
      if ipFail.count >= IpFailThreshold:
        if epochTime() - ipFail.lastFail < IpFailBackoffSec:
          return false
        client.failedIps.del(ip)
    # Skip known seeders when we're seeding (they can't help us and don't need our data)
    if client.state == csSeeding and key in client.knownSeeders:
      return false
    # Check connection backoff (port-level)
    if key in client.failedPeers:
      let failTime: float = client.failedPeers[key]
      if epochTime() - failTime < PeerBackoffSec:
        return false
      client.failedPeers.del(key)  # Backoff expired, allow retry

  let peer = newPeerConn(ip, port, client.metainfo.info.infoHash,
                         client.peerId, client.peerEvents,
                         client.localExtensions)
  client.nextConnGeneration += 1
  peer.connGeneration = client.nextConnGeneration
  peer.source = source
  peer.localMetadataSize = client.rawInfoDict.len
  peer.bandwidthLimiter = client.bandwidthLimiter
  peer.torrentWireDownloaded = addr client.wireDownloaded
  peer.torrentWireUploaded = addr client.wireUploaded
  # Apply configured encryption mode (BEP 10/MSE policy).
  peer.encryptionMode = client.config.encryptionMode
  # Enable uTP with TCP fallback (BEP 29)
  if client.config.enableUtp and client.utpMgr != nil:
    peer.utpManager = client.utpMgr
  if utpConnectTimeoutMs > 0:
    peer.utpConnectTimeoutMs = utpConnectTimeoutMs
  if client.config.listenPort > 0:
    # BEP 10 "p": local TCP listen port.
    # Use actual uTP port if available (may differ from TCP port on ephemeral bind).
    if client.utpMgr != nil and client.utpMgr.port > 0:
      peer.localUtpPort = client.utpMgr.port.uint16
    else:
      peer.localUtpPort = client.config.listenPort
  # Apply PEX capability hints for this endpoint if present.
  var flags = pexFlags
  if key in client.pexPeerFlags:
    flags = flags or client.pexPeerFlags[key]
  if flags != 0:
    client.pexPeerFlags[key] = flags
  peer.pexFlags = flags
  peer.pexHasUtp = (flags and uint8(pexUtp)) != 0
  peer.pexHasHolepunch = (flags and uint8(pexHolepunch)) != 0
  # BEP 40: assign deterministic peer priority when local/public IPv4 is known.
  let localIp = if client.natMgr != nil and client.natMgr.localIp.len > 0:
      client.natMgr.localIp
    else:
      ""
  if localIp.len > 0:
    try:
      peer.priority = peerPriority(localIp, ip)
    except CatchableError:
      peer.priority = btRandU32()
  else:
    peer.priority = btRandU32()
  client.setPeer(key, peer)
  client.halfOpenCount += 1

  # Spawn peer connection as background task
  discard run(peer)
  return true

proc peerIsSeed(client: TorrentClient, peer: PeerConn): bool =
  ## Check if peer has all pieces (is a seeder).
  if client.pieceMgr == nil or peer.peerBitfield.len == 0:
    return false
  countPieces(peer.peerBitfield, client.pieceMgr.totalPieces) == client.pieceMgr.totalPieces

proc markPeerAsSeed(client: TorrentClient, peer: PeerConn) =
  ## Mark a peer for seeder eviction if we're seeding and it's not already marked.
  ## Records the current PEX count so eviction can check if PEX yielded new peers.
  if client.state == csSeeding and peer.markedSeedAt == 0.0:
    peer.markedSeedAt = epochTime()
    peer.pexCountAtMark = client.pexPeersReceived

proc updateAvailability(client: TorrentClient, bitfield: seq[byte], add: bool) =
  if client.pieceMgr == nil:
    return
  for i in 0 ..< min(client.pieceMgr.totalPieces, client.availability.len):
    if not client.isSelectedPiece(i):
      continue
    if hasPiece(bitfield, i):
      if add:
        client.availability[i] += 1
      elif client.availability[i] > 0:
        client.availability[i] -= 1

proc peerHasNeededSelectedPiece(client: TorrentClient, peerBitfield: seq[byte]): bool =
  if client.pieceMgr == nil:
    return false
  for i in 0 ..< min(client.pieceMgr.totalPieces, client.availability.len):
    if not client.isSelectedPiece(i):
      continue
    if hasPiece(peerBitfield, i) and client.pieceMgr.pieces[i].state notin {psOptimistic, psVerified, psComplete}:
      return true
  false

proc unchokedPeerCount(client: TorrentClient): int =
  ## Number of active peers we are currently unchoking.
  let ucKeys = client.snapshotPeerKeys()
  var uci = 0
  while uci < ucKeys.len:
    let uk = ucKeys[uci]
    uci += 1
    if uk in client.peers:
      let p = client.peers[uk]
      if p.state == psActive and not p.amChoking:
        inc result

proc selectHighPriorityPiece(client: TorrentClient, peerBitfield: seq[byte],
                             exclude: HashSet[int] = initHashSet[int]()): int =
  ## Pick a high-priority selected piece the peer has, preferring rarer pieces.
  if client.pieceMgr == nil:
    return -1
  var bestPiece = -1
  var bestAvail = high(int)
  var pi = 0
  while pi < client.pieceMgr.totalPieces:
    if client.isSelectedPiece(pi) and client.isHighPriorityPiece(pi):
      if pi notin exclude and hasPiece(peerBitfield, pi):
        let st = client.pieceMgr.pieces[pi].state
        if st notin {psOptimistic, psVerified, psComplete}:
          let avail = if pi < client.availability.len: client.availability[pi] else: high(int)
          if avail < bestAvail:
            bestAvail = avail
            bestPiece = pi
    inc pi
  bestPiece

proc sendRacingRequests(client: TorrentClient, peer: PeerConn, pKey: string,
                        blocks: seq[tuple[pieceIdx: int, offset: int, length: int]]): CpsVoidFuture {.cps.} =
  ## Register and send racing block requests to a peer.
  var bi: int = 0
  while bi < blocks.len:
    let b = blocks[bi]
    bi += 1
    client.pieceMgr.registerRacer(b.pieceIdx, b.offset, pKey)
    peer.activeRequests.add((pieceIdx: b.pieceIdx, offset: b.offset))
    peer.pendingRequests += 1
    await peer.sendRequest(uint32(b.pieceIdx), uint32(b.offset), uint32(b.length))

proc requestBlocks(client: TorrentClient, peer: PeerConn): CpsVoidFuture {.cps.} =
  ## Request blocks from a peer. In endgame mode, sends duplicate requests
  ## for in-flight blocks to speed up the final pieces.
  if peer.state != psActive or client.pieceMgr == nil:
    return
  if peer.peerChoking and peer.allowedFastSet.len == 0:
    return

  # Build a filtered bitfield view when BEP 53 file selection is active.
  var filteredBf: seq[byte] = peer.peerBitfield
  if client.selectedPiecesMask.len > 0 and peer.peerBitfield.len > 0:
    for pi in 0 ..< min(client.selectedPiecesMask.len, client.pieceMgr.totalPieces):
      if not client.selectedPiecesMask[pi] and hasPiece(filteredBf, pi):
        let byteIdx = pi div 8
        let bitIdx = pi mod 8
        if byteIdx < filteredBf.len:
          filteredBf[byteIdx] = filteredBf[byteIdx] and (not (1'u8 shl (7 - bitIdx)))

  # Endgame mode: send duplicate requests for all remaining requested blocks.
  # Dedup against existing activeRequests to prevent accumulation across
  # repeated requestBlocks calls (refresh loop reconciles pendingRequests
  # from activeRequests.len, so duplicates cause churn).
  let pKey = peerKey(peer.ip, peer.port)
  if client.pieceMgr.inEndgame():
    let egBlocks = client.pieceMgr.getEndgameBlocks(
      filteredBf, MaxPendingRequests - peer.pendingRequests)
    var ei: int = 0
    while ei < egBlocks.len:
      let egb = egBlocks[ei]
      ei += 1
      if not client.isSelectedPiece(egb.pieceIdx):
        continue
      # BEP 6: when choked, only request allowed-fast pieces.
      if peer.peerChoking and uint32(egb.pieceIdx) notin peer.allowedFastSet:
        continue
      if peer.hasActiveRequest(egb.pieceIdx, egb.offset):
        continue
      client.pieceMgr.registerRacer(egb.pieceIdx, egb.offset, pKey)
      peer.activeRequests.add((pieceIdx: egb.pieceIdx, offset: egb.offset))
      peer.pendingRequests += 1
      await peer.sendRequest(uint32(egb.pieceIdx), uint32(egb.offset), uint32(egb.length))
    return

  # Normal mode: rarest-first piece selection.
  # Track pieces whose blocks are all already bsRequested so selectPiece
  # skips them and picks a different piece on the next iteration.
  var skippedPieces: HashSet[int]

  # Reserve 25% of pipeline slots for cross-piece racing when optimistic
  # verification is enabled. Without this, normal blocks fill the entire
  # pipeline (64 slots) leaving no room for racing requests.
  let normalCap = if client.config.enableOptimisticVerification and
                     client.config.enableRacing:
                    MaxPendingRequests * 3 div 4
                  else:
                    MaxPendingRequests

  while peer.pendingRequests < normalCap:
    var pieceIdx = -1
    # BEP 6: prioritize remote suggested pieces.
    if peer.suggestedPieces.len > 0:
      var si = 0
      while si < peer.suggestedPieces.len:
        let sp = peer.suggestedPieces[si]
        si += 1
        if not client.isSelectedPiece(sp):
          continue
        if sp >= client.pieceMgr.totalPieces:
          continue
        if sp in skippedPieces:
          continue
        if peer.peerBitfield.len > 0 and hasPiece(filteredBf, sp):
          let st = client.pieceMgr.pieces[sp].state
          if st notin {psOptimistic, psVerified, psComplete}:
            pieceIdx = sp
            break
      peer.suggestedPieces.setLen(0)

    # BEP 53: prefer explicit high-priority file pieces when unchoked.
    if pieceIdx < 0 and not peer.peerChoking:
      pieceIdx = client.selectHighPriorityPiece(filteredBf, skippedPieces)

    # BEP 6: if choked, only allowed-fast pieces are requestable.
    if pieceIdx < 0 and peer.peerChoking and peer.allowedFastSet.len > 0:
      var afi = 0
      while afi < peer.allowedFastSet.len:
        let afPiece = peer.allowedFastSet[afi].int
        afi += 1
        if afPiece < 0 or afPiece >= client.pieceMgr.totalPieces:
          continue
        if not client.isSelectedPiece(afPiece):
          continue
        if afPiece in skippedPieces:
          continue
        if peer.peerBitfield.len > 0 and hasPiece(filteredBf, afPiece):
          let st = client.pieceMgr.pieces[afPiece].state
          if st notin {psOptimistic, psVerified, psComplete}:
            pieceIdx = afPiece
            break
    elif pieceIdx < 0:
      pieceIdx = client.pieceMgr.selectPiece(filteredBf, client.availability, skippedPieces)

    if pieceIdx < 0:
      break
    if not client.isSelectedPiece(pieceIdx):
      break

    let blocks = client.pieceMgr.getNeededBlocks(pieceIdx, normalCap - peer.pendingRequests)
    if blocks.len == 0:
      # All empty blocks are already bsRequested. Try racing if enabled
      # and piece is partial (close to completion) or rare (availability <= 2).
      if client.config.enableRacing and
         client.pieceMgr.pieces[pieceIdx].state == psPartial:
        let raceBlocks = client.pieceMgr.getRaceableBlocks(
          pieceIdx, pKey, peer.peerBitfield,
          normalCap - peer.pendingRequests,
          includeVerifiable = client.config.enableOptimisticVerification)
        if raceBlocks.len > 0:
          await client.sendRacingRequests(peer, pKey, raceBlocks)
        else:
          skippedPieces.incl(pieceIdx)
      else:
        skippedPieces.incl(pieceIdx)
      continue

    for blk in blocks:
      client.pieceMgr.markBlockRequested(pieceIdx, blk.offset)
      client.pieceMgr.registerRacer(pieceIdx, blk.offset, pKey)
      peer.activeRequests.add((pieceIdx: pieceIdx, offset: blk.offset))
      peer.pendingRequests += 1
      await peer.sendRequest(uint32(pieceIdx), uint32(blk.offset), uint32(blk.length))

    # Race already-requested blocks from other peers.
    # For rare pieces (avail <= 2): race for download speed.
    # For optimistic verification: also race to accumulate agreement data.
    if client.config.enableRacing and peer.pendingRequests < normalCap:
      let avail = if pieceIdx < client.availability.len: client.availability[pieceIdx]
                  else: high(int)
      if avail <= 2 or client.config.enableOptimisticVerification:
        let raceBlocks = client.pieceMgr.getRaceableBlocks(
          pieceIdx, pKey, peer.peerBitfield,
          normalCap - peer.pendingRequests,
          includeVerifiable = client.config.enableOptimisticVerification)
        if raceBlocks.len > 0:
          await client.sendRacingRequests(peer, pKey, raceBlocks)

  # Cross-piece racing: fill remaining pipeline slots with blocks from OTHER
  # partial pieces to accumulate agreement data for optimistic verification.
  if client.config.enableOptimisticVerification and
     client.config.enableRacing and
     peer.pendingRequests < MaxPendingRequests:
    let crossBlocks = client.pieceMgr.getCrossRaceBlocks(
      pKey, peer.peerBitfield,
      MaxPendingRequests - peer.pendingRequests)
    if crossBlocks.len > 0:
      await client.sendRacingRequests(peer, pKey, crossBlocks)

proc requestMetadata(client: TorrentClient, peerKey: string): CpsVoidFuture {.cps.} =
  ## Request needed metadata pieces from a peer (BEP 9).
  if client.metadataExchange == nil:
    return
  if peerKey notin client.peers:
    return
  let peer: PeerConn = client.peers[peerKey]
  let needed: seq[int] = client.metadataExchange.getNeededPieces()
  var ni: int = 0
  while ni < needed.len:
    let pieceIdx: int = needed[ni]
    ni += 1
    let reqPayload: string = encodeMetadataRequest(pieceIdx)
    await peer.sendExtended(UtMetadataName, reqPayload)

proc sendLtDonthaveToPeers(client: TorrentClient, pieceIdx: int): CpsVoidFuture {.cps.} =
  if pieceIdx < 0:
    return
  let payload = encodeLtDonthave(pieceIdx)
  let peerKeys = client.snapshotPeerKeys()
  var ki = 0
  while ki < peerKeys.len:
    let pk = peerKeys[ki]
    inc ki
    if pk notin client.peers:
      continue
    let p = client.peers[pk]
    if p.state != psActive:
      continue
    if p.extensions.supportsExtension(ExtLtDontHave):
      await p.sendExtended(ExtLtDontHave, payload)

proc setFilePriority*(client: TorrentClient, fileIndex: int,
                      priority: string): CpsVoidFuture {.cps.} =
  ## BEP 53: apply per-file priority and refresh piece scheduling masks.
  if fileIndex < 0:
    return
  var pr = priority.toLowerAscii
  if pr notin ["high", "normal", "skip"]:
    pr = "normal"

  if pr == "normal":
    if fileIndex in client.filePriorities:
      client.filePriorities.del(fileIndex)
  else:
    client.filePriorities[fileIndex] = pr

  if client.selectedFiles.len > 0:
    if pr == "skip":
      client.selectedFiles.excl(fileIndex)
    else:
      client.selectedFiles.incl(fileIndex)

  client.buildSelectedPiecesMask()

  if client.pieceMgr == nil:
    return

  # Rebuild availability from scratch: newly-selected pieces may have had
  # zero availability despite connected peers having them.
  for i in 0 ..< client.availability.len:
    client.availability[i] = 0
  let peerKeys = client.snapshotPeerKeys()
  var avki = 0
  while avki < peerKeys.len:
    let avk = peerKeys[avki]
    avki += 1
    if avk in client.peers:
      let ap = client.peers[avk]
      if ap.state == psActive and ap.peerBitfield.len > 0:
        client.updateAvailability(ap.peerBitfield, true)

  # Reuse peerKeys for the next loop (already collected)
  var ki = 0
  while ki < peerKeys.len:
    let pk = peerKeys[ki]
    inc ki
    if pk notin client.peers:
      continue
    let p = client.peers[pk]
    if p.state != psActive:
      continue

    # Drop in-flight requests for pieces that are no longer selected.
    # Send cancel messages and decrement pendingRequests to keep pipeline in sync.
    var ri = 0
    while ri < p.activeRequests.len:
      let req = p.activeRequests[ri]
      if not client.isSelectedPiece(req.pieceIdx):
        # Look up block length for cancel message (default to BlockSize if unknown)
        var blkLen = client.pieceMgr.blockLength(req.pieceIdx, req.offset)
        if blkLen <= 0: blkLen = BlockSize
        # Send cancel to peer so it stops sending unwanted data
        discard p.commands.trySend(cancelMsg(uint32(req.pieceIdx), uint32(req.offset), uint32(blkLen)))
        client.pieceMgr.cancelBlockRequest(req.pieceIdx, req.offset)
        p.activeRequests.del(ri)
        p.pendingRequests = max(0, p.pendingRequests - 1)
      else:
        inc ri

    if p.peerBitfield.len > 0:
      let hasNeeded = client.peerHasNeededSelectedPiece(p.peerBitfield)
      if hasNeeded and not p.amInterested:
        await p.sendInterested()
      elif not hasNeeded and p.amInterested:
        await p.sendNotInterested()
      if hasNeeded and not p.peerChoking:
        await client.requestBlocks(p)

proc recheckAllPieces*(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Reset all local pieces to empty and notify peers via lt_donthave.
  if client.pieceMgr == nil:
    return

  var invalidated: seq[int]
  for pi in 0 ..< client.pieceMgr.totalPieces:
    let st = client.pieceMgr.pieces[pi].state
    if st in {psOptimistic, psVerified, psComplete}:
      invalidated.add(pi)
    client.pieceMgr.pieces[pi].state = psEmpty
    client.pieceMgr.pieces[pi].receivedBytes = 0
    client.pieceMgr.pieces[pi].consensus = PieceConsensus()
    for blk in client.pieceMgr.pieces[pi].blocks.mitems:
      blk.state = bsEmpty
  client.pieceMgr.completedCount = 0
  client.pieceMgr.verifiedCount = 0
  client.pieceMgr.optimisticCount = 0
  client.pieceMgr.downloaded = 0
  client.optimisticVerifyQueue.clear()

  if client.state == csSeeding:
    client.state = csDownloading

  let peerKeys = client.snapshotPeerKeys()
  var ki = 0
  while ki < peerKeys.len:
    let pk = peerKeys[ki]
    inc ki
    if pk in client.peers:
      let p = client.peers[pk]
      p.pendingRequests = 0
      p.activeRequests.setLen(0)

  var ii = 0
  while ii < invalidated.len:
    await client.sendLtDonthaveToPeers(invalidated[ii])
    inc ii

proc verifyPieceHash(pm: PieceManager, pieceIdx: int): CpsFuture[bool] =
  ## Compute SHA1 hash of a completed piece and return whether it matches.
  ## Offloads the computation to the blocking pool when the MT runtime is
  ## active; otherwise runs synchronously. Does NOT modify piece state —
  ## the caller must call applyVerification under the mutex.
  if pieceIdx < 0 or pieceIdx >= pm.totalPieces:
    return completedFuture(false)
  if pm.pieces[pieceIdx].state notin {psComplete, psOptimistic}:
    return completedFuture(false)
  let expected = pm.info.pieceHash(pieceIdx)
  let data = pm.pieces[pieceIdx].data[0 ..< pm.pieces[pieceIdx].totalLength]
  let rt = currentRuntime().runtime
  if rt != nil and rt.flavor == rfMultiThread:
    let hashFut = spawnBlocking(proc(): bool {.gcsafe.} =
      {.cast(gcsafe).}:
        sha1mod.sha1(data) == expected
    )
    let resultFut = newCpsFuture[bool]()
    hashFut.addCallback(proc() =
      {.cast(gcsafe).}:
        resultFut.complete(hashFut.read())
    )
    return resultFut
  else:
    let hashMatch = sha1mod.sha1(data) == expected
    return completedFuture(hashMatch)

proc tryUtpReconnect(client: TorrentClient, key: string): CpsVoidFuture {.cps.} =
  ## Attempt to upgrade a TCP peer connection to uTP for lower overhead.
  ## Snapshots transferable state, closes TCP, and re-adds the peer with
  ## uTP preference. On success, pekConnected restores the snapshot.
  ## On failure, pekDisconnected re-queues for TCP.
  if key notin client.peers:
    return
  let peer: PeerConn = client.peers[key]
  if peer.transport != ptTcp or peer.state != psActive:
    return
  if client.utpMgr == nil or not client.config.enableUtp:
    return
  if key in client.utpReconnectInProgress:
    return
  let now: float = epochTime()
  if key in client.utpReconnectCooldown:
    if now - client.utpReconnectCooldown[key] < UtpReconnectCooldownSec:
      return

  btDebug "[UTP-RECON] Upgrading TCP peer to uTP: ", key

  # 1. Snapshot transferable state
  let snapshot = UtpReconnectSnapshot(
    peerBitfield: peer.peerBitfield,
    extensions: peer.extensions,
    remotePeerId: peer.remotePeerId,
    peerInterested: peer.peerInterested,
    amInterested: peer.amInterested,
    peerUploadOnly: peer.peerUploadOnly,
    isSuperSeeder: peer.isSuperSeeder,
    source: peer.source,
    bytesDownloaded: peer.bytesDownloaded,
    bytesUploaded: peer.bytesUploaded,
    connectedAt: peer.connectedAt,
    priority: peer.priority,
    pexFlags: peer.pexFlags or uint8(pexUtp)
  )
  client.utpReconnectState[key] = snapshot
  client.utpReconnectInProgress.incl(key)
  client.utpReconnectCooldown[key] = now

  # 2. Cancel active requests and unregister racers
  if client.pieceMgr != nil and peer.activeRequests.len > 0:
    var ri = 0
    while ri < peer.activeRequests.len:
      let req = peer.activeRequests[ri]
      client.pieceMgr.unregisterRacer(req.pieceIdx, req.offset, key)
      ri += 1
    client.pieceMgr.cancelPeerRequests(peer.activeRequests)
    peer.activeRequests.setLen(0)
    peer.pendingRequests = 0

  # 3. Remove bitfield contribution from availability
  if peer.peerBitfield.len > 0:
    client.updateAvailability(peer.peerBitfield, false)

  # 4. Close the TCP stream (sets state to psDisconnected)
  peer.closeStream()

  # 5. Remove from peers table, adjust counters
  let peerIp: string = peer.ip
  let peerPort: uint16 = peer.port
  client.delPeer(key)
  if peer.wasConnected:
    if client.connectedPeerCount > 0:
      client.connectedPeerCount -= 1
  else:
    if client.halfOpenCount > 0:
      client.halfOpenCount -= 1

  # 6. Re-add with uTP preference (bypassBackoff skips backoff + limit checks)
  let started: bool = await client.addPeer(peerIp, peerPort, snapshot.source,
    snapshot.pexFlags, bypassBackoff = true,
    utpConnectTimeoutMs = UtpPreferredTimeoutMs)

  if not started:
    btDebug "[UTP-RECON] Failed to start uTP reconnect for ", key
    client.utpReconnectInProgress.excl(key)
    client.utpReconnectState.del(key)
    # Re-queue for TCP (strip uTP flag so it falls back to TCP-only)
    discard client.queuePeerIfNeeded(peerIp, peerPort, snapshot.source,
      snapshot.pexFlags and (not uint8(pexUtp)))

proc tryOptimisticMark(client: TorrentClient, pieceIdx: int) =
  ## Check if a completed piece qualifies for optimistic verification.
  ## If so, mark it and queue for background SHA1 confirmation.
  if client.config.enableOptimisticVerification and
     pieceIdx >= 0 and pieceIdx < client.pieceMgr.totalPieces and
     client.pieceMgr.pieces[pieceIdx].state == psComplete and
     client.pieceMgr.meetsOptimisticThreshold(pieceIdx,
       client.config.optimisticMinAgreePeers,
       client.config.optimisticMinAgreeBlocks):
    client.pieceMgr.markOptimistic(pieceIdx)
    client.optimisticVerifyQueue.addLast(pieceIdx)

proc onPieceVerified(client: TorrentClient, pieceIdx: int,
                     excludeKey: string): CpsVoidFuture {.cps.} =
  ## Common path after a piece has been accepted (optimistic or SHA1-verified).
  ## Assumes mutex is held. Announces HAVE, clears race entries, prunes
  ## stale requests, refills pipelines, checks completion + seed transition.
  await client.events.send(ClientEvent(kind: cekPieceVerified,
    pieceIndex: pieceIdx,
    pieceState: client.pieceMgr.pieces[pieceIdx].state))

  # Collect peer keys once — reused for HAVE broadcast, pruning, and seed transition.
  let peerKeys = client.snapshotPeerKeys()

  # Announce HAVE to all peers and send endgame cancels.
  let isEndgame: bool = client.pieceMgr.inEndgame()
  var ki: int = 0
  while ki < peerKeys.len:
    let pk: string = peerKeys[ki]
    ki += 1
    if pk in client.peers:
      let p: PeerConn = client.peers[pk]
      if p.state == psActive:
        discard p.commands.trySend(haveMsg(uint32(pieceIdx)))
        if isEndgame:
          for blk in client.pieceMgr.pieces[pieceIdx].blocks:
            discard p.commands.trySend(cancelMsg(uint32(pieceIdx), uint32(blk.offset), uint32(blk.length)))

  client.pieceMgr.clearPieceRaceEntries(pieceIdx)

  # Prune stale activeRequests for this piece and refill pipelines.
  var pri: int = 0
  while pri < peerKeys.len:
    let prk: string = peerKeys[pri]
    pri += 1
    if prk in client.peers:
      let prPeer: PeerConn = client.peers[prk]
      var pruned: bool = false
      var ari: int = prPeer.activeRequests.len - 1
      while ari >= 0:
        if prPeer.activeRequests[ari].pieceIdx == pieceIdx:
          prPeer.activeRequests.del(ari)
          prPeer.pendingRequests = max(0, prPeer.pendingRequests - 1)
          pruned = true
        ari -= 1
      if (pruned or prPeer.pendingRequests == 0) and
         prPeer.state == psActive and not prPeer.peerChoking and
         prPeer.pendingRequests < MaxPendingRequests and prk != excludeKey:
        await client.requestBlocks(prPeer)

  if client.pieceMgr.isComplete:
    client.state = csSeeding
    await client.events.send(ClientEvent(kind: cekCompleted))
    # Mark seeders for eviction and unchoke interested leechers.
    var unchokedCount = 0
    var msi = 0
    while msi < peerKeys.len:
      let msk = peerKeys[msi]
      msi += 1
      if msk in client.peers:
        let sp = client.peers[msk]
        if sp.state == psActive:
          if client.peerIsSeed(sp):
            client.markPeerAsSeed(sp)
          elif sp.peerInterested and sp.amChoking and unchokedCount < MaxUnchokedPeers:
            btDebug "[SEED-DBG] Seed-transition unchoke for ", msk
            await sp.sendUnchoke()
            unchokedCount += 1

proc handlePeerEvent(client: TorrentClient, evt: PeerEvent): CpsVoidFuture {.cps.} =
  let key = evt.peerAddr

  case evt.kind
  of pekConnected:
    # Guard against stale events from a replaced peer.
    if key in client.peers and client.peers[key].connGeneration != evt.connGeneration:
      btDebug "[PEER] Ignoring stale pekConnected for ", key, " (event gen=", evt.connGeneration, " current gen=", client.peers[key].connGeneration, ")"
      return
    # Transition from half-open to active
    if client.halfOpenCount > 0:
      client.halfOpenCount -= 1
    client.connectedPeerCount += 1
    if key in client.peers:
      client.peers[key].wasConnected = true
    # Restore state from uTP reconnection snapshot if available.
    if key in client.utpReconnectState and key in client.peers:
      let snap = client.utpReconnectState[key]
      let peer = client.peers[key]
      client.utpReconnectInProgress.excl(key)
      client.utpReconnectState.del(key)
      # Verify same peer identity — reject if a different peer answered.
      if peer.remotePeerId == snap.remotePeerId:
        btDebug "[UTP-RECON] Successfully upgraded ", key, " to uTP — restoring state"
        if snap.peerBitfield.len > 0:
          peer.peerBitfield = snap.peerBitfield
          client.updateAvailability(snap.peerBitfield, true)
        peer.bytesDownloaded = snap.bytesDownloaded
        peer.bytesUploaded = snap.bytesUploaded
        peer.connectedAt = snap.connectedAt
        peer.priority = snap.priority
        peer.peerUploadOnly = snap.peerUploadOnly
        peer.isSuperSeeder = snap.isSuperSeeder
        peer.peerInterested = snap.peerInterested
        peer.source = snap.source
      else:
        btDebug "[UTP-RECON] Peer ID mismatch after uTP reconnect for ", key, " — treating as new peer"
    if key in client.peers:
      let peer = client.peers[key]
      if peer.source == srcHolepunch or
         (peer.transport == ptUtp and
          (client.hp.isBackedOff(key) or client.hp.isInFlight(key))):
        client.hp.recordSuccess(key)
        if peer.source != srcHolepunch:
          peer.source = srcHolepunch
        btDebug "[HP] SUCCESS: connected to ", key, " (source=", peer.source, " transport=", peer.transport, ")"
      else:
        client.hp.clearInFlight(key)
      if client.pieceMgr != nil:
        # BEP 3: BITFIELD must be the first message after handshake.
        # BEP 6: HAVE_ALL/HAVE_NONE replace BITFIELD (never send both).
        if peer.peerSupportsFastExt and
             client.pieceMgr.verifiedCount + client.pieceMgr.optimisticCount == client.pieceMgr.totalPieces:
          btDebug "[SEED-DBG] Sending HAVE_ALL to ", key, " (verified=", client.pieceMgr.verifiedCount, "/", client.pieceMgr.totalPieces, ")"
          await peer.commands.send(haveAllMsg())
        elif peer.peerSupportsFastExt and client.pieceMgr.verifiedCount == 0:
          btDebug "[SEED-DBG] Sending HAVE_NONE to ", key
          await peer.commands.send(haveNoneMsg())
        else:
          let bf = client.pieceMgr.generateBitfield()
          btDebug "[SEED-DBG] Sending BITFIELD to ", key, " (verified=", client.pieceMgr.verifiedCount, "/", client.pieceMgr.totalPieces, ", bf.len=", bf.len, ")"
          await peer.sendBitfield(bf)
        # BEP 6: allowed-fast set AFTER bitfield/have_all/have_none.
        if peer.peerSupportsFastExt:
          let afSet = generateAllowedFastSet(client.metainfo.info.infoHash, peer.ip,
                                             client.pieceMgr.totalPieces, 10)
          var afIdx: int = 0
          while afIdx < afSet.len:
            let afPiece: int = afSet[afIdx].int
            afIdx += 1
            # Only advertise pieces we actually have (verified or optimistic)
            if afPiece >= 0 and afPiece < client.pieceMgr.totalPieces and
               client.pieceMgr.pieces[afPiece].state in {psOptimistic, psVerified}:
              peer.outboundAllowedFast.add(uint32(afPiece))
              await peer.sendAllowedFast(uint32(afPiece))
        # Express interest if peer has pieces we need
        if peer.peerBitfield.len > 0:
          if client.peerHasNeededSelectedPiece(peer.peerBitfield):
            await peer.sendInterested()
        # When seeding, proactively unchoke new peers so they can start
        # requesting as soon as they process our BITFIELD/HAVE_ALL.
        # This eliminates the round-trip wait for INTERESTED → UNCHOKE
        # and avoids the window where unchokeLoop could miss them.
        if client.state == csSeeding and peer.amChoking:
          if client.unchokedPeerCount < MaxUnchokedPeers:
            btDebug "[SEED-DBG] Proactive seed unchoke for ", key, " (unchokedCount=", client.unchokedPeerCount, ")"
            await peer.sendUnchoke()
      else:
        # Magnet link: request metadata
        await client.requestMetadata(key)

  of pekDisconnected:
    # Guard against stale disconnect events from a replaced peer (e.g.,
    # simultaneous-open in handleIncomingPeer replaced the old peer at this
    # key but the old run() coroutine later fires pekDisconnected).
    # Use generation counter for identity: if the peer in the table has a
    # different generation than the event, this event is from an old peer.
    if key in client.peers:
      let peer = client.peers[key]
      if peer.connGeneration != evt.connGeneration:
        btDebug "[PEER] Ignoring stale pekDisconnected for ", key, " (event gen=", evt.connGeneration, " current gen=", peer.connGeneration, ")"
        return
      btDebug "[SEED-DBG] pekDisconnected from ", key, " peerInterested=", peer.peerInterested, " amChoking=", peer.amChoking, " bytesUp=", peer.bytesUploaded, " bytesDn=", peer.bytesDownloaded
    if client.hp.isInFlight(key):
      btDebug "[HP] FAILED: ", key, " disconnected while in-flight"
    client.hp.recordDisconnect(key)
    client.pexPeerFlags.del(key)
    var freedBlocks = false
    if key in client.peers:
      let peer = client.peers[key]
      # Unregister from race tracker before cancelling requests
      if client.pieceMgr != nil and peer.activeRequests.len > 0:
        for req in peer.activeRequests:
          client.pieceMgr.unregisterRacer(req.pieceIdx, req.offset, key)
        client.pieceMgr.cancelPeerRequests(peer.activeRequests)
        peer.activeRequests.setLen(0)
        freedBlocks = true
      if peer.peerBitfield.len > 0:
        client.updateAvailability(peer.peerBitfield, false)
      # Track failed peer for backoff — skip for peers that transferred data,
      # holepunch peers (gated by holepunchBackoff), and uTP reconnection
      # disconnects (deliberate transport upgrade, not a failure).
      if peer.bytesDownloaded == 0 and peer.bytesUploaded == 0 and
         peer.source != srcHolepunch and
         key notin client.utpReconnectInProgress:
        client.failedPeers[key] = epochTime()
        # Track IP-level failures
        let peerIp: string = peer.ip
        if peerIp in client.failedIps:
          var ipf = client.failedIps[peerIp]
          ipf.count += 1
          ipf.lastFail = epochTime()
          client.failedIps[peerIp] = ipf
        else:
          client.failedIps[peerIp] = (count: 1, lastFail: epochTime())
      let disconnPeerIp: string = peer.ip
      let disconnPeerPort: uint16 = peer.port
      client.delPeer(key)
      if peer.wasConnected:
        # Was fully connected (pekConnected fired) → decrement connectedPeerCount
        if client.connectedPeerCount > 0:
          client.connectedPeerCount -= 1
      else:
        # Never completed handshake — still counted as half-open
        if client.halfOpenCount > 0:
          client.halfOpenCount -= 1
      # Handle uTP reconnection failure: re-queue for TCP connection
      if key in client.utpReconnectInProgress:
        btDebug "[UTP-RECON] uTP reconnect failed for ", key, " — falling back to TCP"
        client.utpReconnectInProgress.excl(key)
        if key in client.utpReconnectState:
          let snap = client.utpReconnectState[key]
          client.utpReconnectState.del(key)
          discard client.queuePeerIfNeeded(disconnPeerIp, disconnPeerPort,
            snap.source, snap.pexFlags and (not uint8(pexUtp)))
    # Re-issue freed blocks to other unchoked peers immediately
    if freedBlocks and client.pieceMgr != nil:
      let discKeys = client.snapshotPeerKeys()
      var di: int = 0
      while di < discKeys.len:
        let dk: string = discKeys[di]
        di += 1
        if dk notin client.peers:
          continue
        let other: PeerConn = client.peers[dk]
        if other.state == psActive and not other.peerChoking:
          await client.requestBlocks(other)
  of pekHandshake:
    # Self-connection detection: if remote peer ID matches ours, disconnect.
    # This catches all self-connections regardless of address family or NAT.
    if evt.hsPeerId == client.peerId:
      btDebug "[SELF] Detected self-connection to ", key, " — disconnecting"
      if key in client.peers:
        client.closePeerStream(key)
        client.delPeer(key)
        if client.halfOpenCount > 0:
          client.halfOpenCount -= 1
        # Add to failed peers to prevent immediate reconnection
        client.failedPeers[key] = epochTime()

  of pekChoke:
    if key in client.peers:
      let peer = client.peers[key]
      peer.peerChoking = true
      # Unregister from race tracker, then cancel pending requests
      var hadRequests = false
      if client.pieceMgr != nil and peer.activeRequests.len > 0:
        for req in peer.activeRequests:
          client.pieceMgr.unregisterRacer(req.pieceIdx, req.offset, key)
        client.pieceMgr.cancelPeerRequests(peer.activeRequests)
        peer.activeRequests.setLen(0)
        hadRequests = true
      peer.pendingRequests = 0
      # Re-issue freed blocks to other unchoked peers immediately
      if hadRequests and client.pieceMgr != nil:
        let chokeKeys = client.snapshotPeerKeys()
        var ci: int = 0
        while ci < chokeKeys.len:
          let ck: string = chokeKeys[ci]
          ci += 1
          if ck == key or ck notin client.peers:
            continue
          let other: PeerConn = client.peers[ck]
          if other.state == psActive and not other.peerChoking:
            await client.requestBlocks(other)

  of pekUnchoke:
    if key in client.peers:
      let peer = client.peers[key]
      peer.peerChoking = false
      await client.requestBlocks(peer)

  of pekInterested:
    # Opportunistic unchoke to reduce startup latency for new leechers.
    # Works in both seeding and downloading states — tit-for-tat still
    # governs steady-state via the periodic unchokeLoop.
    if key in client.peers:
      client.peers[key].peerInterested = true
    btDebug "[SEED-DBG] pekInterested from ", key, " state=", client.state, " peerInterested=", (if key in client.peers: $client.peers[key].peerInterested else: "N/A")
    if client.state in {csDownloading, csSeeding} and key in client.peers:
      let peer = client.peers[key]
      if peer.state == psActive and peer.peerInterested and peer.amChoking:
        if client.unchokedPeerCount < MaxUnchokedPeers:
          btDebug "[SEED-DBG] Eagerly unchoking ", key, " (unchokedCount=", client.unchokedPeerCount, ")"
          await peer.sendUnchoke()

  of pekNotInterested:
    discard

  of pekHave:
    if key in client.peers and client.pieceMgr != nil:
      let peer = client.peers[key]
      let idx = evt.haveIndex.int
      # Update peer bitfield if not set yet (super seeder sends HAVE, not BITFIELD)
      if peer.peerBitfield.len == 0 and client.pieceMgr != nil:
        peer.peerBitfield = newBitfield(client.pieceMgr.totalPieces)
        peer.isSuperSeeder = true
      # Only increment availability if peer didn't already have this piece
      let alreadyHad = idx < client.pieceMgr.totalPieces and
                        peer.peerBitfield.len > 0 and
                        hasPiece(peer.peerBitfield, idx)
      if not alreadyHad and idx < client.availability.len:
        client.availability[idx] += 1
      if idx < client.pieceMgr.totalPieces:
        setPiece(peer.peerBitfield, idx)
      # Check if we need this piece
      if not peer.amInterested:
        if idx < client.pieceMgr.totalPieces and
           client.isSelectedPiece(idx) and
           client.pieceMgr.pieces[idx].state notin {psOptimistic, psVerified, psComplete}:
          await peer.sendInterested()
      # Request blocks if unchoked and interested
      if not peer.peerChoking:
        await client.requestBlocks(peer)
      # Check if peer became a seeder (has all pieces)
      if client.peerIsSeed(peer):
        client.markPeerAsSeed(peer)

  of pekBitfield:
    if key in client.peers and client.pieceMgr != nil:
      let peer = client.peers[key]
      peer.peerBitfield = evt.bitfield  # Set here under mutex (not in readLoop)
      let peerHave = countPieces(peer.peerBitfield, client.pieceMgr.totalPieces)
      btDebug "[SEED-DBG] pekBitfield from ", key, " peerHas=", peerHave, "/", client.pieceMgr.totalPieces
      client.updateAvailability(evt.bitfield, true)
      # Check interest
      if client.peerHasNeededSelectedPiece(peer.peerBitfield) and not peer.amInterested:
        await peer.sendInterested()
      # Request blocks if unchoked
      if not peer.peerChoking:
        await client.requestBlocks(peer)
      # Check if peer is a seeder (has all pieces)
      if client.peerIsSeed(peer):
        client.markPeerAsSeed(peer)

  of pekBlock:
    if client.pieceMgr == nil:
      return  # Metadata not yet received (magnet link)
    let pieceIdx = evt.blockIndex.int
    let offset = evt.blockBegin.int
    # Check if this block was actually requested (in activeRequests).
    # Unsolicited or canceled blocks are rejected to prevent piece state corruption.
    var wasRequested = false
    if key in client.peers:
      let peer = client.peers[key]
      var ri = 0
      while ri < peer.activeRequests.len:
        if peer.activeRequests[ri].pieceIdx == pieceIdx and
           peer.activeRequests[ri].offset == offset:
          wasRequested = true
          break
        ri += 1
    if not wasRequested:
      # Block not in activeRequests — possibly a racing duplicate arriving
      # after CANCEL. Check agreement for optimistic verification.
      if pieceIdx >= 0 and pieceIdx < client.pieceMgr.totalPieces and
         client.pieceMgr.pieces[pieceIdx].state in {psPartial, psComplete}:
        discard client.pieceMgr.checkBlockAgreement(pieceIdx, offset,
          evt.blockData.toOpenArrayByte(0, evt.blockData.len - 1))
        client.tryOptimisticMark(pieceIdx)
    else:
      let prevDownloaded = client.pieceMgr.downloaded
      let complete = client.pieceMgr.receiveBlock(pieceIdx, offset, evt.blockData)
      let accepted = client.pieceMgr.downloaded > prevDownloaded

      # Racing duplicate: check agreement even though the data wasn't stored.
      if not accepted and not complete and
         pieceIdx >= 0 and pieceIdx < client.pieceMgr.totalPieces and
         client.pieceMgr.pieces[pieceIdx].state in {psPartial, psComplete}:
        discard client.pieceMgr.checkBlockAgreement(pieceIdx, offset,
          evt.blockData.toOpenArrayByte(0, evt.blockData.len - 1))
        client.tryOptimisticMark(pieceIdx)

      # Cancel racing duplicates: send CANCEL to other peers that requested
      # this block, remove from their activeRequests, and clear the race entry.
      if accepted:
        let racingPeers = client.pieceMgr.getRacingPeers(pieceIdx, offset)
        if racingPeers.len > 0:
          let blkLen = client.pieceMgr.blockLength(pieceIdx, offset)
          var rpi = 0
          while rpi < racingPeers.len:
            let rpk = racingPeers[rpi]
            rpi += 1
            if rpk == key:
              continue  # Skip the peer that delivered this block
            if rpk in client.peers:
              let rp = client.peers[rpk]
              discard rp.commands.trySend(cancelMsg(uint32(pieceIdx), uint32(offset), uint32(blkLen)))
              discard rp.removeActiveRequest(pieceIdx, offset)
          client.pieceMgr.clearRaceEntry(pieceIdx, offset)

      if complete:
        let useOptimistic = client.config.enableOptimisticVerification and
          client.pieceMgr.meetsOptimisticThreshold(pieceIdx,
            client.config.optimisticMinAgreePeers,
            client.config.optimisticMinAgreeBlocks)

        # Remove completing block from this peer's activeRequests
        if key in client.peers:
          discard client.peers[key].removeActiveRequest(pieceIdx, offset)

        if useOptimistic:
          # Optimistic path: skip SHA1, write to disk, queue background verification
          client.pieceMgr.markOptimistic(pieceIdx)
          let pieceLen = client.pieceMgr.pieces[pieceIdx].totalLength
          let writeData = client.pieceMgr.pieces[pieceIdx].data[0 ..< pieceLen]
          unlock(client.mtx)
          var writeError: string = ""
          try:
            client.storageMgr.writePiece(pieceIdx, writeData)
          except CatchableError as e:
            writeError = e.msg
          await lock(client.mtx)
          if writeError.len > 0:
            btDebug "ERROR: writePiece failed for piece ", pieceIdx, ": ", writeError
            client.pieceMgr.resetPiece(pieceIdx)
          else:
            client.optimisticVerifyQueue.addLast(pieceIdx)
            await client.onPieceVerified(pieceIdx, key)

        else:
          # Normal SHA1 verification path
          unlock(client.mtx)
          let valid: bool = await verifyPieceHash(client.pieceMgr, pieceIdx)
          await lock(client.mtx)
          # Guard against concurrent state change (e.g. racing marked optimistic)
          if client.pieceMgr.pieces[pieceIdx].state == psComplete:
            if valid:
              client.pieceMgr.applyVerification(pieceIdx, true)
            else:
              client.pieceMgr.failAndResetPiece(pieceIdx)
          if valid and client.pieceMgr.pieces[pieceIdx].state == psVerified:
            let pieceData = client.pieceMgr.getPieceData(pieceIdx)
            unlock(client.mtx)
            var writeError: string = ""
            try:
              client.storageMgr.writePiece(pieceIdx, pieceData)
            except CatchableError as e:
              writeError = e.msg
            await lock(client.mtx)
            if writeError.len > 0:
              btDebug "ERROR: writePiece failed for piece ", pieceIdx, ": ", writeError
              client.pieceMgr.resetPiece(pieceIdx)
            else:
              await client.onPieceVerified(pieceIdx, key)
          elif client.pieceMgr.pieces[pieceIdx].state == psEmpty:
            # Piece was reset by failAndResetPiece above — notify peers
            await client.sendLtDonthaveToPeers(pieceIdx)
      else:
        # Block accepted but piece not yet complete — remove from activeRequests now
        if key in client.peers:
          discard client.peers[key].removeActiveRequest(pieceIdx, offset)

      # Only request more blocks if this block was actually accepted.
      # Rejected blocks (duplicates, already verified pieces) skip the expensive
      # O(totalPieces) selectPiece scan to avoid CPU saturation.
      if accepted and key in client.peers:
        let peer = client.peers[key]
        await client.requestBlocks(peer)

  of pekRequest:
    # Peer requests a block from us
    btDebug "[SEED-DBG] pekRequest from ", key, " piece=", evt.reqIndex, " offset=", evt.reqBegin, " len=", evt.reqLength
    if key in client.peers and client.pieceMgr != nil and client.storageMgr != nil:
      let peer = client.peers[key]
      let pieceIdx = evt.reqIndex.int
      let reqBegin = evt.reqBegin.int
      let reqLength = evt.reqLength.int
      let isAllowedFast = evt.reqIndex in peer.outboundAllowedFast
      if peer.amChoking and not isAllowedFast:
        # BEP 6: explicitly reject choked requests (only if peer supports fast ext).
        btDebug "[SEED-DBG] Rejecting REQUEST from ", key, ": we are choking (amChoking=true, allowedFast=false)"
        if peer.peerSupportsFastExt:
          await peer.sendRejectRequest(evt.reqIndex, evt.reqBegin, evt.reqLength)
      else:
        var validBounds = false
        if pieceIdx >= 0 and pieceIdx < client.pieceMgr.totalPieces and
           reqLength > 0 and reqLength <= MaxBlockSize:
          let pieceLen = client.metainfo.info.pieceSize(pieceIdx)
          let reqEnd = reqBegin + reqLength
          validBounds = reqBegin >= 0 and reqEnd >= reqBegin and reqEnd <= pieceLen
        if not validBounds:
          # BEP 6: reject invalid-bounds requests. Non-BEP6 peers are silently ignored.
          if peer.peerSupportsFastExt:
            await peer.sendRejectRequest(evt.reqIndex, evt.reqBegin, evt.reqLength)
        elif client.pieceMgr.pieces[pieceIdx].state in {psOptimistic, psVerified}:
          # Release mutex for disk read — no state changes until re-acquired.
          let peerSupportsFast = peer.peerSupportsFastExt
          unlock(client.mtx)
          var blockData: string = ""
          var readError: string = ""
          try:
            blockData = client.storageMgr.readBlock(pieceIdx, reqBegin, reqLength)
          except CatchableError as e:
            readError = e.msg
          await lock(client.mtx)
          if readError.len > 0:
            # Disk I/O failed — send REJECT if peer supports BEP 6.
            if peerSupportsFast and key in client.peers:
              await peer.sendRejectRequest(evt.reqIndex, evt.reqBegin, evt.reqLength)
          elif key in client.peers:
            btDebug "[SEED-DBG] Sending PIECE to ", key, " piece=", evt.reqIndex, " offset=", evt.reqBegin, " len=", blockData.len
            await peer.sendPieceBlock(evt.reqIndex, evt.reqBegin, blockData)
            client.pieceMgr.uploaded += blockData.len
        else:
          # Piece not verified (we don't have it) — reject if fast extension.
          if peer.peerSupportsFastExt:
            await peer.sendRejectRequest(evt.reqIndex, evt.reqBegin, evt.reqLength)

  of pekCancel:
    discard  # We don't track outgoing piece sends to cancel

  of pekError:
    # Per-peer errors are normal (timeouts, refused connections) — don't flood the events channel
    discard

  of pekExtHandshake:
    # Extension handshake received - check for metadata size (BEP 9)
    if client.metadataExchange != nil and evt.extRegistry.metadataSize > 0:
      client.metadataExchange.initFromSize(evt.extRegistry.metadataSize)
      # Request metadata pieces from this peer
      await client.requestMetadata(key)
    # BEP 21: upload_only — mark peer for seeder eviction
    if evt.extRegistry.uploadOnly and key in client.peers:
      let peer = client.peers[key]
      peer.peerUploadOnly = true
      client.markPeerAsSeed(peer)
    # Capture peer extension capabilities.
    if key in client.peers:
      let peer = client.peers[key]
      peer.remoteListenPort = evt.extRegistry.remoteListenPort
      if peer.remoteListenPort > 0:
        let rpKey = peerKey(peer.ip, peer.remoteListenPort)
        if key in client.pexPeerFlags:
          client.pexPeerFlags[rpKey] = client.pexPeerFlags[key]
        for rk in client.hp.relaysFor(key):
          client.hp.recordRelay(rpKey, rk)
      # uTP transport upgrade: if connected via TCP and the remote peer
      # advertises a listen port (implying uTP support), attempt to
      # reconnect via uTP for lower per-connection overhead.
      if peer.transport == ptTcp and peer.remoteListenPort > 0:
        await client.tryUtpReconnect(key)

  of pekExtMessage:
    case evt.extName
    of UtMetadataName:
      # BEP 9: Metadata exchange
      var decoded: tuple[msgType: MetadataMsgType, piece: int, totalSize: int, data: string]
      var decodeError: string = ""
      try:
        decoded = decodeMetadataMsg(evt.extPayload)
      except CatchableError as e:
        decodeError = e.msg
      if decodeError.len == 0:
        case decoded.msgType
        of mtRequest:
          # Peer requests metadata from us
          if client.rawInfoDict.len > 0 and key in client.peers:
            let peer = client.peers[key]
            let pieceData: string = getMetadataPiece(client.rawInfoDict, decoded.piece)
            let respPayload: string = encodeMetadataData(decoded.piece,
              client.rawInfoDict.len, pieceData)
            await peer.sendExtended(UtMetadataName, respPayload)
        of mtData:
          # Received metadata piece
          if client.metadataExchange != nil:
            let allReceived = client.metadataExchange.receivePiece(decoded.piece, decoded.data)
            if allReceived:
              let assembled: string = client.metadataExchange.assembleAndVerify()
              if assembled.len > 0:
                client.rawInfoDict = assembled
                # Parse info dict and initialize piece manager + storage
                let parsedInfo = parseRawInfoDict(assembled, client.metainfo.info.infoHash)
                client.metainfo.info = parsedInfo
                client.pieceMgr = newPieceManager(parsedInfo, client.config.maxRacersPerBlock,
                                                   client.config.enableOptimisticVerification)
                client.availability = newSeq[int](parsedInfo.pieceCount)
                client.isPrivate = parsedInfo.isPrivate
                client.applyPrivateProtocolGating()
                client.buildSelectedPiecesMask()
                # Set up storage
                let downloadDir = client.config.downloadDir / parsedInfo.name
                client.storageMgr = newStorageManager(parsedInfo, downloadDir)
                client.storageMgr.openFiles()
                # Check for existing data
                let verified = client.storageMgr.verifyExistingFiles(parsedInfo)
                client.restoreVerifiedPieces(verified)
                if client.pieceMgr.isComplete:
                  client.state = csSeeding
                  # Mark all connected seeders for eviction
                  let markKeys = client.snapshotPeerKeys()
                  var mki = 0
                  while mki < markKeys.len:
                    let mkk = markKeys[mki]
                    mki += 1
                    if mkk in client.peers:
                      let sp = client.peers[mkk]
                      if sp.state == psActive and client.peerIsSeed(sp):
                        client.markPeerAsSeed(sp)
                # Done with metadata exchange
                client.metadataExchange = nil
                # Rebuild availability from all connected peers' bitfields
                let peerKeys = client.snapshotPeerKeys()
                var avi = 0
                while avi < peerKeys.len:
                  let apk = peerKeys[avi]
                  avi += 1
                  if apk in client.peers:
                    let ap = client.peers[apk]
                    if ap.state == psActive and ap.peerBitfield.len > 0:
                      client.updateAvailability(ap.peerBitfield, true)

                # Send bitfield to all connected peers
                let bf = client.pieceMgr.generateBitfield()
                var bfi = 0
                while bfi < peerKeys.len:
                  let pk = peerKeys[bfi]
                  bfi += 1
                  if pk in client.peers:
                    let p = client.peers[pk]
                    if p.state == psActive:
                      await p.sendBitfield(bf)
                      # Check if peer has pieces we need and start downloading
                      if p.peerBitfield.len > 0:
                        if client.peerHasNeededSelectedPiece(p.peerBitfield):
                          await p.sendInterested()
                          if not p.peerChoking:
                            await client.requestBlocks(p)
                await client.events.send(ClientEvent(kind: cekProgress,
                  completedPieces: client.pieceMgr.verifiedCount + client.pieceMgr.optimisticCount,
                  totalPieces: client.pieceMgr.totalPieces,
                  downloadRate: 0.0, uploadRate: 0.0,
                  peerCount: client.connectedPeerCount))
        of mtReject:
          discard  # Peer rejected our metadata request

    of UtPexName:
      # BEP 11: Peer Exchange — queue for connectLoop
      if not client.isPrivate and client.config.enablePex:
        var pexDecodeError: string = ""
        var pexMsg: PexMessage
        try:
          pexMsg = decodePexMessage(evt.extPayload)
        except CatchableError as e:
          pexDecodeError = e.msg
        if pexDecodeError.len > 0:
          discard  # Malformed PEX message — ignore
        else:
          client.processPexPeers(pexMsg.added, pexMsg.addedFlags, key)
          client.processPexPeers(pexMsg.added6, pexMsg.added6Flags, key)

    of UtHolepunchName:
      # BEP 55: relay + connect/error handling.
      if not client.config.enableHolepunch or client.isPrivate:
        discard
      elif key in client.peers:
        let relayPeer = client.peers[key]
        if relayPeer.state == psActive:
          try:
            let hp = decodeHolepunchMsg(evt.extPayload)
            case hp.msgType
            of HpConnect:
              # Relay instructed us to connect to target endpoint.
              btDebug "[HP] Received HpConnect: ", hp.ip, ":", hp.port, " from relay ", key
              if client.utpMgr != nil and hp.port > 0:
                let hpKey = peerKey(hp.ip, hp.port)
                if client.hp.isInFlight(hpKey):
                  btDebug "[HP] Skip HpConnect ", hpKey, ": already in flight"
                elif client.findConnectedPeerByEndpoint(hp.ip, hp.port) != nil:
                  # Peer already connected — might be a simultaneous-open winner.
                  # Mark it as holepunch if it came in as incoming.
                  if hpKey in client.peers:
                    let ep = client.peers[hpKey]
                    if ep.source == srcIncoming and ep.transport == ptUtp:
                      btDebug "[HP] Already connected (incoming→holepunch): ", hpKey
                      ep.source = srcHolepunch
                      client.hp.recordSuccess(hpKey)
                    else:
                      btDebug "[HP] Skip HpConnect ", hpKey, ": already connected (source=", ep.source, ")"
                  else:
                    btDebug "[HP] Skip HpConnect ", hpKey, ": already connected"
                else:
                  # A relay-triggered attempt must bypass generic failed-peer backoff.
                  var qi = 0
                  while qi < client.pendingPeers.len:
                    if client.pendingPeers[qi].ip == hp.ip and client.pendingPeers[qi].port == hp.port:
                      client.pendingPeers.delete(qi)
                    else:
                      inc qi
                  client.failedPeers.del(hpKey)
                  client.failedIps.del(hp.ip)
                  client.hp.markInFlight(hpKey)
                  let started = await client.addPeer(hp.ip, hp.port, srcHolepunch,
                    uint8(pexUtp) or uint8(pexHolepunch),
                    bypassBackoff = true,
                    utpConnectTimeoutMs = HolepunchDirectUtpTimeoutMs)
                  if started:
                    btDebug "[HP] Started uTP connect to ", hpKey
                  else:
                    # If the peer already exists (incoming arrived first via
                    # simultaneous-open), mark it as holepunch and count success.
                    if hpKey in client.peers:
                      let existingPeer = client.peers[hpKey]
                      if existingPeer.source == srcIncoming and existingPeer.transport == ptUtp:
                        btDebug "[HP] Incoming peer already connected (simultaneous-open won by incoming): ", hpKey
                        existingPeer.source = srcHolepunch
                        client.hp.recordSuccess(hpKey)
                      else:
                        btDebug "[HP] Peer already exists (source=", existingPeer.source, "): ", hpKey
                    else:
                      btDebug "[HP] addPeer failed for ", hpKey, " (peers=", client.connectedPeerCount, " halfOpen=", client.halfOpenCount, ")"
                    client.hp.clearInFlight(hpKey)
              else:
                btDebug "[HP] Skip HpConnect: utpMgr=", client.utpMgr != nil, " port=", hp.port
            of HpError:
              let errStr = errorName(hp.errCode)
              btDebug "[HP] Received HpError: ", hp.ip, ":", hp.port, " err=", errStr
              let hpKey = peerKey(hp.ip, hp.port)
              client.hp.recordError(hpKey, hp.errCode)
            of HpRendezvous:
              # Act as relay: forward CONNECT to both peers when possible.
              let requesterPort = if relayPeer.remoteListenPort > 0: relayPeer.remoteListenPort else: relayPeer.port
              if hp.ip == relayPeer.ip and hp.port == requesterPort:
                let errPayload = encodeHolepunchMsg(errorMsg(hp.ip, hp.port, HpErrNoSelf))
                await relayPeer.sendExtended(UtHolepunchName, errPayload)
              else:
                let targetPeer = client.findConnectedPeerByEndpoint(hp.ip, hp.port)
                if targetPeer == nil or targetPeer.state != psActive:
                  let errPayload = encodeHolepunchMsg(errorMsg(hp.ip, hp.port, HpErrNoSuchPeer))
                  await relayPeer.sendExtended(UtHolepunchName, errPayload)
                elif targetPeer == relayPeer:
                  let errPayload = encodeHolepunchMsg(errorMsg(hp.ip, hp.port, HpErrNoSelf))
                  await relayPeer.sendExtended(UtHolepunchName, errPayload)
                elif not targetPeer.extensions.supportsExtension(UtHolepunchName):
                  let errPayload = encodeHolepunchMsg(errorMsg(hp.ip, hp.port, HpErrNoSupport))
                  await relayPeer.sendExtended(UtHolepunchName, errPayload)
                else:
                  let relayPort = if relayPeer.remoteListenPort > 0: relayPeer.remoteListenPort else: relayPeer.port
                  let targetPort = if targetPeer.remoteListenPort > 0: targetPeer.remoteListenPort else: targetPeer.port
                  let toTarget = encodeHolepunchMsg(connectMsg(relayPeer.ip, relayPort))
                  let toRequester = encodeHolepunchMsg(connectMsg(targetPeer.ip, targetPort))
                  # Send HpConnect to both peers in parallel for tighter timing
                  let relayFut = targetPeer.sendExtended(UtHolepunchName, toTarget)
                  let reqFut = relayPeer.sendExtended(UtHolepunchName, toRequester)
                  await relayFut
                  await reqFut
          except CatchableError as e:
            client.hp.lastError = e.msg

    of ExtLtDontHave:
      # BEP 54: peer no longer has a piece.
      if key in client.peers and client.pieceMgr != nil:
        let p = client.peers[key]
        let pieceIdx = decodeLtDonthave(evt.extPayload)
        if pieceIdx >= 0 and pieceIdx < client.pieceMgr.totalPieces and
           p.peerBitfield.len > 0 and hasPiece(p.peerBitfield, pieceIdx):
          clearPiece(p.peerBitfield, pieceIdx)
          if pieceIdx < client.availability.len and client.availability[pieceIdx] > 0:
            client.availability[pieceIdx] -= 1
          if p.amInterested and not client.peerHasNeededSelectedPiece(p.peerBitfield):
            await p.sendNotInterested()

    else:
      discard  # Unknown extension

  of pekHaveAll:
    btDebug "[SEED-DBG] pekHaveAll from ", key
    # BEP 6: Peer has all pieces - generate full bitfield
    if key in client.peers and client.pieceMgr != nil:
      let peer = client.peers[key]
      peer.peerBitfield = newBitfield(client.pieceMgr.totalPieces)
      var i: int = 0
      while i < client.pieceMgr.totalPieces:
        setPiece(peer.peerBitfield, i)
        i += 1
      client.updateAvailability(peer.peerBitfield, true)
      if client.peerHasNeededSelectedPiece(peer.peerBitfield) and not peer.amInterested:
        await peer.sendInterested()
      if not peer.peerChoking:
        await client.requestBlocks(peer)
      # Peer has all pieces — mark for seeder eviction
      client.markPeerAsSeed(peer)

  of pekHaveNone:
    btDebug "[SEED-DBG] pekHaveNone from ", key
    discard  # Peer has no pieces

  of pekSuggestPiece:
    if key in client.peers:
      let peer = client.peers[key]
      peer.suggestedPieces.add(evt.haveIndex.int)
      if not peer.peerChoking:
        await client.requestBlocks(peer)

  of pekRejectRequest:
    # Peer rejected our request - mark block as not requested.
    # Only decrement pendingRequests if the block was actually in activeRequests
    # to prevent desync from unsolicited reject messages.
    if key in client.peers and client.pieceMgr != nil:
      let peer = client.peers[key]
      if peer.removeActiveRequest(evt.reqIndex.int, evt.reqBegin.int):
        client.pieceMgr.unregisterRacer(evt.reqIndex.int, evt.reqBegin.int, key)
        client.pieceMgr.cancelBlockRequest(evt.reqIndex.int, evt.reqBegin.int)
      # Refill the request pipeline after a rejection frees a slot.
      await client.requestBlocks(peer)

  of pekAllowedFast:
    # Piece can be requested even when choked
    if key in client.peers:
      let peer = client.peers[key]
      if peer.peerChoking:
        await client.requestBlocks(peer)

  of pekPort:
    # BEP 5: Peer announced their DHT port — add to our routing table
    if client.dhtEnabled and key in client.peers:
      let peer = client.peers[key]
      var nodeId: NodeId  # We don't know their DHT node ID yet
      # We'll discover it through DHT ping later
      discard

proc trackerLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Periodically announce to trackers and add new peers.
  var announceParams = defaultAnnounceParams(
    client.metainfo.info, client.peerId, client.config.listenPort)

  # BEP 7: include our IPv6 address so trackers return peers6
  let localIpv6: string = getLocalIpv6()
  if localIpv6.len > 0:
    announceParams.ipv6 = localIpv6

  let trackerUrls = collectTrackerUrls(client.metainfo)

  if trackerUrls.len == 0:
    # No trackers — rely on DHT/PEX/LSD for peer discovery (common for magnet links)
    return

  var initIdx = 0
  while initIdx < trackerUrls.len:
    let trackerUrl = trackerUrls[initIdx]
    withSpinLock(client.trackerLock):
      client.trackerRuntime[trackerUrl] = TrackerRuntime(
        url: trackerUrl,
        status: "updating"
      )
    inc initIdx

  var isFirst = true

  while client.state in {csDownloading, csSeeding}:
    # Update announce params
    if client.pieceMgr != nil:
      announceParams.downloaded = client.pieceMgr.downloaded
      announceParams.uploaded = client.pieceMgr.uploaded
      announceParams.left = client.pieceMgr.bytesRemaining
    if isFirst:
      announceParams.event = teStarted
      isFirst = false
    else:
      announceParams.event = teNone

    var mergedComplete = 0
    var mergedIncomplete = 0
    var mergedInterval = 0
    var anySuccess = false
    var newPeerCount = 0
    var seen = initHashSet[string]()

    var trackIdx = 0
    while trackIdx < trackerUrls.len:
      let trackerUrl = trackerUrls[trackIdx]
      var tr: TrackerRuntime
      withSpinLock(client.trackerLock):
        if trackerUrl notin client.trackerRuntime:
          client.trackerRuntime[trackerUrl] = TrackerRuntime(url: trackerUrl, status: "updating")
        tr = client.trackerRuntime[trackerUrl]
        tr.status = "updating"
        client.trackerRuntime[trackerUrl] = tr
      try:
        let resp = await announce(trackerUrl, announceParams)
        let nowTs = epochTime()
        if resp.failureReason.len > 0:
          tr.status = "error"
          tr.errorText = resp.failureReason
          tr.lastAnnounce = nowTs
          withSpinLock(client.trackerLock):
            client.trackerRuntime[trackerUrl] = tr
          inc trackIdx
          continue
        tr.status = "working"
        tr.seeders = resp.complete
        tr.leechers = resp.incomplete
        tr.lastAnnounce = nowTs
        tr.nextAnnounce = nowTs + max(resp.interval, 30).float
        tr.errorText = ""
        withSpinLock(client.trackerLock):
          client.trackerRuntime[trackerUrl] = tr
        anySuccess = true
        mergedComplete = max(mergedComplete, resp.complete)
        mergedIncomplete = max(mergedIncomplete, resp.incomplete)
        if resp.interval > 0 and (mergedInterval == 0 or resp.interval < mergedInterval):
          mergedInterval = resp.interval
        await lock(client.mtx)
        try:
          var peerIdx = 0
          while peerIdx < resp.peers.len:
            let tp = resp.peers[peerIdx]
            let pKey = peerKey(tp.ip, tp.port)
            if pKey in seen:
              inc peerIdx
              continue
            seen.incl(pKey)
            if pKey notin client.peers:
              if client.queuePeerIfNeeded(tp.ip, tp.port, srcTracker, 0'u8):
                newPeerCount += 1
            inc peerIdx
        finally:
          unlock(client.mtx)
      except CatchableError as e:
        tr.status = "error"
        tr.errorText = e.msg
        withSpinLock(client.trackerLock):
          client.trackerRuntime[trackerUrl] = tr
      inc trackIdx

    if anySuccess:
      await client.events.send(ClientEvent(kind: cekTrackerResponse,
        newPeers: newPeerCount,
        seeders: mergedComplete,
        leechers: mergedIncomplete))

      # Re-announce faster when low on peers, slower when we have enough.
      # When seeding with enough peers, use long intervals to avoid churning
      # seeders (tracker keeps returning the same seeder IPs).
      let interval: int = if client.state == csSeeding and
          client.connectedPeerCount >= MinPeers:
        # Seeding with healthy peer count — respect tracker interval, minimum 120s
        min(max(mergedInterval * 1000, 120000), 1800000)
      elif client.state == csSeeding:
        # Seeding but low on peers — moderate pace
        60000
      elif client.connectedPeerCount < 5:
        10000
      elif client.connectedPeerCount < MinPeers:
        ReannounceIntervalMs
      else:
        min(max(mergedInterval * 1000, 60000), 120000)
      await cpsSleep(interval)
      continue
    else:
      await client.events.send(ClientEvent(kind: cekError,
        errMsg: "tracker error: all announces failed"))

    # Fallback: wait and retry
    await cpsSleep(ReannounceIntervalMs)

proc connectLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Periodically drain the pending peers queue, connecting to new peers
  ## as slots open up. Runs frequently when starving for peers, slower when healthy.
  while client.state in {csDownloading, csSeeding}:
    # Poll faster when we need peers, slower when we have enough
    let sleepMs: int = if client.connectedPeerCount < MinPeers: 250 else: 1000
    await cpsSleep(sleepMs)
    await lock(client.mtx)
    try:
      if client.pendingPeers.len > 0 and
         client.connectedPeerCount < client.config.maxPeers:
        if client.pendingPeers.len > 1 and client.natMgr != nil and client.natMgr.localIp.len > 0:
          let ourIp = client.natMgr.localIp
          client.sortPendingPeersByPriority(ourIp)
        # Fill up to MaxHalfOpen concurrent connection attempts
        while client.pendingPeers.len > 0 and
              client.halfOpenCount < MaxHalfOpen and
              client.connectedPeerCount < client.config.maxPeers:
          let pp = client.pendingPeers[0]
          client.pendingPeers.delete(0)
          discard await client.addPeer(pp.ip, pp.port, pp.source, pp.pexFlags)

    finally:
      unlock(client.mtx)
proc trackerScrapeLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Periodic tracker scrape updates (BEP 48 / UDP scrape via BEP 15).
  if not client.config.enableTrackerScrape:
    return
  let trackerUrls = collectTrackerUrls(client.metainfo)
  if trackerUrls.len == 0:
    return
  while client.state in {csDownloading, csSeeding}:
    var trackIdx = 0
    while trackIdx < trackerUrls.len:
      let trackerUrl = trackerUrls[trackIdx]
      # Read current tracker state (copy out under SpinLock)
      var tr: TrackerRuntime
      withSpinLock(client.trackerLock):
        if trackerUrl notin client.trackerRuntime:
          client.trackerRuntime[trackerUrl] = TrackerRuntime(url: trackerUrl, status: "updating")
        tr = client.trackerRuntime[trackerUrl]
      # Scrape I/O (no lock)
      try:
        let sc = await scrape(trackerUrl, client.metainfo.info.infoHash)
        let nowTs = epochTime()
        tr.seeders = max(tr.seeders, sc.complete)
        tr.leechers = max(tr.leechers, sc.incomplete)
        tr.completed = sc.downloaded
        tr.lastScrape = nowTs
        tr.nextScrape = nowTs + 120.0
        if tr.status != "disabled":
          tr.status = "working"
        tr.errorText = ""
      except CatchableError as e:
        if tr.status != "working":
          tr.status = "error"
        tr.errorText = e.msg
      # Write back under SpinLock
      withSpinLock(client.trackerLock):
        client.trackerRuntime[trackerUrl] = tr
      inc trackIdx
    await cpsSleep(120000)

proc eventLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Main event processing loop.
  while client.state in {csDownloading, csSeeding}:
    var channelClosed: bool = false
    var evt: PeerEvent
    try:
      evt = await client.peerEvents.recv()
    except ChannelClosed:
      channelClosed = true
    if channelClosed:
      break
    await lock(client.mtx)
    try:
      await client.handlePeerEvent(evt)
    finally:
      discard tryUnlock(client.mtx)
proc optimisticVerifyLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Background loop that SHA1-confirms optimistically verified pieces.
  ## Drains the optimisticVerifyQueue at a moderate pace to avoid starving I/O.
  while client.state in {csDownloading, csSeeding}:
    await cpsSleep(100)
    await lock(client.mtx)
    if client.optimisticVerifyQueue.len > 0:
      let pieceIdx = client.optimisticVerifyQueue.popFirst()
      if client.pieceMgr != nil and pieceIdx >= 0 and pieceIdx < client.pieceMgr.totalPieces and
         client.pieceMgr.pieces[pieceIdx].state == psOptimistic:
        # SHA1 outside mutex (data buffer is still alive for optimistic pieces)
        unlock(client.mtx)
        let hashMatch: bool = await verifyPieceHash(client.pieceMgr, pieceIdx)
        await lock(client.mtx)
        if client.pieceMgr != nil and pieceIdx < client.pieceMgr.totalPieces and
           client.pieceMgr.pieces[pieceIdx].state == psOptimistic:
          if hashMatch:
            client.pieceMgr.applyOptimisticVerification(pieceIdx, true)
            # Release the piece data buffer (uploads read from disk)
            client.pieceMgr.pieces[pieceIdx].data = ""
            client.pieceMgr.pieces[pieceIdx].consensus = PieceConsensus()
            # Notify GUI: optimistic → verified
            await client.events.send(ClientEvent(kind: cekPieceStateChanged,
              changedPieceIndex: pieceIdx,
              changedPieceState: client.pieceMgr.pieces[pieceIdx].state))
          else:
            # SHA1 mismatch on optimistic piece — rollback and reschedule
            btDebug "WARN: optimistic piece ", pieceIdx, " failed background SHA1"
            client.pieceMgr.failAndResetPiece(pieceIdx)
            # Notify GUI: piece rescheduled for download
            await client.events.send(ClientEvent(kind: cekPieceStateChanged,
              changedPieceIndex: pieceIdx,
              changedPieceState: client.pieceMgr.pieces[pieceIdx].state))
            await client.sendLtDonthaveToPeers(pieceIdx)
            if client.state == csSeeding:
              client.state = csDownloading
            # Re-request blocks from available peers
            let vrfKeys = client.snapshotPeerKeys()
            var ki = 0
            while ki < vrfKeys.len:
              let pk = vrfKeys[ki]
              ki += 1
              if pk in client.peers:
                let peer = client.peers[pk]
                if peer.state == psActive and not peer.peerChoking:
                  await client.requestBlocks(peer)
    unlock(client.mtx)

const
  StaleTableCleanupSec = 300.0  ## Sweep stale table entries every 5 min
  FailedPeerTtlSec = 1800.0    ## Expire failedPeers entries after 30 min
  FailedIpTtlSec = 1800.0      ## Expire failedIps entries after 30 min
  KnownSeederTtlSec = 3600.0   ## Expire knownSeeders entries after 1 hour

proc cleanupStaleTables(client: TorrentClient) =
  ## Remove expired entries from failedPeers, failedIps, and knownSeeders.
  ## Called periodically under the mutex to bound memory growth.
  let now = epochTime()

  # Sweep failedPeers: delete entries older than FailedPeerTtlSec
  var expiredPeers: seq[string]
  for k, t in client.failedPeers:
    if now - t > FailedPeerTtlSec:
      expiredPeers.add(k)
  for k in expiredPeers:
    client.failedPeers.del(k)

  # Sweep failedIps: delete entries older than FailedIpTtlSec
  var expiredIps: seq[string]
  for k, v in client.failedIps:
    if now - v.lastFail > FailedIpTtlSec:
      expiredIps.add(k)
  for k in expiredIps:
    client.failedIps.del(k)

  # Sweep knownSeeders: only clean when seeding with a healthy peer count.
  # While downloading, knownSeeders is small (only leechers are connected).
  # While seeding, it prevents reconnecting to seeders we already know about.
  if client.state == csSeeding and client.knownSeeders.len > 500:
    client.knownSeeders.clear()

proc requestRefreshLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Periodically recover from stale block requests.
  ## Only resets blocks that belong to peers no longer connected or that have
  ## been in-flight too long. Reconciles pendingRequests with activeRequests
  ## to prevent counter drift and request explosion.
  var lastCleanupTime: float = epochTime()
  while client.state == csDownloading:
    await cpsSleep(5000)  # Every 5 seconds
    await lock(client.mtx)
    try:
      # Periodic cleanup of unbounded tables (every StaleTableCleanupSec)
      let now = epochTime()
      if now - lastCleanupTime > StaleTableCleanupSec:
        lastCleanupTime = now
        client.cleanupStaleTables()
      if client.pieceMgr != nil and not client.pieceMgr.isComplete:

        # Collect the set of blocks that are actively tracked by connected peers
        var trackedBlocks: HashSet[tuple[pieceIdx: int, offset: int]]
        let peerKeys = client.snapshotPeerKeys()

        var reclaimedBlocks: bool = false
        var ki: int = 0
        while ki < peerKeys.len:
          let pk: string = peerKeys[ki]
          ki += 1
          if pk notin client.peers:
            continue
          let peer: PeerConn = client.peers[pk]
          if peer.state != psActive:
            # Peer no longer active — don't count its requests
            if peer.activeRequests.len > 0:
              for req in peer.activeRequests:
                client.pieceMgr.unregisterRacer(req.pieceIdx, req.offset, pk)
              client.pieceMgr.cancelPeerRequests(peer.activeRequests)
              peer.activeRequests.setLen(0)
              peer.pendingRequests = 0
              reclaimedBlocks = true
            continue
          # Timeout active-but-silent peers: if they have outstanding requests
          # but haven't sent piece data in StaleRequestTimeoutSec, reclaim.
          let now: float = epochTime()
          if peer.activeRequests.len > 0 and
             (now - peer.lastPieceTime) > StaleRequestTimeoutSec:
            for req in peer.activeRequests:
              client.pieceMgr.unregisterRacer(req.pieceIdx, req.offset, pk)
            client.pieceMgr.cancelPeerRequests(peer.activeRequests)
            peer.activeRequests.setLen(0)
            peer.pendingRequests = 0
            reclaimedBlocks = true
            continue
          # Reconcile pendingRequests with actual activeRequests length
          peer.pendingRequests = peer.activeRequests.len
          for req in peer.activeRequests:
            trackedBlocks.incl((req.pieceIdx, req.offset))

        # Reset bsRequested blocks that are NOT tracked by any active peer.
        # This un-stalls blocks from disconnected peers without disturbing
        # in-flight requests from active peers.
        var resetCount = 0
        for pi in 0 ..< client.pieceMgr.totalPieces:
          if client.pieceMgr.pieces[pi].state in {psPartial, psEmpty}:
            for blk in client.pieceMgr.pieces[pi].blocks.mitems:
              if blk.state == bsRequested:
                if (pi, blk.offset) notin trackedBlocks:
                  blk.state = bsEmpty
                  inc resetCount

        # Steal blocks for stuck partial pieces: pieces where all remaining
        # blocks are bsRequested but no new block has arrived in time. Instead
        # of canceling the original requests, send DUPLICATE requests to other
        # unchoked peers that have the piece (first response wins). This is
        # per-piece aggressive endgame, applied before formal endgame mode.
        var stealCount = 0
        var stealIdx: int = 0
        while stealIdx < client.pieceMgr.totalPieces:
          let stPi: int = stealIdx
          stealIdx += 1
          if not client.pieceMgr.pieces[stPi].isStuckPartial(StaleRequestTimeoutSec):
            continue
          # Collect bsRequested blocks for this stuck piece
          var stealBlocks: seq[tuple[offset: int, length: int]]
          for blk in client.pieceMgr.pieces[stPi].blocks:
            if blk.state == bsRequested:
              stealBlocks.add((blk.offset, blk.length))
          if stealBlocks.len == 0:
            continue
          # Send duplicate requests to other unchoked peers that have this piece
          var ski: int = 0
          while ski < peerKeys.len:
            let spk: string = peerKeys[ski]
            ski += 1
            if spk notin client.peers:
              continue
            let sp: PeerConn = client.peers[spk]
            if sp.state != psActive or sp.peerChoking:
              continue
            if sp.peerBitfield.len == 0 or not hasPiece(sp.peerBitfield, stPi):
              continue
            if sp.pendingRequests >= MaxPendingRequests:
              continue
            var sbi: int = 0
            while sbi < stealBlocks.len and sp.pendingRequests < MaxPendingRequests:
              let sb = stealBlocks[sbi]
              sbi += 1
              if sp.hasActiveRequest(stPi, sb.offset):
                continue
              # Use trySend to avoid blocking refresh loop on congested peers
              let spKey = peerKey(sp.ip, sp.port)
              if sp.commands.trySend(requestMsg(uint32(stPi), uint32(sb.offset), uint32(sb.length))):
                client.pieceMgr.registerRacer(stPi, sb.offset, spKey)
                sp.activeRequests.add((pieceIdx: stPi, offset: sb.offset))
                sp.pendingRequests += 1
                inc stealCount

        # Slow-peer racing: for peers that are active but silent longer than
        # raceSlowPeerSec (but not yet StaleRequestTimeoutSec), race their
        # in-flight blocks by sending duplicate requests to faster peers.
        if client.config.enableRacing:
          let raceNow: float = epochTime()
          var slowPeerIdx: int = 0
          while slowPeerIdx < peerKeys.len:
            let slowPk: string = peerKeys[slowPeerIdx]
            slowPeerIdx += 1
            if slowPk notin client.peers:
              continue
            let slowPeer: PeerConn = client.peers[slowPk]
            if slowPeer.state != psActive or slowPeer.activeRequests.len == 0:
              continue
            let silentSec: float = raceNow - slowPeer.lastPieceTime
            # Only race if peer is slow but not yet fully stale (already handled above)
            if silentSec < client.config.raceSlowPeerSec or
               silentSec >= StaleRequestTimeoutSec:
              continue
            # Race this peer's blocks via other connected peers
            var slowReqIdx: int = 0
            while slowReqIdx < slowPeer.activeRequests.len:
              let slowReq = slowPeer.activeRequests[slowReqIdx]
              slowReqIdx += 1
              # Find another unchoked peer that has this piece and can accept more requests
              var fastPeerIdx: int = 0
              while fastPeerIdx < peerKeys.len:
                let fastPk: string = peerKeys[fastPeerIdx]
                fastPeerIdx += 1
                if fastPk == slowPk or fastPk notin client.peers:
                  continue
                let fastPeer: PeerConn = client.peers[fastPk]
                if fastPeer.state != psActive or fastPeer.peerChoking:
                  continue
                if fastPeer.pendingRequests >= MaxPendingRequests:
                  continue
                if fastPeer.peerBitfield.len == 0 or
                   not hasPiece(fastPeer.peerBitfield, slowReq.pieceIdx):
                  continue
                if fastPeer.hasActiveRequest(slowReq.pieceIdx, slowReq.offset):
                  continue
                # Check race tracker allows another racer
                let raceKey: BlockKey = (slowReq.pieceIdx, slowReq.offset)
                if raceKey in client.pieceMgr.raceTracker.raced:
                  if client.pieceMgr.raceTracker.raced[raceKey].requesters.len >=
                     client.pieceMgr.raceTracker.maxRacers:
                    continue  # Can't add more racers for this block, try next fast peer
                # Send duplicate request via trySend (non-blocking)
                let blkLen = client.pieceMgr.blockLength(slowReq.pieceIdx, slowReq.offset)
                if blkLen > 0 and fastPeer.commands.trySend(
                    requestMsg(uint32(slowReq.pieceIdx), uint32(slowReq.offset), uint32(blkLen))):
                  client.pieceMgr.registerRacer(slowReq.pieceIdx, slowReq.offset, fastPk)
                  fastPeer.activeRequests.add((pieceIdx: slowReq.pieceIdx, offset: slowReq.offset))
                  fastPeer.pendingRequests += 1
                break  # One duplicate per block is enough

        # Re-issue requests if we freed blocks (from stale/inactive peers
        # or orphaned bsRequested blocks not tracked by any peer).
        if resetCount > 0 or reclaimedBlocks:
          ki = 0
          while ki < peerKeys.len:
            let pk: string = peerKeys[ki]
            ki += 1
            if pk notin client.peers:
              continue
            let peer: PeerConn = client.peers[pk]
            if peer.state != psActive or peer.peerChoking:
              continue
            await client.requestBlocks(peer)

    finally:
      unlock(client.mtx)
proc progressLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Periodically emit progress events.
  ## Rates use EMA smoothing over a ~2s window for stable display.
  ## Uses per-torrent wire-level byte counters so reported rates match what
  ## network monitors observe and sum correctly across torrents.
  var lastDownloaded: int64 = client.wireDownloaded
  var lastUploaded: int64 = client.wireUploaded
  var lastTime = epochTime()
  var lastEmitTime = 0.0
  var lastCompleted = -1
  var lastPeerCount = -1
  var lastDlRate = -1.0
  var lastUlRate = -1.0
  var smoothDlRate = 0.0
  var smoothUlRate = 0.0

  while client.state in {csDownloading, csSeeding}:
    await cpsSleep(500)
    # No mutex needed: all counter writes happen in CPS tasks on the same
    # event loop thread. CPS tasks only yield at await points, so reading
    # multiple fields in a tight block is consistent. Stale reads (off by
    # one tick) are harmless for progress display.
    let now = epochTime()
    let elapsed = now - lastTime
    if elapsed > 0 and client.pieceMgr != nil:
      # Use per-torrent wire-level byte counters for rate display. These track
      # all protocol bytes (framing, control messages, piece data) for this
      # torrent only, so they sum correctly in the GUI status bar.
      let currentDl: int64 = client.wireDownloaded
      let currentUl: int64 = client.wireUploaded
      let instantDl = float(currentDl - lastDownloaded) / elapsed
      let instantUl = float(currentUl - lastUploaded) / elapsed
      lastDownloaded = currentDl
      lastUploaded = currentUl
      lastTime = now

      # EMA smoothing: alpha adapts to sample interval so the effective
      # time constant is ~2 seconds regardless of how often we sample.
      # alpha = 1 - e^(-elapsed/tau), tau = 2.0s
      let alpha = 1.0 - exp(-elapsed / 2.0)
      let clampedAlpha = max(0.05, min(0.8, alpha))
      smoothDlRate = clampedAlpha * instantDl + (1.0 - clampedAlpha) * smoothDlRate
      smoothUlRate = clampedAlpha * instantUl + (1.0 - clampedAlpha) * smoothUlRate

      # Snap to zero when traffic truly stops (avoids lingering 0.1 KB/s)
      if instantDl == 0.0 and smoothDlRate < 100.0:
        smoothDlRate = 0.0
      if instantUl == 0.0 and smoothUlRate < 100.0:
        smoothUlRate = 0.0

      # Use maintained counter instead of iterating the peers table
      let activePeers: int = client.connectedPeerCount

      let completed = client.pieceMgr.verifiedCount + client.pieceMgr.optimisticCount
      let changed =
        completed != lastCompleted or
        activePeers != lastPeerCount or
        abs(smoothDlRate - lastDlRate) >= 1.0 or
        abs(smoothUlRate - lastUlRate) >= 1.0
      let heartbeatDue = (now - lastEmitTime) >= 1.0
      if changed or heartbeatDue:
        await client.events.send(ClientEvent(kind: cekProgress,
          completedPieces: completed,
          totalPieces: client.pieceMgr.totalPieces,
          downloadRate: smoothDlRate,
          uploadRate: smoothUlRate,
          peerCount: activePeers))
        lastEmitTime = now
        lastCompleted = completed
        lastPeerCount = activePeers
        lastDlRate = smoothDlRate
        lastUlRate = smoothUlRate
type
  PeerRate = tuple[key: string, rate: float]

proc cmpPeerRateDesc(a, b: PeerRate): int =
  cmp(b.rate, a.rate)

proc nextDhtTransId(client: TorrentClient): string =
  ## Generate a unique 2-byte transaction ID for DHT queries.
  client.dhtTransIdCounter += 1
  # Wrap to 16-bit range to prevent overflow in char conversion.
  let c = client.dhtTransIdCounter and 0xFFFF
  result = newString(2)
  result[0] = char((c shr 8) and 0xFF)
  result[1] = char(c and 0xFF)

proc dhtPendingKey*(transId, ip: string, port: int): string =
  ## Composite key for dhtPendingQueries keyed by (transactionId, sender endpoint).
  transId & "|" & ip & ":" & $port

proc sendDhtDatagram(client: TorrentClient, data: string,
                     ip: string, port: int): CpsVoidFuture {.cps.} =
  ## Send a DHT datagram with bounded retries when kernel send buffer is full.
  var tries: int = 0
  while tries < 6:
    if client.dhtSock.trySendToAddr(data, ip, port):
      return
    tries += 1
    await client.sleepOrStop(10)
    if client.stopSignal.finished:
      return
  raise newException(AsyncIoError, "DHT send buffer remained full for " & ip & ":" & $port)

proc resolveDhtBootstrapAddrs(host: string): CpsFuture[seq[string]] {.cps.} =
  ## Resolve bootstrap host with both cached and uncached paths (IPv4 + IPv6).
  var addrs: seq[string] = @[]
  # IPv4 (A records)
  try:
    addrs = await resolve(host, Port(0), AF_INET)
  except CatchableError:
    discard

  var freshAddrs: seq[string] = @[]
  try:
    freshAddrs = await asyncResolve(host, Port(0), AF_INET)
  except CatchableError:
    discard

  if addrs.len == 0:
    addrs = freshAddrs
  elif freshAddrs.len > 0:
    addrs.add(freshAddrs)

  # IPv6 (AAAA records)
  var addrs6: seq[string] = @[]
  try:
    addrs6 = await resolve(host, Port(0), AF_INET6)
  except CatchableError:
    discard
  if addrs6.len == 0:
    try:
      addrs6 = await asyncResolve(host, Port(0), AF_INET6)
    except CatchableError:
      discard
  addrs.add(addrs6)

  var uniqueAddrs: seq[string] = @[]
  var i: int = 0
  while i < addrs.len:
    let ip: string = addrs[i]
    i += 1
    if ip.len == 0:
      continue
    var seen: bool = false
    var ui: int = 0
    while ui < uniqueAddrs.len:
      if uniqueAddrs[ui] == ip:
        seen = true
      ui += 1
    if not seen:
      uniqueAddrs.add(ip)

  return uniqueAddrs

proc isZeroNodeId(id: NodeId): bool =
  for b in id:
    if b != 0:
      return false
  true

proc generateDhtSecret(client: TorrentClient)  # forward decl for dhtRotateSecret

# ---------------------------------------------------------------------------
# DHT spinlock helpers — wrap dhtSpinLock acquire/release for MT safety.
# These are regular procs (not CPS), called only from CPS tasks (never reactor).
# The reactor DHT callback now pushes to a lock-free buffer instead of
# acquiring a lock, so dhtSpinLock only serializes CPS-to-CPS access.
# ---------------------------------------------------------------------------

proc sortByXorDistance(nodes: var seq[DhtNode], target: NodeId, limit: int = 0) =
  ## Selection sort nodes by XOR distance to target (closest first).
  ## If limit > 0, partial sort and truncate to that many entries.
  # Pre-compute distances to avoid redundant xorDistance calls in inner loop.
  var dists = newSeq[NodeId](nodes.len)
  var di = 0
  while di < nodes.len:
    dists[di] = xorDistance(nodes[di].id, target)
    di += 1
  let sortLen = if limit > 0: min(limit, nodes.len) else: nodes.len
  var si = 0
  while si < sortLen and si < nodes.len - 1:
    var minIdx = si
    var mi = si + 1
    while mi < nodes.len:
      if dists[mi] < dists[minIdx]:
        minIdx = mi
      mi += 1
    if minIdx != si:
      swap(nodes[si], nodes[minIdx])
      swap(dists[si], dists[minIdx])
    si += 1
  if limit > 0 and nodes.len > limit:
    nodes.setLen(limit)

proc addNodeIfEndpointNew(nodes: var seq[DhtNode], node: DhtNode) =
  ## Append node if no existing entry shares the same endpoint (ip, port).
  for n in nodes:
    if n.ip == node.ip and n.port == node.port:
      return
  nodes.add(node)

proc dhtFindClosest(client: TorrentClient, target: NodeId, count: int): seq[DhtNode] =
  ## Find closest nodes from BOTH routing tables, merged by XOR distance.
  var v4: seq[DhtNode]
  var v6: seq[DhtNode]
  withSpinLock(client.dhtSpinLock):
    v4 = client.dhtRoutingTable.findClosest(target, count)
    v6 = client.dhtRoutingTable6.findClosest(target, count)
  var merged = v4
  merged.add(v6)
  sortByXorDistance(merged, target, count)
  result = merged

proc dhtAddNode(client: TorrentClient, node: DhtNode): bool =
  withSpinLock(client.dhtSpinLock):
    if isIpv6(node.ip):
      result = client.dhtRoutingTable6.addNode(node)
    else:
      result = client.dhtRoutingTable.addNode(node)

proc dhtMarkFailed(client: TorrentClient, nodeId: NodeId) =
  withSpinLock(client.dhtSpinLock):
    client.dhtRoutingTable.markFailed(nodeId)
    client.dhtRoutingTable6.markFailed(nodeId)

proc dhtRegisterPending(client: TorrentClient, key: string, fut: CpsFuture[DhtMessage]) =
  withSpinLock(client.dhtSpinLock):
    client.dhtPendingQueries[key] = fut

proc dhtRemovePending(client: TorrentClient, key: string) =
  withSpinLock(client.dhtSpinLock):
    client.dhtPendingQueries.del(key)

proc dhtTotalNodes(client: TorrentClient): int =
  withSpinLock(client.dhtSpinLock):
    result = client.dhtRoutingTable.totalNodes + client.dhtRoutingTable6.totalNodes

proc dhtStaleBuckets(client: TorrentClient, thresholdSec: float): seq[int] =
  withSpinLock(client.dhtSpinLock):
    result = client.dhtRoutingTable.staleBuckets(thresholdSec)

proc dhtStaleBuckets6(client: TorrentClient, thresholdSec: float): seq[int] =
  withSpinLock(client.dhtSpinLock):
    result = client.dhtRoutingTable6.staleBuckets(thresholdSec)

proc dhtLeastRecentlySeenNode(client: TorrentClient, bucketIdx: int): DhtNode =
  withSpinLock(client.dhtSpinLock):
    result = client.dhtRoutingTable.leastRecentlySeenNode(bucketIdx)

proc dhtLeastRecentlySeenNode6(client: TorrentClient, bucketIdx: int): DhtNode =
  withSpinLock(client.dhtSpinLock):
    result = client.dhtRoutingTable6.leastRecentlySeenNode(bucketIdx)

proc dhtRotateSecret(client: TorrentClient) =
  withSpinLock(client.dhtSpinLock):
    client.generateDhtSecret()

proc dhtExpirePeers(client: TorrentClient, ttlSec: float) =
  withSpinLock(client.dhtSpinLock):
    client.dhtPeerStore.expirePeers(ttlSec)

proc dhtQuery(client: TorrentClient, transId: string, data: string,
              ip: string, port: int, timeoutMs: int = 5000): CpsFuture[DhtMessage] {.cps.} =
  ## Send a DHT query and wait for matching response.
  let pendingKey: string = dhtPendingKey(transId, ip, port)
  let queryFut: CpsFuture[DhtMessage] = newCpsFuture[DhtMessage]()
  queryFut.pinFutureRuntime()
  client.dhtRegisterPending(pendingKey, queryFut)
  var sendError: string = ""
  try:
    await client.sendDhtDatagram(data, ip, port)
  except CatchableError as e:
    sendError = e.msg
  if sendError.len > 0:
    client.dhtRemovePending(pendingKey)
    raise newException(CatchableError, sendError)
  var queryError: string = ""
  var resp: DhtMessage
  try:
    resp = await withTimeout(queryFut, timeoutMs)
  except CatchableError as e:
    queryError = e.msg
  # Always clean up pending query entry (may already be removed by onRecv handler)
  client.dhtRemovePending(pendingKey)
  if queryError.len > 0:
    raise newException(CatchableError, queryError)
  return resp

proc generateDhtSecret(client: TorrentClient) =
  ## Generate a new DHT token secret.
  var s = newString(8)
  for i in 0 ..< 8:
    s[i] = char(btRandU32() and 0xFF)
  client.dhtPrevSecret = client.dhtSecret
  client.dhtSecret = s

proc refreshSecureDhtIdentity(client: TorrentClient) =
  ## BEP 42: derive secure node ID when a public IPv4 endpoint is known.
  if not client.dhtEnabled:
    return
  var publicIp = ""
  if client.natMgr != nil:
    if isPublicIpv4(client.natMgr.externalIp):
      publicIp = client.natMgr.externalIp
    elif isPublicIpv4(client.natMgr.localIp):
      publicIp = client.natMgr.localIp
  if publicIp.len == 0:
    return
  try:
    client.dhtNodeId = generateSecureNodeId(publicIp)
    client.dhtRoutingTable = newRoutingTable(client.dhtNodeId)
    client.dhtRoutingTable6 = newRoutingTable(client.dhtNodeId)
  except CatchableError:
    discard

proc extractIpPort(srcAddr: Sockaddr_storage, addrLen: SockLen): tuple[ip: string, port: uint16] =
  ## Extract IP and port from a Sockaddr_storage.
  ## Handles both IPv4 (AF_INET) and IPv6 (AF_INET6) address families.
  ## IPv4-mapped IPv6 addresses (::ffff:x.x.x.x) are returned as plain IPv4.
  if srcAddr.ss_family.cint == toInt(AF_INET6):
    let sa6 = cast[ptr Sockaddr_in6](unsafeAddr srcAddr)
    let addrBytes = cast[ptr array[16, byte]](unsafeAddr sa6.sin6_addr)
    result.port = ntohs(sa6.sin6_port)
    # Check for IPv4-mapped IPv6 (::ffff:x.x.x.x): first 10 bytes zero, bytes 10-11 = 0xFF
    var isV4Mapped = true
    for i in 0 ..< 10:
      if addrBytes[i] != 0:
        isV4Mapped = false
        break
    if isV4Mapped and addrBytes[10] == 0xFF and addrBytes[11] == 0xFF:
      result.ip = $addrBytes[12] & "." & $addrBytes[13] & "." & $addrBytes[14] & "." & $addrBytes[15]
    else:
      var parts: array[8, uint16]
      for i in 0 ..< 8:
        parts[i] = (uint16(addrBytes[i*2]) shl 8) or uint16(addrBytes[i*2 + 1])
      var expanded = ""
      for i in 0 ..< 8:
        if i > 0: expanded.add(':')
        expanded.add(parts[i].int.toHex(4).toLowerAscii())
      result.ip = canonicalizeIpv6(expanded)
  else:
    let sa = cast[ptr Sockaddr_in](unsafeAddr srcAddr)
    let addrBytes = cast[ptr array[4, byte]](addr sa.sin_addr)
    result.ip = $addrBytes[0] & "." & $addrBytes[1] & "." & $addrBytes[2] & "." & $addrBytes[3]
    result.port = ntohs(sa.sin_port)

proc setupDhtSocket(client: TorrentClient): bool =
  ## Create UDP socket with persistent onRecv callback for DHT messages.
  ## Handles both outgoing query responses and incoming queries from other nodes.
  ## Try dual-stack IPv6 first, fall back to IPv4.
  ## Returns false if socket creation fails (fd exhaustion, etc).
  client.generateDhtSecret()
  var sockReady = false
  # Try dual-stack IPv6 first
  try:
    client.dhtSock = newUdpSocket(AF_INET6)
    var no: cint = 0
    discard setsockoptRaw(client.dhtSock.fd, IPPROTO_IPV6_C, IPV6_V6ONLY_C,
                         addr no, sizeof(no).SockLen)
    client.dhtSock.bindAddr("::", 0)
    sockReady = true
  except CatchableError:
    discard
  # Fall back to IPv4
  if not sockReady:
    try:
      client.dhtSock = newUdpSocket()
      client.dhtSock.bindAddr("0.0.0.0", 0)
      sockReady = true
    except CatchableError:
      return false
  # Lock-free: reactor callback only parses and pushes to Treiber stack.
  # All routing table access, response sending, and query matching happen
  # in the CPS dhtRecvDrainLoop — zero locks on the reactor thread.
  client.dhtSock.onRecv(1500, proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
    try:
      let msg = decodeDhtMessage(data)
      {.cast(gcsafe).}:
        client.pushDhtRecv(msg, srcAddr, addrLen)
    except CatchableError:
      discard
  )
  return true

const
  DhtBootstrapHosts = ["router.bittorrent.com", "dht.transmissionbt.com",
                       "router.utorrent.com", "dht.aelitis.com",
                       "dht.libtorrent.org"]
  DhtBootstrapPort = 6881
  DhtLookupIntervalMs = 30000   ## Re-query DHT every 30s
  DhtInitialLookupMs = 5000     ## First few lookups at 5s interval for fast discovery
  DhtIterativeMaxRounds = 10    ## Max iterative rounds per lookup
  DhtIterativeWidth = 24        ## Query up to 24 nodes per round
  DhtRoundTimeoutMs = 5000      ## Wait up to 5s for responses per round

# Keep DHT iterative CPS flows on copy semantics: large transformed environments
# carry seq/string state across await points and can alias under ARC sink moves.
proc dhtIterativeFindNode(client: TorrentClient, target: NodeId): CpsVoidFuture {.cps, nosinks.} =
  ## Iterative Kademlia find_node: fire queries in parallel per round,
  ## collect responses, follow returned nodes closer to the target.
  var queriedKeys: HashSet[string]  ## Track "ip:port" of already-queried nodes
  var discoveredNodes: seq[DhtNode]  ## Nodes discovered but not in routing table
  var round: int = 0
  while round < DhtIterativeMaxRounds:
    round += 1
    # Merge routing table nodes with discovered nodes for candidates
    var candidates: seq[DhtNode] = client.dhtFindClosest(target, DhtIterativeWidth)
    var di: int = 0
    while di < discoveredNodes.len:
      candidates.addNodeIfEndpointNew(discoveredNodes[di])
      di += 1
    sortByXorDistance(candidates, target)
    var newNodesFound: int = 0
    let prevDiscoveredCount: int = discoveredNodes.len

    # Fire all queries in this round concurrently
    var fnFutures: seq[CpsFuture[DhtMessage]]
    var fnPendingKeys: seq[string]  # Parallel array: composite pending key for each future
    var fnNodeIds: seq[NodeId]  # Parallel array: node ID for markFailed on timeout/error
    var ci: int = 0
    while ci < candidates.len:
      let node: DhtNode = candidates[ci]
      ci += 1
      let nodeKey: string = node.ip & ":" & $node.port
      if nodeKey in queriedKeys:
        continue
      queriedKeys.incl(nodeKey)
      let transId: string = client.nextDhtTransId()
      let fnData: string = encodeFindNodeQuery(transId, client.dhtNodeId, target)
      var sendOk: bool = false
      try:
        sendOk = client.dhtSock.trySendToAddr(fnData, node.ip, node.port.int)
      except Exception:
        sendOk = false
      if not sendOk:
        client.dhtMarkFailed(node.id)
        continue  # Don't register a future for a failed send
      let queryFut: CpsFuture[DhtMessage] = newCpsFuture[DhtMessage]()
      queryFut.pinFutureRuntime()
      let pendingKey: string = dhtPendingKey(transId, node.ip, node.port.int)
      client.dhtRegisterPending(pendingKey, queryFut)
      fnFutures.add(queryFut)
      fnPendingKeys.add(pendingKey)
      fnNodeIds.add(node.id)
      if fnFutures.len >= DhtIterativeWidth:
        ci = candidates.len

    if fnFutures.len == 0:
      return  # No new nodes to query

    # Wait for either: all query futures done, round timeout, or client stop.
    discard await waitAllOrSignal(fnFutures, DhtRoundTimeoutMs, client.stopSignal)

    # Process all responses that finished within this round window.
    var fni: int = 0
    while fni < fnFutures.len:
      let fnf: CpsFuture[DhtMessage] = fnFutures[fni]
      fni += 1
      if fnf == nil:
        continue
      if not fnf.finished:
        continue  # Will be handled by cancel loop below
      if fnf.hasError:
        # Error response — mark the node as failed so it can be evicted
        client.dhtMarkFailed(fnNodeIds[fni - 1])
        continue
      let fnMsg: DhtMessage = fnf.read()
      if not fnMsg.isQuery:
        var ni: int = 0
        while ni < fnMsg.nodes.len:
          let cn: CompactNodeInfo = fnMsg.nodes[ni]
          ni += 1
          let newNode: DhtNode = DhtNode(
            id: cn.id, ip: cn.ip, port: cn.port, lastSeen: epochTime())
          if client.shouldAcceptDhtNode(newNode.id, newNode.ip):
            let added: bool = client.dhtAddNode(newNode)
            if added:
              newNodesFound += 1
            else:
              discoveredNodes.add(newNode)

    # Cancel remaining futures and clean up pending query table entries
    var cfi: int = 0
    while cfi < fnFutures.len:
      if fnFutures[cfi] != nil:
        if not fnFutures[cfi].finished:
          fnFutures[cfi].cancel()
          # Timed-out node — mark as failed for eviction
          client.dhtMarkFailed(fnNodeIds[cfi])
        fnFutures[cfi] = nil
      # Remove from pending queries table (may already be removed by onRecv)
      client.dhtRemovePending(fnPendingKeys[cfi])
      cfi += 1

    # Prune discoveredNodes to bound O(n²) merge/sort cost in future rounds.
    let maxDiscovered = DhtIterativeWidth * 2
    if discoveredNodes.len > maxDiscovered:
      sortByXorDistance(discoveredNodes, target, maxDiscovered)

    # Converged — no new nodes found this round (neither table insertions nor new discoveries)
    let newDiscovered: int = discoveredNodes.len - prevDiscoveredCount
    if newNodesFound == 0 and newDiscovered == 0:
      return

proc dhtIterativeGetPeers(client: TorrentClient, infoHash: NodeId): CpsFuture[int] {.cps, nosinks.} =
  ## Iterative get_peers: fire queries in parallel per round, collect peers
  ## and follow returned nodes closer to the target.
  ## Returns the number of new peers found.
  ## Also caches tokens and sends announce_peer to nodes that gave us tokens.
  var queriedKeys: HashSet[string]
  var totalPeersFound: int = 0
  var totalNodesFound: int = 0
  # Track nodes that gave us tokens for announce_peer
  var tokenNodes: seq[tuple[ip: string, port: uint16, token: string]]
  # Keep ALL discovered nodes for querying (not just routing table nodes)
  var discoveredNodes: seq[DhtNode]
  var round: int = 0
  while round < DhtIterativeMaxRounds:
    round += 1
    # Merge routing table nodes with discovered nodes for candidates
    var candidates: seq[DhtNode] = client.dhtFindClosest(infoHash, DhtIterativeWidth)
    var di: int = 0
    while di < discoveredNodes.len:
      candidates.addNodeIfEndpointNew(discoveredNodes[di])
      di += 1
    sortByXorDistance(candidates, infoHash)
    var newNodesFound: int = 0

    # Fire all queries in this round concurrently, track which node each future maps to
    var gpFutures: seq[CpsFuture[DhtMessage]]
    var gpNodeAddrs: seq[CompactPeer]  # Parallel array with gpFutures
    var gpPendingKeys: seq[string]  # Parallel array: composite pending key for each future
    var gpNodeIds: seq[NodeId]  # Parallel array: node ID for markFailed on timeout/error
    var ci: int = 0
    while ci < candidates.len:
      let node: DhtNode = candidates[ci]
      ci += 1
      let nodeKey: string = node.ip & ":" & $node.port
      if nodeKey in queriedKeys:
        continue
      queriedKeys.incl(nodeKey)
      let transId: string = client.nextDhtTransId()
      let gpData: string = encodeGetPeersQuery(transId, client.dhtNodeId, infoHash)
      var sendOk: bool = false
      try:
        sendOk = client.dhtSock.trySendToAddr(gpData, node.ip, node.port.int)
      except Exception:
        sendOk = false
      if not sendOk:
        client.dhtMarkFailed(node.id)
        continue  # Don't register a future for a failed send
      let queryFut: CpsFuture[DhtMessage] = newCpsFuture[DhtMessage]()
      queryFut.pinFutureRuntime()
      let pendingKey: string = dhtPendingKey(transId, node.ip, node.port.int)
      client.dhtRegisterPending(pendingKey, queryFut)
      gpFutures.add(queryFut)
      gpNodeAddrs.add((node.ip, node.port))
      gpPendingKeys.add(pendingKey)
      gpNodeIds.add(node.id)
      # Cap queries per round to avoid flooding
      if gpFutures.len >= DhtIterativeWidth:
        ci = candidates.len  # break

    if gpFutures.len == 0:
      await client.events.send(ClientEvent(kind: cekInfo,
        errMsg: "  DHT get_peers round " & $round & ": no new nodes to query (queried " &
                $queriedKeys.len & " total, table has " & $client.dhtTotalNodes() & " nodes)"))
      break  # No new nodes to query — done iterating

    # Wait for either: all query futures done, round timeout, or client stop.
    let roundStart = epochTime()
    discard await waitAllOrSignal(gpFutures, DhtRoundTimeoutMs, client.stopSignal)
    let waitedMs: int = int((epochTime() - roundStart) * 1000.0)

    # Process all responses that finished within this round window.
    # Collect peers to queue — batched under mtx after processing.
    var peersToQueue: seq[CompactPeer]
    var pendingCount: int = 0
    var roundResponses: int = 0
    var roundErrors: int = 0
    var roundPeers: int = 0
    var roundNodes: int = 0
    var roundTokens: int = 0
    var gpi: int = 0
    while gpi < gpFutures.len:
      let gpf: CpsFuture[DhtMessage] = gpFutures[gpi]
      gpi += 1
      if gpf == nil:
        continue
      if not gpf.finished:
        pendingCount += 1
        continue
      if gpf.hasError:
        roundErrors += 1
        client.dhtMarkFailed(gpNodeIds[gpi - 1])
        continue
      roundResponses += 1
      let gpMsg: DhtMessage = gpf.read()
      if gpMsg.errorCode != 0:
        roundErrors += 1
        client.dhtMarkFailed(gpNodeIds[gpi - 1])
        continue
      if not gpMsg.isQuery:
        # Cache token from response for announce_peer
        if gpMsg.respToken.len > 0:
          let nodeAddr = gpNodeAddrs[gpi - 1]
          tokenNodes.add((nodeAddr.ip, nodeAddr.port, gpMsg.respToken))
          roundTokens += 1
        # Collect returned peers for batched queueing under mtx
        roundPeers += gpMsg.values.len
        var vi: int = 0
        while vi < gpMsg.values.len:
          let peerInfo = gpMsg.values[vi]
          vi += 1
          peersToQueue.add((peerInfo.ip, peerInfo.port))
        # Add returned nodes to routing table AND discovery list
        roundNodes += gpMsg.nodes.len
        var ni: int = 0
        while ni < gpMsg.nodes.len:
          let cn: CompactNodeInfo = gpMsg.nodes[ni]
          ni += 1
          let newNode: DhtNode = DhtNode(
            id: cn.id, ip: cn.ip, port: cn.port, lastSeen: epochTime())
          if client.shouldAcceptDhtNode(newNode.id, newNode.ip):
            let added: bool = client.dhtAddNode(newNode)
            # Even if not added to routing table, keep for iterative querying
            if not added:
              discoveredNodes.add(newNode)
            if added:
              newNodesFound += 1
              totalNodesFound += 1

    # Batch queue discovered peers under mtx (protects pendingPeers/peers/failedPeers)
    if peersToQueue.len > 0:
      await lock(client.mtx)
      try:
        var pqi: int = 0
        while pqi < peersToQueue.len:
          if client.queuePeerIfNeeded(peersToQueue[pqi].ip, peersToQueue[pqi].port, srcDht, 0'u8):
            totalPeersFound += 1
          pqi += 1
      finally:
        unlock(client.mtx)

    # Cancel remaining futures and clean up pending query table entries
    var timedOut: int = 0
    var cfi: int = 0
    while cfi < gpFutures.len:
      if gpFutures[cfi] != nil:
        if not gpFutures[cfi].finished:
          gpFutures[cfi].cancel()
          timedOut += 1
          # Timed-out node — mark as failed for eviction
          client.dhtMarkFailed(gpNodeIds[cfi])
        gpFutures[cfi] = nil
      # Remove from pending queries table (may already be removed by onRecv)
      client.dhtRemovePending(gpPendingKeys[cfi])
      cfi += 1

    await client.events.send(ClientEvent(kind: cekInfo,
      errMsg: "  DHT get_peers round " & $round & ": sent=" & $gpFutures.len &
              " resp=" & $roundResponses & " err=" & $roundErrors &
              " timeout=" & $timedOut & " peers=" & $roundPeers &
              " nodes=" & $roundNodes & " tokens=" & $roundTokens &
              " pending=" & $pendingCount & " waited=" & $waitedMs & "ms"))

    # Prune discoveredNodes to bound O(n²) merge/sort cost in future rounds.
    let maxDiscovered = DhtIterativeWidth * 2
    if discoveredNodes.len > maxDiscovered:
      sortByXorDistance(discoveredNodes, infoHash, maxDiscovered)

    # Stop if converged: no new closer nodes discovered AND no peers found.
    # Don't stop merely because roundResponses == 0 (a slow round with all
    # timeouts) — there may still be unqueried discovered nodes to try.
    if newNodesFound == 0 and roundPeers == 0 and roundNodes == 0:
      break

  # Announce ourselves to nodes that gave us tokens (BEP 5)
  # This makes us discoverable by other peers doing get_peers for this torrent
  var ati: int = 0
  while ati < tokenNodes.len:
    let tn = tokenNodes[ati]
    ati += 1
    let transId: string = client.nextDhtTransId()
    let announceData: string = encodeAnnouncePeerQuery(
      transId, client.dhtNodeId, infoHash,
      client.config.listenPort.uint16, tn.token, impliedPort = false)
    discard client.dhtSock.trySendToAddr(announceData, tn.ip, tn.port.int)
    # Don't wait for responses — announce is fire-and-forget

  return totalPeersFound

proc dhtBootstrap(client: TorrentClient): CpsFuture[bool] {.cps.} =
  ## Try to bootstrap the DHT by pinging known routers in parallel.
  ## Resolves all hosts first, then fires pings concurrently for faster bootstrap.

  # Phase 1: Resolve all bootstrap hosts and collect unique IPs
  var allIps: seq[string]
  var bi: int = 0
  while bi < DhtBootstrapHosts.len:
    let host: string = DhtBootstrapHosts[bi]
    bi += 1
    let addrs: seq[string] = await resolveDhtBootstrapAddrs(host)
    var ai: int = 0
    while ai < addrs.len:
      let ip: string = addrs[ai]
      ai += 1
      var seen: bool = false
      var ui: int = 0
      while ui < allIps.len:
        if allIps[ui] == ip:
          seen = true
        ui += 1
      if not seen:
        allIps.add(ip)

  if allIps.len == 0:
    return false

  # Phase 2: Fire ping queries to all resolved IPs concurrently
  var pingFutures: seq[CpsFuture[DhtMessage]]
  var pingIps: seq[string]
  var pingPendingKeys: seq[string]
  var ipi: int = 0
  while ipi < allIps.len:
    let ip: string = allIps[ipi]
    ipi += 1
    let transId: string = client.nextDhtTransId()
    let pingData: string = encodePingQuery(transId, client.dhtNodeId)
    let pendingKey: string = dhtPendingKey(transId, ip, DhtBootstrapPort)
    let queryFut: CpsFuture[DhtMessage] = newCpsFuture[DhtMessage]()
    queryFut.pinFutureRuntime()
    client.dhtRegisterPending(pendingKey, queryFut)
    var sendOk: bool = false
    try:
      sendOk = client.dhtSock.trySendToAddr(pingData, ip, DhtBootstrapPort)
    except Exception:
      sendOk = false
    if not sendOk:
      client.dhtRemovePending(pendingKey)
      continue
    pingFutures.add(queryFut)
    pingIps.add(ip)
    pingPendingKeys.add(pendingKey)

  if pingFutures.len == 0:
    return false

  # Wait up to 5s for bootstrap responses
  discard await waitAllOrSignal(pingFutures, 5000, client.stopSignal)

  # Phase 3: Process responses and populate routing table
  var seedsAdded: int = 0
  var pfi: int = 0
  while pfi < pingFutures.len:
    let pf: CpsFuture[DhtMessage] = pingFutures[pfi]
    let ip: string = pingIps[pfi]
    pfi += 1
    if pf == nil or not pf.finished or pf.hasError:
      continue
    let msg: DhtMessage = pf.read()
    if msg.isQuery or msg.errorCode != 0 or isZeroNodeId(msg.responderId):
      continue
    discard client.dhtAddNode(DhtNode(
      id: msg.responderId, ip: ip, port: DhtBootstrapPort.uint16,
      lastSeen: epochTime()
    ))
    seedsAdded += 1

  # Cancel any remaining pending futures and clean up
  var cfi: int = 0
  while cfi < pingFutures.len:
    if pingFutures[cfi] != nil:
      if not pingFutures[cfi].finished:
        pingFutures[cfi].cancel()
      pingFutures[cfi] = nil
    client.dhtRemovePending(pingPendingKeys[cfi])
    cfi += 1

  return seedsAdded > 0

const
  DhtSecretRotationMs = 300000   ## Rotate token secret every 5 min
  DhtPeerStoreTtlSec = 1800.0   ## Expire stored peers after 30 min
  DhtBucketRefreshSec = 900.0   ## Refresh stale buckets after 15 min

proc dhtRefreshStaleBuckets(client: TorrentClient, isIpv6: bool) =
  ## Ping least-recently-seen node in up to 3 stale buckets (IPv4 or IPv6).
  ## Registers pending queries so responses update the routing table lastSeen.
  let staleIdxs = if isIpv6: client.dhtStaleBuckets6(DhtBucketRefreshSec)
                  else: client.dhtStaleBuckets(DhtBucketRefreshSec)
  var i = 0
  while i < staleIdxs.len and i < 3:
    let node = if isIpv6: client.dhtLeastRecentlySeenNode6(staleIdxs[i])
               else: client.dhtLeastRecentlySeenNode(staleIdxs[i])
    i += 1
    let transId = client.nextDhtTransId()
    let pingData = encodePingQuery(transId, client.dhtNodeId)
    let pendingKey = dhtPendingKey(transId, node.ip, node.port.int)
    let fut = newCpsFuture[DhtMessage]()
    client.dhtRegisterPending(pendingKey, fut)
    var sendOk = false
    try:
      sendOk = client.dhtSock.trySendToAddr(pingData, node.ip, node.port.int)
    except CatchableError:
      sendOk = false
    if not sendOk:
      client.dhtRemovePending(pendingKey)
      client.dhtMarkFailed(node.id)

proc dhtCleanup(client: TorrentClient) =
  ## Cancel pending DHT queries and close socket. Called from finally block.
  withSpinLock(client.dhtSpinLock):
    var dhtKeys: seq[string]
    for k in client.dhtPendingQueries.keys:
      dhtKeys.add(k)
    for k in dhtKeys:
      if k in client.dhtPendingQueries:
        let fut = client.dhtPendingQueries[k]
        if not fut.finished:
          fut.cancel()
    client.dhtPendingQueries.clear()
  if client.dhtSock != nil:
    client.dhtSock.close()

proc dhtFindClosestCompact(client: TorrentClient, target: NodeId, count: int): seq[CompactNodeInfo] =
  ## Find closest nodes from both routing tables and return as CompactNodeInfo.
  let nodes = client.dhtFindClosest(target, count)
  var ni = 0
  while ni < nodes.len:
    result.add(CompactNodeInfo(id: nodes[ni].id, ip: nodes[ni].ip, port: nodes[ni].port))
    ni += 1

proc dhtProcessRecvBatch(client: TorrentClient) =
  ## Process all buffered DHT messages from the lock-free receive queue.
  ## Handles both incoming queries (send responses) and outgoing query responses
  ## (complete pending futures). Called from dhtRecvDrainLoop under no lock.
  let batch = client.drainDhtRecv()
  for item in batch:
    let msg = item.msg
    if msg.isQuery:
      let (senderIp, senderPort) = extractIpPort(item.srcAddr, item.addrLen)
      # Update correct routing table (BEP 32: separate IPv4/IPv6 tables)
      var accepted: bool
      withSpinLock(client.dhtSpinLock):
        accepted = client.shouldAcceptDhtNode(msg.queryerId, senderIp)
        if accepted:
          let senderNode = DhtNode(
            id: msg.queryerId, ip: senderIp, port: senderPort, lastSeen: epochTime())
          if isIpv6(senderIp):
            discard client.dhtRoutingTable6.addNode(senderNode)
          else:
            discard client.dhtRoutingTable.addNode(senderNode)
      # Send responses outside the spinlock (network I/O)
      case msg.queryType
      of "ping":
        let resp = encodePingResponse(msg.transactionId, client.dhtNodeId)
        discard client.dhtSock.trySendToAddr(resp, senderIp, senderPort.int)
      of "find_node":
        let compactNodes = client.dhtFindClosestCompact(msg.targetId, K)
        let resp = encodeFindNodeResponse(msg.transactionId, client.dhtNodeId, compactNodes)
        discard client.dhtSock.trySendToAddr(resp, senderIp, senderPort.int)
      of "get_peers":
        var token: string
        var storedPeers: seq[CompactPeer]
        withSpinLock(client.dhtSpinLock):
          token = generateToken(senderIp, client.dhtSecret)
          storedPeers = client.dhtPeerStore.getPeers(msg.infoHash)
        if storedPeers.len > 0:
          let resp = encodeGetPeersResponse(msg.transactionId, client.dhtNodeId,
                                             token, peers = storedPeers)
          discard client.dhtSock.trySendToAddr(resp, senderIp, senderPort.int)
        else:
          let compactNodes = client.dhtFindClosestCompact(msg.infoHash, K)
          let resp = encodeGetPeersResponse(msg.transactionId, client.dhtNodeId,
                                             token, nodes = compactNodes)
          discard client.dhtSock.trySendToAddr(resp, senderIp, senderPort.int)
      of "announce_peer":
        var tokenOk: bool
        withSpinLock(client.dhtSpinLock):
          tokenOk = validateToken(msg.token, senderIp, client.dhtSecret, client.dhtPrevSecret)
        if tokenOk:
          let announcePort = if msg.impliedPort: senderPort else: msg.announcePort
          if announcePort >= 1 and announcePort <= 65535:
            withSpinLock(client.dhtSpinLock):
              client.dhtPeerStore.addPeer(msg.infoHash, senderIp, announcePort)
            let resp = encodePingResponse(msg.transactionId, client.dhtNodeId)
            discard client.dhtSock.trySendToAddr(resp, senderIp, senderPort.int)
          else:
            let resp = encodeDhtError(msg.transactionId, 203, "invalid port")
            discard client.dhtSock.trySendToAddr(resp, senderIp, senderPort.int)
        else:
          let resp = encodeDhtError(msg.transactionId, 203, "bad token")
          discard client.dhtSock.trySendToAddr(resp, senderIp, senderPort.int)
      else:
        discard
    else:
      # Response to our outgoing query — match by (transactionId, sender endpoint)
      let (respIp, respPort) = extractIpPort(item.srcAddr, item.addrLen)
      let pendingKey = dhtPendingKey(msg.transactionId, respIp, respPort.int)
      var fut: CpsFuture[DhtMessage] = nil
      withSpinLock(client.dhtSpinLock):
        if pendingKey in client.dhtPendingQueries:
          fut = client.dhtPendingQueries[pendingKey]
          client.dhtPendingQueries.del(pendingKey)
      if fut != nil and not fut.finished:
        # Any valid response proves the node is alive — update lastSeen.
        let accepted = client.shouldAcceptDhtNode(msg.responderId, respIp)
        if accepted:
          let respNode = DhtNode(
            id: msg.responderId, ip: respIp, port: respPort, lastSeen: epochTime())
          withSpinLock(client.dhtSpinLock):
            if isIpv6(respIp):
              discard client.dhtRoutingTable6.addNode(respNode)
            else:
              discard client.dhtRoutingTable.addNode(respNode)
        fut.complete(msg)

proc dhtRecvDrainLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## CPS task that drains the lock-free DHT receive buffer every 5ms.
  ## All DHT message processing (queries + responses) happens here,
  ## keeping the reactor thread completely lock-free.
  while client.state in {csDownloading, csSeeding, csStarting}:
    client.dhtProcessRecvBatch()
    await cpsSleep(5)
  # Final drain for any messages received during shutdown
  client.dhtProcessRecvBatch()

proc dhtLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## DHT peer discovery loop (BEP 5).
  ## Bootstraps with iterative crawling, then periodically queries for peers.
  ## Retries bootstrap with backoff for as long as the torrent is active.
  if not client.dhtEnabled:
    return

  if not client.setupDhtSocket():
    await client.events.send(ClientEvent(kind: cekError,
      errMsg: "DHT disabled: failed to create UDP socket"))
    return

  # Start the lock-free DHT receive drain loop alongside the discovery loop
  discard spawn dhtRecvDrainLoop(client)

  # Step 1: Bootstrap — ping known routers until at least one responds.
  var bootstrapOk: bool = false
  var attempt: int = 0
  while not bootstrapOk and client.state in {csDownloading, csSeeding}:
    attempt += 1
    bootstrapOk = await client.dhtBootstrap()
    if not bootstrapOk:
      var retryMs: int = 10000
      if attempt > 3:
        let shift: int = min(attempt - 3, 3)
        retryMs = min(60000, 10000 * (1 shl shift))
      await client.events.send(ClientEvent(kind: cekError,
        errMsg: "DHT bootstrap attempt " & $attempt & " failed, retrying in " &
                $(retryMs div 1000) & "s..."))
      await client.sleepOrStop(retryMs)

  if bootstrapOk:
    # Step 2: Iterative find_node to populate routing table (multiple passes)
    await client.dhtIterativeFindNode(client.dhtNodeId)
    let rtSize1: int = client.dhtTotalNodes()
    # Second pass with info hash as target to find nodes closer to our torrent
    var infoAsTarget: NodeId
    for ifi in 0 ..< 20:
      infoAsTarget[ifi] = client.metainfo.info.infoHash[ifi]
    await client.dhtIterativeFindNode(infoAsTarget)
    let rtSize: int = client.dhtTotalNodes()
    await client.events.send(ClientEvent(kind: cekInfo,
      errMsg: "DHT bootstrapped: " & $rtSize & " nodes (self-lookup: " & $rtSize1 & ")"))

    # Step 3: Periodic iterative get_peers + routing table refresh loop
    var infoHashAsNodeId: NodeId
    for i in 0 ..< 20:
      infoHashAsNodeId[i] = client.metainfo.info.infoHash[i]

    var lookupCount: int = 0
    var lastSecretRotation: float = epochTime()
    var lastPeerExpiry: float = epochTime()
    while client.state in {csDownloading, csSeeding} and not client.isPrivate:
      let peersFound: int = await client.dhtIterativeGetPeers(infoHashAsNodeId)
      lookupCount += 1
      let rtNodes: int = client.dhtTotalNodes()
      await client.events.send(ClientEvent(kind: cekInfo,
        errMsg: "DHT lookup #" & $lookupCount & ": " & $peersFound &
                " peers found, " & $rtNodes & " nodes in table"))

      # Every 4th lookup, do a find_node to refresh the routing table
      if lookupCount mod 4 == 0:
        await client.dhtIterativeFindNode(infoHashAsNodeId)

      let now: float = epochTime()

      # Token secret rotation (#46): rotate every 5 minutes
      if (now - lastSecretRotation) * 1000.0 >= float(DhtSecretRotationMs):
        client.dhtRotateSecret()
        lastSecretRotation = now

      # Peer store aging (#82): expire stale peers every lookup cycle
      if now - lastPeerExpiry >= DhtPeerStoreTtlSec / 2.0:
        client.dhtExpirePeers(DhtPeerStoreTtlSec)
        lastPeerExpiry = now

      # Routing table maintenance (#83): ping least-recently-seen node in stale buckets
      client.dhtRefreshStaleBuckets(isIpv6 = false)
      # IPv6 routing table maintenance (BEP 32)
      client.dhtRefreshStaleBuckets(isIpv6 = true)

      # First 5 lookups at shorter intervals for fast initial discovery.
      # When seeding with healthy peer count, slow down to avoid discovering
      # the same seeders repeatedly (reduces churn).
      if lookupCount <= 5:
        await client.sleepOrStop(DhtInitialLookupMs)
      elif client.state == csSeeding and client.connectedPeerCount >= MinPeers:
        await client.sleepOrStop(DhtLookupIntervalMs * 4)  # 120s between lookups
      elif client.state == csSeeding:
        await client.sleepOrStop(DhtLookupIntervalMs)  # 30s — still need leechers
      else:
        await client.sleepOrStop(DhtLookupIntervalMs)

  # Always clean up DHT state on exit (fixes socket leak #45)
  client.dhtCleanup()

proc unchokeLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Tit-for-tat choking algorithm (BEP 3 / libtorrent-style).
  ##
  ## Every UnchokeIntervalMs:
  ## - While downloading: unchoke top N peers by download rate (they give us most data)
  ## - While seeding: unchoke top N peers by upload rate (fastest uploaders to them)
  ## - Always keep one optimistic unchoke slot (rotated every 30s)
  var optimisticRotateTime: float = 0.0
  var lastCleanup: float = epochTime()

  while client.state in {csDownloading, csSeeding}:
    await cpsSleep(UnchokeIntervalMs)

    # Phase 1 (under lock): collect peer state and compute unchoke decisions.
    # No await in this phase — lock is held only for the snapshot.
    var unchokeKeys: seq[string]
    var chokeKeys: seq[string]
    await lock(client.mtx)
    try:
      if client.state in {csDownloading, csSeeding}:
        let now: float = epochTime()
        # Periodic cleanup of unbounded tables (covers seeding mode)
        if now - lastCleanup > StaleTableCleanupSec:
          lastCleanup = now
          client.cleanupStaleTables()

        # Collect interested peers and their transfer rates
        var interestedPeers: seq[PeerRate]

        let peerKeys = client.snapshotPeerKeys()

        var ki: int = 0
        while ki < peerKeys.len:
          let pk: string = peerKeys[ki]
          ki += 1
          if pk notin client.peers:
            continue
          let p: PeerConn = client.peers[pk]
          if p.state != psActive or not p.peerInterested:
            continue
          let rate: float = if client.state == csDownloading:
            float(p.bytesDownloaded - p.prevBytesDownloaded)
          else:
            float(p.bytesUploaded - p.prevBytesUploaded)
          interestedPeers.add((pk, rate))

        if interestedPeers.len > 0:
          btDebug "[SEED-DBG] unchokeLoop: ", $interestedPeers.len, " interested peers"
        interestedPeers.sort(cmpPeerRateDesc)

        # Determine unchoke set: top N by rate
        var unchokeSet: seq[string]
        var ui: int = 0
        while ui < interestedPeers.len and unchokeSet.len < MaxUnchokedPeers - 1:
          unchokeSet.add(interestedPeers[ui].key)
          ui += 1

        # Optimistic unchoke: rotate every 30s
        if now - optimisticRotateTime > 30.0 or client.optimisticPeerKey.len == 0:
          optimisticRotateTime = now
          client.optimisticPeerKey = ""
          var eligible: seq[int]
          var oi: int = 0
          while oi < interestedPeers.len:
            if interestedPeers[oi].key notin unchokeSet:
              eligible.add(oi)
            oi += 1
          if eligible.len > 0:
            client.optimisticPeerKey = interestedPeers[eligible[btRand(eligible.len)]].key

        if client.optimisticPeerKey.len > 0 and
           client.optimisticPeerKey notin unchokeSet:
          unchokeSet.add(client.optimisticPeerKey)

        # Build unchoke/choke decision lists (no I/O here)
        var ai: int = 0
        while ai < peerKeys.len:
          let pk: string = peerKeys[ai]
          ai += 1
          if pk notin client.peers:
            continue
          let p: PeerConn = client.peers[pk]
          if p.state != psActive:
            continue

          var shouldUnchoke: bool = false
          var si: int = 0
          while si < unchokeSet.len:
            if unchokeSet[si] == pk:
              shouldUnchoke = true
            si += 1

          if client.state == csSeeding and not shouldUnchoke and not p.amChoking and
             not p.peerInterested:
            if client.unchokedPeerCount <= MaxUnchokedPeers + 2:
              continue

          if shouldUnchoke and p.amChoking:
            unchokeKeys.add(pk)
          elif not shouldUnchoke and not p.amChoking:
            chokeKeys.add(pk)

    finally:
      unlock(client.mtx)

    # Phase 2 (no lock): send choke/unchoke messages.
    # Peers may disconnect between phases — guard each send.
    var ci: int = 0
    while ci < unchokeKeys.len:
      let pk: string = unchokeKeys[ci]
      ci += 1
      if pk in client.peers:
        let p: PeerConn = client.peers[pk]
        if p.state == psActive and p.amChoking:
          btDebug "[SEED-DBG] unchokeLoop: unchoking ", pk
          await p.sendUnchoke()
    ci = 0
    while ci < chokeKeys.len:
      let pk: string = chokeKeys[ci]
      ci += 1
      if pk in client.peers:
        let p: PeerConn = client.peers[pk]
        if p.state == psActive and not p.amChoking:
          await p.sendChoke()

    # Phase 3 (under lock): snapshot byte counters for next interval.
    await lock(client.mtx)
    try:
      var si2: int = 0
      while si2 < peerKeys.len:
        let pk: string = peerKeys[si2]
        si2 += 1
        if pk in client.peers:
          let p: PeerConn = client.peers[pk]
          p.prevBytesDownloaded = p.bytesDownloaded
          p.prevBytesUploaded = p.bytesUploaded
    finally:
      unlock(client.mtx)
proc handleIncomingPeer*(client: TorrentClient, stream: AsyncStream,
                         ip: string = "incoming", port: uint16 = 0,
                         transport: TransportKind = ptTcp) =
  ## Inject an incoming connection into this client. Non-CPS.
  ## Called by the bridge's shared accept loop after info hash dispatch.
  if client.connectedPeerCount >= client.config.maxPeers:
    stream.close()
    return
  if client.halfOpenCount >= MaxHalfOpen:
    stream.close()
    return
  if client.state notin {csDownloading, csSeeding}:
    stream.close()
    return
  # Reject self-connections early (before allocating PeerConn)
  if client.isOwnAddress(ip, port):
    stream.close()
    return
  # Reject incoming connections from known seeders when we're seeding —
  # they'll just churn (connect, exchange HAVE_ALL, neither side interested,
  # eventually evicted). Prevents the connect-disconnect cycle that gets us
  # banned from swarms.
  let inKey = peerKey(ip, port)
  if client.state == csSeeding and inKey in client.knownSeeders:
    stream.close()
    return
  let peer = newPeerConn(ip, port, client.metainfo.info.infoHash,
                         client.peerId, client.peerEvents,
                         client.localExtensions)
  client.nextConnGeneration += 1
  peer.connGeneration = client.nextConnGeneration
  peer.transport = transport
  peer.source = srcIncoming
  peer.localMetadataSize = client.rawInfoDict.len
  peer.bandwidthLimiter = client.bandwidthLimiter
  peer.torrentWireDownloaded = addr client.wireDownloaded
  peer.torrentWireUploaded = addr client.wireUploaded
  peer.encryptionMode = client.config.encryptionMode
  if client.utpMgr != nil and client.utpMgr.port > 0:
    peer.localUtpPort = client.utpMgr.port.uint16
  elif client.config.listenPort > 0:
    peer.localUtpPort = client.config.listenPort
  let key = peerKey(ip, port)
  # Check if this incoming connection is from a holepunch target we're expecting.
  # This survives the outgoing peer's disconnect cleanup.
  if client.hp.isExpected(key):
    if transport == ptUtp:
      peer.source = srcHolepunch
      btDebug "[HP] Incoming peer matched holepunchExpected: ", key
    client.hp.clearExpected(key)
  if key in client.peers:
    let existing = client.peers[key]
    if existing.state == psConnecting and client.hp.isInFlight(key):
      # BEP 55 simultaneous-open race: our outbound attempt is still connecting
      # but the remote's inbound SYN arrived first. Accept the inbound winner.
      btDebug "[HP] Simultaneous-open race won by incoming for ", key
      existing.state = psDisconnected
      client.halfOpenCount = max(0, client.halfOpenCount - 1)
      client.delPeer(key)
      if transport == ptUtp:
        peer.source = srcHolepunch
    else:
      stream.close()
      return
  client.setPeer(key, peer)
  client.halfOpenCount += 1
  discard runIncoming(peer, stream)

proc acceptLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Accept incoming TCP peer connections.
  ## Skipped when using a shared listener (bridge runs its own dispatcher).
  if client.listener == nil or client.config.sharedListener != nil:
    return
  while client.state in {csDownloading, csSeeding}:
    let tcpStream: TcpStream = await client.listener.accept()
    let ep = tcpStream.peerEndpoint()
    await lock(client.mtx)
    try:
      if ep.ip.len > 0 and ep.port > 0:
        client.handleIncomingPeer(tcpStream.AsyncStream, ep.ip, ep.port, ptTcp)
      else:
        client.handleIncomingPeer(tcpStream.AsyncStream, "incoming", 0, ptTcp)

    finally:
      unlock(client.mtx)
proc utpAcceptLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Accept incoming uTP peer connections.
  ## Skipped when using a shared uTP manager (bridge runs its own dispatcher).
  if client.utpMgr == nil or client.config.sharedUtpMgr != nil:
    return
  while client.state in {csDownloading, csSeeding}:
    let utpStream: UtpStream = await utpAccept(client.utpMgr)
    await lock(client.mtx)
    try:
      client.handleIncomingPeer(utpStream.AsyncStream,
                                utpStream.remoteIp, utpStream.remotePort.uint16,
                                ptUtp)

    finally:
      unlock(client.mtx)
proc webSeedLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Download pieces from HTTP web seeds (BEP 19).
  ## Uses split-lock pattern: mtx held for piece selection + data processing,
  ## released during HTTP I/O to avoid blocking other tasks.
  if client.webSeeds.len == 0 or not client.config.enableWebSeed:
    return

  while client.state == csDownloading:
    # Check pieceMgr under mtx
    await lock(client.mtx)
    var skipToSleep: bool = false
    try:
      if client.pieceMgr == nil or client.pieceMgr.isComplete:
        skipToSleep = true
    finally:
      unlock(client.mtx)
    if skipToSleep:
      await cpsSleep(5000)
      continue

    var downloadedAny: bool = false
    var wi: int = 0
    while wi < client.webSeeds.len:
      let ws: WebSeed = client.webSeeds[wi]
      wi += 1
      if ws.state == wssFailed and ws.failCount >= 3:
        continue

      # Phase 1: Find piece and mark blocks (under mtx)
      var pieceIdx: int = -1
      var pieceLen: int = 0
      var wsBlockOffsets: seq[int]
      await lock(client.mtx)
      try:
        var partialIdx: int = -1
        var pi: int = 0
        while pi < client.pieceMgr.totalPieces and pieceIdx < 0:
          if client.isSelectedPiece(pi):
            if client.pieceMgr.pieces[pi].state == psEmpty:
              pieceIdx = pi
            elif client.pieceMgr.pieces[pi].state == psPartial and partialIdx < 0:
              partialIdx = pi
          pi += 1
        if pieceIdx < 0:
          pieceIdx = partialIdx
        if pieceIdx >= 0:
          pieceLen = client.metainfo.info.pieceSize(pieceIdx)
          var markOff: int = 0
          while markOff < pieceLen:
            let blkLen = min(BlockSize, pieceLen - markOff)
            if client.pieceMgr.pieces[pieceIdx].state notin {psOptimistic, psVerified, psComplete}:
              var bi: int = 0
              while bi < client.pieceMgr.pieces[pieceIdx].blocks.len:
                if client.pieceMgr.pieces[pieceIdx].blocks[bi].offset == markOff and
                   client.pieceMgr.pieces[pieceIdx].blocks[bi].state == bsEmpty:
                  client.pieceMgr.markBlockRequested(pieceIdx, markOff)
                  wsBlockOffsets.add(markOff)
                  break
                bi += 1
            markOff += blkLen
      finally:
        unlock(client.mtx)

      if pieceIdx < 0:
        continue

      # Phase 2: HTTP download (no lock — allows other tasks to proceed)
      try:
        ws.state = wssDownloading
        client.webSeedActiveUrl = ws.url
        let ranges = buildPieceRanges(ws.url, client.metainfo.info, pieceIdx, pieceLen, BlockSize)
        if ranges.len == 0:
          raise newException(WebSeedError, "no ranges produced for piece")
        var data = newString(pieceLen)
        for rr in ranges:
          let expectedChunkLen = int(rr.rangeEnd - rr.rangeStart + 1)
          let chunk: string = await withTimeout(
            httpRangeRequest(rr.url, rr.rangeStart, rr.rangeEnd), 30000)
          if chunk.len != expectedChunkLen:
            raise newException(WebSeedError,
              "webseed short read: got " & $chunk.len & " expected " & $expectedChunkLen)
          if chunk.len > 0:
            copyMem(addr data[rr.pieceOffset], unsafeAddr chunk[0], chunk.len)

        # Phase 3: Process downloaded data (under mtx)
        await lock(client.mtx)
        try:
          client.webSeedBytes += int64(data.len)
          var offset: int = 0
          while offset < data.len:
            let blockLen = min(BlockSize, data.len - offset)
            let complete = client.pieceMgr.receiveBlock(pieceIdx, offset, data[offset ..< offset + blockLen])
            offset += blockLen
            if complete:
              # Release mutex for SHA1 + disk I/O
              unlock(client.mtx)
              let valid: bool = await verifyPieceHash(client.pieceMgr, pieceIdx)
              var wsWriteError: string = ""
              var wsPieceData: string = ""
              if valid:
                wsPieceData = client.pieceMgr.getPieceData(pieceIdx)
                try:
                  client.storageMgr.writePiece(pieceIdx, wsPieceData)
                except CatchableError as we:
                  wsWriteError = we.msg
              await lock(client.mtx)
              # Apply state under mutex — guard against concurrent optimistic transition
              if client.pieceMgr.pieces[pieceIdx].state == psComplete:
                if valid:
                  client.pieceMgr.applyVerification(pieceIdx, true)
                else:
                  btDebug "WARN: web seed piece ", pieceIdx, " failed SHA1, rescheduling"
                  client.pieceMgr.failAndResetPiece(pieceIdx)
              if valid and client.pieceMgr.pieces[pieceIdx].state == psVerified:
                if wsWriteError.len > 0:
                  client.pieceMgr.resetPiece(pieceIdx)
                else:
                  await client.events.send(ClientEvent(kind: cekPieceVerified,
                    pieceIndex: pieceIdx,
                    pieceState: client.pieceMgr.pieces[pieceIdx].state))
                  let wsPeerKeys = client.snapshotPeerKeys()
                  var wki: int = 0
                  while wki < wsPeerKeys.len:
                    let wpk: string = wsPeerKeys[wki]
                    wki += 1
                    if wpk in client.peers:
                      let wp: PeerConn = client.peers[wpk]
                      if wp.state == psActive:
                        discard wp.commands.trySend(haveMsg(uint32(pieceIdx)))
                  downloadedAny = true
                  if client.pieceMgr.isComplete:
                    client.state = csSeeding
                    await client.events.send(ClientEvent(kind: cekCompleted))
              elif client.pieceMgr.pieces[pieceIdx].state == psEmpty:
                # Piece was reset by failAndResetPiece above — notify peers
                await client.sendLtDonthaveToPeers(pieceIdx)
        finally:
          discard tryUnlock(client.mtx)
        ws.state = wssIdle
        client.webSeedActiveUrl = ""
      except CatchableError as e:
        ws.state = wssFailed
        ws.failCount += 1
        client.webSeedFailures += 1
        ws.lastError = e.msg
        client.webSeedActiveUrl = ""
        # Release blocks under mtx
        await lock(client.mtx)
        try:
          var ci: int = 0
          while ci < wsBlockOffsets.len:
            client.pieceMgr.cancelBlockRequest(pieceIdx, wsBlockOffsets[ci])
            ci += 1
        finally:
          unlock(client.mtx)

    if not downloadedAny:
      await cpsSleep(10000)  # Back off if no progress

from std/posix import getnameinfo, NI_NUMERICHOST, NI_NUMERICSERV

proc makeLsdCallback(client: TorrentClient): UdpRecvCallback =
  ## Build the LSD receive callback outside CPS context.
  ## Lock-free: pushes raw datagrams to Treiber stack for processing by
  ## a CPS task under the client mutex (reactor callbacks cannot use AsyncMutex).
  result = proc(pktData: string, srcAddr: Sockaddr_storage, addrLen: SockLen) {.closure.} =
    {.cast(gcsafe).}:
      client.pushLsdRecv(pktData, srcAddr, addrLen)

proc setupLsdSocket(client: TorrentClient): bool =
  ## Set up LSD socket and callback outside CPS context.
  ## Returns false if bind fails (port in use, permission denied).
  ## Uses shared LSD socket if provided in config.
  if client.config.sharedLsdSock != nil:
    client.lsdSock = client.config.sharedLsdSock
    return true
  try:
    client.lsdSock = newUdpSocket()
    client.lsdSock.bindAddr("0.0.0.0", LsdPort)
    client.lsdSock.onRecv(1500, makeLsdCallback(client))
    return true
  except CatchableError:
    if client.lsdSock != nil:
      client.lsdSock.close()
      client.lsdSock = nil
    return false

proc lsdRecvDrainLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Drain LSD receive buffer under the client mutex.
  ## The reactor's LSD onRecv callback enqueues raw datagrams;
  ## this CPS task processes them with proper synchronization.
  while client.state in {csDownloading, csSeeding}:
    await cpsSleep(100)  # 100ms poll — LSD peers are infrequent
    let batch = client.drainLsdRecv()
    if batch.len > 0:
      await lock(client.mtx)
      try:
        for item in batch:
          try:
            let announces = decodeLsdAnnounce(item.data)
            for ann in announces:
              if ann.infoHash == client.metainfo.info.infoHash and ann.port > 0:
                if client.connectedPeerCount < client.config.maxPeers:
                  var host = newString(256)
                  var portStr = newString(32)
                  let rc = getnameinfo(cast[ptr SockAddr](unsafeAddr item.srcAddr), item.addrLen,
                                       cstring(host), 256.SockLen,
                                       cstring(portStr), 32.SockLen,
                                       (NI_NUMERICHOST or NI_NUMERICSERV).cint)
                  if rc == 0:
                    host.setLen(host.cstring.len)
                    if client.queuePeerIfNeeded(host, ann.port, srcLsd):
                      client.lsdPeersDiscovered += 1
          except CatchableError:
            discard

      finally:
        unlock(client.mtx)
proc lsdLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## BEP 14: Local Service Discovery loop.
  ## Periodically announce our torrent on the LAN via multicast UDP.
  if client.isPrivate or not client.config.enableLsd:
    return  # LSD disabled for private torrents

  if not client.setupLsdSocket():
    return  # LSD unavailable (port in use, permission denied)

  # Periodic announce
  while client.state in {csDownloading, csSeeding} and not client.isPrivate:
    try:
      let announceData: string = encodeLsdAnnounce(
        client.metainfo.info.infoHash, client.config.listenPort)
      discard client.lsdSock.trySendToAddr(announceData, LsdMulticastAddr, LsdPort)
      client.lsdAnnounceCount += 1
    except CatchableError:
      client.lsdLastError = getCurrentExceptionMsg()
    await cpsSleep(LsdAnnounceInterval * 1000)

  if client.lsdSock != nil and client.config.sharedLsdSock == nil:
    client.lsdSock.close()

proc pexBuildFlags(client: TorrentClient, peers: seq[CompactPeer]): seq[uint8] =
  ## Build BEP 11 added.f flags from real peer capabilities.
  var fi: int = 0
  while fi < peers.len:
    let ap = peers[fi]
    var f: uint8 = 0
    let aKey = peerKey(ap.ip, ap.port)
    if aKey in client.peers:
      let p = client.peers[aKey]
      if p.mseEncrypted or p.encryptionMode != emPreferPlaintext:
        f = f or uint8(pexEncryption)
      if p.peerUploadOnly or p.markedSeedAt > 0.0:
        f = f or uint8(pexSeedOnly)
      if p.transport == ptUtp or p.pexHasUtp:
        f = f or uint8(pexUtp)
      if client.config.enableHolepunch and p.extensions.supportsExtension(UtHolepunchName):
        f = f or uint8(pexHolepunch)
      if p.source != srcIncoming:
        f = f or uint8(pexOutgoing)
    result.add(f)
    fi += 1

proc peerDelta(current, previous: seq[CompactPeer]): seq[CompactPeer] =
  ## Return entries in `current` but not in `previous` (set difference by ip+port).
  ## Uses HashSet for O(n+m) instead of O(n*m) nested scan.
  var prevSet = initHashSet[CompactPeer](previous.len)
  for p in previous:
    prevSet.incl(p)
  for c in current:
    if c notin prevSet:
      result.add(c)

proc runPexUpdate(client: TorrentClient) =
  ## Runs one PEX delta computation + broadcast pass.
  ## Kept outside CPS to avoid continuation-owned ARC state for payload strings.
  # Build current peer lists, separated by address family (BEP 11).
  var currentPeers: seq[CompactPeer]
  var currentPeers6: seq[CompactPeer]
  let pexBuildKeys = client.snapshotPeerKeys()
  var pbi: int = 0
  while pbi < pexBuildKeys.len:
    let pbKey: string = pexBuildKeys[pbi]
    pbi += 1
    if pbKey in client.peers:
      let pxPeer: PeerConn = client.peers[pbKey]
      if pxPeer.state == psActive and pxPeer.ip != "incoming":
        let advertisePort: uint16 = if pxPeer.remoteListenPort > 0: pxPeer.remoteListenPort else: pxPeer.port
        if pxPeer.ip.contains(':'):
          currentPeers6.add((pxPeer.ip, advertisePort))
        else:
          currentPeers.add((pxPeer.ip, advertisePort))

  # Compute IPv4 delta from last PEX.
  let added = peerDelta(currentPeers, client.lastPexPeers)
  let dropped = peerDelta(client.lastPexPeers, currentPeers)
  client.lastPexPeers = currentPeers

  # Compute IPv6 delta from last PEX (BEP 11 added6/dropped6).
  let added6 = peerDelta(currentPeers6, client.lastPexPeers6)
  let dropped6 = peerDelta(client.lastPexPeers6, currentPeers6)
  client.lastPexPeers6 = currentPeers6

  if added.len == 0 and dropped.len == 0 and added6.len == 0 and dropped6.len == 0:
    return

  let flags = client.pexBuildFlags(added)
  let flags6 = client.pexBuildFlags(added6)

  let pexPayload: string = encodePexMessage(added, flags, dropped, added6, flags6, dropped6)

  # Send to all peers that support PEX.
  let pexSendKeys = client.snapshotPeerKeys()
  var psi: int = 0
  while psi < pexSendKeys.len:
    let psKey: string = pexSendKeys[psi]
    psi += 1
    if psKey in client.peers:
      let pxSendPeer: PeerConn = client.peers[psKey]
      if pxSendPeer.state == psActive and pxSendPeer.peerSupportsExtensions:
        let remoteId: ExtensionId = pxSendPeer.extensions.remoteId(UtPexName)
        if remoteId != 0:
          discard pxSendPeer.commands.trySend(extendedMsg(remoteId, pexPayload))

proc pexLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## BEP 11: Periodically send PEX messages to all connected peers.
  ## This helps connected peers discover other peers in the swarm.
  if client.isPrivate or not client.config.enablePex:
    return  # PEX disabled for private torrents

  while client.state in {csDownloading, csSeeding} and not client.isPrivate:
    await cpsSleep(PexIntervalMs)  # PEX interval per BEP 11

    if client.state notin {csDownloading, csSeeding}:
      return

    await lock(client.mtx)
    try:
      runPexUpdate(client)

    finally:
      unlock(client.mtx)
const
  HolepunchIntervalMs = 5000

proc holepunchLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## BEP 55: periodically request relay rendezvous for eligible PEX candidates.
  if client.isPrivate or not client.config.enableHolepunch:
    return
  if client.utpMgr == nil:
    return

  var cleanupCounter: int = 0
  while client.state in {csDownloading, csSeeding} and not client.isPrivate:
    await cpsSleep(HolepunchIntervalMs)
    await lock(client.mtx)
    try:
      # Periodic cleanup of expired backoffs/expectations (every ~60s)
      cleanupCounter += 1
      if cleanupCounter >= 12:  # 12 * 5000ms = 60s
        cleanupCounter = 0
        client.hp.cleanupExpired()

      if client.connectedPeerCount < client.config.maxPeers:

        let nowTs = epochTime()
        # Collect candidates: (targetKey, targetIp, targetPort, relay)
        var candidates: seq[tuple[key: string, ip: string, port: uint16, relay: PeerConn]]
        # Snapshot keys to avoid "table changed while iterating" in MT mode.
        let pexKeys = safeTableKeys(client.pexPeerFlags)
        var pxi = 0
        while pxi < pexKeys.len:
          let pKey = pexKeys[pxi]
          pxi += 1
          if pKey notin client.pexPeerFlags:
            continue
          let flags = client.pexPeerFlags[pKey]
          if (flags and uint8(pexHolepunch)) == 0 or (flags and uint8(pexUtp)) == 0:
            continue
          let ip = peerIpFromKey(pKey)
          let port = peerPortFromKey(pKey)
          if ip.len == 0 or port == 0:
            continue
          if pKey in client.peers:
            continue
          if client.isPeerQueued(ip, port):
            continue
          if pKey in client.failedPeers and (nowTs - client.failedPeers[pKey]) < PeerBackoffSec:
            continue
          if client.hp.isBackedOff(pKey, nowTs) or client.hp.isInFlight(pKey):
            continue
          var candidateRelay: PeerConn = nil
          # Try stored relays first
          for rk in client.hp.relaysFor(pKey):
            if rk in client.peers:
              let r = client.peers[rk]
              if r.state == psActive and r.extensions.supportsExtension(UtHolepunchName):
                candidateRelay = r
                break
          # All stored relays gone — try any connected peer that supports ut_holepunch.
          if candidateRelay == nil:
            let relaySearchKeys = client.snapshotPeerKeys()
            var rsi = 0
            while rsi < relaySearchKeys.len:
              let altKey = relaySearchKeys[rsi]
              rsi += 1
              if altKey notin client.peers:
                continue
              let altPeer = client.peers[altKey]
              if altPeer.state == psActive and
                 altPeer.extensions.supportsExtension(UtHolepunchName):
                candidateRelay = altPeer
                client.hp.recordRelay(pKey, altKey)
                break
          if candidateRelay == nil:
            continue
          candidates.add((key: pKey, ip: ip, port: port, relay: candidateRelay))
          if candidates.len >= MaxCandidatesPerCycle:
            break

        var ci = 0
        while ci < candidates.len:
          try:
            btDebug "[HP] Sending rendezvous for ", candidates[ci].key, " via relay ", peerKey(candidates[ci].relay.ip, candidates[ci].relay.port)
            let rendezvousPayload = encodeHolepunchMsg(rendezvousMsg(candidates[ci].ip, candidates[ci].port))
            await candidates[ci].relay.sendExtended(UtHolepunchName, rendezvousPayload)
            client.hp.recordAttempt(candidates[ci].key)
          except CatchableError as e:
            client.hp.lastError = e.msg
          ci += 1

    finally:
      unlock(client.mtx)
const
  EvictionIntervalMs = 30000        ## Seeder eviction check interval (30s)
  SeederGracePeriodSec = 120.0      ## Minimum time before a seeder can be evicted (PEX exchange)
  SlotPressureThreshold = 0.8       ## Evict seeders when connection count exceeds this fraction of maxPeers

proc seederEvictionLoop(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Slot-pressure-based seeder eviction: only disconnect seeders when we
  ## need their connection slots for leechers. Seeder-to-seeder connections
  ## are essentially free (no data flows), so keeping them avoids the
  ## connect-disconnect churn that gets us banned from swarms.
  ##
  ## Eviction triggers only when ALL of:
  ##   1. We're above SlotPressureThreshold of maxPeers (need the slots)
  ##   2. We have pending leecher peers waiting to connect
  ##   3. The seeder's grace period (120s for PEX exchange) has expired
  while client.state in {csDownloading, csSeeding}:
    await cpsSleep(EvictionIntervalMs)
    await lock(client.mtx)
    try:
      if client.state == csSeeding:

        let now = epochTime()
        let slotThreshold: int = int(float(client.config.maxPeers) * SlotPressureThreshold)
        let underPressure: bool = client.connectedPeerCount >= slotThreshold

        # Only consider eviction if we're actually running out of connection slots
        # AND there are pending peers waiting (likely leechers that need the slot)
        if underPressure and client.pendingPeers.len > 0:

          # Count seeders eligible for eviction (past grace period)
          var toEvict: seq[string]

          let evictCheckKeys = client.snapshotPeerKeys()
          var evci: int = 0
          while evci < evictCheckKeys.len:
            let evk2: string = evictCheckKeys[evci]
            evci += 1
            if evk2 notin client.peers:
              continue
            let evPeer: PeerConn = client.peers[evk2]
            if evPeer.state != psActive:
              continue
            if evPeer.markedSeedAt <= 0.0:
              continue
            if (now - evPeer.markedSeedAt) < SeederGracePeriodSec:
              continue

            toEvict.add(evk2)

          # Evict only enough seeders to drop below the pressure threshold,
          # keeping at least one seeder for PEX/DHT connectivity
          var evicted: int = 0
          var ei: int = 0
          while ei < toEvict.len:
            if client.connectedPeerCount < slotThreshold:
              break  # No longer under pressure
            let evKey: string = toEvict[ei]
            ei += 1
            if evKey in client.peers:
              let peer = client.peers[evKey]
              client.knownSeeders.incl(evKey)
              peer.state = psDisconnected
              evicted += 1

    finally:
      unlock(client.mtx)
proc start*(client: TorrentClient): CpsVoidFuture {.cps.} =
  ## Start downloading/seeding the torrent.
  if client.state != csIdle:
    return

  client.resetStopSignal()
  client.state = csStarting
  client.startTime = epochTime()

  # Set up storage (skip for magnet links — no metadata yet)
  if client.pieceMgr != nil:
    let downloadDir = client.config.downloadDir / client.metainfo.info.name
    let existedBefore: bool = dirExists(downloadDir)
    client.storageMgr = newStorageManager(client.metainfo.info, downloadDir)
    client.storageMgr.openFiles()

    # Check for existing data (skip if this is a fresh download)
    if existedBefore:
      let verified = client.storageMgr.verifyExistingFiles(client.metainfo.info)
      client.restoreVerifiedPieces(verified)

    if client.pieceMgr.isComplete:
      client.state = csSeeding
    else:
      client.state = csDownloading
  else:
    # Magnet link: no metadata yet, start downloading (metadata first)
    client.state = csDownloading

  await client.events.send(ClientEvent(kind: cekStarted))

  # Start listener for incoming connections.
  # Use shared listener if provided, otherwise create own.
  # Try dual-stack IPv6 first (accepts both IPv4 and IPv6), fall back to IPv4.
  var listenerError: string = ""
  if client.config.sharedListener != nil:
    client.listener = client.config.sharedListener
  else:
    try:
      client.listener = tcpListen("::", client.config.listenPort.int,
                                  domain = AF_INET6, dualStack = true)
    except CatchableError:
      try:
        client.listener = tcpListen("0.0.0.0", client.config.listenPort.int)
      except CatchableError:
        try:
          client.listener = tcpListen("0.0.0.0", 0)
        except CatchableError as e:
          listenerError = e.msg
  if listenerError.len > 0:
    await client.events.send(ClientEvent(kind: cekError,
      errMsg: "Failed to create TCP listener: " & listenerError))
  # Update config to reflect the actual bound port (important for tracker/DHT)
  if client.listener != nil:
    let actualPort = client.listener.localPort()
    if actualPort > 0:
      client.config.listenPort = actualPort.uint16

  # Start uTP manager for BEP 29 transport.
  # Use shared manager if provided, otherwise create own.
  # Try dual-stack IPv6 first, fall back to IPv4.
  var utpError: string = ""
  if client.config.enableUtp:
    if client.config.sharedUtpMgr != nil:
      client.utpMgr = client.config.sharedUtpMgr
    else:
      try:
        client.utpMgr = newUtpManager(client.config.listenPort.int, AF_INET6)
        client.utpMgr.start()
      except CatchableError:
        try:
          client.utpMgr = newUtpManager(client.config.listenPort.int)
          client.utpMgr.start()
        except CatchableError:
          try:
            client.utpMgr = newUtpManager(0)
            client.utpMgr.start()
          except CatchableError as e:
            utpError = e.msg
  else:
    client.utpMgr = nil
  if utpError.len > 0:
    await client.events.send(ClientEvent(kind: cekError,
      errMsg: "Failed to create uTP manager: " & utpError))

  # Set up NAT port forwarding (best-effort, non-blocking).
  # Use shared NAT manager if provided (e.g. from GUI bridge), else create own.
  if client.config.sharedNatMgr != nil:
    client.natMgr = client.config.sharedNatMgr
  elif client.natMgr == nil:
    try:
      client.natMgr = newNatManager()
      await discover(client.natMgr)
      if client.natMgr.protocol != npNone:
        # Forward TCP listen port
        try:
          discard await addMapping(client.natMgr, mpTcp, client.config.listenPort,
                                    client.config.listenPort, 7200)
        except CatchableError:
          discard
        # Forward uTP/UDP port
        if client.utpMgr != nil:
          try:
            let utpPort: uint16 = client.utpMgr.port.uint16
            discard await addMapping(client.natMgr, mpUdp, utpPort, utpPort, 7200)
          except CatchableError:
            discard
        # Start renewal loop
        let natRenewalFut = startRenewal(client.natMgr)
    except CatchableError:
      discard

  client.refreshSecureDhtIdentity()

  # Launch concurrent loops
  let trackerFut = trackerLoop(client)
  let trackerScrapeFut = trackerScrapeLoop(client)
  let eventFut = eventLoop(client)
  let progressFut = progressLoop(client)
  let requestRefreshFut = requestRefreshLoop(client)
  let optimisticVerifyFut = optimisticVerifyLoop(client)
  let connectFut = connectLoop(client)
  let acceptFut = acceptLoop(client)
  let utpAcceptFut = utpAcceptLoop(client)
  let unchokeFut = unchokeLoop(client)
  let dhtFut = dhtLoop(client)
  let webSeedFut = webSeedLoop(client)
  let lsdFut = lsdLoop(client)
  let lsdDrainFut = lsdRecvDrainLoop(client)
  let pexFut = pexLoop(client)
  let holepunchFut = holepunchLoop(client)
  let seederEvictFut = seederEvictionLoop(client)

  # Wait for event loop (runs until stopped)
  await eventFut

  # Clean up
  trackerFut.cancel()
  trackerScrapeFut.cancel()
  progressFut.cancel()
  requestRefreshFut.cancel()
  optimisticVerifyFut.cancel()
  connectFut.cancel()
  acceptFut.cancel()
  utpAcceptFut.cancel()
  unchokeFut.cancel()
  dhtFut.cancel()
  webSeedFut.cancel()
  lsdFut.cancel()
  lsdDrainFut.cancel()
  pexFut.cancel()
  holepunchFut.cancel()
  seederEvictFut.cancel()

  # Send stopped event to tracker
  var stopParams = defaultAnnounceParams(
    client.metainfo.info, client.peerId, client.config.listenPort)
  stopParams.event = teStopped
  if client.pieceMgr != nil:
    stopParams.downloaded = client.pieceMgr.downloaded
    stopParams.uploaded = client.pieceMgr.uploaded
    stopParams.left = client.pieceMgr.bytesRemaining

  let trackerUrls = collectTrackerUrls(client.metainfo)
  try:
    discard await announceToAll(trackerUrls, stopParams)
  except CatchableError:
    discard

  # Clean up NAT port mappings (only if we own it, not shared)
  if client.natMgr != nil and client.config.sharedNatMgr == nil:
    try:
      await shutdown(client.natMgr)
    except CatchableError:
      discard

  if client.storageMgr != nil:
    client.storageMgr.closeFiles()
  # Only close resources we own (not shared ones)
  if client.listener != nil and client.config.sharedListener == nil:
    client.listener.close()
  if client.utpMgr != nil and client.config.sharedUtpMgr == nil:
    client.utpMgr.close()
  if client.lsdSock != nil and client.config.sharedLsdSock == nil:
    client.lsdSock.close()
  # Cancel any remaining pending DHT queries to avoid dangling futures
  client.dhtCleanup()
  client.state = csStopped
  await client.events.send(ClientEvent(kind: cekStopped))

proc stop*(client: TorrentClient) =
  ## Signal the client to stop.
  client.signalStop()
  client.state = csStopping
  # Close peer event channel to unblock event loop
  client.peerEvents.close()

