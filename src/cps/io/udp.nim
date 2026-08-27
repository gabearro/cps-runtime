## CPS I/O UDP
##
## Provides UDP socket support with non-blocking sendTo and recvFrom
## integrated with the CPS event loop.
##
## Also provides low-level building blocks for multiplexed UDP protocols
## (e.g., DNS): fire-and-forget sends to pre-resolved IPs, persistent
## read callbacks, and raw datagram access.

import std/[nativesockets, net, os, strutils]
import ../runtime
import ../eventloop
import ../private/platform
import ./streams

when defined(linux):
  import std/posix

  type UdpMMsgHdr {.importc: "struct mmsghdr", pure, final,
                     header: "<sys/socket.h>".} = object
    msg_hdr: Tmsghdr
    msg_len: cuint

  proc sendmmsg(fd: cint, msgvec: ptr UdpMMsgHdr, vlen: cuint,
                flags: cint): cint {.importc, header: "<sys/socket.h>".}

type
  UdpSocket* = ref object
    fd*: SocketHandle
    domain*: Domain
    closed*: bool

  Datagram* = object
    data*: string
    address*: string
    port*: int

  RawDatagram* = object
    ## A datagram with the raw sockaddr, avoiding getnameinfo cost.
    data*: string
    srcAddr*: Sockaddr_storage
    addrLen*: SockLen

  UdpRecvCallback* = proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) {.closure.}
  UdpRecvBorrowedCallback* = proc(data: openArray[byte], srcAddr: Sockaddr_storage,
                                  addrLen: SockLen) {.closure.}

const
  MaxUdpSendBatch* = 32

proc newUdpSocket*(domain: Domain = AF_INET): UdpSocket =
  ## Create a new non-blocking UDP socket.
  let fd = createNativeSocket(domain, SOCK_DGRAM, IPPROTO_UDP)
  if fd == osInvalidSocket:
    raise newException(streams.AsyncIoError, "Failed to create UDP socket")
  fd.setBlocking(false)
  when defined(macosx) or defined(bsd):
    var yes: cint = 1
    const SO_NOSIGPIPE_C {.importc: "SO_NOSIGPIPE", header: "<sys/socket.h>".}: cint = 0
    discard setsockopt(fd, SOL_SOCKET.cint, SO_NOSIGPIPE_C,
                       addr yes, sizeof(yes).SockLen)
  result = UdpSocket(fd: fd, domain: domain, closed: false)

proc bindAddr*(sock: UdpSocket, host: string, port: int,
               reusePort: bool = false) =
  ## Bind the UDP socket to a local address.
  var optval: cint = 1
  discard setsockopt(sock.fd, SOL_SOCKET.cint, SO_REUSEADDR.cint,
                     addr optval, sizeof(optval).SockLen)
  when defined(posix):
    if reusePort and setsockopt(sock.fd, SOL_SOCKET.cint, SO_REUSEPORT.cint,
                               addr optval, sizeof(optval).SockLen) != 0:
      raise newException(streams.AsyncIoError, "Failed to set UDP SO_REUSEPORT")

  let aiList = getAddrInfo(host, Port(port), sock.domain, SOCK_DGRAM, IPPROTO_UDP)
  if aiList == nil:
    raise newException(streams.AsyncIoError, "Could not resolve bind address: " & host)

  if bindAddr(sock.fd, aiList.ai_addr, aiList.ai_addrlen.SockLen) != 0:
    let err = osLastError()
    freeAddrInfo(aiList)
    raise newException(streams.AsyncIoError, "UDP bind failed: " & osErrorMsg(err))

  freeAddrInfo(aiList)

proc setBufferSizes*(sock: UdpSocket, receiveBytes: int = 0,
                     sendBytes: int = 0) =
  ## Request larger kernel UDP buffers. The kernel may clamp these values to
  ## its configured limits; that is still preferable to failing socket setup.
  if receiveBytes > 0:
    var value = receiveBytes.cint
    discard setsockopt(sock.fd, SOL_SOCKET.cint, SO_RCVBUF.cint,
                       addr value, sizeof(value).SockLen)
  if sendBytes > 0:
    var value = sendBytes.cint
    discard setsockopt(sock.fd, SOL_SOCKET.cint, SO_SNDBUF.cint,
                       addr value, sizeof(value).SockLen)

# ============================================================
# Address helpers
# ============================================================

proc detectDomain(ip: string, default: Domain): Domain {.inline.} =
  ## Auto-detect IPv6 when `ip` contains a colon.
  if ':' in ip: AF_INET6 else: default

