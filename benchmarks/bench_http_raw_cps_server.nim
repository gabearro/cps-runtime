## Raw CPS TCP Server Benchmark
## Minimal "Hello, World!" server using raw CPS I/O (no HTTP parsing/routing).
## Same approach as httpleast: read until \r\n\r\n, write fixed response.
## Compile: nim c -d:danger benchmarks/bench_http_raw_cps_server.nim

import std/[nativesockets, net, os]
from std/posix import recv, send, INADDR_LOOPBACK, Sockaddr_storage, Sockaddr_in, SockLen, TSa_Family
import cps/runtime
import cps/transform
import cps/eventloop

const
  replyConst = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nContent-Type: text/plain\r\n\r\nHello, World!"

proc waitReadable(fd: SocketHandle): CpsVoidFuture =
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  loop.registerRead(fd, proc() =
    loop.unregister(fd)
    fut.complete()
  )
  result = fut

proc waitWritable(fd: SocketHandle): CpsVoidFuture =
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  loop.registerWrite(fd, proc() =
    loop.unregister(fd)
    fut.complete()
  )
  result = fut

proc handleClient(fd: SocketHandle): CpsVoidFuture {.cps.} =
  var buf: array[256, char]
  var received = newStringOfCap(256)
  let replyStr = replyConst
  var alive = true

  while alive:
    # --- request ---
    received.setLen(0)
    var gotHeaders = false
    while not gotHeaders:
      await waitReadable(fd)
      let n = recv(fd, addr buf[0], buf.len.cint, 0'i32)
      if n <= 0:
        alive = false
        gotHeaders = true
      else:
        let oldLen = received.len
        received.setLen(oldLen + n)
        copyMem(addr received[oldLen], addr buf[0], n)
        if received.len >= 4 and
           received[received.len - 4] == '\r' and
           received[received.len - 3] == '\l' and
           received[received.len - 2] == '\r' and
           received[received.len - 1] == '\l':
          gotHeaders = true

    if not alive:
      fd.close()
      return

    # --- reply ---
    var pos = 0
    while pos < replyStr.len:
      await waitWritable(fd)
      let n = send(fd, unsafeAddr replyStr[pos], (replyStr.len - pos).cint, 0'i32)
      if n <= 0:
        alive = false
      else:
        pos += n

  fd.close()

proc acceptLoop(serverFd: SocketHandle): CpsVoidFuture {.cps.} =
  while true:
    await waitReadable(serverFd)
    var clientAddr: Sockaddr_storage
    var addrLen = sizeof(clientAddr).SockLen
    let clientFd = accept(serverFd, cast[ptr SockAddr](addr clientAddr), addr addrLen)
    if clientFd == osInvalidSocket:
      continue
    clientFd.setBlocking(false)
    discard handleClient(clientFd)

proc main() =
  let sock = createNativeSocket(Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
  sock.setSockOptInt(SOL_SOCKET, SO_REUSEADDR, 1)
  sock.setSockOptInt(SOL_SOCKET, SO_REUSEPORT, 1)
  sock.setBlocking(false)

  var sa: Sockaddr_in
  sa.sin_family = AF_INET.TSa_Family
  sa.sin_port = nativesockets.htons(8080'u16)
  sa.sin_addr.s_addr = nativesockets.htonl(INADDR_LOOPBACK.uint32)

  if bindAddr(sock, cast[ptr SockAddr](addr sa), sizeof(sa).SockLen) < 0:
    raiseOSError(osLastError())
  if listen(sock, SOMAXCONN) < 0:
    raiseOSError(osLastError())

  echo "Raw CPS server listening on http://127.0.0.1:8080"
  discard acceptLoop(sock)
  let loop = getEventLoop()
  while true:
    loop.tick()

main()
