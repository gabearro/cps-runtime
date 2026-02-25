## WebSocket Protocol (RFC 6455) - Shared Types and Codec
##
## Types, frame codec, handshake helpers, and message-level API shared by
## both client and server WebSocket implementations.

import std/[strutils, sysrand, base64, atomics, unicode]
import checksums/sha1
import ../../runtime
import ../../transform
import ../../io/streams
import ../../io/buffered
import ./compression

# ============================================================
# Constants
# ============================================================

const
  WsMagicGuid* = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  WsVersion* = "13"

# ============================================================
# Types
# ============================================================

type
  WsOpcode* = enum
    opContinuation = 0x0
    opText = 0x1
    opBinary = 0x2
    # 0x3-0x7 reserved
    opClose = 0x8
    opPing = 0x9
    opPong = 0xA

  WsFrame* = object
    fin*: bool
    rsv1*: bool
    opcode*: WsOpcode
    masked*: bool
    maskKey*: array[4, byte]
    payload*: string

  WsMessage* = object
    kind*: WsOpcode       ## opText, opBinary, or opClose
    data*: string
    closeCode*: uint16    ## Only meaningful for opClose

  WsState* = enum
    wsOpen, wsClosing, wsClosed

  WebSocket* = ref object
    stream*: AsyncStream
    reader*: BufferedReader
    stateVal: Atomic[int]
    isMasked*: bool       ## true for client (masks outgoing frames)
    requireMaskedIncoming*: bool ## true on server receive path (clients must mask)
    maxFrameBytes*: int
    maxMessageBytes*: int
    compressEnabled*: bool     ## permessage-deflate negotiated
    clientNoContextTakeover*: bool
    serverNoContextTakeover*: bool

  WsError* = object of CatchableError
  WsProtocolError* = object of WsError
    closeCode*: uint16

proc newWsProtocolError*(code: uint16, msg: string): ref WsProtocolError =
  let err = newException(WsProtocolError, msg)
  err.closeCode = code
  err

proc isControlOpcode(opcode: WsOpcode): bool {.inline.} =
  opcode in {opClose, opPing, opPong}

proc isValidCloseCode(code: uint16): bool {.inline.} =
  ## RFC 6455: wire close codes are 1000-4999 excluding reserved values.
  if code < 1000'u16 or code >= 5000'u16:
    return false
  code notin [1004'u16, 1005'u16, 1006'u16, 1015'u16]

proc getState*(ws: WebSocket): WsState {.inline.} =
  ## Get the current WebSocket state. Thread-safe via atomic load.
  WsState(ws.stateVal.load(moAcquire))

proc setState*(ws: WebSocket, newState: WsState) {.inline.} =
  ## Set the WebSocket state. Thread-safe via atomic store.
  ws.stateVal.store(newState.int, moRelease)

proc initWsMtFields*(ws: WebSocket) =
  ## Initialize state. Atomic[int] zero-initializes to wsOpen (0).
  discard

# ============================================================
# Handshake helpers
# ============================================================

proc computeAcceptKey*(clientKey: string): string =
  ## Compute Sec-WebSocket-Accept from client's Sec-WebSocket-Key.
  ## SHA-1 hash of (key + GUID), then base64-encode the raw 20-byte digest.
  let hash = secureHash(clientKey & WsMagicGuid)
  let digest = Sha1Digest(hash)
  var raw = newString(20)
  for i in 0 ..< 20:
    raw[i] = char(digest[i])
  result = base64.encode(raw)

proc parseWsExtensions*(header: string): tuple[enabled: bool, serverNoCtx: bool, clientNoCtx: bool] =
  ## Parse Sec-WebSocket-Extensions header for permessage-deflate.
  result = (false, false, false)
  for ext in header.split(','):
    let trimmed = ext.strip()
    if trimmed.len == 0:
      continue
    let parts = trimmed.split(';')
    if parts.len == 0:
      continue
    let extName = parts[0].strip().toLowerAscii
    if extName == "permessage-deflate":
      result.enabled = true
      for i in 1 ..< parts.len:
        let p = parts[i].strip().toLowerAscii
        if p == "server_no_context_takeover":
          result.serverNoCtx = true
        elif p == "client_no_context_takeover":
          result.clientNoCtx = true
      break

