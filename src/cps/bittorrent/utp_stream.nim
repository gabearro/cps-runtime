## uTP stream adapter.
##
## Wraps the low-level uTP protocol state machine (utp.nim) into an
## AsyncStream, integrated with the CPS event loop via a shared UDP socket.
## UtpManager multiplexes multiple uTP connections over a single UDP port.

import std/[nativesockets, strutils, times, deques, atomics]
import ../runtime
import ../transform
import ../eventloop
import ../io/streams
import ../io/udp
import ../io/timeouts
import ../private/platform
import ../private/concurrent_table
import utp

const
  IPPROTO_IPV6_C {.importc: "IPPROTO_IPV6", header: "<netinet/in.h>".}: cint = 0
  IPV6_V6ONLY_C {.importc: "IPV6_V6ONLY", header: "<netinet/in.h>".}: cint = 0

const
  UtpMaxPayload* = MaxPacketSize - UtpHeaderSize  ## Max data bytes per uTP packet
  UtpConnectTimeoutMs* = 3000  ## Default uTP connect timeout
  UtpAcceptBacklogSize* = 16   ## Max pending connections queued before accept

type
  UtpStream* = ref object of AsyncStream
    manager: UtpManager
    sock: UtpSocket
    remoteIp*: string
    remotePort*: int
    readWaiter: CpsFuture[string]
    readWaiterSize: int
    connectWaiter: CpsVoidFuture
    writeWaiter: CpsVoidFuture
    writePending: string       ## Unsent data waiting for window space
    writeOffset: int           ## Offset into writePending

  UtpManager* = ref object
    udpSock*: UdpSocket
    port*: int                                    ## Local UDP port (for advertising in extension handshake)
    domain: Domain                                ## Socket domain (AF_INET or AF_INET6)
    connections: ConcurrentTable[string, UtpStream]  ## Key: "connId:ip:port" (thread-safe)
    nextConnId: Atomic[uint16]  ## Atomic for thread-safe allocation from CPS workers
    closed*: bool
    acceptWaiter: CpsFuture[UtpStream]  ## Single accept waiter (one accept loop)
    acceptBacklog: Deque[UtpStream]     ## Pending connections awaiting accept (capped)
    reactorLoop: EventLoop              ## Owning event loop (set in start)

# Forward declarations for AsyncStream vtable
proc utpStreamRead(s: AsyncStream, size: int): CpsFuture[string]
proc utpStreamWrite(s: AsyncStream, data: string): CpsVoidFuture
proc utpStreamClose(s: AsyncStream)

# ============================================================
# Debug logging (compile with -d:utpDebug to enable)
# ============================================================

const utpDebug* {.booldefine.} = false

proc utpLog*(msg: string) {.inline.} =
  when utpDebug:
    echo "[uTP] ", msg

proc pktTypeName(t: uint8): string =
  case t
  of StData: "DATA"
  of StFin: "FIN"
  of StState: "STATE"
  of StReset: "RESET"
  of StSyn: "SYN"
  else: "UNK(" & $t & ")"

# ============================================================
# Helpers
# ============================================================

proc normalizeIp(ip: string): string =
  ## Strip IPv4-mapped IPv6 prefix so dual-stack sockets produce consistent
  ## keys for IPv4 peers.  "::ffff:1.2.3.4" → "1.2.3.4".
  if ip.len > 7 and ip.startsWith("::ffff:"):
    let tail = ip[7 .. ^1]
    # Verify the tail is an IPv4 address (contains dots, no colons)
    if '.' in tail and ':' notin tail:
      return tail
  result = ip

proc extractAddr(srcAddr: Sockaddr_storage, addrLen: SockLen): (string, int) =
  ## Extract IP string and port from a sockaddr.
  ## Normalizes IPv4-mapped IPv6 addresses (::ffff:x.x.x.x → x.x.x.x)
  ## so connection keys match regardless of socket domain.
  var host = newString(256)
  var portStr = newString(32)
  let rc = getnameinfo(cast[ptr SockAddr](unsafeAddr srcAddr), addrLen,
                       cstring(host), 256.SockLen,
                       cstring(portStr), 32.SockLen,
                       (NI_NUMERICHOST or NI_NUMERICSERV).cint)
  if rc != 0:
    return ("", 0)
  host.setLen(host.cstring.len)
  portStr.setLen(portStr.cstring.len)
  result = (normalizeIp(host), parseInt(portStr))

