## BEP 29: uTorrent Transport Protocol (uTP).
##
## A UDP-based transport protocol with LEDBAT congestion control.
## Provides reliable, ordered data delivery like TCP but over UDP,
## with congestion control that yields to TCP traffic.

import std/[times, deques]
import utils

const
  UtpVersion* = 1'u8
  UtpHeaderSize* = 20

  # Packet types
  StData* = 0'u8
  StFin* = 1'u8
  StState* = 2'u8    # ACK
  StReset* = 3'u8
  StSyn* = 4'u8

  # Window and timing constants
  DefaultWindowSize* = 1048576   ## 1 MiB default max window (used as initial ssthresh)
  MinPacketSize* = 150            ## Minimum packet size
  MaxPacketSize* = 1400           ## Max UDP payload (MTU-safe)
  MinCwndBytes* = MaxPacketSize   ## Minimum congestion window = 1 MSS
  MaxCwndIncrease* = 3000         ## Max cwnd increase per RTT in bytes (BEP 29)
  SynTimeout* = 3000              ## SYN timeout in ms
  ConnTimeout* = 5000             ## Connection timeout in ms
  MaxRetransmit* = 4              ## Max retransmission attempts
  PacketLossTimeout* = 500        ## ms before considering a packet lost
  DelayTarget* = 100_000          ## LEDBAT target delay in microseconds (100ms)
  MaxDelayMicros* = 10_000_000'u32 ## Discard delay samples above 10s (clock anomaly)
  BaseDelaySlots* = 13             ## ~2 min base delay history (libutp convention)
  BaseDelayInterval* = 10.0       ## Seconds per base delay slot rotation

type
  UtpState* = enum
    usIdle
    usSynSent      ## We sent SYN, waiting for STATE
    usSynRecv      ## We received SYN, sent STATE
    usConnected    ## Data transfer
    usFinSent      ## We sent FIN
    usReset        ## Connection reset
    usDestroyed    ## Connection closed

  UtpPacketHeader* = object
    packetType*: uint8
    version*: uint8
    extension*: uint8
    connectionId*: uint16
    timestamp*: uint32           ## Microseconds
    timestampDiff*: uint32       ## Microsecond delay
    windowSize*: uint32          ## Advertised receive window
    seqNr*: uint16
    ackNr*: uint16

  UtpPacket* = object
    header*: UtpPacketHeader
    payload*: string
    extensions*: seq[tuple[kind: uint8, data: string]]

  OutstandingPacket* = object
    seqNr*: uint16
    data*: string          ## Full packet data (header + payload)
    sentAt*: float         ## When it was sent
    retransmits*: int

  UtpSocket* = ref object
    state*: UtpState
    connectionId*: uint16          ## Our connection ID (recv)
    sendConnectionId*: uint16      ## Their connection ID (send)
    seqNr*: uint16                 ## Next sequence number to send
    ackNr*: uint16                 ## Last ack'd packet from peer
    # Congestion control (LEDBAT)
    maxWindow*: int                ## Max send window (bytes)
    curWindow*: int                ## Current bytes in flight
    wndSize*: uint32               ## Peer's advertised window
    slowStart*: bool               ## True until first congestion signal
    ssthresh*: int                 ## Slow start threshold
    # Delay measurement
    lastPeerTimestamp*: uint32     ## Peer's timestamp from last received packet
    hasPeerTimestamp*: bool        ## Whether we've received at least one packet
    # Base delay tracking (LEDBAT)
    baseDelays*: array[BaseDelaySlots, uint32]  ## Min delay per 10s window
    baseDelayIdx*: int             ## Current slot index
    baseDelayTime*: float          ## When current slot started (epochTime)
    baseDelayValid*: int           ## Number of valid slots (0 until first sample)
    # Loss event tracking
    lastLossSeqNr*: uint16         ## seqNr at time of last loss halving
    lastLossTime*: float           ## epochTime of last loss event
    # Timing
    rtt*: int                      ## Smoothed RTT in microseconds
    rttVar*: int                   ## RTT variance
    rto*: int                      ## Retransmission timeout in ms
    # Buffers
    outBuffer*: Deque[OutstandingPacket]
    inBuffer*: seq[tuple[seqNr: uint16, data: string]]  ## Out-of-order receive buffer
    receiveBuffer*: string         ## Ordered data ready for reading
    # Stats
    bytesAcked*: int64
    bytesReceived*: int64
    lastRecvTime*: float
    maxRetransmit*: int            ## Per-socket retransmit limit (0 = use global MaxRetransmit)

