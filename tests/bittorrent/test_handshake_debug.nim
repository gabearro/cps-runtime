## Quick test: connect to a peer and handshake
import std/[os, strutils]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/tcp
import cps/io/buffered
import cps/io/streams
import cps/io/timeouts
import cps/bittorrent/metainfo
import cps/bittorrent/peer_protocol

proc testHandshake(ip: string, port: int, infoHash: array[20, byte]): CpsVoidFuture {.cps.} =
  echo "Connecting to " & ip & ":" & $port
  try:
    let stream = await withTimeout(tcpConnect(ip, port), 5000)
    echo "  TCP connected"
    
    var peerId: array[20, byte]
    let prefix = "-NC0100-test12345678"
    copyMem(addr peerId[0], unsafeAddr prefix[0], 20)
    
    let hsData = encodeHandshake(infoHash, peerId)
    echo "  Sending handshake (" & $hsData.len & " bytes)"
    echo "  First bytes: " & $hsData[0].byte & " " & hsData[1..19]
    
    # Print info hash we're sending
    var ihHex = ""
    for i in 28 ..< 48:
      ihHex.add(hsData[i].byte.int.toHex(2).toLowerAscii)
    echo "  Info hash in handshake: " & ihHex
    
    await stream.write(hsData)
    echo "  Handshake sent, waiting for response..."
    
    let reader = newBufferedReader(stream.AsyncStream, 65536)
    let respData = await reader.readExact(HandshakeLength)
    echo "  Got response: " & $respData.len & " bytes"
    
    let hs = decodeHandshake(respData)
    
    var remoteIhHex = ""
    for b in hs.infoHash:
      remoteIhHex.add(b.int.toHex(2).toLowerAscii)
    echo "  Remote info hash: " & remoteIhHex
    echo "  Match: " & $(hs.infoHash == infoHash)
    echo "  Extensions: " & $hs.supportsExtensions
    
    var pidStr = ""
    for b in hs.peerId:
      if b >= 0x20 and b <= 0x7E:
        pidStr.add(char(b))
      else:
        pidStr.add(".")
    echo "  Peer ID: " & pidStr
    
    stream.close()
    echo "PASS: handshake succeeded"
  except CatchableError as e:
    echo "  FAIL: " & e.msg

proc main(): CpsVoidFuture {.cps.} =
  let torrentData = readFile("/Users/gabriel/Downloads/linuxmint-22.3-cinnamon-64bit.iso.torrent")
  let meta = parseTorrent(torrentData)
  echo "Info hash: " & meta.info.infoHashHex()
  
  # Try peers that Python confirmed work
  let peers = @[
    ("172.105.8.23", 6888),
    ("50.46.13.238", 6881),
    ("198.44.129.195", 61934),
    ("97.80.120.89", 52438),
    ("80.89.223.202", 16881),
    ("88.192.121.72", 60000),
  ]
  
  var pi: int = 0
  while pi < peers.len:
    await testHandshake(peers[pi][0], peers[pi][1], meta.info.infoHash)
    echo ""
    pi += 1

block:
  let fut = main()
  let loop = getEventLoop()
  var ticks = 0
  while not fut.finished and ticks < 500000:
    loop.tick()
    ticks += 1