proc newUtpStream*(mgr: UtpManager, sock: UtpSocket, ip: string, port: int): UtpStream =
  result = UtpStream(
    manager: mgr,
    sock: sock,
    remoteIp: ip,
    remotePort: port
  )
  result.readProc = utpStreamRead
  result.writeProc = utpStreamWrite
  result.closeProc = utpStreamClose

proc allocConnId(mgr: UtpManager): uint16 =
  result = mgr.nextConnId.fetchAdd(2, moRelaxed)  # recv and send IDs differ by 1

proc sendPacket(mgr: UtpManager, data: string, ip: string, port: int) =
  ## Fire-and-forget UDP send.
  ## When the socket is AF_INET6 dual-stack and the target is an IPv4 address,
  ## map it to ::ffff:x.x.x.x so sendto() gets an AF_INET6 sockaddr.
  let sendIp = if mgr.domain == AF_INET6 and ':' notin ip:
      "::ffff:" & ip
    else:
      ip
  try:
    let ok = mgr.udpSock.trySendToAddr(data, sendIp, port)
    if not ok:
      utpLog("SEND EAGAIN to " & ip & ":" & $port & " len=" & $data.len)
  except CatchableError as e:
    utpLog("SEND ERROR to " & ip & ":" & $port & " len=" & $data.len & " err=" & e.msg)

proc dispatchDeferred(mgr: UtpManager, cb: proc() {.closure.}) {.inline.} =
  if mgr != nil and mgr.reactorLoop != nil:
    mgr.reactorLoop.scheduleCallback(cb)
  else:
    cb()

proc ensureOnReactor(mgr: UtpManager, cb: proc() {.closure.}) {.inline.} =
  ## Run cb on the event loop thread.  If already on the reactor (or
  ## single-threaded), runs inline.  Otherwise, posts to cross-thread queue.
  if mgr == nil or mgr.reactorLoop == nil:
    cb()
  elif mgr.reactorLoop.shouldProxyToReactor():
    let cbCopy = cb
    mgr.reactorLoop.postToEventLoop(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        cbCopy()
    )
  else:
    cb()  # Already on reactor thread

proc utpConnKey*(connId: uint16, ip: string, port: int): string =
  ## Composite key for connection table: (connectionId, remoteIp, remotePort).
  $connId & ":" & ip & ":" & $port

proc removeConnection(mgr: UtpManager, connId: uint16, ip: string, port: int) {.inline.} =
  if mgr != nil:
    let key = utpConnKey(connId, ip, port)
    mgr.connections.del(key)

# ============================================================
# Packet dispatch
# ============================================================

proc wakeConnectWaiter(stream: UtpStream) =
  if stream.connectWaiter != nil:
    let cw = stream.connectWaiter
    stream.connectWaiter = nil
    dispatchDeferred(stream.manager, proc() =
      cw.complete()
    )

proc failConnectWaiter(stream: UtpStream, msg: string) =
  if stream.connectWaiter != nil:
    let cw = stream.connectWaiter
    stream.connectWaiter = nil
    dispatchDeferred(stream.manager, proc() =
      cw.fail(newException(AsyncIoError, msg))
    )

proc wakeReadWaiterEof(stream: UtpStream) =
  if stream.readWaiter != nil:
    let rw = stream.readWaiter
    stream.readWaiter = nil
    stream.readWaiterSize = 0
    dispatchDeferred(stream.manager, proc() =
      rw.complete("")
    )

proc failReadWaiter(stream: UtpStream, msg: string) =
  if stream.readWaiter != nil:
    let rw = stream.readWaiter
    stream.readWaiter = nil
    stream.readWaiterSize = 0
    dispatchDeferred(stream.manager, proc() =
      rw.fail(newException(AsyncIoError, msg))
    )

proc failWriteWaiter(stream: UtpStream, msg: string) =
  if stream.writeWaiter != nil:
    let ww = stream.writeWaiter
    stream.writeWaiter = nil
    stream.writePending = ""
    stream.writeOffset = 0
    dispatchDeferred(stream.manager, proc() =
      ww.fail(newException(AsyncIoError, msg))
    )

proc drainReceiveBuffer(stream: UtpStream, size: int): string =
  ## Extract up to `size` bytes from the receive buffer, removing them.
  let toRead = min(size, stream.sock.receiveBuffer.len)
  if toRead <= 0: return ""
  result = stream.sock.receiveBuffer[0 ..< toRead]
  if toRead >= stream.sock.receiveBuffer.len:
    stream.sock.receiveBuffer = ""
  else:
    stream.sock.receiveBuffer.delete(0 .. toRead - 1)

