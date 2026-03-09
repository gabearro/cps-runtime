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
import utils

const
  MaxPendingRequests* = 64      ## Max outstanding block requests per peer
  KeepAliveIntervalMs* = 90000  ## Send keep-alive every 90s
  PeerTimeoutMs* = 120000       ## Disconnect after 120s of silence
  MaxMessageSize* = 2 * 1024 * 1024  ## 2 MiB max message size
  UtpFallbackTimeoutMs* = 2000  ## uTP connect timeout before TCP fallback
  UtpPreferredTimeoutMs* = 5000 ## uTP connect timeout for peers known to support uTP (from PEX)

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

proc newPeerConn*(ip: string, port: uint16, infoHash: array[20, byte],
                  peerId: array[20, byte],
                  events: AsyncChannel[PeerEvent],
                  localExtensions: ExtensionRegistry = newExtensionRegistry()): PeerConn =
  PeerConn(
    ip: ip,
    port: port,
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
  peer.state = psDisconnected

proc emitEvent(peer: PeerConn, evt: PeerEvent): CpsVoidFuture {.cps.} =
  var e = evt
  e.connGeneration = peer.connGeneration
  await peer.events.send(e)

proc sendMessage(peer: PeerConn, msg: PeerMessage): CpsVoidFuture {.cps.} =
  let data = encodeMessage(msg)
  await peer.stream.write(data)
  if msg.id == msgPiece:
    peer.bytesUploaded += msg.blockData.len

proc readMessage(peer: PeerConn): CpsFuture[tuple[isKeepAlive: bool, msg: PeerMessage]] {.cps.} =
  ## Read a framed message from the peer.
  let lenData = await peer.reader.readExact(4)
  let msgLen = readUint32BE(lenData, 0)

  if msgLen == 0:
    # Keep-alive
    return (true, PeerMessage(id: msgChoke))  # dummy

  if msgLen > MaxMessageSize.uint32:
    raise newException(AsyncIoError, "message too large: " & $msgLen)

  let payload = await peer.reader.readExact(msgLen.int)
  let msg = decodeMessage(payload)
  return (false, msg)

proc performHandshake(peer: PeerConn): CpsFuture[string] {.cps.} =
  ## Perform BitTorrent handshake. Returns "" on success, error message on failure.
  try:
    let hsData = encodeHandshake(peer.infoHash, peer.peerId)
    await peer.stream.write(hsData)

    # Read handshake response (with timeout to prevent slot exhaustion)
    let respData = await withTimeout(peer.reader.readExact(HandshakeLength), 15000)
    let hs = decodeHandshake(respData)

    # Verify info hash matches
    if hs.infoHash != peer.infoHash:
      return "info hash mismatch"

    peer.remotePeerId = hs.peerId
    peer.peerSupportsExtensions = hs.supportsExtensions
    peer.peerSupportsFastExt = (hs.reserved[7] and 0x04) != 0
    peer.state = psActive

    await peer.emitEvent(PeerEvent(
      kind: pekHandshake,
      peerAddr: formatPeerAddr(peer.ip, peer.port),
      peerId: peer.peerId,
      hsInfoHash: hs.infoHash,
      hsPeerId: hs.peerId,
      supportsExtensions: hs.supportsExtensions,
      supportsFastExt: peer.peerSupportsFastExt
    ))

    # Send extension handshake if peer supports it (BEP 10)
    if peer.peerSupportsExtensions:
      let clientStr: string = "NimCPS/0.1.0"
      let extPayload: string = encodeExtHandshake(peer.extensions, peer.localMetadataSize, peer.localUtpPort, 250, clientStr)
      await peer.sendMessage(extendedMsg(ExtHandshakeId, extPayload))

    return ""
  except CatchableError as e:
    return e.msg

proc readLoop(peer: PeerConn): CpsVoidFuture {.cps.} =
  ## Read messages from peer until disconnected.
  while peer.state == psActive:
    let readResult = await peer.readMessage()
    peer.lastActivity = epochTime()

    if readResult.isKeepAlive:
      continue

    let msg = readResult.msg
    let pAddr = formatPeerAddr(peer.ip, peer.port)

    echo "[SEED-DBG] readLoop GOT id=", msg.id, " from ", pAddr

    case msg.id
    of msgChoke:
      # State change (peerChoking = true) deferred to eventLoop handler
      # to prevent race: readLoop could process CHOKE before eventLoop
      # processes a prior UNCHOKE, causing requestBlocks to see stale state.
      peer.pendingRequests = 0
      await peer.emitEvent(PeerEvent(kind: pekChoke, peerAddr: pAddr, peerId: peer.peerId))
    of msgUnchoke:
      # State change (peerChoking = false) deferred to eventLoop handler
      await peer.emitEvent(PeerEvent(kind: pekUnchoke, peerAddr: pAddr, peerId: peer.peerId))
    of msgInterested:
      # State change (peerInterested = true) deferred to eventLoop handler
      await peer.emitEvent(PeerEvent(kind: pekInterested, peerAddr: pAddr, peerId: peer.peerId))
    of msgNotInterested:
      peer.peerInterested = false
      await peer.emitEvent(PeerEvent(kind: pekNotInterested, peerAddr: pAddr, peerId: peer.peerId))
    of msgHave:
      # Bitfield update deferred to eventLoop handler (MT safety: readLoop
      # runs without the client mutex; eventLoop runs under it).
      await peer.emitEvent(PeerEvent(kind: pekHave, peerAddr: pAddr, peerId: peer.peerId,
                                     haveIndex: msg.pieceIndex))
    of msgBitfield:
      # Bitfield update deferred to eventLoop handler (MT safety).
      await peer.emitEvent(PeerEvent(kind: pekBitfield, peerAddr: pAddr, peerId: peer.peerId,
                                     bitfield: msg.bitfield))
    of msgPiece:
      # Reject oversized piece payloads to prevent memory amplification.
      if msg.blockData.len > MaxBlockSize:
        raise newException(AsyncIoError, "piece block too large: " & $msg.blockData.len &
                           " > " & $MaxBlockSize)
      peer.bytesDownloaded += msg.blockData.len
      peer.lastPieceTime = epochTime()
      # Note: pendingRequests is decremented by client.nim when the block
      # is found in activeRequests. Decrementing here blindly would desync
      # the counter for unsolicited/duplicate piece messages.
      await peer.emitEvent(PeerEvent(kind: pekBlock, peerAddr: pAddr, peerId: peer.peerId,
                                     blockIndex: msg.blockIndex,
                                     blockBegin: msg.blockBegin,
                                     blockData: msg.blockData))
    of msgRequest:
      await peer.emitEvent(PeerEvent(kind: pekRequest, peerAddr: pAddr, peerId: peer.peerId,
                                     reqIndex: msg.reqIndex,
                                     reqBegin: msg.reqBegin,
                                     reqLength: msg.reqLength))
    of msgCancel:
      await peer.emitEvent(PeerEvent(kind: pekCancel, peerAddr: pAddr, peerId: peer.peerId,
                                     reqIndex: msg.reqIndex,
                                     reqBegin: msg.reqBegin,
                                     reqLength: msg.reqLength))
    of msgPort:
      await peer.emitEvent(PeerEvent(kind: pekPort, peerAddr: pAddr,
                                     peerId: peer.peerId, dhtPort: msg.dhtPort))
    of msgExtended:
      if msg.extId == ExtHandshakeId:
        # Extension handshake (BEP 10)
        peer.extensions.decodeExtHandshake(msg.extPayload)
        peer.remoteListenPort = peer.extensions.remoteListenPort
        await peer.emitEvent(PeerEvent(kind: pekExtHandshake, peerAddr: pAddr,
                                       peerId: peer.peerId,
                                       extRegistry: peer.extensions))
      else:
        # Incoming extended messages carry OUR local ID — the one we told
        # the remote peer to use when sending to us (BEP 10).
        let extName: string = peer.extensions.lookupLocalName(msg.extId)
        if extName.len > 0:
          await peer.emitEvent(PeerEvent(kind: pekExtMessage, peerAddr: pAddr,
                                         peerId: peer.peerId,
                                         extName: extName,
                                         extPayload: msg.extPayload))
    of msgSuggestPiece:
      await peer.emitEvent(PeerEvent(kind: pekSuggestPiece, peerAddr: pAddr,
                                     peerId: peer.peerId,
                                     haveIndex: msg.fastPieceIndex))
    of msgHaveAll:
      await peer.emitEvent(PeerEvent(kind: pekHaveAll, peerAddr: pAddr,
                                     peerId: peer.peerId))
    of msgHaveNone:
      await peer.emitEvent(PeerEvent(kind: pekHaveNone, peerAddr: pAddr,
                                     peerId: peer.peerId))
    of msgRejectRequest:
      # Note: pendingRequests is decremented by client.nim when the block
      # is found in activeRequests. Decrementing here blindly would desync
      # the counter for unsolicited reject messages.
      await peer.emitEvent(PeerEvent(kind: pekRejectRequest, peerAddr: pAddr,
                                     peerId: peer.peerId,
                                     reqIndex: msg.reqIndex,
                                     reqBegin: msg.reqBegin,
                                     reqLength: msg.reqLength))
    of msgAllowedFast:
      peer.allowedFastSet.add(msg.fastPieceIndex)
      await peer.emitEvent(PeerEvent(kind: pekAllowedFast, peerAddr: pAddr,
                                     peerId: peer.peerId,
                                     haveIndex: msg.fastPieceIndex))

proc writeLoop(peer: PeerConn): CpsVoidFuture {.cps.} =
  ## Process outgoing commands from the command channel.
  ## Note: pendingRequests is incremented by requestBlocks (client.nim) when
  ## the request is enqueued, not here. This prevents counter drift that caused
  ## download stalling (requestBlocks saw stale count, over-requested, starved
  ## other peers of blocks to request).
  while peer.state == psActive:
    let msg = await peer.commands.recv()
    if msg.id in {msgBitfield, msgHaveAll, msgHaveNone, msgUnchoke, msgChoke, msgInterested}:
      echo "[SEED-DBG] writeLoop SENDING id=", msg.id, " to ", formatPeerAddr(peer.ip, peer.port)
    await peer.sendMessage(msg)

proc keepAliveLoop(peer: PeerConn): CpsVoidFuture {.cps.} =
  ## Send periodic keep-alive messages.
  while peer.state == psActive:
    await cpsSleep(KeepAliveIntervalMs)
    if peer.state != psActive:
      break
    let idle = epochTime() - peer.lastActivity
    if idle > PeerTimeoutMs.float / 1000.0:
      peer.state = psDisconnected
      # Close the stream to unblock the read loop
      if peer.stream != nil:
        try:
          peer.stream.close()
        except Exception:
          discard
      break
    let ka = encodeKeepAlive()
    await peer.stream.write(ka)

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
    # Ensure any partial/corrupted transport state is torn down before caller
    # decides whether to reconnect in plaintext.
    if peer.stream != nil:
      try:
        peer.stream.close()
      except Exception:
        discard
      peer.stream = nil
    peer.mseEncrypted = false
    return false

proc run*(peer: PeerConn): CpsVoidFuture {.cps.} =
  ## Main peer connection loop. Connects, handshakes, then runs read/write loops.
  ## Prefers uTP transport when a UtpManager is available, falls back to TCP.
  ## Peers known to support uTP (via PEX flags) get a longer uTP timeout
  ## and are retried via uTP before falling back to TCP.
  let pAddr = formatPeerAddr(peer.ip, peer.port)
  try:
    # Try uTP first (BEP 29), fall back to TCP
    var connected: bool = false
    let allowUtp: bool = peer.utpManager != nil
    if allowUtp:
      # Peers known to support uTP (from PEX) get a longer timeout since
      # we're confident they accept uTP — reduces unnecessary TCP fallback.
      if peer.pexHasUtp and peer.utpConnectTimeoutMs <= UtpFallbackTimeoutMs:
        peer.utpConnectTimeoutMs = UtpPreferredTimeoutMs
      connected = await tryUtpConnect(peer)
    if not connected:
      # BEP 55: holepunch peers are behind NAT — TCP will never reach them.
      # Skip TCP fallback to avoid wasting 5s on a doomed attempt.
      if peer.source == srcHolepunch:
        raise newException(AsyncIoError, "uTP holepunch failed to " & pAddr)
      let tcpStream = await withTimeout(tcpConnect(peer.ip, peer.port.int), 5000)
      peer.stream = tcpStream.AsyncStream
      peer.transport = ptTcp

    # MSE/PE handshake (uTP + TCP). 5s timeout prevents hanging on peers that
    # do not support MSE.
    # BEP 55: holepunched connections are NAT-punched and can't be retried.
    # MSE corrupts the stream on failure (DH bytes sent), so skip MSE entirely
    # for holepunch peers to preserve the precious NAT-punched connection.
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
        if peer.stream != nil:
          try:
            peer.stream.close()
          except Exception:
            discard
          peer.stream = nil

        connected = false
        if allowUtp and peer.transport == ptUtp:
          connected = await tryUtpConnect(peer)
        if not connected:
          let tcpStream = await withTimeout(tcpConnect(peer.ip, peer.port.int), 5000)
          peer.stream = tcpStream.AsyncStream
          peer.transport = ptTcp

    peer.reader = newBufferedReader(peer.stream, 65536)
    peer.state = psHandshaking

    # Handshake
    let hsErr: string = await peer.performHandshake()
    if hsErr.len > 0:
      raise newException(AsyncIoError, pAddr & ": " & hsErr)

    await peer.emitEvent(PeerEvent(kind: pekConnected, peerAddr: pAddr, peerId: peer.peerId))

    # Run read, write, and keep-alive loops concurrently.
    # Use raceCancel so that if ANY loop fails (e.g., writeLoop gets a socket
    # error), the peer is disconnected instead of silently losing outbound.
    let readFut = readLoop(peer)
    let writeFut = writeLoop(peer)
    let kaFut = keepAliveLoop(peer)

    await raceCancel(readFut, writeFut, kaFut)

  except CatchableError as e:
    await peer.emitEvent(PeerEvent(kind: pekError, peerAddr: pAddr, peerId: peer.peerId,
                                   errMsg: e.msg))

  peer.state = psDisconnected
  if peer.stream != nil:
    try:
      peer.stream.close()
    except Exception:
      discard
    peer.stream = nil
  await peer.emitEvent(PeerEvent(kind: pekDisconnected, peerAddr: pAddr, peerId: peer.peerId))

proc runIncoming*(peer: PeerConn, stream: AsyncStream): CpsVoidFuture {.cps.} =
  ## Handle an incoming peer connection (already connected).
  ## Detects MSE handshake vs plain BT handshake by peeking at the first byte:
  ## - byte 19 (\x13) = plain BT handshake ("BitTorrent protocol")
  ## - anything else = MSE DH key exchange
  let pAddr = formatPeerAddr(peer.ip, peer.port)
  try:
    peer.stream = stream
    peer.state = psHandshaking

    # Peek at first byte to detect MSE vs plain handshake (with timeout).
    let firstByte: string = await withTimeout(readExactRaw(stream, 1), 15000)
    if firstByte[0].byte != 19:
      # MSE handshake: first byte is start of DH public key (96 bytes total)
      let restOfDh: string = await withTimeout(readExactRaw(stream, DhKeyLen - 1), 15000)
      let yaData: string = firstByte & restOfDh
      let mseRes: MseResult = await withTimeout(
        mseRespond(stream, peer.infoHash, yaData), 5000)
      if peer.encryptionMode == emForceRc4 and not mseRes.isEncrypted:
        raise newException(AsyncIoError, pAddr & ": peer negotiated non-RC4 MSE in force_rc4 mode")
      peer.stream = mseRes.stream
      peer.mseEncrypted = mseRes.isEncrypted
    elif peer.encryptionMode in {emRequireEncrypted, emForceRc4}:
      raise newException(AsyncIoError, pAddr & ": plaintext handshake rejected by encryption policy")

    peer.reader = newBufferedReader(peer.stream, 65536)

    # If MSE was used, the BT handshake comes through the (possibly encrypted) stream.
    # If first byte was 19, we already consumed it — prepend it to the handshake read.
    var respData: string
    if firstByte[0].byte == 19:
      # Plain handshake: read remaining 67 bytes (HandshakeLength - 1)
      let rest: string = await withTimeout(peer.reader.readExact(HandshakeLength - 1), 15000)
      respData = firstByte & rest
    else:
      # MSE: read full handshake through the (possibly encrypted) stream
      respData = await withTimeout(peer.reader.readExact(HandshakeLength), 15000)
    let hs = decodeHandshake(respData)

    if hs.infoHash != peer.infoHash:
      raise newException(AsyncIoError, pAddr & ": incoming handshake: info hash mismatch")

    peer.remotePeerId = hs.peerId
    peer.peerSupportsExtensions = hs.supportsExtensions
    peer.peerSupportsFastExt = (hs.reserved[7] and 0x04) != 0

    # Send our handshake
    let hsData = encodeHandshake(peer.infoHash, peer.peerId)
    await peer.stream.write(hsData)

    # Send extension handshake if peer supports it (BEP 10)
    if peer.peerSupportsExtensions:
      let clientStr: string = "NimCPS/0.1.0"
      let extPayload: string = encodeExtHandshake(peer.extensions, peer.localMetadataSize, peer.localUtpPort, 250, clientStr)
      await peer.sendMessage(extendedMsg(ExtHandshakeId, extPayload))

    peer.state = psActive
    await peer.emitEvent(PeerEvent(kind: pekHandshake, peerAddr: pAddr, peerId: peer.peerId,
                                   hsInfoHash: hs.infoHash, hsPeerId: hs.peerId,
                                   supportsExtensions: hs.supportsExtensions,
                                   supportsFastExt: peer.peerSupportsFastExt))
    await peer.emitEvent(PeerEvent(kind: pekConnected, peerAddr: pAddr, peerId: peer.peerId))

    # Use raceCancel so that if ANY loop fails, the peer disconnects cleanly
    let readFut = readLoop(peer)
    let writeFut = writeLoop(peer)
    let kaFut = keepAliveLoop(peer)

    await raceCancel(readFut, writeFut, kaFut)

  except CatchableError as e:
    await peer.emitEvent(PeerEvent(kind: pekError, peerAddr: pAddr, peerId: peer.peerId,
                                   errMsg: e.msg))

  peer.state = psDisconnected
  if peer.stream != nil:
    try:
      peer.stream.close()
    except Exception:
      discard
    peer.stream = nil
  await peer.emitEvent(PeerEvent(kind: pekDisconnected, peerAddr: pAddr, peerId: peer.peerId))

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
