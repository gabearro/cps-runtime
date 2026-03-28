## BitTorrent peer connection.
##
## Handles async communication with a single peer using the CPS runtime.
## Each peer runs as an independent CPS task with its own read/write loops.

import std/[times, strutils]
import ../runtime
import ../transform
import ../eventloop
import ../io/streams
import ../io/tcp
import ../io/buffered
import ../io/timeouts
import ../concurrency/channels
import peer_protocol
import pieces
import extensions
import utp_stream
import mse
import ratelimit
import utils

const
  MaxPendingRequests* = 512     ## Max outstanding block requests per peer
  KeepAliveIntervalMs* = 90000  ## Send keep-alive every 90s
  PeerTimeoutMs* = 120000       ## Disconnect after 120s of silence
  MaxMessageSize* = 2 * 1024 * 1024  ## 2 MiB max message size
  UtpFallbackTimeoutMs* = 2000  ## uTP connect timeout before TCP fallback
  UtpPreferredTimeoutMs* = 5000 ## uTP connect timeout for peers known to support uTP (from PEX)
  MaxAllowedFastPieces = 256    ## Cap on allowedFastSet to prevent memory exhaustion from hostile peers
  PreConsumeEstimate = BlockSize + 13  ## Pre-consume budget per read iteration (16 KiB + piece header)
  ClientName = "NimCPS/0.1.0"

proc formatPeerAddr*(ip: string, port: uint16): string =
  ## Canonical peer address text:
  ## - IPv4: "1.2.3.4:6881"
  ## - IPv6: "[2001:db8::1]:6881"  (canonicalized per RFC 5952)
  if ip.contains(':') and not ip.startsWith("["):
    return "[" & canonicalizeIpv6(ip) & "]:" & $port
  return ip & ":" & $port