proc teardownStream(stream: UtpStream, reason: string) =
  ## Tear down a stream: fail all pending waiters and mark as closed.
  stream.closed = true
  stream.failConnectWaiter(reason)
  if stream.sock.state == usReset:
    stream.failReadWaiter(reason)
  else:
    stream.wakeReadWaiterEof()
  stream.failWriteWaiter(reason)

proc resumePendingWrite(stream: UtpStream) =
  ## Try to send more of the pending write data now that window space opened.
  if stream.writeWaiter == nil or stream.writePending.len == 0:
    return
  while stream.writeOffset < stream.writePending.len:
    let avail = stream.sock.sendWindowAvailable()
    if avail <= 0:
      return  # Still no space, wait for more ACKs
    let chunkLen = min(min(UtpMaxPayload, avail),
                       stream.writePending.len - stream.writeOffset)
    let chunk = stream.writePending[stream.writeOffset ..<
                                    stream.writeOffset + chunkLen]
    let pkt = stream.sock.makeDataPacket(chunk)
    stream.manager.sendPacket(pkt, stream.remoteIp, stream.remotePort)
    stream.writeOffset += chunkLen
  # All data sent
  let ww = stream.writeWaiter
  stream.writeWaiter = nil
  stream.writePending = ""
  stream.writeOffset = 0
  dispatchDeferred(stream.manager, proc() =
    ww.complete()
  )

proc dispatchPacket(mgr: UtpManager, data: string, srcIp: string, srcPort: int) =
  ## Route an incoming UDP packet to the correct UtpStream by connection ID.
  if data.len < UtpHeaderSize:
    return

  var hdr: UtpPacketHeader
  try:
    hdr = decodeHeader(data)
  except ValueError:
    return

  utpLog("RECV " & pktTypeName(hdr.packetType) & " connId=" & $hdr.connectionId &
    " seq=" & $hdr.seqNr & " ack=" & $hdr.ackNr &
    " wnd=" & $hdr.windowSize & " len=" & $(data.len - UtpHeaderSize) &
    " from " & srcIp & ":" & $srcPort)

  # Look up by (connectionId, srcIp, srcPort) to prevent cross-peer collision
  let connKey = utpConnKey(hdr.connectionId, srcIp, srcPort)
  var stream: UtpStream
  if mgr.connections.tryGet(connKey, stream):
    var res: tuple[response: string, payload: string, stateChanged: bool]
    try:
      res = stream.sock.processIncoming(data)
    except CatchableError as e:
      utpLog("processIncoming ERROR: " & e.msg)
      return

    utpLog("  state=" & $stream.sock.state & " curWnd=" & $stream.sock.curWindow &
      " maxWnd=" & $stream.sock.maxWindow & " peerWnd=" & $stream.sock.wndSize &
      " ackNr=" & $stream.sock.ackNr & " seqNr=" & $stream.sock.seqNr &
      " outBuf=" & $stream.sock.outBuffer.len &
      " rcvBuf=" & $stream.sock.receiveBuffer.len &
      " payload=" & $res.payload.len)

    # Send response packet (ACK, etc.)
    if res.response.len > 0:
      mgr.sendPacket(res.response, srcIp, srcPort)

    # ACK may have freed window space — try to send buffered write data
    stream.resumePendingWrite()

    # Deliver received data to pending read waiter
    if res.payload.len > 0:
      stream.sock.receiveBuffer.add(res.payload)
      if stream.readWaiter != nil:
        let rw = stream.readWaiter
        stream.readWaiter = nil
        let requested = max(0, stream.readWaiterSize)
        stream.readWaiterSize = 0
        let buf = stream.drainReceiveBuffer(requested)
        dispatchDeferred(stream.manager, proc() =
          rw.complete(buf)
        )

    # Handle state transitions
    if res.stateChanged:
      if stream.sock.state == usConnected:
        stream.wakeConnectWaiter()
      elif stream.sock.state in {usDestroyed, usReset}:
        stream.teardownStream("uTP " & $stream.sock.state)
        removeConnection(mgr, stream.sock.connectionId, stream.remoteIp, stream.remotePort)

  elif hdr.packetType == StSyn:
    # Incoming connection request
    let connId = hdr.connectionId + 1
    let synKey = utpConnKey(connId, srcIp, srcPort)
    # Reject if a stream with this key already exists (prevent overwrite)
    if synKey in mgr.connections:
      return

    # BEP 55 simultaneous open: if we already have an outgoing connection
    # attempt to this (ip, port), the remote sent their own SYN at the same
    # time.  Accept the incoming SYN as the winner: create the new stream,
    # transfer the outgoing connectWaiter to it, and remove the stale
    # outgoing entry so that `utpConnect` unblocks on the incoming stream.
    var existingOutgoing: UtpStream = nil
    var existingKey: string = ""
    for (k, s) in mgr.connections.snapshotPairs():
      if s.remoteIp == srcIp and s.remotePort == srcPort and
         s.connectWaiter != nil and s.sock.state == usSynSent:
        existingOutgoing = s
        existingKey = k
        break

    let sock = newUtpSocket(connId)
    let newStream = newUtpStream(mgr, sock, srcIp, srcPort)
    mgr.connections[synKey] = newStream

    var res: tuple[response: string, payload: string, stateChanged: bool]
    try:
      res = sock.processIncoming(data)
    except CatchableError:
      mgr.connections.del(synKey)
      return

    if res.response.len > 0:
      mgr.sendPacket(res.response, srcIp, srcPort)

    if existingOutgoing != nil:
      # BEP 55 simultaneous open: both sides sent SYN at the same time.
      # Cancel our outgoing attempt so it fails fast (instead of waiting for
      # the 8s timeout) and let the incoming stream proceed through the
      # normal utpAccept → handleIncomingPeer path. The handleIncomingPeer
      # race handler will detect the stale outgoing peer and replace it.
      utpLog("SIMULTANEOUS-OPEN: incoming SYN from " & srcIp & ":" & $srcPort &
        " cancelling outgoing connId=" & $existingOutgoing.sock.connectionId)
      existingOutgoing.sock.state = usReset
      existingOutgoing.failConnectWaiter("uTP simultaneous open — incoming wins")
      mgr.connections.del(existingKey)
    if mgr.acceptWaiter != nil:
      let aw = mgr.acceptWaiter
      mgr.acceptWaiter = nil
      dispatchDeferred(mgr, proc() =
        aw.complete(newStream)
      )
    elif mgr.acceptBacklog.len < UtpAcceptBacklogSize:
      # Queue for a future accept call.
      mgr.acceptBacklog.addLast(newStream)
    else:
      # Backlog full — reset
      let resetPkt = sock.makeResetPacket()
      mgr.sendPacket(resetPkt, srcIp, srcPort)
      removeConnection(mgr, connId, srcIp, srcPort)

