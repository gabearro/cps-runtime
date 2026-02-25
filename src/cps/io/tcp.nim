## CPS I/O TCP
##
## Provides TCP client (TcpStream) and server (TcpListener) sockets
## integrated with the CPS event loop.

import std/[nativesockets, net, os]
import ../runtime
import ../eventloop
import ../private/platform
import ./streams
import ./dns

# ============================================================
# TcpStream - connected TCP socket as AsyncStream
# ============================================================

type
  TcpStream* = ref object of AsyncStream
    fd*: SocketHandle
    domain: Domain

proc tcpStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let ts = TcpStream(s)

  # Fast path: try non-blocking recv immediately
  var buf = newString(size)
  let n = recv(ts.fd, addr buf[0], size.cint, 0'i32)
  if n > 0:
    buf.setLen(n)
    return completedFuture(buf)
  elif n == 0:
    return completedFuture("")  # EOF

  # n < 0: check if it's EAGAIN (need to wait) or real error
  let firstErr = osLastError()
  if not firstErr.isWouldBlock():
    let fut = newCpsFuture[string]()
    fut.fail(newException(streams.AsyncIoError, "Read failed: " & osErrorMsg(firstErr)))
    return fut

  # Async path: register for readability
  let fut = newCpsFuture[string]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  proc tryRecv() =
    let n = recv(ts.fd, addr buf[0], size.cint, 0'i32)
    if n < 0:
      let err = osLastError()
      if err.isWouldBlock():
        loop.registerRead(ts.fd, proc() =
          loop.unregister(ts.fd)
          tryRecv()
        )
        return
      else:
        fut.fail(newException(streams.AsyncIoError, "Read failed: " & osErrorMsg(err)))
        return
    elif n == 0:
      fut.complete("")  # EOF
      return
    else:
      buf.setLen(n)
      fut.complete(buf)

  loop.registerRead(ts.fd, proc() =
    loop.unregister(ts.fd)
    tryRecv()
  )
  result = fut

var gSyncWriteCompleted: CpsVoidFuture

proc getSyncWriteCompleted(): CpsVoidFuture {.inline.} =
  ## Singleton pre-completed void future for synchronous writes.
  ## Safe to share: addCallback on a completed future fires inline,
  ## finished/hasError are read-only checks. No mutation occurs.
  if gSyncWriteCompleted.isNil:
    gSyncWriteCompleted = newCpsVoidFuture()
    gSyncWriteCompleted.complete()
  gSyncWriteCompleted

proc tcpStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let ts = TcpStream(s)
  let totalLen = data.len

  # Fast path: try synchronous send first (common for small writes)
  var sent = 0
  while sent < totalLen:
    let n = send(ts.fd, unsafeAddr data[sent], (totalLen - sent).cint, 0'i32)
    if n < 0:
      let err = osLastError()
      if err.isWouldBlock():
        break  # Need async path
      else:
        let fut = newCpsVoidFuture()
        fut.fail(newException(streams.AsyncIoError, "Write failed: " & osErrorMsg(err)))
        return fut
    elif n == 0:
      let fut = newCpsVoidFuture()
      fut.fail(newException(streams.ConnectionClosedError, "Connection closed during write"))
      return fut
    else:
      sent += n

  if sent >= totalLen:
    return getSyncWriteCompleted()  # Zero allocation!

  # Async path: need to wait for writability
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  proc trySend() =
    while sent < totalLen:
      let remaining = totalLen - sent
      let n = send(ts.fd, unsafeAddr data[sent], remaining.cint, 0'i32)
      if n < 0:
        let err = osLastError()
        if err.isWouldBlock():
          loop.registerWrite(ts.fd, proc() =
            loop.unregister(ts.fd)
            trySend()
          )
          return
        else:
          fut.fail(newException(streams.AsyncIoError, "Write failed: " & osErrorMsg(err)))
          return
      elif n == 0:
        fut.fail(newException(streams.ConnectionClosedError, "Connection closed during write"))
        return
      else:
        sent += n
    fut.complete()

  trySend()
  result = fut

proc tcpStreamReadInto(s: AsyncStream, buf: pointer, size: int): int =
  ## Zero-copy read: recv directly into caller's buffer.
  ## Returns >0 = bytes read, 0 = EOF, -1 = EAGAIN, < -1 = error.
  let ts = TcpStream(s)
  let n = recv(ts.fd, buf, size.cint, 0'i32)
  if n > 0: return n
  if n == 0: return 0
  let err = osLastError()
  if err.isWouldBlock(): return -1
  return -2

proc tcpStreamWaitReadable(s: AsyncStream): CpsVoidFuture =
  ## Wait until the socket is readable (data available or EOF).
  let ts = TcpStream(s)
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  loop.registerRead(ts.fd, proc() =
    loop.unregister(ts.fd)
    fut.complete()
  )
  result = fut

proc tcpStreamClose(s: AsyncStream) =
  let ts = TcpStream(s)
  try:
    let loop = getEventLoop()
    loop.unregister(ts.fd)
  except Exception:
    discard
  ts.fd.close()

proc newTcpStream*(fd: SocketHandle, domain: Domain = AF_INET): TcpStream =
  ## Wrap a connected, non-blocking socket fd into a TcpStream.
  result = TcpStream(
    fd: fd,
    domain: domain,
    closed: false
  )
  result.readProc = tcpStreamRead
  result.writeProc = tcpStreamWrite
  result.closeProc = tcpStreamClose
  result.readIntoProc = tcpStreamReadInto
  result.waitReadableProc = tcpStreamWaitReadable

# ============================================================
# tcpConnectIp - async TCP connection to a pre-resolved IP
# ============================================================

proc tcpConnectIp*(ip: string, port: int, domain: Domain = AF_INET): CpsFuture[TcpStream] =
  ## Connect to a pre-resolved IP:port asynchronously. Returns a TcpStream.
  ## Use this when you already have the IP address and want to skip DNS.
  let fut = newCpsFuture[TcpStream]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  let fd = createNativeSocket(domain, SOCK_STREAM, IPPROTO_TCP)
  if fd == osInvalidSocket:
    fut.fail(newException(streams.AsyncIoError, "Failed to create socket"))
    return fut

  fd.setBlocking(false)

  # Build sockaddr directly from IP via inet_pton (no getAddrInfo)
  var sa: Sockaddr_storage
  var saLen: SockLen
  zeroMem(addr sa, sizeof(sa))
  if domain == AF_INET:
    var sa4 = cast[ptr Sockaddr_in](addr sa)
    sa4.sin_family = AF_INET.TSa_Family
    sa4.sin_port = nativesockets.htons(port.uint16)
    if inet_pton(AF_INET.cint, ip.cstring, addr sa4.sin_addr) != 1:
      fd.close()
      fut.fail(newException(streams.AsyncIoError, "Invalid IPv4 address: " & ip))
      return fut
    saLen = sizeof(Sockaddr_in).SockLen
  elif domain == AF_INET6:
    var sa6 = cast[ptr Sockaddr_in6](addr sa)
    sa6.sin6_family = AF_INET6.TSa_Family
    sa6.sin6_port = nativesockets.htons(port.uint16)
    if inet_pton(AF_INET6.cint, ip.cstring, addr sa6.sin6_addr) != 1:
      fd.close()
      fut.fail(newException(streams.AsyncIoError, "Invalid IPv6 address: " & ip))
      return fut
    saLen = sizeof(Sockaddr_in6).SockLen
  else:
    fd.close()
    fut.fail(newException(streams.AsyncIoError, "Unsupported domain: " & $domain))
    return fut

  let res = connect(fd, cast[ptr SockAddr](addr sa), saLen)

  if res == 0.cint:
    fut.complete(newTcpStream(fd, domain))
    return fut

  let errCode = osLastError()
  if errCode.isInProgress():
    loop.registerWrite(fd, proc() =
      loop.unregister(fd)
      var optVal: cint = 0
      var optLen: SockLen = sizeof(optVal).SockLen
      let r = getsockopt(fd, SOL_SOCKET.cint, SO_ERROR.cint,
                          cast[pointer](addr optVal), addr optLen)
      if r != 0 or optVal != 0:
        fd.close()
        fut.fail(newException(streams.AsyncIoError, "Connection failed: " & $optVal))
      else:
        fut.complete(newTcpStream(fd, domain))
    )
  else:
    fd.close()
    fut.fail(newException(streams.AsyncIoError, "Connect failed: " & osErrorMsg(errCode)))

  result = fut

# ============================================================
# tcpConnect - async TCP client connection with async DNS
# ============================================================

proc tcpConnect*(host: string, port: int, domain: Domain = AF_INET): CpsFuture[TcpStream] =
  ## Connect to a remote host:port asynchronously. Resolves the hostname
  ## via the async DNS resolver (with caching), then connects to the IP.
  # Short-circuit for IP addresses — skip DNS entirely
  if dns.isIpAddress(host):
    return tcpConnectIp(host, port, domain)

  let fut = newCpsFuture[TcpStream]()
  fut.pinFutureRuntime()

  let dnsFut = resolve(host, Port(port), domain)

  proc makeDnsCb(df: CpsFuture[seq[string]], rf: CpsFuture[TcpStream],
                 p: int, d: Domain): proc() {.closure.} =
    result = proc() =
      if df.hasError():
        rf.fail(df.getError())
        return
      let ips = df.read()
      if ips.len == 0:
        rf.fail(newException(streams.AsyncIoError, "DNS resolved no addresses for host"))
        return
      let connectFut = tcpConnectIp(ips[0], p, d)
      proc makeConnCb(cf: CpsFuture[TcpStream], rf2: CpsFuture[TcpStream]): proc() {.closure.} =
        result = proc() =
          if cf.hasError():
            rf2.fail(cf.getError())
          else:
            rf2.complete(cf.read())
      connectFut.addCallback(makeConnCb(connectFut, rf))

  dnsFut.addCallback(makeDnsCb(dnsFut, fut, port, domain))
  result = fut

# ============================================================
# TcpListener - TCP server socket
# ============================================================

type
  TcpListener* = ref object
    fd*: SocketHandle
    domain: Domain
    closed*: bool

proc tcpListen*(host: string, port: int, backlog: int = 128,
                domain: Domain = AF_INET): TcpListener =
  ## Create a TCP listening socket. Binds to host:port and starts listening.
  ## This is a synchronous operation — the socket is ready for accept() calls.
  let fd = createNativeSocket(domain, SOCK_STREAM, IPPROTO_TCP)
  if fd == osInvalidSocket:
    raise newException(streams.AsyncIoError, "Failed to create socket")

  # SO_REUSEADDR
  var yes: cint = 1
  if setsockopt(fd, SOL_SOCKET.cint, SO_REUSEADDR.cint,
                addr yes, sizeof(yes).SockLen) != 0:
    fd.close()
    raise newException(streams.AsyncIoError, "Failed to set SO_REUSEADDR")

  fd.setBlocking(false)

  let aiList = getAddrInfo(host, Port(port), domain)
  if aiList == nil:
    fd.close()
    raise newException(streams.AsyncIoError, "Could not resolve bind address: " & host)

  if bindAddr(fd, aiList.ai_addr, aiList.ai_addrlen.SockLen) != 0:
    let err = osLastError()
    freeAddrInfo(aiList)
    fd.close()
    raise newException(streams.AsyncIoError, "Bind failed: " & osErrorMsg(err))

  freeAddrInfo(aiList)

  if nativesockets.listen(fd, backlog.cint) != 0:
    let err = osLastError()
    fd.close()
    raise newException(streams.AsyncIoError, "Listen failed: " & osErrorMsg(err))

  result = TcpListener(fd: fd, domain: domain, closed: false)

proc accept*(listener: TcpListener): CpsFuture[TcpStream] =
  ## Accept a new connection asynchronously. Returns a TcpStream.
  let fut = newCpsFuture[TcpStream]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  proc tryAccept() =
    var clientAddr: Sockaddr_storage
    var addrLen: SockLen = sizeof(clientAddr).SockLen
    let clientFd = accept(listener.fd, cast[ptr SockAddr](addr clientAddr), addr addrLen)
    if clientFd == osInvalidSocket:
      let err = osLastError()
      if err.isWouldBlock():
        loop.registerRead(listener.fd, proc() =
          loop.unregister(listener.fd)
          tryAccept()
        )
        return
      else:
        fut.fail(newException(streams.AsyncIoError, "Accept failed: " & osErrorMsg(err)))
        return
    clientFd.setBlocking(false)
    fut.complete(newTcpStream(clientFd, listener.domain))

  tryAccept()
  result = fut

proc close*(listener: TcpListener) =
  ## Close the listening socket.
  if not listener.closed:
    listener.closed = true
    try:
      let loop = getEventLoop()
      loop.unregister(listener.fd)
    except Exception:
      discard
    listener.fd.close()