# ============================================================
# Frame Codec
# ============================================================

proc recvFrame*(ws: WebSocket): CpsFuture[WsFrame] {.cps.} =
  ## Read a single WebSocket frame from the connection.
  let frameHdr = await ws.reader.readExact(2)

  let b0 = frameHdr[0].byte
  let b1 = frameHdr[1].byte

  var frame: WsFrame
  frame.fin = (b0 and 0x80'u8) != 0
  frame.rsv1 = (b0 and 0x40'u8) != 0

  let rsv2Set = (b0 and 0x20'u8) != 0
  let rsv3Set = (b0 and 0x10'u8) != 0
  if rsv2Set or rsv3Set:
    raise newWsProtocolError(1002'u16, "RSV2/RSV3 set without negotiation")

  let opcodeVal = b0 and 0x0F'u8
  case opcodeVal
  of 0'u8: frame.opcode = opContinuation
  of 1'u8: frame.opcode = opText
  of 2'u8: frame.opcode = opBinary
  of 8'u8: frame.opcode = opClose
  of 9'u8: frame.opcode = opPing
  of 10'u8: frame.opcode = opPong
  else:
    raise newWsProtocolError(1002'u16, "Invalid WebSocket opcode: " & $opcodeVal)

  if frame.rsv1 and not ws.compressEnabled:
    raise newWsProtocolError(1002'u16, "RSV1 set without permessage-deflate")

  frame.masked = (b1 and 0x80'u8) != 0

  if ws.requireMaskedIncoming and not frame.masked:
    raise newWsProtocolError(1002'u16, "Client frames must be masked")
  if not ws.requireMaskedIncoming and frame.masked:
    raise newWsProtocolError(1002'u16, "Server frames must not be masked")

  var payloadLen = (b1 and 0x7F'u8).uint64

  if payloadLen == 126:
    let extLen = await ws.reader.readExact(2)
    payloadLen = (extLen[0].byte.uint64 shl 8) or extLen[1].byte.uint64
    if payloadLen < 126'u64:
      raise newWsProtocolError(1002'u16, "Non-minimal payload length encoding")
  elif payloadLen == 127:
    let extLen = await ws.reader.readExact(8)
    if (extLen[0].byte and 0x80'u8) != 0'u8:
      raise newWsProtocolError(1002'u16, "Invalid 64-bit payload length")
    payloadLen = 0'u64
    for i in 0 ..< 8:
      payloadLen = (payloadLen shl 8) or extLen[i].byte.uint64
    if payloadLen <= 0xFFFF'u64:
      raise newWsProtocolError(1002'u16, "Non-minimal payload length encoding")

  if ws.maxFrameBytes > 0 and payloadLen > ws.maxFrameBytes.uint64:
    raise newWsProtocolError(1009'u16, "WebSocket frame exceeds configured max size")

  if frame.masked:
    let maskData = await ws.reader.readExact(4)
    for i in 0 ..< 4:
      frame.maskKey[i] = maskData[i].byte

  if payloadLen > 0:
    let data = await ws.reader.readExact(payloadLen.int)
    if frame.masked:
      var unmasked = newString(data.len)
      for i in 0 ..< data.len:
        unmasked[i] = char(data[i].byte xor frame.maskKey[i mod 4])
      frame.payload = unmasked
    else:
      frame.payload = data
  else:
    frame.payload = ""

  return frame

proc sendFrame*(ws: WebSocket, opcode: WsOpcode, payload: string,
                fin: bool = true): CpsVoidFuture =
  ## Send a single WebSocket frame. Non-CPS (single write).
  let state = ws.getState()
  if state == wsClosed:
    let fut = newCpsVoidFuture()
    fut.fail(newException(WsError, "WebSocket is closed"))
    return fut
  if state == wsClosing and opcode notin {opClose, opPong}:
    let fut = newCpsVoidFuture()
    fut.fail(newException(WsError, "WebSocket is closing"))
    return fut

  if isControlOpcode(opcode):
    if not fin:
      let fut = newCpsVoidFuture()
      fut.fail(newWsProtocolError(1002'u16, "Control frames must not be fragmented"))
      return fut
    if payload.len > 125:
      let fut = newCpsVoidFuture()
      fut.fail(newWsProtocolError(1002'u16, "Control frame payload exceeds 125 bytes"))
      return fut

  var frame: seq[byte]
  var actualPayload = payload
  var setRsv1 = false

  # Compress only single-frame data messages.
  # Fragmented sends are emitted uncompressed because this send path does not
  # track per-message deflate state across continuation frames.
  if ws.compressEnabled and fin and (opcode == opText or opcode == opBinary):
    actualPayload = rawDeflateCompress(payload)
    setRsv1 = true

  # Byte 0: FIN + RSV1 + opcode
  var b0 = (if fin: 0x80'u8 else: 0x00'u8) or opcode.uint8
  if setRsv1:
    b0 = b0 or 0x40'u8
  frame.add(b0)

  # Byte 1: MASK + payload length
  let maskBit = if ws.isMasked: 0x80'u8 else: 0x00'u8

  if actualPayload.len < 126:
    frame.add(maskBit or actualPayload.len.uint8)
  elif actualPayload.len <= 0xFFFF:
    frame.add(maskBit or 126'u8)
    frame.add(uint8(actualPayload.len shr 8))
    frame.add(uint8(actualPayload.len and 0xFF))
  else:
    frame.add(maskBit or 127'u8)
    for i in countdown(7, 0):
      frame.add(uint8((actualPayload.len shr (i * 8)) and 0xFF))

  if ws.isMasked:
    var maskKey: array[4, byte]
    let randomBytes = urandom(4)
    for i in 0 ..< 4:
      maskKey[i] = randomBytes[i]
    for i in 0 ..< 4:
      frame.add(maskKey[i])
    for i in 0 ..< actualPayload.len:
      frame.add(uint8(actualPayload[i].byte xor maskKey[i mod 4]))
  else:
    for i in 0 ..< actualPayload.len:
      frame.add(actualPayload[i].byte)

  var frameStr = newString(frame.len)
  for i in 0 ..< frame.len:
    frameStr[i] = char(frame[i])

  ws.stream.write(frameStr)

# ============================================================
# Message-Level API
# ============================================================

proc closeWithCode(ws: WebSocket, code: uint16): CpsVoidFuture {.cps.} =
  if ws.getState() == wsOpen:
    ws.setState(wsClosing)
    var payload = ""
    payload &= char(code shr 8)
    payload &= char(code and 0xFF)
    try:
      await ws.sendFrame(opClose, payload)
    except CatchableError:
      discard
  ws.setState(wsClosed)

proc recvMessage*(ws: WebSocket): CpsFuture[WsMessage] {.cps.} =
  ## Read a complete WebSocket message, handling fragmentation and control frames.
  ## Auto-responds to Ping with Pong. Returns WsMessage with kind opText/opBinary/opClose.
  ## Handles permessage-deflate decompression when RSV1 is set on the first frame.
  var msgOpcode: WsOpcode
  var msgData = ""
  var started = false
  var msgCompressed = false
  var pendingProtocolError: ref WsProtocolError = nil

  while true:
    var frame: WsFrame
    try:
      frame = await ws.recvFrame()
    except WsProtocolError as err:
      pendingProtocolError = err

    if pendingProtocolError != nil:
      let closeCode = if pendingProtocolError.closeCode != 0'u16:
        pendingProtocolError.closeCode
      else:
        1002'u16
      if ws.getState() == wsOpen:
        ws.setState(wsClosing)
        var payload = ""
        payload &= char(closeCode shr 8)
        payload &= char(closeCode and 0xFF)
        try:
          await ws.sendFrame(opClose, payload)
        except CatchableError:
          discard
      ws.setState(wsClosed)
      return WsMessage(kind: opClose, closeCode: closeCode, data: pendingProtocolError.msg)
    let op = frame.opcode

    if isControlOpcode(op):
      if not frame.fin:
        await closeWithCode(ws, 1002'u16)
        raise newWsProtocolError(1002'u16, "Control frames must not be fragmented")
      if frame.payload.len > 125:
        await closeWithCode(ws, 1002'u16)
        raise newWsProtocolError(1002'u16, "Control frame payload exceeds 125 bytes")
      if frame.rsv1:
        await closeWithCode(ws, 1002'u16)
        raise newWsProtocolError(1002'u16, "Control frames must not use RSV1")

    case op
    of opPing:
      # Auto-respond with Pong (control frames never compressed)
      await ws.sendFrame(opPong, frame.payload)
      continue
    of opPong:
      # Ignore unsolicited pongs
      continue
    of opClose:
      var closeCode: uint16 = 1005  # No status code
      var hasCloseCode = false
      var reason = ""
      if frame.payload.len == 1:
        await closeWithCode(ws, 1002'u16)
        raise newWsProtocolError(1002'u16, "Close frame payload length of 1 is invalid")
      if frame.payload.len >= 2:
        hasCloseCode = true
        closeCode = (frame.payload[0].byte.uint16 shl 8) or frame.payload[1].byte.uint16
        if not isValidCloseCode(closeCode):
          await closeWithCode(ws, 1002'u16)
          raise newWsProtocolError(1002'u16, "Invalid close code")
        if frame.payload.len > 2:
          reason = frame.payload[2 .. ^1]
          if validateUtf8(reason) >= 0:
            await closeWithCode(ws, 1007'u16)
            raise newWsProtocolError(1007'u16, "Close reason must be valid UTF-8")
      # Send close response if we haven't already
      if ws.getState() == wsOpen:
        ws.setState(wsClosing)
        var closePayload = ""
        if hasCloseCode:
          closePayload &= char(closeCode shr 8)
          closePayload &= char(closeCode and 0xFF)
        await ws.sendFrame(opClose, closePayload)
      ws.setState(wsClosed)
      return WsMessage(kind: opClose, closeCode: closeCode, data: reason)
    of opContinuation:
      if not started:
        await closeWithCode(ws, 1002'u16)
        raise newWsProtocolError(1002'u16, "Received continuation frame without initial frame")
      if frame.rsv1:
        await closeWithCode(ws, 1002'u16)
        raise newWsProtocolError(1002'u16, "Continuation frame must not set RSV1")
      if ws.maxMessageBytes > 0 and msgData.len + frame.payload.len > ws.maxMessageBytes:
        await closeWithCode(ws, 1009'u16)
        raise newWsProtocolError(1009'u16, "Message exceeds configured max size")
      msgData &= frame.payload
      if frame.fin:
        if msgCompressed and ws.compressEnabled:
          var decompressed = ""
          var decompressCode = 0'u16
          try:
            decompressed = rawDeflateDecompressLimited(msgData, ws.maxMessageBytes)
          except CompressionError as err:
            if "max size" in err.msg.toLowerAscii:
              decompressCode = 1009'u16
            else:
              decompressCode = 1002'u16
          except CatchableError:
            decompressCode = 1002'u16
          if decompressCode != 0'u16:
            await closeWithCode(ws, decompressCode)
            if decompressCode == 1009'u16:
              raise newWsProtocolError(1009'u16, "Message exceeds configured max size")
            raise newWsProtocolError(1002'u16, "Invalid compressed message payload")
          msgData = decompressed
        if msgOpcode == opText and validateUtf8(msgData) >= 0:
          await closeWithCode(ws, 1007'u16)
          raise newWsProtocolError(1007'u16, "Text message must be valid UTF-8")
        return WsMessage(kind: msgOpcode, data: msgData)
    of opText, opBinary:
      if started:
        await closeWithCode(ws, 1002'u16)
        raise newWsProtocolError(1002'u16, "Received new data frame while fragmented message in progress")
      msgOpcode = frame.opcode
      msgData = frame.payload
      msgCompressed = frame.rsv1
      if ws.maxMessageBytes > 0 and msgData.len > ws.maxMessageBytes:
        await closeWithCode(ws, 1009'u16)
        raise newWsProtocolError(1009'u16, "Message exceeds configured max size")
      started = true
      if frame.fin:
        if msgCompressed and ws.compressEnabled:
          var decompressed = ""
          var decompressCode = 0'u16
          try:
            decompressed = rawDeflateDecompressLimited(msgData, ws.maxMessageBytes)
          except CompressionError as err:
            if "max size" in err.msg.toLowerAscii:
              decompressCode = 1009'u16
            else:
              decompressCode = 1002'u16
          except CatchableError:
            decompressCode = 1002'u16
          if decompressCode != 0'u16:
            await closeWithCode(ws, decompressCode)
            if decompressCode == 1009'u16:
              raise newWsProtocolError(1009'u16, "Message exceeds configured max size")
            raise newWsProtocolError(1002'u16, "Invalid compressed message payload")
          msgData = decompressed
        if msgOpcode == opText and validateUtf8(msgData) >= 0:
          await closeWithCode(ws, 1007'u16)
          raise newWsProtocolError(1007'u16, "Text message must be valid UTF-8")
        return WsMessage(kind: msgOpcode, data: msgData)

# ============================================================
# Convenience send procs (non-CPS, return write future)
# ============================================================

proc sendText*(ws: WebSocket, data: string): CpsVoidFuture =
  ## Send a text message as a single frame.
  if validateUtf8(data) >= 0:
    let fut = newCpsVoidFuture()
    fut.fail(newWsProtocolError(1007'u16, "Text message must be valid UTF-8"))
    return fut
  ws.sendFrame(opText, data)

proc sendBinary*(ws: WebSocket, data: string): CpsVoidFuture =
  ## Send a binary message as a single frame.
  ws.sendFrame(opBinary, data)

proc sendPing*(ws: WebSocket, payload: string = ""): CpsVoidFuture =
  ## Send a Ping control frame.
  ws.sendFrame(opPing, payload)

proc sendPong*(ws: WebSocket, payload: string = ""): CpsVoidFuture =
  ## Send a Pong control frame.
  ws.sendFrame(opPong, payload)

proc sendClose*(ws: WebSocket, code: uint16 = 1000,
                reason: string = ""): CpsVoidFuture =
  ## Send a Close control frame.
  if not isValidCloseCode(code):
    let fut = newCpsVoidFuture()
    fut.fail(newWsProtocolError(1002'u16, "Invalid close code"))
    return fut
  if reason.len > 0 and validateUtf8(reason) >= 0:
    let fut = newCpsVoidFuture()
    fut.fail(newWsProtocolError(1007'u16, "Close reason must be valid UTF-8"))
    return fut
  if reason.len > 123:
    let fut = newCpsVoidFuture()
    fut.fail(newWsProtocolError(1002'u16, "Close reason exceeds 123-byte limit"))
    return fut
  ws.setState(wsClosing)
  var payload = ""
  payload &= char(code shr 8)
  payload &= char(code and 0xFF)
  payload &= reason
  ws.sendFrame(opClose, payload)

proc close*(ws: WebSocket) =
  ## Mark the WebSocket as closed. Does NOT close the underlying stream.
  ws.setState(wsClosed)