# ============================================================
# Manager lifecycle
# ============================================================

proc newUtpManager*(listenPort: int = 0, domain: Domain = AF_INET): UtpManager =
  result = UtpManager(
    udpSock: newUdpSocket(domain),
    domain: domain,
    closed: false,
    acceptBacklog: initDeque[UtpStream](),
    reactorLoop: nil
  )
  result.nextConnId.store(1000, moRelaxed)
  result.connections = initConcurrentTable[string, UtpStream]()
  # Dual-stack: allow IPv6 socket to handle IPv4 (as ::ffff:x.x.x.x) too
  if domain == AF_INET6:
    var no: cint = 0
    discard setsockopt(result.udpSock.fd, IPPROTO_IPV6_C, IPV6_V6ONLY_C,
                       addr no, sizeof(no).SockLen)
    result.udpSock.bindAddr("::", listenPort)
  else:
    result.udpSock.bindAddr("0.0.0.0", listenPort)
  result.port = result.udpSock.localPort()

proc start*(mgr: UtpManager) =
  ## Start the uTP manager: receive packets and check timeouts.

  # Persistent UDP read callback
  let loop = getEventLoop()
  mgr.reactorLoop = loop
  utpLog("START manager port=" & $mgr.port & " fd=" & $mgr.udpSock.fd.int)
  mgr.udpSock.onRecv(1500, proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
    try:
      let (ip, port) = extractAddr(srcAddr, addrLen)
      if ip.len > 0:
        mgr.dispatchPacket(data, ip, port)
    except CatchableError:
      discard
  )

  # Periodic timeout checker (every 500ms)
  proc checkTimeouts() {.closure.} =
    if mgr.closed:
      return
    # Snapshot keys atomically — worker threads may call utpConnect/
    # removeConnection concurrently via CPS continuations.
    let keys = mgr.connections.snapshotKeys()
    var toRemove: seq[string]
    var ki = 0
    while ki < keys.len:
      let cKey = keys[ki]
      inc ki
      var stream: UtpStream
      if not mgr.connections.tryGet(cKey, stream):
        continue  # Removed concurrently
      let retransmits = stream.sock.checkTimeouts()
      if retransmits.len > 0:
        utpLog("TIMEOUT retransmit " & $retransmits.len & " pkts to " &
          stream.remoteIp & ":" & $stream.remotePort &
          " state=" & $stream.sock.state &
          " outBuf=" & $stream.sock.outBuffer.len &
          " curWnd=" & $stream.sock.curWindow &
          " maxWnd=" & $stream.sock.maxWindow)
      for pkt in retransmits:
        mgr.sendPacket(pkt, stream.remoteIp, stream.remotePort)
      if not mgr.connections.contains(cKey):
        continue
      if stream.sock.state in {usReset, usDestroyed}:
        stream.teardownStream("uTP timeout " & $stream.sock.state)
        toRemove.add(cKey)
    for cKey in toRemove:
      mgr.connections.del(cKey)
    if not mgr.closed:
      loop.registerTimer(500, checkTimeouts)
  loop.registerTimer(500, checkTimeouts)

