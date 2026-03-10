## CPS I/O TCP
##
## Provides TCP client (TcpStream) and server (TcpListener) sockets
## integrated with the CPS event loop.

import std/[nativesockets, net, os]
from std/posix import shutdown, SHUT_WR
import ../runtime
import ../eventloop
import ../private/platform
import ./streams
import ./dns
import ./timeouts
import ./udp

const
  TCP_NODELAY_OPT {.importc: "TCP_NODELAY", header: "<netinet/tcp.h>".}: cint = 0
  IPPROTO_TCP_C {.importc: "IPPROTO_TCP", header: "<netinet/in.h>".}: cint = 0
  IPPROTO_IPV6_C {.importc: "IPPROTO_IPV6", header: "<netinet/in.h>".}: cint = 0
  IPV6_V6ONLY_C {.importc: "IPV6_V6ONLY", header: "<netinet/in.h>".}: cint = 0
  TcpConnectPerAddressTimeoutMs = 5000

when defined(macosx) or defined(bsd):
  const SO_NOSIGPIPE_C {.importc: "SO_NOSIGPIPE", header: "<sys/socket.h>".}: cint = 0

proc setSoNosigpipe(fd: SocketHandle) {.inline.} =
  ## On macOS/BSD, set SO_NOSIGPIPE to prevent SIGPIPE on broken-pipe writes.
  ## Combined with the global SIGPIPE ignore, this provides defense in depth.
  when defined(macosx) or defined(bsd):
    var yes: cint = 1
    discard setsockopt(fd, SOL_SOCKET.cint, SO_NOSIGPIPE_C,
                       addr yes, sizeof(yes).SockLen)