type
  TransportKind* = enum
    ptTcp
    ptUtp

  PeerSource* = enum
    srcUnknown    ## Source not tracked
    srcTracker    ## Discovered via HTTP/UDP tracker announce
    srcDht        ## Discovered via DHT get_peers
    srcPex        ## Discovered via PEX (Peer Exchange, BEP 11)
    srcLsd        ## Discovered via LSD (Local Service Discovery, BEP 14)
    srcIncoming   ## Peer connected to us (accept loop)
    srcHolepunch  ## Connected via BEP 55 holepunch

  PeerState* = enum
    psConnecting
    psHandshaking
    psActive
    psDisconnected

  PeerEventKind* = enum
    pekConnected
    pekDisconnected
    pekHandshake
    pekChoke
    pekUnchoke
    pekInterested
    pekNotInterested
    pekHave
    pekBitfield
    pekBlock           ## Received a piece block
    pekRequest         ## Peer requests a block from us
    pekCancel
    pekError
    pekExtHandshake    ## Extension handshake received (BEP 10)
    pekExtMessage      ## Extension message received (BEP 10)
    pekHaveAll         ## BEP 6: peer has all pieces
    pekHaveNone        ## BEP 6: peer has no pieces
    pekSuggestPiece    ## BEP 6: peer suggests a piece
    pekRejectRequest   ## BEP 6: peer rejected our request
    pekAllowedFast     ## BEP 6: piece requestable while choked
    pekPort            ## BEP 5: DHT port

  PeerEvent* = object
    peerId*: array[20, byte]
    peerAddr*: string
    connGeneration*: uint32  ## Generation of the PeerConn that emitted this event
    case kind*: PeerEventKind
    of pekConnected, pekDisconnected, pekChoke, pekUnchoke,
       pekInterested, pekNotInterested, pekHaveAll, pekHaveNone:
      discard
    of pekHandshake:
      hsInfoHash*: array[20, byte]
      hsPeerId*: array[20, byte]
      supportsExtensions*: bool
      supportsFastExt*: bool
    of pekHave, pekSuggestPiece, pekAllowedFast:
      haveIndex*: uint32
    of pekBitfield:
      bitfield*: seq[byte]
    of pekBlock:
      blockIndex*: uint32
      blockBegin*: uint32
      blockData*: string
    of pekRequest, pekCancel, pekRejectRequest:
      reqIndex*: uint32
      reqBegin*: uint32
      reqLength*: uint32
    of pekError:
      errMsg*: string
    of pekExtHandshake:
      extRegistry*: ExtensionRegistry
    of pekExtMessage:
      extName*: string    ## Extension name (e.g., "ut_metadata", "ut_pex")
      extPayload*: string ## Raw extension message payload
    of pekPort:
      dhtPort*: uint16

  PeerConn* = ref object
    ip*: string
    port*: uint16
    cachedAddr*: string       ## Formatted "ip:port" — computed once, reused everywhere
    state*: PeerState
    wasConnected*: bool       ## Set to true once handshake succeeds (pekConnected fired)
    transport*: TransportKind
    stream: AsyncStream
    reader: BufferedReader
    events*: AsyncChannel[PeerEvent]
    commands*: AsyncChannel[PeerMessage]
    peerId*: array[20, byte]
    remotePeerId*: array[20, byte]
    infoHash*: array[20, byte]
    amChoking*: bool       ## We are choking the peer
    amInterested*: bool    ## We are interested in the peer
    peerChoking*: bool     ## Peer is choking us
    peerInterested*: bool  ## Peer is interested in us
    peerBitfield*: seq[byte]
    pendingRequests*: int
    activeRequests*: seq[tuple[pieceIdx: int, offset: int]]  ## Blocks currently in-flight to this peer
    lastActivity*: float
    lastPieceTime*: float   ## Last time we received piece data from this peer
    bytesDownloaded*: int64
    bytesUploaded*: int64
    # Per-interval snapshots for instantaneous rate calculation (unchokeLoop)
    prevBytesDownloaded*: int64
    prevBytesUploaded*: int64
    # BEP 10: Extension Protocol
    extensions*: ExtensionRegistry
    remoteListenPort*: uint16   ## Remote listen port from BEP 10 "p"
    localUtpPort*: uint16       ## Advertised local uTP listen port in BEP 10 "p"
    peerSupportsExtensions*: bool
    peerSupportsFastExt*: bool
    localMetadataSize*: int       ## Size of our raw info dict (for BEP 9/10)
    # BEP 6: Fast Extension
    allowedFastSet*: seq[uint32]  ## Pieces we can request while choked (inbound: remote told us)
    outboundAllowedFast*: seq[uint32]  ## Pieces remote can request while choked (outbound: we told them)
    # uTP transport
    utpManager*: UtpManager       ## Shared uTP manager (nil = TCP only)
    utpConnectTimeoutMs*: int     ## Per-peer uTP connect timeout
    # MSE/PE (Message Stream Encryption)
    encryptionMode*: EncryptionMode  ## Desired encryption mode
    mseEncrypted*: bool              ## Whether MSE RC4 is active
    # BEP 21: upload_only
    peerUploadOnly*: bool  ## Remote peer is a partial seed
    # BEP 40: Canonical Peer Priority
    priority*: uint32      ## CRC32C-based peer priority (lower = higher)
    # PEX-discovered capability hints (BEP 11 added.f)
    pexFlags*: uint8
    pexHasUtp*: bool
    pexHasHolepunch*: bool
    # BEP 6 suggest-piece hints
    suggestedPieces*: seq[int]
    # Discovery source
    source*: PeerSource    ## How this peer was discovered
    # BEP 16: Super Seeding
    isSuperSeeder*: bool   ## Detected super seeder (HAVE without prior BITFIELD)
    # Seeder eviction
    connectedAt*: float    ## Timestamp when connection was established
    markedSeedAt*: float   ## When peer was marked as seeder for eviction (0 = not marked)
    pexCountAtMark*: int   ## PEX peers received at time of marking (for conditional eviction)
    connGeneration*: uint32 ## Monotonic generation counter to distinguish replaced peers
    # Global bandwidth limiter (shared across all peers)
    bandwidthLimiter*: BandwidthLimiter
    # Per-torrent wire byte counters (points to TorrentClient fields)
    torrentWireDownloaded*: ptr int64
    torrentWireUploaded*: ptr int64

