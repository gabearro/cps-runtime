## BitTorrent peer wire protocol (BEP 3).
##
## Handles message framing, handshake, and message types.

import utils

const
  ProtocolString* = "BitTorrent protocol"
  HandshakeLength* = 68  # 1 + 19 + 8 + 20 + 20

type
  MessageId* = enum
    msgChoke = 0
    msgUnchoke = 1
    msgInterested = 2
    msgNotInterested = 3
    msgHave = 4
    msgBitfield = 5
    msgRequest = 6
    msgPiece = 7
    msgCancel = 8
    msgPort = 9              # DHT port (BEP 5)
    msgSuggestPiece = 13     # BEP 6: Fast Extension
    msgHaveAll = 14          # BEP 6: Fast Extension
    msgHaveNone = 15         # BEP 6: Fast Extension
    msgRejectRequest = 16    # BEP 6: Fast Extension
    msgAllowedFast = 17      # BEP 6: Fast Extension
    msgExtended = 20         # Extension protocol (BEP 10)

  PeerMessage* = object
    case id*: MessageId
    of msgChoke, msgUnchoke, msgInterested, msgNotInterested:
      discard
    of msgHave:
      pieceIndex*: uint32
    of msgBitfield:
      bitfield*: seq[byte]
    of msgRequest, msgCancel, msgRejectRequest:
      reqIndex*: uint32
      reqBegin*: uint32
      reqLength*: uint32
    of msgPiece:
      blockIndex*: uint32
      blockBegin*: uint32
      blockData*: string
    of msgPort:
      dhtPort*: uint16
    of msgSuggestPiece, msgAllowedFast:
      fastPieceIndex*: uint32
    of msgHaveAll, msgHaveNone:
      discard
    of msgExtended:
      extId*: uint8
      extPayload*: string

  Handshake* = object
    infoHash*: array[20, byte]
    peerId*: array[20, byte]
    reserved*: array[8, byte]

# Handshake encoding/decoding
proc encodeHandshake*(infoHash: array[20, byte], peerId: array[20, byte],
                      supportExtensions: bool = true): string =
  ## Encode a BitTorrent handshake message.
  result = newStringOfCap(HandshakeLength)
  result.add(char(19))  # pstrlen
  result.add(ProtocolString)
  var reserved: array[8, byte]
  if supportExtensions:
    reserved[5] = 0x10  # BEP 10 extension protocol
  reserved[7] = 0x04    # BEP 6 fast extension
  let pos = result.len
  result.setLen(pos + 48)  # 8 + 20 + 20
  copyMem(addr result[pos], unsafeAddr reserved[0], 8)
  copyMem(addr result[pos + 8], unsafeAddr infoHash[0], 20)
  copyMem(addr result[pos + 28], unsafeAddr peerId[0], 20)

proc decodeHandshake*(data: string): Handshake =
  ## Decode a BitTorrent handshake message.
  if data.len < HandshakeLength:
    raise newException(ValueError, "handshake too short: " & $data.len)
  let pstrlen = data[0].byte
  if pstrlen != 19:
    raise newException(ValueError, "invalid pstrlen: " & $pstrlen)
  let pstr = data[1..19]
  if pstr != ProtocolString:
    raise newException(ValueError, "invalid protocol string: " & pstr)
  copyMem(addr result.reserved[0], unsafeAddr data[20], 8)
  copyMem(addr result.infoHash[0], unsafeAddr data[28], 20)
  copyMem(addr result.peerId[0], unsafeAddr data[48], 20)

proc supportsExtensions*(h: Handshake): bool =
  ## Check if peer supports BEP 10 extension protocol.
  (h.reserved[5] and 0x10) != 0