# Ensure SIGPIPE is ignored at module init — before any socket I/O.
when defined(posix):
  proc c_signal(sig: cint, handler: pointer): pointer
    {.importc: "signal", header: "<signal.h>".}
  const SIG_IGN_PTR = cast[pointer](1)
  const SIGPIPE_C = 13.cint
  discard c_signal(SIGPIPE_C, SIG_IGN_PTR)

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

  fut.addCallback(proc() =
    if fut.isCancelled():
      try: loop.unregister(ts.fd)
      except Exception: discard
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

  fut.addCallback(proc() =
    if fut.isCancelled():
      try: loop.unregister(ts.fd)
      except Exception: discard
  )
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
  ## Safety: clears any orphaned registration from a prior timed-out read
  ## (withTimeout can fire without unregistering the fd from the selector).
  let ts = TcpStream(s)
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  try: loop.unregister(ts.fd)
  except Exception: discard
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
  # Half-close write side first: the kernel sends FIN *after* all pending
  # send-buffer data has been transmitted. Without this, close() on a socket
  # with unread receive-buffer data sends TCP RST, which causes the peer
  # kernel to discard ALL unread data from its receive buffer — including
  # data we just wrote (e.g. an IRC QUIT message).
  discard shutdown(ts.fd, SHUT_WR)
  # Drain the receive buffer so close() finds it empty and sends FIN
  # instead of RST. Non-blocking socket: recv returns -1/EAGAIN when empty.
  var drainBuf: array[4096, byte]
  for i in 0 ..< 16:
    if recv(ts.fd, addr drainBuf[0], 4096.cint, 0'i32) <= 0:
      break
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
  fd.setSoNosigpipe()

  var writeRegistered = false
  var fdClosed = false

  proc closePendingFd() =
    if fdClosed:
      return
    if writeRegistered:
      try:
        loop.unregister(fd)
      except Exception:
        discard
      writeRegistered = false
    fd.close()
    fdClosed = true

  # Disable Nagle's algorithm for low-latency sends
  var optOne: cint = 1
  discard setsockopt(fd, IPPROTO_TCP_C, TCP_NODELAY_OPT,
                     addr optOne, sizeof(optOne).SockLen)

  # Build sockaddr directly from IP via inet_pton (no getAddrInfo)
  var sa: Sockaddr_storage
  var saLen: SockLen
  try:
    saLen = fillSockaddrIp(ip, port, domain, sa)
  except OSError as e:
    closePendingFd()
    fut.fail(newException(streams.AsyncIoError, e.msg))
    return fut

  let res = connect(fd, cast[ptr SockAddr](addr sa), saLen)

  if res == 0.cint:
    fdClosed = true
    fut.complete(newTcpStream(fd, domain))
    return fut

  let errCode = osLastError()
  if errCode.isInProgress():
    writeRegistered = true
    loop.registerWrite(fd, proc() =
      writeRegistered = false
      try:
        loop.unregister(fd)
      except Exception:
        discard
      if fut.finished:
        closePendingFd()
        return
      var optVal: cint = 0
      var optLen: SockLen = sizeof(optVal).SockLen
      let r = getsockopt(fd, SOL_SOCKET.cint, SO_ERROR.cint,
                          cast[pointer](addr optVal), addr optLen)
      if r != 0 or optVal != 0:
        closePendingFd()
        fut.fail(newException(streams.AsyncIoError,
          "Connection failed: " & osErrorMsg(OSErrorCode(optVal))))
      else:
        fdClosed = true
        fut.complete(newTcpStream(fd, domain))
    )
  else:
    closePendingFd()
    fut.fail(newException(streams.AsyncIoError, "Connect failed: " & osErrorMsg(errCode)))

  fut.addCallback(proc() =
    if fut.isCancelled():
      closePendingFd()
  )

  result = fut

# ============================================================
# tcpConnect - async TCP client connection with async DNS
# ============================================================

proc tcpConnect*(host: string, port: int, domain: Domain = AF_INET): CpsFuture[TcpStream] =
  ## Connect to a remote host:port asynchronously. Resolves the hostname
  ## via the async DNS resolver (with caching), then connects to the IP.
  # Short-circuit for IP addresses — skip DNS entirely.
  # Auto-detect IPv6 from the address string so callers don't need to pass AF_INET6.
  if dns.isIpAddress(host):
    let actualDomain = if ':' in host: AF_INET6 else: domain
    return tcpConnectIp(host, port, actualDomain)

  let fut = newCpsFuture[TcpStream]()
  fut.pinFutureRuntime()

  let dnsFut = resolve(host, Port(port), domain)

  proc makeDnsCb(df: CpsFuture[seq[string]], rf: CpsFuture[TcpStream],
                 h: string, p: int, d: Domain): proc() {.closure.} =
    result = proc() =
      if df.hasError():
        rf.fail(df.getError())
        return
      let ips = df.read()
      if ips.len == 0:
        rf.fail(newException(streams.AsyncIoError, "DNS resolved no addresses for host"))
        return
      proc tryIp(idx: int, lastErr: string)
      proc tryIp(idx: int, lastErr: string) =
        if rf.finished:
          return
        if idx >= ips.len:
          let suffix = if lastErr.len > 0: ": " & lastErr else: ""
          rf.fail(newException(streams.AsyncIoError,
            "Connect failed for " & h & " on all resolved addresses" & suffix))
          return

        let ip = ips[idx]
        let connectFut = withTimeout(
          tcpConnectIp(ip, p, d), TcpConnectPerAddressTimeoutMs)
        connectFut.addCallback(proc() =
          if rf.finished:
            return
          if connectFut.hasError():
            let e = connectFut.getError()
            let msg =
              if e != nil and e.msg.len > 0: e.msg
              else: "connect failed"
            tryIp(idx + 1, ip & " (" & msg & ")")
          else:
            rf.complete(connectFut.read())
        )

      tryIp(0, "")

  dnsFut.addCallback(makeDnsCb(dnsFut, fut, host, port, domain))
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
                domain: Domain = AF_INET, dualStack: bool = false): TcpListener =
  ## Create a TCP listening socket. Binds to host:port and starts listening.
  ## This is a synchronous operation — the socket is ready for accept() calls.
  ## When `dualStack` is true and `domain` is AF_INET6, sets IPV6_V6ONLY=0 so
  ## the socket accepts both IPv4 (as ::ffff:x.x.x.x) and IPv6 connections.
  let fd = createNativeSocket(domain, SOCK_STREAM, IPPROTO_TCP)
  if fd == osInvalidSocket:
    raise newException(streams.AsyncIoError, "Failed to create socket")

  fd.setSoNosigpipe()

  # SO_REUSEADDR
  var yes: cint = 1
  if setsockopt(fd, SOL_SOCKET.cint, SO_REUSEADDR.cint,
                addr yes, sizeof(yes).SockLen) != 0:
    fd.close()
    raise newException(streams.AsyncIoError, "Failed to set SO_REUSEADDR")

  # Dual-stack: allow IPv6 socket to accept IPv4 connections too
  if dualStack and domain == AF_INET6:
    var no: cint = 0
    discard setsockopt(fd, IPPROTO_IPV6_C, IPV6_V6ONLY_C,
                       addr no, sizeof(no).SockLen)

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

proc localPort*(listener: TcpListener): int =
  ## Return the port the listener is bound to. Useful when bound to port 0
  ## (OS-assigned) to discover the actual port.
  ## Works for both IPv4 and IPv6 listeners.
  var sa: Sockaddr_storage
  var saLen: SockLen = sizeof(sa).SockLen
  if getsockname(listener.fd, cast[ptr SockAddr](addr sa), addr saLen) != 0:
    return 0
  extractPort(cast[ptr SockAddr](addr sa), saLen)

proc peerEndpoint*(stream: TcpStream): tuple[ip: string, port: uint16] =
  ## Return the connected peer endpoint for this stream.
  ## On failure, returns ("", 0).
  var sa: Sockaddr_storage
  var saLen: SockLen = sizeof(sa).SockLen
  if getpeername(stream.fd, cast[ptr SockAddr](addr sa), addr saLen) != 0:
    return ("", 0'u16)
  let (ip, port) = extractEndpoint(cast[ptr SockAddr](addr sa), saLen)
  if port <= 0 or port > 65535:
    return (ip, 0'u16)
  (ip, uint16(port))

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
    clientFd.setSoNosigpipe()
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