proc newPeerConn*(ip: string, port: uint16, infoHash: array[20, byte],
                  peerId: array[20, byte],
                  events: AsyncChannel[PeerEvent],
                  localExtensions: ExtensionRegistry = newExtensionRegistry()): PeerConn =
  PeerConn(
    ip: ip,
    port: port,
    cachedAddr: formatPeerAddr(ip, port),
    state: psConnecting,
    events: events,
    commands: newAsyncChannel[PeerMessage](),  # Unbounded — must never block handlePeerEvent
    peerId: peerId,
    infoHash: infoHash,
    amChoking: true,
    amInterested: false,
    peerChoking: true,
    peerInterested: false,
    lastActivity: epochTime(),
    lastPieceTime: epochTime(),
    extensions: localExtensions,
    utpConnectTimeoutMs: UtpFallbackTimeoutMs,
    encryptionMode: emPreferPlaintext,  # Default to plaintext; MSE tried on retry
    connectedAt: epochTime()
  )

proc closeStream*(peer: PeerConn) =
  ## Close the peer's underlying stream safely. Non-CPS.
  if peer.stream != nil:
    try: peer.stream.close()
    except Exception: discard
    peer.stream = nil
  peer.state = psDisconnected

proc emitEvent(peer: PeerConn, evt: PeerEvent): CpsVoidFuture {.cps.} =
  var e = evt
  e.peerAddr = peer.cachedAddr
  e.peerId = peer.peerId
  e.connGeneration = peer.connGeneration
  await peer.events.send(e)

proc trackWireUpload(peer: PeerConn, bytes: int) {.inline.} =
  if peer.torrentWireUploaded != nil:
    peer.torrentWireUploaded[] += bytes

proc trackWireDownload(peer: PeerConn, bytes: int) {.inline.} =
  if peer.torrentWireDownloaded != nil:
    peer.torrentWireDownloaded[] += bytes

proc sendMessage(peer: PeerConn, msg: PeerMessage): CpsVoidFuture {.cps.} =
  let data = encodeMessage(msg)
  # Consume upload budget for all outgoing wire bytes, not just piece data.
  await peer.bandwidthLimiter.consume(data.len, Upload)
  if peer.stream == nil or peer.stream.closed:
    raise newException(AsyncIoError, "peer stream closed")
  await peer.stream.write(data)
  peer.trackWireUpload(data.len)
  if msg.id == msgPiece:
    peer.bytesUploaded += msg.blockData.len

proc readMessage(peer: PeerConn): CpsFuture[tuple[isKeepAlive: bool, msg: PeerMessage]] {.cps.} =
  ## Read a framed message from the peer.
  let lenData = await peer.reader.readExact(4)
  let msgLen = readUint32BE(lenData, 0)

  if msgLen == 0:
    peer.trackWireDownload(4)
    return (true, PeerMessage(id: msgChoke))  # dummy

  if msgLen > MaxMessageSize.uint32:
    raise newException(AsyncIoError, "message too large: " & $msgLen)

  let payload = await peer.reader.readExact(msgLen.int)
  peer.trackWireDownload(4 + msgLen.int)
  let msg = decodeMessage(payload)
  return (false, msg)

proc sendExtHandshake(peer: PeerConn): CpsVoidFuture {.cps.} =
  ## Send BEP 10 extension handshake if peer supports it.
  if peer.peerSupportsExtensions:
    let extPayload: string = encodeExtHandshake(
      peer.extensions, peer.localMetadataSize, peer.localUtpPort, 250, ClientName)
    await peer.sendMessage(extendedMsg(ExtHandshakeId, extPayload))

proc performHandshake(peer: PeerConn): CpsFuture[string] {.cps.} =
  ## Perform BitTorrent handshake. Returns "" on success, error message on failure.
  try:
    let hsData = encodeHandshake(peer.infoHash, peer.peerId)
    await peer.bandwidthLimiter.consume(hsData.len, Upload)
    await peer.stream.write(hsData)
    peer.trackWireUpload(hsData.len)

    await peer.bandwidthLimiter.consume(HandshakeLength, Download)
    let respData = await withTimeout(peer.reader.readExact(HandshakeLength), 15000)
    peer.trackWireDownload(HandshakeLength)
    let hs = decodeHandshake(respData)

    if hs.infoHash != peer.infoHash:
      return "info hash mismatch"

    peer.remotePeerId = hs.peerId
    peer.peerSupportsExtensions = hs.supportsExtensions
    peer.peerSupportsFastExt = (hs.reserved[7] and 0x04) != 0
    peer.state = psActive

    await peer.emitEvent(PeerEvent(
      kind: pekHandshake,
      hsInfoHash: hs.infoHash,
      hsPeerId: hs.peerId,
      supportsExtensions: hs.supportsExtensions,
      supportsFastExt: peer.peerSupportsFastExt
    ))

    await peer.sendExtHandshake()
    return ""
  except CatchableError as e:
    return e.msg