# Message encoding
proc encodeMessage*(msg: PeerMessage): string =
  ## Encode a peer message with 4-byte length prefix. Single allocation.
  let payloadLen = case msg.id
    of msgChoke, msgUnchoke, msgInterested, msgNotInterested,
       msgHaveAll, msgHaveNone: 1
    of msgHave, msgSuggestPiece, msgAllowedFast: 5
    of msgBitfield: 1 + msg.bitfield.len
    of msgRequest, msgCancel, msgRejectRequest: 13
    of msgPiece: 9 + msg.blockData.len
    of msgPort: 3
    of msgExtended: 2 + msg.extPayload.len
  result = newStringOfCap(4 + payloadLen)
  result.writeUint32BE(uint32(payloadLen))
  result.add(char(msg.id.byte))
  case msg.id
  of msgChoke, msgUnchoke, msgInterested, msgNotInterested,
     msgHaveAll, msgHaveNone:
    discard
  of msgHave:
    result.writeUint32BE(msg.pieceIndex)
  of msgBitfield:
    if msg.bitfield.len > 0:
      let pos = result.len
      result.setLen(pos + msg.bitfield.len)
      copyMem(addr result[pos], unsafeAddr msg.bitfield[0], msg.bitfield.len)
  of msgRequest, msgCancel, msgRejectRequest:
    result.writeUint32BE(msg.reqIndex)
    result.writeUint32BE(msg.reqBegin)
    result.writeUint32BE(msg.reqLength)
  of msgPiece:
    result.writeUint32BE(msg.blockIndex)
    result.writeUint32BE(msg.blockBegin)
    result.add(msg.blockData)
  of msgPort:
    result.writeUint16BE(msg.dhtPort)
  of msgSuggestPiece, msgAllowedFast:
    result.writeUint32BE(msg.fastPieceIndex)
  of msgExtended:
    result.add(char(msg.extId))
    result.add(msg.extPayload)

proc encodeKeepAlive*(): string =
  ## Encode a keep-alive message (4 zero bytes).
  result = newStringOfCap(4)
  result.writeUint32BE(0)

proc decodeMessage*(data: string): PeerMessage =
  ## Decode a peer message from its payload (without length prefix).
  if data.len == 0:
    raise newException(ValueError, "empty message payload")

  let id = data[0].byte
  case id
  of msgChoke.byte:
    result = PeerMessage(id: msgChoke)
  of msgUnchoke.byte:
    result = PeerMessage(id: msgUnchoke)
  of msgInterested.byte:
    result = PeerMessage(id: msgInterested)
  of msgNotInterested.byte:
    result = PeerMessage(id: msgNotInterested)
  of msgHave.byte:
    if data.len < 5:
      raise newException(ValueError, "have message too short")
    result = PeerMessage(id: msgHave, pieceIndex: readUint32BE(data, 1))
  of msgBitfield.byte:
    var bf = newSeq[byte](data.len - 1)
    if bf.len > 0:
      copyMem(addr bf[0], unsafeAddr data[1], bf.len)
    result = PeerMessage(id: msgBitfield, bitfield: bf)
  of msgRequest.byte:
    if data.len < 13:
      raise newException(ValueError, "request message too short")
    result = PeerMessage(id: msgRequest,
      reqIndex: readUint32BE(data, 1),
      reqBegin: readUint32BE(data, 5),
      reqLength: readUint32BE(data, 9))
  of msgPiece.byte:
    if data.len < 9:
      raise newException(ValueError, "piece message too short")
    result = PeerMessage(id: msgPiece,
      blockIndex: readUint32BE(data, 1),
      blockBegin: readUint32BE(data, 5),
      blockData: data[9..^1])
  of msgCancel.byte:
    if data.len < 13:
      raise newException(ValueError, "cancel message too short")
    result = PeerMessage(id: msgCancel,
      reqIndex: readUint32BE(data, 1),
      reqBegin: readUint32BE(data, 5),
      reqLength: readUint32BE(data, 9))
  of msgPort.byte:
    if data.len < 3:
      raise newException(ValueError, "port message too short")
    result = PeerMessage(id: msgPort, dhtPort: readUint16BE(data, 1))
  of msgExtended.byte:
    if data.len < 2:
      raise newException(ValueError, "extended message too short")
    result = PeerMessage(id: msgExtended,
      extId: data[1].byte,
      extPayload: if data.len > 2: data[2..^1] else: "")
  of msgSuggestPiece.byte:
    if data.len < 5:
      raise newException(ValueError, "suggest piece message too short")
    result = PeerMessage(id: msgSuggestPiece, fastPieceIndex: readUint32BE(data, 1))
  of msgHaveAll.byte:
    result = PeerMessage(id: msgHaveAll)
  of msgHaveNone.byte:
    result = PeerMessage(id: msgHaveNone)
  of msgRejectRequest.byte:
    if data.len < 13:
      raise newException(ValueError, "reject request message too short")
    result = PeerMessage(id: msgRejectRequest,
      reqIndex: readUint32BE(data, 1),
      reqBegin: readUint32BE(data, 5),
      reqLength: readUint32BE(data, 9))
  of msgAllowedFast.byte:
    if data.len < 5:
      raise newException(ValueError, "allowed fast message too short")
    result = PeerMessage(id: msgAllowedFast, fastPieceIndex: readUint32BE(data, 1))
  else:
    raise newException(ValueError, "unknown message id: " & $id)