proc nowMicros(): uint32 =
  ## Current time in microseconds (truncated to uint32).
  uint32((epochTime() * 1_000_000).int64 and 0xFFFFFFFF'i64)

proc seqNrAfter*(a, b: uint16): bool {.inline.} =
  ## True if sequence number `a` is after `b` (with uint16 wraparound).
  cast[int16](a - b) > 0

proc newUtpSocket*(connId: uint16): UtpSocket =
  UtpSocket(
    state: usIdle,
    connectionId: connId,
    sendConnectionId: connId + 1,
    seqNr: 1,
    ackNr: 0,
    maxWindow: 2 * MaxPacketSize,  # Start small (slow start)
    curWindow: 0,
    wndSize: DefaultWindowSize.uint32,
    slowStart: true,
    ssthresh: DefaultWindowSize,
    hasPeerTimestamp: false,
    baseDelayValid: 0,
    rtt: 0,
    rttVar: 800_000,  # 800ms initial
    rto: 1000,
    outBuffer: initDeque[OutstandingPacket](),
    lastRecvTime: epochTime()
  )

# Base delay tracking (LEDBAT)

proc updateBaseDelay*(sock: UtpSocket, delaySample: uint32) =
  ## Update the rolling base delay with a new one-way delay sample.
  if delaySample > MaxDelayMicros:
    return  # Discard anomalous samples
  let now = epochTime()
  if sock.baseDelayValid == 0:
    # First sample ever
    sock.baseDelays[0] = delaySample
    sock.baseDelayIdx = 0
    sock.baseDelayTime = now
    sock.baseDelayValid = 1
  else:
    # Rotate slot if enough time has passed
    if now - sock.baseDelayTime >= BaseDelayInterval:
      sock.baseDelayIdx = (sock.baseDelayIdx + 1) mod BaseDelaySlots
      sock.baseDelays[sock.baseDelayIdx] = delaySample
      sock.baseDelayTime = now
      if sock.baseDelayValid < BaseDelaySlots:
        sock.baseDelayValid += 1
    else:
      # Update current slot with minimum
      if delaySample < sock.baseDelays[sock.baseDelayIdx]:
        sock.baseDelays[sock.baseDelayIdx] = delaySample

proc getBaseDelay*(sock: UtpSocket): uint32 =
  ## Return the minimum delay across all valid base delay slots.
  if sock.baseDelayValid == 0:
    return 0
  result = high(uint32)
  for i in 0 ..< sock.baseDelayValid:
    let idx = (sock.baseDelayIdx - i + BaseDelaySlots) mod BaseDelaySlots
    if sock.baseDelays[idx] < result:
      result = sock.baseDelays[idx]

proc computeTimestampDiff*(sock: UtpSocket): uint32 {.inline.} =
  ## Compute timestampDiff for outgoing packets: nowMicros() - lastPeerTimestamp.
  ## Tells the peer their one-way delay. Returns 0 before first recv.
  if sock.hasPeerTimestamp:
    nowMicros() - sock.lastPeerTimestamp  # uint32 wraps naturally
  else:
    0'u32

# Packet encoding/decoding

proc encodeHeader*(h: UtpPacketHeader): string =
  ## Encode a uTP header to bytes (20 bytes).
  result = newStringOfCap(UtpHeaderSize)
  # Type + version (4 bits each)
  result.add(char((h.packetType shl 4) or (h.version and 0x0F)))
  result.add(char(h.extension))
  result.writeUint16BE(h.connectionId)
  result.writeUint32BE(h.timestamp)
  result.writeUint32BE(h.timestampDiff)
  result.writeUint32BE(h.windowSize)
  result.writeUint16BE(h.seqNr)
  result.writeUint16BE(h.ackNr)

proc decodeHeader*(data: string): UtpPacketHeader =
  ## Decode a uTP header from bytes.
  if data.len < UtpHeaderSize:
    raise newException(ValueError, "uTP packet too short: " & $data.len)

  result.packetType = (data[0].byte shr 4) and 0x0F
  result.version = data[0].byte and 0x0F
  result.extension = data[1].byte
  result.connectionId = readUint16BE(data, 2)
  result.timestamp = readUint32BE(data, 4)
  result.timestampDiff = readUint32BE(data, 8)
  result.windowSize = readUint32BE(data, 12)
  result.seqNr = readUint16BE(data, 16)
  result.ackNr = readUint16BE(data, 18)

proc decodePacket*(data: string): UtpPacket =
  ## Decode a complete uTP packet.
  result.header = decodeHeader(data)
  if result.header.version != UtpVersion:
    raise newException(ValueError, "unsupported uTP version: " & $result.header.version)

  var offset = UtpHeaderSize

  # Parse extensions
  var extType = result.header.extension
  while extType != 0 and offset < data.len:
    if offset + 2 > data.len:
      break
    let nextExt = data[offset].byte
    let extLen = int(data[offset+1])
    offset += 2
    if extLen == 0 or offset + extLen > data.len:
      break
    let extData = data[offset ..< offset + extLen]
    result.extensions.add((extType, extData))
    extType = nextExt
    offset += extLen

  # Remaining data is payload
  if offset < data.len:
    result.payload = data[offset .. ^1]

proc encodePacket*(pkt: UtpPacket): string =
  ## Encode a complete uTP packet.
  ## Extension chain format: header.extension = first ext type,
  ## each ext starts with [next_ext_type, length, data].
  result = encodeHeader(pkt.header)
  # Extensions
  for i, ext in pkt.extensions:
    let nextType = if i + 1 < pkt.extensions.len: pkt.extensions[i + 1].kind
                   else: 0'u8
    result.add(char(nextType))
    result.add(char(ext.data.len.byte))
    result.add(ext.data)
  result.add(pkt.payload)

# Connection state machine

proc makePacketHeader(sock: UtpSocket, packetType: uint8,
                      connectionId: uint16,
                      ackNr: uint16): UtpPacketHeader {.inline.} =
  ## Build a uTP header with common fields filled from socket state.
  UtpPacketHeader(
    packetType: packetType,
    version: UtpVersion,
    connectionId: connectionId,
    timestamp: nowMicros(),
    timestampDiff: sock.computeTimestampDiff(),
    windowSize: sock.maxWindow.uint32,
    seqNr: sock.seqNr,
    ackNr: ackNr
  )

proc makeSynPacket*(sock: UtpSocket): string =
  ## Create a SYN packet to initiate connection.
  let hdr = sock.makePacketHeader(StSyn, sock.connectionId, ackNr = 0)
  sock.seqNr += 1
  sock.state = usSynSent
  return encodeHeader(hdr)

proc makeStatePacket*(sock: UtpSocket): string =
  ## Create a STATE (ACK) packet.
  encodeHeader(sock.makePacketHeader(StState, sock.sendConnectionId, sock.ackNr))

proc makeDataPacket*(sock: UtpSocket, payload: string): string =
  ## Create a DATA packet.
  let hdr = sock.makePacketHeader(StData, sock.sendConnectionId, sock.ackNr)
  let pkt = UtpPacket(header: hdr, payload: payload)
  let data = encodePacket(pkt)
  sock.outBuffer.addLast(OutstandingPacket(
    seqNr: sock.seqNr,
    data: data,
    sentAt: epochTime()
  ))
  sock.seqNr += 1
  sock.curWindow += payload.len
  return data

proc makeFinPacket*(sock: UtpSocket): string =
  ## Create a FIN packet to close connection.
  let hdr = sock.makePacketHeader(StFin, sock.sendConnectionId, sock.ackNr)
  sock.seqNr += 1
  sock.state = usFinSent
  return encodeHeader(hdr)

proc makeResetPacket*(sock: UtpSocket): string =
  ## Create a RESET packet.
  let hdr = sock.makePacketHeader(StReset, sock.sendConnectionId, sock.ackNr)
  sock.state = usReset
  return encodeHeader(hdr)

proc processAck(sock: UtpSocket, ackNr: uint16, timestampDiff: uint32,
                now: float) =
  ## Process an ACK - remove ack'd packets from outBuffer, update RTT, run LEDBAT.
  var totalBytesAcked = 0

  while sock.outBuffer.len > 0:
    let front = sock.outBuffer.peekFirst()
    # Check if this packet is ack'd (handling wraparound)
    if not seqNrAfter(front.seqNr, ackNr):
      let acked = sock.outBuffer.popFirst()
      let payloadBytes = acked.data.len - UtpHeaderSize
      let rttSample = int((now - acked.sentAt) * 1_000_000)
      sock.curWindow -= payloadBytes
      sock.bytesAcked += payloadBytes
      totalBytesAcked += payloadBytes

      # Update RTT estimates (RFC 6298)
      if sock.rtt == 0:
        sock.rtt = rttSample
        sock.rttVar = rttSample div 2
      else:
        sock.rttVar = (3 * sock.rttVar + abs(sock.rtt - rttSample)) div 4
        sock.rtt = (7 * sock.rtt + rttSample) div 8

      # Update RTO
      sock.rto = max(500, (sock.rtt + 4 * sock.rttVar) div 1000)
    else:
      break

  # LEDBAT congestion control
  # timestampDiff is the peer's measurement of our one-way delay (uint32 microseconds).
  if timestampDiff > 0 and timestampDiff <= MaxDelayMicros and totalBytesAcked > 0:
    let ourDelay = timestampDiff  # uint32 microseconds
    sock.updateBaseDelay(ourDelay)

    if sock.baseDelayValid > 0:
      let baseDelay = sock.getBaseDelay()
      # Clamp to zero: if ourDelay < baseDelay (clock jitter), no queuing delay
      let queuingDelay =
        if ourDelay >= baseDelay: ourDelay - baseDelay
        else: 0'u32

      if sock.slowStart:
        # Slow start: exponential growth until congestion signal
        if queuingDelay > DelayTarget.uint32:
          # Congestion detected — exit slow start
          sock.ssthresh = sock.maxWindow
          sock.slowStart = false
        elif sock.maxWindow >= sock.ssthresh:
          # Reached threshold — exit slow start
          sock.slowStart = false
        else:
          sock.maxWindow += totalBytesAcked  # ~doubles per RTT

      if not sock.slowStart:
        # LEDBAT: cwnd += MAX_CWND_INCREASE * (TARGET - qdelay) / TARGET * bytes_acked / cwnd
        let offTarget = clamp(
          (DelayTarget.float - queuingDelay.float) / DelayTarget.float,
          -1.0, 1.0)
        let scaledGain = MaxCwndIncrease.float * offTarget *
                         totalBytesAcked.float / max(1, sock.maxWindow).float
        sock.maxWindow = max(MinCwndBytes, sock.maxWindow + int(scaledGain))

proc processIncoming*(sock: UtpSocket, data: string): tuple[
    response: string, payload: string, stateChanged: bool] =
  ## Process an incoming uTP packet.
  ## Returns: response packet to send (if any), extracted payload, whether state changed.
  let pkt = decodePacket(data)
  let hdr = pkt.header

  let now = epochTime()
  sock.lastRecvTime = now
  sock.lastPeerTimestamp = hdr.timestamp
  sock.hasPeerTimestamp = true
  sock.wndSize = hdr.windowSize

  case sock.state
  of usIdle:
    if hdr.packetType == StSyn:
      # Incoming connection
      sock.connectionId = hdr.connectionId + 1
      sock.sendConnectionId = hdr.connectionId
      sock.ackNr = hdr.seqNr
      sock.state = usConnected
      result.response = sock.makeStatePacket()
      result.stateChanged = true

  of usSynSent:
    if hdr.packetType == StState:
      # SYN-ACK received — STATE doesn't consume a sequence number
      sock.ackNr = hdr.seqNr - 1
      sock.state = usConnected
      sock.processAck(hdr.ackNr, hdr.timestampDiff, now)
      result.stateChanged = true
    elif hdr.packetType == StSyn:
      # Simultaneous open (BEP 55 holepunch race): both sides sent SYN.
      # SYN consumes a sequence number, so ackNr = seqNr (not seqNr - 1).
      sock.ackNr = hdr.seqNr
      sock.connectionId = hdr.connectionId + 1
      sock.sendConnectionId = hdr.connectionId
      sock.state = usConnected
      result.response = sock.makeStatePacket()
      result.stateChanged = true

  of usConnected:
    case hdr.packetType
    of StData:
      let expectedSeq = sock.ackNr + 1
      if hdr.seqNr == expectedSeq:
        sock.ackNr = hdr.seqNr
        result.payload = pkt.payload
        sock.bytesReceived += pkt.payload.len
        # Check if we have buffered follow-on packets
        var deliveredMore = true
        while deliveredMore:
          deliveredMore = false
          var i = 0
          while i < sock.inBuffer.len:
            if sock.inBuffer[i].seqNr == sock.ackNr + 1:
              sock.ackNr = sock.inBuffer[i].seqNr
              result.payload.add(sock.inBuffer[i].data)
              sock.bytesReceived += sock.inBuffer[i].data.len
              sock.inBuffer.delete(i)
              deliveredMore = true
            else:
              i += 1
      elif seqNrAfter(hdr.seqNr, expectedSeq):
        # Future packet - buffer it
        var found = false
        for buf in sock.inBuffer:
          if buf.seqNr == hdr.seqNr:
            found = true
            break
        if not found:
          sock.inBuffer.add((hdr.seqNr, pkt.payload))
      # Send ACK
      result.response = sock.makeStatePacket()
      sock.processAck(hdr.ackNr, hdr.timestampDiff, now)

    of StState:
      # ACK only
      sock.processAck(hdr.ackNr, hdr.timestampDiff, now)

    of StFin:
      sock.ackNr = hdr.seqNr
      result.response = sock.makeStatePacket()
      sock.state = usDestroyed
      result.stateChanged = true

    of StReset:
      sock.state = usReset
      result.stateChanged = true

    else:
      discard

  of usFinSent:
    if hdr.packetType == StState:
      sock.processAck(hdr.ackNr, hdr.timestampDiff, now)
      sock.state = usDestroyed
      result.stateChanged = true
    elif hdr.packetType == StFin:
      sock.ackNr = hdr.seqNr
      result.response = sock.makeStatePacket()
      sock.state = usDestroyed
      result.stateChanged = true

  else:
    discard

proc canSend*(sock: UtpSocket): bool =
  ## Check if we can send more data (window allows it).
  sock.state == usConnected and
  sock.curWindow < sock.maxWindow and
  sock.curWindow < sock.wndSize.int

proc sendWindowAvailable*(sock: UtpSocket): int =
  ## How many bytes we can send right now.
  if not sock.canSend():
    return 0
  min(sock.maxWindow - sock.curWindow, sock.wndSize.int - sock.curWindow)

proc checkTimeouts*(sock: UtpSocket): seq[string] =
  ## Check for timed-out packets and return those needing retransmission.
  ## sentAt is updated on retransmit so the packet waits another full RTO
  ## before being eligible again.
  ## Window is halved at most once per loss event (not per timed-out packet).
  let now = epochTime()
  let timeoutSec = sock.rto.float / 1000.0
  let maxRetx = if sock.maxRetransmit > 0: sock.maxRetransmit else: MaxRetransmit
  var halvedThisRound = false

  for pkt in sock.outBuffer.mitems:
    if now - pkt.sentAt > timeoutSec:
      pkt.retransmits += 1
      if pkt.retransmits > maxRetx:
        sock.state = usReset
        return @[]
      pkt.sentAt = now
      result.add(pkt.data)

      # Halve the window once per loss event
      if not halvedThisRound:
        # Check if this is a new loss event (packet was sent after last loss)
        if seqNrAfter(pkt.seqNr, sock.lastLossSeqNr) or sock.lastLossTime == 0:
          sock.maxWindow = max(MinCwndBytes, sock.maxWindow div 2)
          sock.lastLossSeqNr = sock.seqNr - 1  # Highest sent seqNr
          sock.lastLossTime = now
          if sock.slowStart:
            sock.ssthresh = sock.maxWindow
            sock.slowStart = false
          halvedThisRound = true