proc readLoop(peer: PeerConn): CpsVoidFuture {.cps.} =
  ## Read messages from peer until disconnected.
  ## Pre-consumes an estimated block-sized budget before each read so that
  ## peers collectively cannot burst past the global limit at wire speed.
  ## After the read completes, refunds or charges the difference.
  while peer.state == psActive:
    # Pre-consume: deduct estimated bytes and sleep off any resulting debt
    # BEFORE touching the wire. All peers compete for budget here, so
    # aggregate throughput stays within the global limit.
    await peer.bandwidthLimiter.consume(PreConsumeEstimate, Download)
    let readResult = await peer.readMessage()
    peer.lastActivity = epochTime()

    if readResult.isKeepAlive:
      # Keep-alive is 4 bytes on the wire; refund the overestimate.
      peer.bandwidthLimiter.refund(PreConsumeEstimate - 4, Download)
      continue

    let msg = readResult.msg
    let actualWire: int = wireSize(msg)
    # Settle the difference between estimate and actual wire bytes.
    let diff: int = PreConsumeEstimate - actualWire
    if diff > 0:
      peer.bandwidthLimiter.refund(diff, Download)
    elif diff < 0:
      # Underestimate (e.g., large extension message) — charge the extra.
      await peer.bandwidthLimiter.consume(-diff, Download)

    case msg.id
    of msgChoke:
      peer.pendingRequests = 0
      await peer.emitEvent(PeerEvent(kind: pekChoke))
    of msgUnchoke:
      await peer.emitEvent(PeerEvent(kind: pekUnchoke))
    of msgInterested:
      await peer.emitEvent(PeerEvent(kind: pekInterested))
    of msgNotInterested:
      peer.peerInterested = false
      await peer.emitEvent(PeerEvent(kind: pekNotInterested))
    of msgHave:
      await peer.emitEvent(PeerEvent(kind: pekHave, haveIndex: msg.pieceIndex))
    of msgBitfield:
      await peer.emitEvent(PeerEvent(kind: pekBitfield, bitfield: msg.bitfield))
    of msgPiece:
      if msg.blockData.len > MaxBlockSize:
        raise newException(AsyncIoError, "piece block too large: " & $msg.blockData.len &
                           " > " & $MaxBlockSize)
      peer.bytesDownloaded += msg.blockData.len
      peer.lastPieceTime = epochTime()
      await peer.emitEvent(PeerEvent(kind: pekBlock,
                                     blockIndex: msg.blockIndex,
                                     blockBegin: msg.blockBegin,
                                     blockData: msg.blockData))
    of msgRequest:
      await peer.emitEvent(PeerEvent(kind: pekRequest,
                                     reqIndex: msg.reqIndex,
                                     reqBegin: msg.reqBegin,
                                     reqLength: msg.reqLength))
    of msgCancel:
      await peer.emitEvent(PeerEvent(kind: pekCancel,
                                     reqIndex: msg.reqIndex,
                                     reqBegin: msg.reqBegin,
                                     reqLength: msg.reqLength))
    of msgPort:
      await peer.emitEvent(PeerEvent(kind: pekPort, dhtPort: msg.dhtPort))
    of msgExtended:
      if msg.extId == ExtHandshakeId:
        peer.extensions.decodeExtHandshake(msg.extPayload)
        peer.remoteListenPort = peer.extensions.remoteListenPort
        await peer.emitEvent(PeerEvent(kind: pekExtHandshake,
                                       extRegistry: peer.extensions))
      else:
        let extName: string = peer.extensions.lookupLocalName(msg.extId)
        if extName.len > 0:
          await peer.emitEvent(PeerEvent(kind: pekExtMessage,
                                         extName: extName,
                                         extPayload: msg.extPayload))
    of msgSuggestPiece:
      await peer.emitEvent(PeerEvent(kind: pekSuggestPiece,
                                     haveIndex: msg.fastPieceIndex))
    of msgHaveAll:
      await peer.emitEvent(PeerEvent(kind: pekHaveAll))
    of msgHaveNone:
      await peer.emitEvent(PeerEvent(kind: pekHaveNone))
    of msgRejectRequest:
      await peer.emitEvent(PeerEvent(kind: pekRejectRequest,
                                     reqIndex: msg.reqIndex,
                                     reqBegin: msg.reqBegin,
                                     reqLength: msg.reqLength))
    of msgAllowedFast:
      if peer.allowedFastSet.len < MaxAllowedFastPieces:
        peer.allowedFastSet.add(msg.fastPieceIndex)
      await peer.emitEvent(PeerEvent(kind: pekAllowedFast,
                                     haveIndex: msg.fastPieceIndex))

