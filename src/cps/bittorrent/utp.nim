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
  DefaultWindowSize* = 1048576   ## 1 MiB default max window
  MinPacketSize* = 150            ## Minimum packet size
  MaxPacketSize* = 1400           ## Max UDP payload (MTU-safe)
  SynTimeout* = 3000              ## SYN timeout in ms
  ConnTimeout* = 5000             ## Connection timeout in ms
  MaxRetransmit* = 4              ## Max retransmission attempts
  PacketLossTimeout* = 500        ## ms before considering a packet lost
  DelayTarget* = 100_000          ## LEDBAT target delay in microseconds (100ms)
  Gain* = 1.0                     ## LEDBAT gain factor

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
    needsResend*: bool

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

proc newUtpSocket*(connId: uint16): UtpSocket =
  UtpSocket(
    state: usIdle,
    connectionId: connId,
    sendConnectionId: connId + 1,
    seqNr: 1,
    ackNr: 0,
    maxWindow: DefaultWindowSize,
    curWindow: 0,
    wndSize: DefaultWindowSize.uint32,
    rtt: 0,
    rttVar: 800_000,  # 800ms initial
    rto: 1000,
    outBuffer: initDeque[OutstandingPacket](),
    lastRecvTime: epochTime()
  )

# Packet encoding/decoding

proc encodeHeader*(h: UtpPacketHeader): string =
  ## Encode a uTP header to bytes (20 bytes).
  result = newStringOfCap(UtpHeaderSize)
  # Type + version (4 bits each)
  result.add(char((h.packetType shl 4) or (h.version and 0x0F)))
  result.add(char(h.extension))
  result.add(char((h.connectionId shr 8).byte))
  result.add(char((h.connectionId and 0xFF).byte))
  # Timestamp (4 bytes)
  result.writeUint32BE(h.timestamp)
  # Timestamp diff (4 bytes)
  result.writeUint32BE(h.timestampDiff)
  # Window size (4 bytes)
  result.writeUint32BE(h.windowSize)
  # Seq nr (2 bytes)
  result.add(char((h.seqNr shr 8).byte))
  result.add(char((h.seqNr and 0xFF).byte))
  # Ack nr (2 bytes)
  result.add(char((h.ackNr shr 8).byte))
  result.add(char((h.ackNr and 0xFF).byte))

proc decodeHeader*(data: string): UtpPacketHeader =
  ## Decode a uTP header from bytes.
  if data.len < UtpHeaderSize:
    raise newException(ValueError, "uTP packet too short: " & $data.len)

  result.packetType = (data[0].byte shr 4) and 0x0F
  result.version = data[0].byte and 0x0F
  result.extension = data[1].byte
  result.connectionId = (uint16(data[2].byte) shl 8) or uint16(data[3].byte)
  result.timestamp = readUint32BE(data, 4)
  result.timestampDiff = readUint32BE(data, 8)
  result.windowSize = readUint32BE(data, 12)
  result.seqNr = (uint16(data[16].byte) shl 8) or uint16(data[17].byte)
  result.ackNr = (uint16(data[18].byte) shl 8) or uint16(data[19].byte)

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
    let extLen = data[offset+1].byte.int
    offset += 2
    if offset + extLen > data.len:
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

proc makeSynPacket*(sock: UtpSocket): string =
  ## Create a SYN packet to initiate connection.
  let hdr = UtpPacketHeader(
    packetType: StSyn,
    version: UtpVersion,
    connectionId: sock.connectionId,
    timestamp: nowMicros(),
    windowSize: sock.maxWindow.uint32,
    seqNr: sock.seqNr,
    ackNr: 0
  )
  sock.seqNr += 1
  sock.state = usSynSent
  return encodeHeader(hdr)

proc makeStatePacket*(sock: UtpSocket): string =
  ## Create a STATE (ACK) packet.
  let hdr = UtpPacketHeader(
    packetType: StState,
    version: UtpVersion,
    connectionId: sock.sendConnectionId,
    timestamp: nowMicros(),
    windowSize: sock.maxWindow.uint32,
    seqNr: sock.seqNr,
    ackNr: sock.ackNr
  )
  return encodeHeader(hdr)