proc fillSockaddrIp*(ip: string, port: int, domain: Domain,
                     sa: var Sockaddr_storage): SockLen =
  ## Convert an IP string + port into a Sockaddr_storage.
  ## Returns the address length. Raises AsyncIoError on invalid IP.
  zeroMem(addr sa, sizeof(sa))
  if domain == AF_INET:
    var sa4 = cast[ptr Sockaddr_in](addr sa)
    sa4.sin_family = AF_INET.TSa_Family
    sa4.sin_port = nativesockets.htons(port.uint16)
    if inet_pton(AF_INET.cint, ip.cstring, addr sa4.sin_addr) != 1:
      raise newException(streams.AsyncIoError, "Invalid IPv4 address: " & ip)
    result = sizeof(Sockaddr_in).SockLen
  elif domain == AF_INET6:
    var sa6 = cast[ptr Sockaddr_in6](addr sa)
    sa6.sin6_family = AF_INET6.TSa_Family
    sa6.sin6_port = nativesockets.htons(port.uint16)
    if inet_pton(AF_INET6.cint, ip.cstring, addr sa6.sin6_addr) != 1:
      raise newException(streams.AsyncIoError, "Invalid IPv6 address: " & ip)
    result = sizeof(Sockaddr_in6).SockLen
  else:
    raise newException(streams.AsyncIoError, "Unsupported domain: " & $domain)

proc extractEndpoint*(sa: ptr SockAddr, saLen: SockLen): (string, int) =
  ## Extract a numeric IP and port without resolver/service-database work for
  ## the normal IPv4 and IPv6 cases. Falls back to getnameinfo for any other
  ## address family.
  let family = cast[ptr Sockaddr_in](sa).sin_family
  var host: array[46, char]
  if family == AF_INET.TSa_Family:
    let sa4 = cast[ptr Sockaddr_in](sa)
    if inet_ntop(AF_INET.cint, addr sa4.sin_addr,
                 cast[cstring](addr host[0]), host.len.int32) == nil:
      return ("", 0)
    return ($cast[cstring](addr host[0]), int(nativesockets.ntohs(sa4.sin_port)))
  if family == AF_INET6.TSa_Family:
    let sa6 = cast[ptr Sockaddr_in6](sa)
    if inet_ntop(AF_INET6.cint, addr sa6.sin6_addr,
                 cast[cstring](addr host[0]), host.len.int32) == nil:
      return ("", 0)
    return ($cast[cstring](addr host[0]), int(nativesockets.ntohs(sa6.sin6_port)))

  var hostStr = newString(46)
  var portStr = newString(6)
  let rc = getnameinfo(sa, saLen,
                       cstring(hostStr), hostStr.len.SockLen,
                       cstring(portStr), portStr.len.SockLen,
                       (NI_NUMERICHOST or NI_NUMERICSERV).cint)
  if rc != 0:
    return ("", 0)
  hostStr.setLen(hostStr.cstring.len)
  portStr.setLen(portStr.cstring.len)
  try: (hostStr, parseInt(portStr))
  except ValueError: (hostStr, 0)

proc parseSockaddr(sa: ptr SockAddr, saLen: SockLen): (string, int) =
  result = extractEndpoint(sa, saLen)
  if result[0].len == 0:
    raise newException(streams.AsyncIoError, "Failed to parse socket address")

proc extractPort*(sa: ptr SockAddr, saLen: SockLen): int =
  ## Extract just the port from a sockaddr. Returns 0 on failure.
  let family = cast[ptr Sockaddr_in](sa).sin_family
  if family == AF_INET.TSa_Family:
    return int(nativesockets.ntohs(cast[ptr Sockaddr_in](sa).sin_port))
  if family == AF_INET6.TSa_Family:
    return int(nativesockets.ntohs(cast[ptr Sockaddr_in6](sa).sin6_port))
  var portStr = newString(6)
  let rc = getnameinfo(sa, saLen,
                       nil, 0.SockLen,
                       cstring(portStr), portStr.len.SockLen,
                       NI_NUMERICSERV.cint)
  if rc != 0:
    return 0
  portStr.setLen(portStr.cstring.len)
  try: parseInt(portStr)
  except ValueError: 0

proc parseSenderAddress*(rd: RawDatagram): (string, int) =
  ## Extract the sender IP and port from a RawDatagram.
  parseSockaddr(cast[ptr SockAddr](unsafeAddr rd.srcAddr), rd.addrLen)

# ============================================================
# Send helpers
# ============================================================

