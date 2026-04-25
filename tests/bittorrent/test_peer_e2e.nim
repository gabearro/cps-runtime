## End-to-end test for BitTorrent peer wire protocol.
##
## Sets up a mock seeder and a downloading peer, transfers a piece.

import std/[nativesockets, net]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/concurrency/channels
import cps/bittorrent/peer_protocol
import cps/bittorrent/utils
import cps/bittorrent/metainfo
import cps/bittorrent/pieces
import cps/bittorrent/sha1
import cps/bittorrent/peer

proc getListenerPort(listener: TcpListener): uint16 =
  getSockName(listener.fd).uint16

# Test data: create a small "torrent" with 2 pieces of 32KB each
const PieceLen = 32768
const TotalLen = PieceLen * 2

proc makeTestData(): string =
  result = newString(TotalLen)
  for i in 0 ..< TotalLen:
    result[i] = char(i mod 256)

proc makeTestInfo(data: string): TorrentInfo =
  result.pieceLength = PieceLen
  result.totalLength = TotalLen
  result.name = "test"
  result.files = @[FileEntry(path: "test", length: TotalLen)]
  var piecesStr = ""
  for p in 0 ..< 2:
    let start = p * PieceLen
    let hash = sha1(data[start ..< start + PieceLen])
    for b in hash:
      piecesStr.add(char(b))
  result.pieces = piecesStr
  result.infoHash = sha1(piecesStr)  # simplified info hash for test

# Mock seeder: accepts a connection, does handshake, sends bitfield, unchokes, serves blocks
proc mockSeeder(listener: TcpListener, infoHash: array[20, byte],
                seederId: array[20, byte], testData: string): CpsVoidFuture {.cps.} =
  let stream = await listener.accept()
  let reader = newBufferedReader(stream.AsyncStream, 65536)

  # Read client's handshake
  let hsData = await reader.readExact(HandshakeLength)
  let hs = decodeHandshake(hsData)
  assert hs.infoHash == infoHash

  # Send our handshake
  let ourHs = encodeHandshake(infoHash, seederId)
  await stream.write(ourHs)

  # Send bitfield (we have all pieces)
  var bf = newBitfield(2)
  setPiece(bf, 0)
  setPiece(bf, 1)
  let bfMsg = encodeMessage(bitfieldMsg(bf))
  await stream.write(bfMsg)

  # Send unchoke
  let unchokeData = encodeMessage(unchokeMsg())
  await stream.write(unchokeData)

  # Read messages and serve requests
  var servedBlocks = 0
  while servedBlocks < 4:  # 2 pieces * 2 blocks each
    let lenData = await reader.readExact(4)
    let msgLen = readUint32BE(lenData, 0)
    if msgLen == 0:
      continue  # keep-alive

    let payload = await reader.readExact(msgLen.int)
    let msg = decodeMessage(payload)

    case msg.id
    of msgInterested:
      discard  # Already unchoked
    of msgRequest:
      # Serve the requested block
      let pieceStart: int = msg.reqIndex.int * PieceLen
      let blockStart: int = pieceStart + msg.reqBegin.int
      let blockLen: int = msg.reqLength.int
      var blockData: string = newString(blockLen)
      copyMem(addr blockData[0], unsafeAddr testData[blockStart], blockLen)
      let reqIdx: uint32 = msg.reqIndex
      let reqBeg: uint32 = msg.reqBegin
      let respMsg: PeerMessage = pieceMsg(reqIdx, reqBeg, blockData)
      let resp: string = encodeMessage(respMsg)
      await stream.write(resp)
      servedBlocks += 1
    of msgBitfield:
      discard  # Client's bitfield
    else:
      discard

  # Wait a bit then close
  await cpsSleep(100)
  stream.close()

# Test: peer connects, downloads, and we verify piece data
block testPeerDownload:
  let testData = makeTestData()
  let info = makeTestInfo(testData)

  var seederId: array[20, byte]
  for i in 0 ..< 20:
    seederId[i] = byte(0xAA)

  var clientId: array[20, byte]
  for i in 0 ..< 20:
    clientId[i] = byte(0xBB)

  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  # Channel for peer events
  let events = newAsyncChannel[PeerEvent](64)

  # Spawn mock seeder
  discard mockSeeder(listener, info.infoHash, seederId, testData)

  # Create piece manager
  let pm = newPieceManager(info)

  # Create peer connection
  let peer = newPeerConn("127.0.0.1", port.uint16, info.infoHash, clientId, events)

  # Spawn peer connection
  discard run(peer)

  # Run the event loop and process events
  proc processEvents(pm: PieceManager, events: AsyncChannel[PeerEvent],
                     peer: PeerConn, info: TorrentInfo): CpsVoidFuture {.cps.} =
    var handshakeReceived = false
    var bitfieldReceived = false
    var unchokeReceived = false
    var piecesDone = 0
    var requestSent = false

    while piecesDone < 2:
      let evt = await events.recv()

      case evt.kind
      of pekConnected:
        discard

      of pekHandshake:
        handshakeReceived = true
        # Send our (empty) bitfield
        let bf = pm.generateBitfield()
        await peer.sendBitfield(bf)

      of pekBitfield:
        bitfieldReceived = true

      of pekUnchoke:
        unchokeReceived = true
        # Start requesting blocks
        for pieceIdx in 0 ..< 2:
          let blocks = pm.getNeededBlocks(pieceIdx)
          for blk in blocks:
            pm.markBlockRequested(pieceIdx, blk.offset)
            await peer.sendRequest(uint32(pieceIdx), uint32(blk.offset), uint32(blk.length))

      of pekBlock:
        let complete = pm.receiveBlock(evt.blockIndex.int, evt.blockBegin.int, evt.blockData)
        if complete:
          let valid = pm.verifyPiece(evt.blockIndex.int)
          assert valid, "piece " & $evt.blockIndex & " verification failed"
          piecesDone += 1

      of pekDisconnected:
        break

      of pekError:
        echo "Error: " & evt.errMsg
        break

      else:
        discard

    assert handshakeReceived, "did not receive handshake"
    assert bitfieldReceived, "did not receive bitfield"
    assert unchokeReceived, "did not receive unchoke"
    assert piecesDone == 2, "expected 2 pieces, got " & $piecesDone
    assert pm.isComplete, "piece manager should be complete"

  let processFut = processEvents(pm, events, peer, info)

  # Drive event loop
  let loop = getEventLoop()
  var elapsed = 0
  while not processFut.finished and elapsed < 10000:
    loop.tick()
    elapsed += 1

  if processFut.hasError:
    raise processFut.getError()

  assert processFut.finished, "event processing didn't complete in time"

  # Verify piece data matches
  for i in 0 ..< 2:
    let expected = testData[i * PieceLen ..< (i + 1) * PieceLen]
    let actual = pm.getPieceData(i)
    assert actual == expected, "piece " & $i & " data mismatch"

  listener.close()
  echo "PASS: peer download e2e"

echo "ALL PEER E2E TESTS PASSED"
