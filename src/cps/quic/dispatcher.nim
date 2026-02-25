## QUIC UDP dispatcher.

import std/[tables, strutils, os]
import std/nativesockets
import ../private/platform
import ../runtime
import ../io/udp

type
  QuicConnectionDirectory* = ref object
    byDcid*: Table[string, string]
    byPath*: Table[string, string]

  QuicDatagramHandler* = proc(data: seq[byte], address: string, port: int): CpsVoidFuture {.closure.}

  QuicDispatcher* = ref object
    socket*: UdpSocket
    maxDatagramSize*: int
    running*: bool
    onDatagram*: QuicDatagramHandler

proc pathKey(address: string, port: int): string {.inline.} =
  address.toLowerAscii & ":" & $port

proc newQuicConnectionDirectory*(): QuicConnectionDirectory =
  QuicConnectionDirectory(
    byDcid: initTable[string, string](),
    byPath: initTable[string, string]()
  )

proc register*(dir: QuicConnectionDirectory,
               dcidHex: string,
               address: string,
               port: int) =
  if dir.isNil or dcidHex.len == 0:
    return
  dir.byDcid[dcidHex] = dcidHex
  dir.byPath[pathKey(address, port)] = dcidHex

proc retire*(dir: QuicConnectionDirectory, dcidHex: string) =
  if dir.isNil or dcidHex.len == 0:
    return
  if dcidHex in dir.byDcid:
    dir.byDcid.del(dcidHex)
  var drop: seq[string] = @[]
  for key, cid in dir.byPath:
    if cid == dcidHex:
      drop.add key
  for key in drop:
    dir.byPath.del(key)

proc updatePath*(dir: QuicConnectionDirectory,
                 dcidHex: string,
                 address: string,
                 port: int) =
  if dir.isNil or dcidHex.len == 0:
    return
  dir.byPath[pathKey(address, port)] = dcidHex

proc lookupByDcid*(dir: QuicConnectionDirectory, dcidHex: string): string =
  if dir.isNil or dcidHex.len == 0:
    return ""
  if dcidHex in dir.byDcid:
    return dir.byDcid[dcidHex]
  ""

proc lookupByPath*(dir: QuicConnectionDirectory, address: string, port: int): string =
  if dir.isNil:
    return ""
  let key = pathKey(address, port)
  if key in dir.byPath:
    return dir.byPath[key]
  ""

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i in 0 ..< data.len:
    result[i] = char(data[i])

proc stringToBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(ord(s[i]) and 0xFF)

proc newQuicDispatcher*(bindHost: string,
                        bindPort: int,
                        onDatagram: QuicDatagramHandler,
                        maxDatagramSize: int = 2048,
                        domain: Domain = AF_INET): QuicDispatcher =
  let sock = newUdpSocket(domain)
  sock.bindAddr(bindHost, bindPort)
  QuicDispatcher(
    socket: sock,
    maxDatagramSize: maxDatagramSize,
    running: false,
    onDatagram: onDatagram
  )

proc start*(d: QuicDispatcher) =
  if d.running:
    return
  d.running = true
  d.socket.onRecv(d.maxDatagramSize, proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
    if not d.running:
      return
    if d.onDatagram.isNil:
      return
    var raw = RawDatagram(data: data, srcAddr: srcAddr, addrLen: addrLen)
    let (host, port) = parseSenderAddress(raw)
    let fut = d.onDatagram(stringToBytes(data), host, port)
    if existsEnv("CPS_QUIC_DEBUG") and not fut.isNil:
      fut.addCallback(proc() =
        if fut.hasError():
          let err = fut.getError()
          if err.isNil:
            echo "[cps-quic] onDatagram error: <unknown>"
          else:
            echo "[cps-quic] onDatagram error: " & err.msg
      )
    discard fut
  )

proc stop*(d: QuicDispatcher, closeSocket: bool = false) =
  if not d.running:
    if closeSocket and not d.socket.closed:
      d.socket.close()
    return
  d.running = false
  d.socket.cancelOnRecv()
  if closeSocket and not d.socket.closed:
    d.socket.close()

proc sendDatagram*(d: QuicDispatcher, data: openArray[byte], address: string, port: int): CpsVoidFuture =
  d.socket.sendTo(bytesToString(data), address, port)