proc sendWithRetry(sock: UdpSocket, data: string,
                   destAddr: Sockaddr_storage, destLen: SockLen,
                   errorContext: string): CpsVoidFuture =
  ## Shared non-blocking sendto with a bounded-delay EAGAIN retry.
  ##
  ## A UDP socket can also own a persistent read callback. Registering a write
  ## callback for that same fd would replace the selector's read callback, and
  ## the read drain could then overwrite the pending write retry. A short timer
  ## avoids that single-slot race and permits multiple blocked datagram sends.
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  var sa = destAddr

  proc trySend() =
    let n = sendto(sock.fd, unsafeAddr data[0], data.len.cint, 0'i32,
                   cast[ptr SockAddr](addr sa), destLen)
    if n < 0:
      let err = osLastError()
      if err.isWouldBlock():
        discard loop.registerTimer(1, trySend)
      else:
        fut.fail(newException(streams.AsyncIoError,
          errorContext & ": " & osErrorMsg(err)))
    else:
      fut.complete()

  trySend()
  result = fut

# ============================================================
# High-level API
# ============================================================

proc sendTo*(sock: UdpSocket, data: string, host: string, port: int): CpsVoidFuture =
  ## Send a datagram to the specified host:port (uses getAddrInfo).
  let aiList = getAddrInfo(host, Port(port), sock.domain, SOCK_DGRAM, IPPROTO_UDP)
  if aiList == nil:
    let fut = newCpsVoidFuture()
    fut.pinFutureRuntime()
    fut.fail(newException(streams.AsyncIoError, "Could not resolve address: " & host))
    return fut

  # Copy address data and free immediately — avoids holding aiList across retries
  var sa: Sockaddr_storage
  copyMem(addr sa, aiList.ai_addr, aiList.ai_addrlen)
  let saLen = aiList.ai_addrlen.SockLen
  freeAddrInfo(aiList)

  result = sendWithRetry(sock, data, sa, saLen,
    "sendTo host=" & host & " port=" & $port & " bytes=" & $data.len)

proc recvFrom*(sock: UdpSocket, maxSize: int = 65535): CpsFuture[Datagram] =
  ## Receive a datagram. Returns the data and sender address.
  let fut = newCpsFuture[Datagram]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  var buf = newString(maxSize)
  var registered = false

  proc tryRecv() =
    var srcAddr: Sockaddr_storage
    var addrLen: SockLen = sizeof(srcAddr).SockLen

    let n = recvfrom(sock.fd, addr buf[0], maxSize.cint, 0'i32,
                     cast[ptr SockAddr](addr srcAddr), addr addrLen)
    if n < 0:
      let err = osLastError()
      if err.isWouldBlock():
        registered = true
        loop.registerRead(sock.fd, proc() =
          loop.disarm(sock.fd)
          registered = false
          tryRecv()
        )
        return
      else:
        fut.fail(newException(streams.AsyncIoError, "recvFrom failed: " & osErrorMsg(err)))
        return
    buf.setLen(n)

    let (senderHost, senderPort) = parseSockaddr(
      cast[ptr SockAddr](addr srcAddr), addrLen)
    fut.complete(Datagram(data: buf, address: senderHost, port: senderPort))

  # When the future is cancelled (e.g. by withTimeout), clean up the
  # selector registration to prevent orphaned read callbacks.
  fut.addCallback(proc() =
    if fut.isCancelled() and registered:
      try:
        loop.unregister(sock.fd)
      except Exception:
        discard
      registered = false
  )

  tryRecv()
  result = fut

# ============================================================
# Low-level send (pre-resolved IP, no getAddrInfo)
# ============================================================

proc fillSockaddrForSocket*(sock: UdpSocket, ip: string, port: int,
                            sa: var Sockaddr_storage): SockLen =
  ## Build a sockaddr for sending on this socket.
  ## Handles dual-stack: IPv4 addresses on IPv6 sockets use IPv4-mapped IPv6.
  let ipDomain = detectDomain(ip, AF_INET)
  if sock.domain == AF_INET6 and ipDomain == AF_INET:
    # Build ::ffff:x.x.x.x mapped address
    zeroMem(addr sa, sizeof(sa))
    var sa6 = cast[ptr Sockaddr_in6](addr sa)
    sa6.sin6_family = AF_INET6.TSa_Family
    sa6.sin6_port = nativesockets.htons(port.uint16)
    let addrBytes = cast[ptr array[16, byte]](unsafeAddr sa6.sin6_addr)
    addrBytes[10] = 0xFF
    addrBytes[11] = 0xFF
    var tmpSa4: Sockaddr_in
    if inet_pton(AF_INET.cint, ip.cstring, addr tmpSa4.sin_addr) != 1:
      raise newException(streams.AsyncIoError, "Invalid IPv4 address: " & ip)
    let v4Bytes = cast[ptr array[4, byte]](addr tmpSa4.sin_addr)
    addrBytes[12] = v4Bytes[0]
    addrBytes[13] = v4Bytes[1]
    addrBytes[14] = v4Bytes[2]
    addrBytes[15] = v4Bytes[3]
    result = sizeof(Sockaddr_in6).SockLen
  else:
    result = fillSockaddrIp(ip, port, detectDomain(ip, sock.domain), sa)