proc close*(mgr: UtpManager) =
  if mgr.closed:
    return
  mgr.closed = true
  if mgr.acceptWaiter != nil:
    mgr.acceptWaiter.fail(newException(AsyncIoError, "uTP manager closed"))
    mgr.acceptWaiter = nil
  mgr.acceptBacklog.clear()
  let closeKeys = mgr.connections.snapshotKeys()
  for cKey in closeKeys:
    var stream: UtpStream
    if not mgr.connections.tryGet(cKey, stream):
      continue
    if stream.sock.state == usConnected:
      let fin = stream.sock.makeFinPacket()
      mgr.sendPacket(fin, stream.remoteIp, stream.remotePort)
    stream.teardownStream("uTP manager closed")
  mgr.connections.clear()
  mgr.udpSock.close()

proc connectionCount*(mgr: UtpManager): int =
  mgr.connections.len

# ============================================================
# CPS procs: connect and accept
# ============================================================

proc utpConnect*(mgr: UtpManager, ip: string, port: int,
                 timeoutMs: int = UtpConnectTimeoutMs): CpsFuture[UtpStream] {.cps.} =
  ## Connect to a remote peer via uTP. Raises AsyncIoError on timeout/failure.
  let connId: uint16 = mgr.allocConnId()
  let sock: UtpSocket = newUtpSocket(connId)
  let stream: UtpStream = newUtpStream(mgr, sock, ip, port)
  let cKey: string = utpConnKey(connId, ip, port)
  mgr.connections[cKey] = stream

  # Send SYN (also add to outBuffer for automatic retransmission via checkTimeouts)
  let synPkt: string = sock.makeSynPacket()
  mgr.sendPacket(synPkt, ip, port)
  # BEP 55 holepunch: send a burst of SYN packets to widen the NAT timing
  # window.  Back-to-back sends maximise the chance that one SYN is in
  # transit when the remote's NAT mapping (created by their outgoing SYN)
  # opens.  The checkTimeouts retransmit loop (500ms) covers the rest of
  # the timeout window.
  if timeoutMs >= 5000:
    mgr.sendPacket(synPkt, ip, port)
    mgr.sendPacket(synPkt, ip, port)
    sock.rto = 500  # Faster retransmit for holepunch (500ms vs default 1000ms)
    sock.maxRetransmit = 14  # 500ms * 14 = 7s of retransmits, fills the 8s window
  sock.outBuffer.addLast(OutstandingPacket(
    seqNr: sock.seqNr - 1,
    data: synPkt,
    sentAt: epochTime()
  ))

  # Wait for STATE response
  let connectFut: CpsVoidFuture = newCpsVoidFuture()
  connectFut.pinFutureRuntime()
  stream.connectWaiter = connectFut

  try:
    await withTimeout(connectFut, timeoutMs)
  except TimeoutError:
    stream.connectWaiter = nil
    removeConnection(mgr, connId, ip, port)
    raise newException(AsyncIoError, "uTP connect timed out to " & ip & ":" & $port)
  except CatchableError as e:
    stream.connectWaiter = nil
    removeConnection(mgr, connId, ip, port)
    raise e

  if sock.state != usConnected:
    removeConnection(mgr, connId, ip, port)
    raise newException(AsyncIoError, "uTP connect failed: " & $sock.state)

  return stream