proc writeLoop(peer: PeerConn): CpsVoidFuture {.cps.} =
  ## Process outgoing commands from the command channel.
  while peer.state == psActive:
    let msg = await peer.commands.recv()
    if peer.state != psActive:
      break
    await peer.sendMessage(msg)

proc keepAliveLoop(peer: PeerConn): CpsVoidFuture {.cps.} =
  ## Send periodic keep-alive messages.
  while peer.state == psActive:
    await cpsSleep(KeepAliveIntervalMs)
    if peer.state != psActive:
      break
    let idle = epochTime() - peer.lastActivity
    if idle > PeerTimeoutMs.float / 1000.0:
      peer.closeStream()
      break
    if peer.stream == nil or peer.stream.closed:
      break
    let ka = encodeKeepAlive()
    await peer.bandwidthLimiter.consume(ka.len, Upload)
    await peer.stream.write(ka)
    peer.trackWireUpload(ka.len)

proc tryUtpConnect(peer: PeerConn): CpsFuture[bool] {.cps.} =
  ## Try uTP connection. Returns true on success, false on failure.
  ## On success, peer.stream and peer.transport are set.
  try:
    let utpStream: UtpStream = await utpConnect(peer.utpManager, peer.ip,
                                                 peer.port.int,
                                                 peer.utpConnectTimeoutMs)
    peer.stream = utpStream.AsyncStream
    peer.transport = ptUtp
    return true
  except CatchableError:
    return false

proc tryMseHandshake(peer: PeerConn): CpsFuture[bool] {.cps.} =
  ## Try MSE/PE handshake. Returns true on success, false on failure.
  ## On success, peer.stream may be wrapped with encryption.
  try:
    let cryptoProvide: uint32 =
      if peer.encryptionMode == emForceRc4: MseCryptoRc4
      else: MseCryptoRc4 or MseCryptoPlaintext
    let mseRes: MseResult = await withTimeout(
      mseInitiate(peer.stream, peer.infoHash, cryptoProvide), 5000)
    peer.stream = mseRes.stream
    peer.mseEncrypted = mseRes.isEncrypted
    return true
  except CatchableError:
    # Tear down partial/corrupted transport before caller reconnects.
    peer.closeStream()
    peer.mseEncrypted = false
    return false