proc trySendToAddr*(sock: UdpSocket, data: string, ip: string, port: int,
                    domain: Domain = AF_INET): bool =
  ## Fire-and-forget send to a pre-resolved IP address.
  ## Returns true on success, false on EAGAIN/EWOULDBLOCK.
  ## Raises AsyncIoError on hard errors.
  ## Auto-detects IPv6 when `ip` contains a colon.
  ## On dual-stack IPv6 sockets, IPv4 addresses are sent as IPv4-mapped IPv6.
  var sa: Sockaddr_storage
  let saLen = fillSockaddrForSocket(sock, ip, port, sa)
  let n = sendto(sock.fd, unsafeAddr data[0], data.len.cint, 0'i32,
                 cast[ptr SockAddr](addr sa), saLen)
  if n < 0:
    let err = osLastError()
    if err.isWouldBlock():
      return false
    else:
      raise newException(streams.AsyncIoError, "sendToAddr failed: " & osErrorMsg(err))
  return true

proc sendToAddr*(sock: UdpSocket, data: string, ip: string, port: int,
                 domain: Domain = AF_INET): CpsVoidFuture =
  ## Async send to a pre-resolved IP address with write-readiness waiting.
  ## Auto-detects IPv6 when `ip` contains a colon.
  ## On dual-stack IPv6 sockets, IPv4 addresses are sent as IPv4-mapped IPv6.
  var sa: Sockaddr_storage
  let saLen = fillSockaddrForSocket(sock, ip, port, sa)
  result = sendWithRetry(sock, data, sa, saLen,
    "sendToAddr ip=" & ip & " port=" & $port & " bytes=" & $data.len)

proc sendToAddrBytes*(sock: UdpSocket, data: seq[byte], ip: string,
                      port: int): CpsVoidFuture =
  ## Send owned byte data to a numeric address without converting it to a
  ## string or resolving it. Ownership is retained across an EAGAIN retry.
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  var sa: Sockaddr_storage
  let saLen = fillSockaddrForSocket(sock, ip, port, sa)

  proc trySend() =
    let dataPtr = if data.len == 0: nil else: unsafeAddr data[0]
    let n = sendto(sock.fd, dataPtr, data.len.cint, 0'i32,
                   cast[ptr SockAddr](addr sa), saLen)
    if n < 0:
      let err = osLastError()
      if err.isWouldBlock():
        discard loop.registerTimer(1, trySend)
      else:
        fut.fail(newException(streams.AsyncIoError,
          "sendToAddrBytes failed: " & osErrorMsg(err)))
    else:
      fut.complete()

  trySend()
  result = fut

proc trySendToAddrBytes*(sock: UdpSocket, data: openArray[byte], ip: string,
                         port: int): bool =
  ## Attempt an owned/borrowed byte datagram without allocating a future or
  ## retry closure. Returns false only when the non-blocking socket would block;
  ## callers can then fall back to `sendToAddrBytes` for readiness-based retry.
  var sa: Sockaddr_storage
  let saLen = fillSockaddrForSocket(sock, ip, port, sa)
  let dataPtr = if data.len == 0: nil else: unsafeAddr data[0]
  let n = sendto(sock.fd, dataPtr, data.len.cint, 0'i32,
                 cast[ptr SockAddr](addr sa), saLen)
  if n < 0:
    let err = osLastError()
    if err.isWouldBlock():
      return false
    raise newException(streams.AsyncIoError,
      "trySendToAddrBytes failed: " & osErrorMsg(err))
  true