proc utpAccept*(mgr: UtpManager): CpsFuture[UtpStream] {.cps.} =
  ## Wait for an incoming uTP connection.
  # Drain backlog first — return a queued connection immediately if available.
  if mgr.acceptBacklog.len > 0:
    let queued: UtpStream = mgr.acceptBacklog.popFirst()
    return queued
  let acceptFut: CpsFuture[UtpStream] = newCpsFuture[UtpStream]()
  acceptFut.pinFutureRuntime()
  mgr.acceptWaiter = acceptFut
  let stream: UtpStream = await acceptFut
  return stream

# ============================================================
# AsyncStream vtable implementations
# ============================================================

proc utpStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let stream = UtpStream(s)
  let fut = newCpsFuture[string]()
  fut.pinFutureRuntime()

  if size <= 0:
    fut.complete("")
    return fut

  # All receiveBuffer / readWaiter access must happen on the reactor thread
  # to avoid data races with dispatchPacket (UDP read handler).
  ensureOnReactor(stream.manager, proc() =
    if stream.sock.receiveBuffer.len > 0:
      fut.complete(stream.drainReceiveBuffer(size))
    elif stream.closed or stream.sock.state in {usDestroyed, usReset}:
      fut.complete("")  # EOF
    else:
      stream.readWaiter = fut
      stream.readWaiterSize = size
  )

  return fut

proc utpStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let stream = UtpStream(s)
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()

  if data.len == 0:
    fut.complete()
    return fut

  # All socket state / writeWaiter access must happen on the reactor thread
  # to avoid data races with dispatchPacket → resumePendingWrite.
  let dataCopy = data
  ensureOnReactor(stream.manager, proc() =
    if stream.closed or stream.sock.state != usConnected:
      utpLog("WRITE FAIL: not connected state=" & $stream.sock.state &
        " to " & stream.remoteIp & ":" & $stream.remotePort)
      fut.fail(newException(AsyncIoError, "uTP stream not connected"))
      return

    if stream.writeWaiter != nil:
      utpLog("WRITE FAIL: concurrent write to " & stream.remoteIp & ":" & $stream.remotePort)
      fut.fail(newException(AsyncIoError, "uTP concurrent write not supported"))
      return

    utpLog("WRITE " & $dataCopy.len & "B to " & stream.remoteIp & ":" & $stream.remotePort &
      " avail=" & $stream.sock.sendWindowAvailable() &
      " curWnd=" & $stream.sock.curWindow & " maxWnd=" & $stream.sock.maxWindow &
      " peerWnd=" & $stream.sock.wndSize)

    # Send data in MTU-sized chunks, respecting congestion window
    var offset = 0
    while offset < dataCopy.len:
      let avail = stream.sock.sendWindowAvailable()
      if avail <= 0:
        break  # Window full — wait for ACKs to free space
      let chunkLen = min(min(UtpMaxPayload, avail), dataCopy.len - offset)
      let chunk = dataCopy[offset ..< offset + chunkLen]
      let pkt = stream.sock.makeDataPacket(chunk)
      stream.manager.sendPacket(pkt, stream.remoteIp, stream.remotePort)
      offset += chunkLen

    if offset >= dataCopy.len:
      # All data sent
      utpLog("WRITE complete " & $dataCopy.len & "B to " & stream.remoteIp & ":" & $stream.remotePort)
      fut.complete()
    else:
      # Window full — buffer remaining data and wait for ACKs
      utpLog("WRITE partial " & $offset & "/" & $dataCopy.len & "B, buffering rest to " &
        stream.remoteIp & ":" & $stream.remotePort)
      stream.writeWaiter = fut
      stream.writePending = dataCopy
      stream.writeOffset = offset
  )

  return fut

proc utpStreamClose(s: AsyncStream) =
  let stream = UtpStream(s)
  # Close logic mutates socket state and mgr.connections — must run on reactor.
  ensureOnReactor(stream.manager, proc() =
    if stream.sock.state == usConnected:
      let fin = stream.sock.makeFinPacket()
      stream.manager.sendPacket(fin, stream.remoteIp, stream.remotePort)
    stream.teardownStream("uTP stream closed")
    if stream.manager != nil and not stream.manager.closed:
      removeConnection(stream.manager, stream.sock.connectionId, stream.remoteIp, stream.remotePort)
  )