proc makeDataPacket*(sock: UtpSocket, payload: string): string =
  ## Create a DATA packet.
  let hdr = UtpPacketHeader(
    packetType: StData,
    version: UtpVersion,
    connectionId: sock.sendConnectionId,
    timestamp: nowMicros(),
    windowSize: sock.maxWindow.uint32,
    seqNr: sock.seqNr,
    ackNr: sock.ackNr
  )
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
  let hdr = UtpPacketHeader(
    packetType: StFin,
    version: UtpVersion,
    connectionId: sock.sendConnectionId,
    timestamp: nowMicros(),
    windowSize: sock.maxWindow.uint32,
    seqNr: sock.seqNr,
    ackNr: sock.ackNr
  )
  sock.seqNr += 1
  sock.state = usFinSent
  return encodeHeader(hdr)

proc makeResetPacket*(sock: UtpSocket): string =
  ## Create a RESET packet.
  let hdr = UtpPacketHeader(
    packetType: StReset,
    version: UtpVersion,
    connectionId: sock.sendConnectionId,
    timestamp: nowMicros(),
    seqNr: sock.seqNr,
    ackNr: sock.ackNr
  )
  sock.state = usReset
  return encodeHeader(hdr)

proc processAck(sock: UtpSocket, ackNr: uint16, timestampDiff: uint32) =
  ## Process an ACK - remove ack'd packets from outBuffer and update RTT.
  while sock.outBuffer.len > 0:
    let front = sock.outBuffer.peekFirst()
    # Check if this packet is ack'd (handling wraparound)
    let diff = cast[int16](ackNr - front.seqNr)
    if diff >= 0:
      let acked = sock.outBuffer.popFirst()
      let rttSample = int((epochTime() - acked.sentAt) * 1_000_000)
      sock.curWindow -= (acked.data.len - UtpHeaderSize)
      sock.bytesAcked += (acked.data.len - UtpHeaderSize)

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
  if timestampDiff > 0:
    let delay = timestampDiff.int  # one-way delay in microseconds
    let offTarget = (DelayTarget - delay).float / DelayTarget.float
    let windowIncrease = offTarget * Gain * MaxPacketSize.float
    sock.maxWindow = max(MinPacketSize, sock.maxWindow + int(windowIncrease))

proc processIncoming*(sock: UtpSocket, data: string): tuple[
    response: string, payload: string, stateChanged: bool] =
  ## Process an incoming uTP packet.
  ## Returns: response packet to send (if any), extracted payload, whether state changed.
  let pkt = decodePacket(data)
  let hdr = pkt.header

  sock.lastRecvTime = epochTime()
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
      # SYN-ACK received
      sock.ackNr = hdr.seqNr - 1
      sock.state = usConnected
      sock.processAck(hdr.ackNr, hdr.timestampDiff)
      result.stateChanged = true
    elif hdr.packetType == StSyn:
      # Simultaneous open (BEP 55 holepunch race): both sides sent SYN.
      # Accept the remote SYN and transition to connected.
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
      elif cast[int16](hdr.seqNr - expectedSeq) > 0:
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
      sock.processAck(hdr.ackNr, hdr.timestampDiff)

    of StState:
      # ACK only
      sock.processAck(hdr.ackNr, hdr.timestampDiff)

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
      sock.processAck(hdr.ackNr, hdr.timestampDiff)
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
  ## Uses sentAt to prevent premature re-retransmission: after each retransmit,
  ## sentAt is updated to now, so the packet must wait another full RTO before
  ## being eligible again. This allows multiple retransmission attempts until
  ## MaxRetransmit is reached, unlike the previous needsResend guard which
  ## permanently blocked re-retransmission after the first attempt.
  let now = epochTime()
  let timeoutSec = sock.rto.float / 1000.0
  let maxRetx = if sock.maxRetransmit > 0: sock.maxRetransmit else: MaxRetransmit

  for pkt in sock.outBuffer.mitems:
    if now - pkt.sentAt > timeoutSec:
      pkt.retransmits += 1
      if pkt.retransmits > maxRetx:
        sock.state = usReset
        return @[]
      pkt.sentAt = now
      result.add(pkt.data)
      # Halve the window on timeout (congestion response)
      sock.maxWindow = max(MinPacketSize, sock.maxWindow div 2)