proc trySendToAddrBatchBytes*(sock: UdpSocket,
                              datagrams: openArray[seq[byte]],
                              ip: string,
                              port: int): int =
  ## Send a bounded prefix of datagrams to one numeric address without futures.
  ## Linux uses one `sendmmsg`; other platforms preserve the same partial-send
  ## contract with the ordinary non-blocking send path.
  let count = min(datagrams.len, MaxUdpSendBatch)
  if count == 0:
    return 0
  when defined(linux):
    var sa: Sockaddr_storage
    let saLen = fillSockaddrForSocket(sock, ip, port, sa)
    var iov: array[MaxUdpSendBatch, IOVec]
    var msgs: array[MaxUdpSendBatch, UdpMMsgHdr]
    for i in 0 ..< count:
      iov[i].iov_base =
        if datagrams[i].len == 0: nil
        else: unsafeAddr datagrams[i][0]
      iov[i].iov_len = datagrams[i].len.csize_t
      msgs[i].msg_hdr.msg_name = addr sa
      msgs[i].msg_hdr.msg_namelen = saLen
      msgs[i].msg_hdr.msg_iov = addr iov[i]
      msgs[i].msg_hdr.msg_iovlen = 1
    let sent = sendmmsg(sock.fd.cint, addr msgs[0], count.cuint, 0)
    if sent < 0:
      let err = osLastError()
      if err.isWouldBlock():
        return 0
      raise newException(streams.AsyncIoError,
        "trySendToAddrBatchBytes failed: " & osErrorMsg(err))
    int(sent)
  else:
    while result < count and
        sock.trySendToAddrBytes(datagrams[result], ip, port):
      inc result

# ============================================================
# Persistent read callback (for multiplexed protocols like DNS)
# ============================================================

proc onRecv*(sock: UdpSocket, maxSize: int, callback: UdpRecvCallback) =
  ## Register a persistent read callback on the socket.
  ## When data arrives, all available datagrams are drained and the callback
  ## is invoked for each. The socket is then re-registered for more reads.
  ## Uses the unregister-drain-reregister pattern required by kqueue.
  let loop = getEventLoop()
  var buf = newString(maxSize)

  proc readHandler() {.closure.} =
    # Unregister first (kqueue requirement)
    try:
      loop.disarm(sock.fd)
    except Exception:
      discard

    # Drain all available datagrams
    while not sock.closed:
      var srcAddr: Sockaddr_storage
      var addrLen: SockLen = sizeof(srcAddr).SockLen

      let n = recvfrom(sock.fd, addr buf[0], maxSize.cint, 0'i32,
                       cast[ptr SockAddr](addr srcAddr), addr addrLen)
      if n <= 0:
        break
      # Copy data out so the shared buffer can be reused
      let data = buf[0 ..< n]
      try:
        callback(data, srcAddr, addrLen)
      except Exception:
        discard

    # Re-register for next read event (if socket not closed)
    if not sock.closed:
      loop.registerRead(sock.fd, readHandler)

  loop.registerRead(sock.fd, readHandler)

proc onRecvBorrowed*(sock: UdpSocket, maxSize: int,
                     callback: UdpRecvBorrowedCallback) =
  ## Persistent zero-copy receive callback. `data` is valid only for the
  ## duration of callback execution and must be copied if retained.
  let loop = getEventLoop()
  var buf = newString(maxSize)

  proc readHandler() {.closure.} =
    try:
      loop.disarm(sock.fd)
    except Exception:
      discard

    while not sock.closed:
      var srcAddr: Sockaddr_storage
      var addrLen: SockLen = sizeof(srcAddr).SockLen
      let n = recvfrom(sock.fd, addr buf[0], maxSize.cint, 0'i32,
                       cast[ptr SockAddr](addr srcAddr), addr addrLen)
      if n <= 0:
        break
      try:
        callback(buf.toOpenArrayByte(0, n - 1), srcAddr, addrLen)
      except Exception:
        discard

    if not sock.closed:
      loop.registerRead(sock.fd, readHandler)

  loop.registerRead(sock.fd, readHandler)

proc cancelOnRecv*(sock: UdpSocket) =
  ## Cancel a persistent read callback previously set with onRecv.
  try:
    let loop = getEventLoop()
    loop.unregister(sock.fd)
  except Exception:
    discard

# ============================================================
# Utilities and close
# ============================================================

proc localPort*(sock: UdpSocket): int =
  ## Get the local port the socket is bound to (useful for ephemeral ports).
  var sa: Sockaddr_storage
  var saLen: SockLen = sizeof(sa).SockLen
  if getsockname(sock.fd, cast[ptr SockAddr](addr sa), addr saLen) != 0:
    raise newException(streams.AsyncIoError, "getsockname failed")
  if sock.domain == AF_INET:
    result = int(nativesockets.ntohs(cast[ptr Sockaddr_in](addr sa).sin_port))
  else:
    result = int(nativesockets.ntohs(cast[ptr Sockaddr_in6](addr sa).sin6_port))

proc close*(sock: UdpSocket) =
  ## Close the UDP socket.
  if not sock.closed:
    sock.closed = true
    try:
      let loop = getEventLoop()
      loop.unregister(sock.fd)
    except Exception:
      discard
    sock.fd.close()