proc run*(peer: PeerConn): CpsVoidFuture {.cps.} =
  ## Main peer connection loop. Connects, handshakes, then runs read/write loops.
  ## Prefers uTP transport when a UtpManager is available, falls back to TCP.
  ## Peers known to support uTP (via PEX flags) get a longer uTP timeout
  ## and are retried via uTP before falling back to TCP.
  try:
    # Try uTP first (BEP 29), fall back to TCP
    var connected: bool = false
    let allowUtp: bool = peer.utpManager != nil
    if allowUtp:
      if peer.pexHasUtp and peer.utpConnectTimeoutMs <= UtpFallbackTimeoutMs:
        peer.utpConnectTimeoutMs = UtpPreferredTimeoutMs
      connected = await tryUtpConnect(peer)
    if not connected:
      # BEP 55: holepunch peers are behind NAT — TCP will never reach them.
      if peer.source == srcHolepunch:
        raise newException(AsyncIoError, "uTP holepunch failed to " & peer.cachedAddr)
      let tcpStream = await withTimeout(tcpConnect(peer.ip, peer.port.int), 5000)
      peer.stream = tcpStream.AsyncStream
      peer.transport = ptTcp

    # MSE/PE handshake. Skip for holepunch peers — MSE corrupts the stream
    # on failure and NAT-punched connections can't be retried.
    if peer.encryptionMode != emPreferPlaintext and peer.source != srcHolepunch:
      var mseOk: bool = await tryMseHandshake(peer)

      # If encryption is required and uTP MSE failed, retry encrypted over TCP.
      if not mseOk and peer.transport == ptUtp and
         peer.encryptionMode in {emRequireEncrypted, emForceRc4}:
        let tcpStream = await withTimeout(tcpConnect(peer.ip, peer.port.int), 5000)
        peer.stream = tcpStream.AsyncStream
        peer.transport = ptTcp
        mseOk = await tryMseHandshake(peer)

      if not mseOk:
        if peer.encryptionMode in {emRequireEncrypted, emForceRc4}:
          raise newException(AsyncIoError, "MSE handshake failed and encryption is required")

        # emPreferEncrypted fallback: reconnect plaintext with fresh transport.
        peer.closeStream()
        connected = false
        if allowUtp and peer.transport == ptUtp:
          connected = await tryUtpConnect(peer)
        if not connected:
          let tcpStream = await withTimeout(tcpConnect(peer.ip, peer.port.int), 5000)
          peer.stream = tcpStream.AsyncStream
          peer.transport = ptTcp

    # Keep read-ahead bounded to one pre-consume quantum to avoid large wire bursts.
    peer.reader = newBufferedReader(peer.stream, PreConsumeEstimate)
    peer.state = psHandshaking

    let hsErr: string = await peer.performHandshake()
    if hsErr.len > 0:
      raise newException(AsyncIoError, peer.cachedAddr & ": " & hsErr)

    await peer.emitEvent(PeerEvent(kind: pekConnected))
    await raceCancel(readLoop(peer), writeLoop(peer), keepAliveLoop(peer))

  except CatchableError as e:
    await peer.emitEvent(PeerEvent(kind: pekError, errMsg: e.msg))

  peer.closeStream()
  await peer.emitEvent(PeerEvent(kind: pekDisconnected))

proc runIncoming*(peer: PeerConn, stream: AsyncStream): CpsVoidFuture {.cps.} =
  ## Handle an incoming peer connection (already connected).
  ## Detects MSE handshake vs plain BT handshake by peeking at the first byte:
  ## - byte 19 (\x13) = plain BT handshake ("BitTorrent protocol")
  ## - anything else = MSE DH key exchange
  try:
    peer.stream = stream
    peer.state = psHandshaking

    await peer.bandwidthLimiter.consume(1, Download)
    let firstByte: string = await withTimeout(readExactRaw(stream, 1), 15000)
    if firstByte[0].byte != 19:
      # MSE handshake: first byte is start of DH public key (96 bytes total)
      await peer.bandwidthLimiter.consume(DhKeyLen - 1, Download)
      let restOfDh: string = await withTimeout(readExactRaw(stream, DhKeyLen - 1), 15000)
      let yaData: string = firstByte & restOfDh
      let mseRes: MseResult = await withTimeout(
        mseRespond(stream, peer.infoHash, yaData), 5000)
      if peer.encryptionMode == emForceRc4 and not mseRes.isEncrypted:
        raise newException(AsyncIoError, peer.cachedAddr & ": non-RC4 MSE in force_rc4 mode")
      peer.stream = mseRes.stream
      peer.mseEncrypted = mseRes.isEncrypted
    elif peer.encryptionMode in {emRequireEncrypted, emForceRc4}:
      raise newException(AsyncIoError, peer.cachedAddr & ": plaintext rejected by encryption policy")

    # Keep read-ahead bounded to one pre-consume quantum to avoid large wire bursts.
    peer.reader = newBufferedReader(peer.stream, PreConsumeEstimate)

    var respData: string
    if firstByte[0].byte == 19:
      await peer.bandwidthLimiter.consume(HandshakeLength - 1, Download)
      let rest: string = await withTimeout(peer.reader.readExact(HandshakeLength - 1), 15000)
      respData = firstByte & rest
    else:
      await peer.bandwidthLimiter.consume(HandshakeLength, Download)
      respData = await withTimeout(peer.reader.readExact(HandshakeLength), 15000)
    let hs = decodeHandshake(respData)

    if hs.infoHash != peer.infoHash:
      raise newException(AsyncIoError, peer.cachedAddr & ": info hash mismatch")

    peer.remotePeerId = hs.peerId
    peer.peerSupportsExtensions = hs.supportsExtensions
    peer.peerSupportsFastExt = (hs.reserved[7] and 0x04) != 0

    let hsData = encodeHandshake(peer.infoHash, peer.peerId)
    await peer.bandwidthLimiter.consume(hsData.len, Upload)
    await peer.stream.write(hsData)
    await peer.sendExtHandshake()

    peer.state = psActive
    await peer.emitEvent(PeerEvent(kind: pekHandshake,
                                   hsInfoHash: hs.infoHash, hsPeerId: hs.peerId,
                                   supportsExtensions: hs.supportsExtensions,
                                   supportsFastExt: peer.peerSupportsFastExt))
    await peer.emitEvent(PeerEvent(kind: pekConnected))
    await raceCancel(readLoop(peer), writeLoop(peer), keepAliveLoop(peer))

  except CatchableError as e:
    await peer.emitEvent(PeerEvent(kind: pekError, errMsg: e.msg))

  peer.closeStream()
  await peer.emitEvent(PeerEvent(kind: pekDisconnected))