# Bitfield helpers
proc hasPiece*(bitfield: seq[byte], index: int): bool =
  let byteIdx = index shr 3
  let mask = 1'u8 shl (7 - (index and 7))
  byteIdx < bitfield.len and (bitfield[byteIdx] and mask) != 0

proc setPiece*(bitfield: var seq[byte], index: int) =
  let byteIdx = index shr 3
  if byteIdx < bitfield.len:
    bitfield[byteIdx] = bitfield[byteIdx] or (1'u8 shl (7 - (index and 7)))

proc clearPiece*(bitfield: var seq[byte], index: int) =
  let byteIdx = index shr 3
  if byteIdx < bitfield.len:
    bitfield[byteIdx] = bitfield[byteIdx] and not (1'u8 shl (7 - (index and 7)))

proc newBitfield*(numPieces: int): seq[byte] =
  newSeq[byte]((numPieces + 7) shr 3)

proc countPieces*(bitfield: seq[byte], total: int): int =
  countBitsSet(bitfield, total)

# Convenience constructors
proc chokeMsg*(): PeerMessage = PeerMessage(id: msgChoke)
proc unchokeMsg*(): PeerMessage = PeerMessage(id: msgUnchoke)
proc interestedMsg*(): PeerMessage = PeerMessage(id: msgInterested)
proc notInterestedMsg*(): PeerMessage = PeerMessage(id: msgNotInterested)

proc haveMsg*(index: uint32): PeerMessage =
  PeerMessage(id: msgHave, pieceIndex: index)

proc bitfieldMsg*(bf: seq[byte]): PeerMessage =
  PeerMessage(id: msgBitfield, bitfield: bf)

proc requestMsg*(index, begin, length: uint32): PeerMessage =
  PeerMessage(id: msgRequest, reqIndex: index, reqBegin: begin, reqLength: length)

proc cancelMsg*(index, begin, length: uint32): PeerMessage =
  PeerMessage(id: msgCancel, reqIndex: index, reqBegin: begin, reqLength: length)

proc pieceMsg*(index, begin: uint32, data: string): PeerMessage =
  PeerMessage(id: msgPiece, blockIndex: index, blockBegin: begin, blockData: data)

proc suggestPieceMsg*(index: uint32): PeerMessage =
  PeerMessage(id: msgSuggestPiece, fastPieceIndex: index)

proc haveAllMsg*(): PeerMessage = PeerMessage(id: msgHaveAll)
proc haveNoneMsg*(): PeerMessage = PeerMessage(id: msgHaveNone)

proc rejectRequestMsg*(index, begin, length: uint32): PeerMessage =
  PeerMessage(id: msgRejectRequest, reqIndex: index, reqBegin: begin, reqLength: length)

proc allowedFastMsg*(index: uint32): PeerMessage =
  PeerMessage(id: msgAllowedFast, fastPieceIndex: index)

proc portMsg*(port: uint16): PeerMessage =
  PeerMessage(id: msgPort, dhtPort: port)

proc extendedMsg*(extId: uint8, payload: string): PeerMessage =
  PeerMessage(id: msgExtended, extId: extId, extPayload: payload)
