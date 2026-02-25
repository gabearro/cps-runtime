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

proc newUdpSocket*(domain: Domain = AF_INET): UdpSocket =
  ## Create a new non-blocking UDP socket.
  let fd = createNativeSocket(domain, SOCK_DGRAM, IPPROTO_UDP)
  if fd == osInvalidSocket:
    raise newException(streams.AsyncIoError, "Failed to create UDP socket")
  fd.setBlocking(false)
  result = UdpSocket(fd: fd, domain: domain, closed: false)

proc bindAddr*(sock: UdpSocket, host: string, port: int) =
  ## Bind the UDP socket to a local address.
  let aiList = getAddrInfo(host, Port(port), sock.domain, SOCK_DGRAM, IPPROTO_UDP)
  if aiList == nil:
    raise newException(streams.AsyncIoError, "Could not resolve bind address: " & host)

  if bindAddr(sock.fd, aiList.ai_addr, aiList.ai_addrlen.SockLen) != 0:
    let err = osLastError()
    freeAddrInfo(aiList)
    raise newException(streams.AsyncIoError, "UDP bind failed: " & osErrorMsg(err))

  freeAddrInfo(aiList)

# ============================================================
# Address helpers
# ============================================================

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

proc parseSenderAddress*(rd: RawDatagram): (string, int) =
  ## Extract the sender IP and port from a RawDatagram.
  var host = newString(256)
  var portStr = newString(32)
  let rc = getnameinfo(cast[ptr SockAddr](unsafeAddr rd.srcAddr), rd.addrLen,
                       cstring(host), 256.SockLen,
                       cstring(portStr), 32.SockLen,
                       (NI_NUMERICHOST or NI_NUMERICSERV).cint)
  if rc != 0:
    raise newException(streams.AsyncIoError, "Failed to parse sender address")
  host.setLen(host.cstring.len)
  portStr.setLen(portStr.cstring.len)
  result = (host, parseInt(portStr))

# ============================================================
# Existing high-level API
# ============================================================

proc sendTo*(sock: UdpSocket, data: string, host: string, port: int): CpsVoidFuture =
  ## Send a datagram to the specified host:port (uses getAddrInfo).
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  let aiList = getAddrInfo(host, Port(port), sock.domain, SOCK_DGRAM, IPPROTO_UDP)
  if aiList == nil:
    fut.fail(newException(streams.AsyncIoError, "Could not resolve address: " & host))
    return fut

  let ai_addr = aiList.ai_addr
  let ai_addrlen = aiList.ai_addrlen

  proc trySend() =
    let n = sendto(sock.fd, unsafeAddr data[0], data.len.cint, 0'i32,
                   ai_addr, ai_addrlen.SockLen)
    if n < 0:
      let err = osLastError()
      if err.isWouldBlock():
        loop.registerWrite(sock.fd, proc() =
          loop.unregister(sock.fd)
          trySend()
        )
        return
      else:
        freeAddrInfo(aiList)
        fut.fail(newException(
          streams.AsyncIoError,
          "sendTo failed host=" & host & " port=" & $port &
            " bytes=" & $data.len & ": " & osErrorMsg(err)
        ))
        return
    freeAddrInfo(aiList)
    fut.complete()

  trySend()
  result = fut

proc recvFrom*(sock: UdpSocket, maxSize: int = 65535): CpsFuture[Datagram] =
  ## Receive a datagram. Returns the data and sender address.
  let fut = newCpsFuture[Datagram]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  var buf = newString(maxSize)

  proc tryRecv() =
    var srcAddr: Sockaddr_storage
    var addrLen: SockLen = sizeof(srcAddr).SockLen

    let n = recvfrom(sock.fd, addr buf[0], maxSize.cint, 0'i32,
                     cast[ptr SockAddr](addr srcAddr), addr addrLen)
    if n < 0:
      let err = osLastError()
      if err.isWouldBlock():
        loop.registerRead(sock.fd, proc() =
          loop.unregister(sock.fd)
          tryRecv()
        )
        return
      else:
        fut.fail(newException(streams.AsyncIoError, "recvFrom failed: " & osErrorMsg(err)))
        return
    buf.setLen(n)

    # Parse sender address
    var senderHost = newString(256)
    var senderPort = newString(32)
    let rc = getnameinfo(cast[ptr SockAddr](addr srcAddr), addrLen,
                         cstring(senderHost), 256.SockLen,
                         cstring(senderPort), 32.SockLen,
                         (NI_NUMERICHOST or NI_NUMERICSERV).cint)
    if rc != 0:
      fut.fail(newException(streams.AsyncIoError, "Failed to parse sender address"))
      return

    senderHost.setLen(senderHost.cstring.len)
    senderPort.setLen(senderPort.cstring.len)

    fut.complete(Datagram(
      data: buf,
      address: senderHost,
      port: parseInt(senderPort)
    ))

  tryRecv()
  result = fut

# ============================================================
# Low-level send (pre-resolved IP, no getAddrInfo)
# ============================================================

proc trySendToAddr*(sock: UdpSocket, data: string, ip: string, port: int,
                    domain: Domain = AF_INET): bool =
  ## Fire-and-forget send to a pre-resolved IP address.
  ## Returns true on success, false on EAGAIN/EWOULDBLOCK.
  ## Raises AsyncIoError on hard errors.
  var sa: Sockaddr_storage
  let saLen = fillSockaddrIp(ip, port, domain, sa)
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
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  var sa: Sockaddr_storage
  let saLen = fillSockaddrIp(ip, port, domain, sa)

  proc trySend() =
    let n = sendto(sock.fd, unsafeAddr data[0], data.len.cint, 0'i32,
                   cast[ptr SockAddr](addr sa), saLen)
    if n < 0:
      let err = osLastError()
      if err.isWouldBlock():
        loop.registerWrite(sock.fd, proc() =
          loop.unregister(sock.fd)
          trySend()
        )
        return
      else:
        fut.fail(newException(
          streams.AsyncIoError,
          "sendToAddr failed ip=" & ip & " port=" & $port &
            " bytes=" & $data.len & ": " & osErrorMsg(err)
        ))
        return
    fut.complete()

  trySend()
  result = fut

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
      loop.unregister(sock.fd)
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
      callback(data, srcAddr, addrLen)

    # Re-register for next read event (if socket not closed)
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
# Close
# ============================================================

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