# Command helpers (send via command channel to be processed by write loop)
proc sendChoke*(peer: PeerConn): CpsVoidFuture {.cps.} =
  peer.amChoking = true
  await peer.commands.send(chokeMsg())

proc sendUnchoke*(peer: PeerConn): CpsVoidFuture {.cps.} =
  peer.amChoking = false
  await peer.commands.send(unchokeMsg())

proc sendInterested*(peer: PeerConn): CpsVoidFuture {.cps.} =
  peer.amInterested = true
  await peer.commands.send(interestedMsg())

proc sendNotInterested*(peer: PeerConn): CpsVoidFuture {.cps.} =
  peer.amInterested = false
  await peer.commands.send(notInterestedMsg())

proc sendHave*(peer: PeerConn, index: uint32): CpsVoidFuture {.cps.} =
  await peer.commands.send(haveMsg(index))

proc sendBitfield*(peer: PeerConn, bf: seq[byte]): CpsVoidFuture {.cps.} =
  await peer.commands.send(bitfieldMsg(bf))

proc sendRequest*(peer: PeerConn, index, begin, length: uint32): CpsVoidFuture {.cps.} =
  await peer.commands.send(requestMsg(index, begin, length))

proc sendCancel*(peer: PeerConn, index, begin, length: uint32): CpsVoidFuture {.cps.} =
  await peer.commands.send(cancelMsg(index, begin, length))

proc sendPieceBlock*(peer: PeerConn, index, begin: uint32, data: string): CpsVoidFuture {.cps.} =
  await peer.commands.send(pieceMsg(index, begin, data))

proc sendExtended*(peer: PeerConn, extName: string, payload: string): CpsVoidFuture {.cps.} =
  ## Send an extension message using the remote peer's ID for the extension.
  let remoteExtId: ExtensionId = peer.extensions.remoteId(extName)
  if remoteExtId != 0:
    await peer.commands.send(extendedMsg(remoteExtId, payload))

proc sendRejectRequest*(peer: PeerConn, index, begin, length: uint32): CpsVoidFuture {.cps.} =
  await peer.commands.send(rejectRequestMsg(index, begin, length))

proc sendSuggestPiece*(peer: PeerConn, index: uint32): CpsVoidFuture {.cps.} =
  await peer.commands.send(suggestPieceMsg(index))

proc sendAllowedFast*(peer: PeerConn, index: uint32): CpsVoidFuture {.cps.} =
  await peer.commands.send(allowedFastMsg(index))

proc sendPort*(peer: PeerConn, port: uint16): CpsVoidFuture {.cps.} =
  await peer.commands.send(portMsg(port))
