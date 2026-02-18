## CPS I/O Unix Domain Sockets
##
## Provides Unix domain socket client (UnixStream) and server (UnixListener)
## for local IPC, integrated with the CPS event loop.

import std/[nativesockets, os, posix]
import ../runtime
import ../eventloop
import ./streams

# ============================================================
# POSIX types for Unix domain sockets
# ============================================================

const AF_UNIX_C = 1.cint  ## AF_UNIX / AF_LOCAL — same value on Linux and macOS

type
  SockaddrUn {.importc: "struct sockaddr_un", header: "<sys/un.h>".} = object
    sun_family {.importc.}: uint16
    sun_path {.importc.}: array[104, char]  # 104 on macOS, 108 on Linux — use 104 for portability

# ============================================================
# UnixStream - connected Unix socket as AsyncStream
# ============================================================

type
  UnixStream* = ref object of AsyncStream
    fd*: SocketHandle

proc unixStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let us = UnixStream(s)
  let fut = newCpsFuture[string]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  proc tryRecv() =
    var buf = newString(size)
    let n = recv(us.fd, addr buf[0], size.cint, 0'i32)
    if n < 0:
      let err = osLastError()
      if err.int == EAGAIN or err.int == EWOULDBLOCK:
        loop.registerRead(us.fd, proc() =
          loop.unregister(us.fd)
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

  tryRecv()
  result = fut

proc unixStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let us = UnixStream(s)
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  var sent = 0
  let totalLen = data.len

  proc trySend() =
    while sent < totalLen:
      let remaining = totalLen - sent
      let n = send(us.fd, unsafeAddr data[sent], remaining.cint, 0'i32)
      if n < 0:
        let err = osLastError()
        if err.int == EAGAIN or err.int == EWOULDBLOCK:
          loop.registerWrite(us.fd, proc() =
            loop.unregister(us.fd)
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

proc unixStreamClose(s: AsyncStream) =
  let us = UnixStream(s)
  try:
    let loop = getEventLoop()
    loop.unregister(us.fd)
  except Exception:
    discard
  us.fd.close()

proc newUnixStream*(fd: SocketHandle): UnixStream =
  ## Wrap a connected, non-blocking Unix socket fd into a UnixStream.
  result = UnixStream(
    fd: fd,
    closed: false
  )
  result.readProc = unixStreamRead
  result.writeProc = unixStreamWrite
  result.closeProc = unixStreamClose

# ============================================================
# unixConnect - async Unix domain socket client connection
# ============================================================

proc fillSockaddrUn(path: string): SockaddrUn =
  ## Fill a sockaddr_un with the given path. Raises on path too long.
  if path.len >= sizeof(result.sun_path):
    raise newException(streams.AsyncIoError,
      "Unix socket path too long: " & $path.len & " >= " & $sizeof(result.sun_path))
  result.sun_family = AF_UNIX_C.uint16
  for i in 0 ..< path.len:
    result.sun_path[i] = path[i]
  result.sun_path[path.len] = '\0'

proc unixConnect*(path: string): CpsFuture[UnixStream] =
  ## Connect to a Unix domain socket at `path` asynchronously.
  ## Returns a UnixStream.
  let fut = newCpsFuture[UnixStream]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  let fd = createNativeSocket(AF_UNIX_C, SOCK_STREAM.cint, 0)
  if fd == osInvalidSocket:
    fut.fail(newException(streams.AsyncIoError, "Failed to create Unix socket"))
    return fut

  fd.setBlocking(false)

  var addr_un = fillSockaddrUn(path)

  let res = connect(fd, cast[ptr SockAddr](addr addr_un), sizeof(addr_un).SockLen)

  if res == 0.cint:
    fut.complete(newUnixStream(fd))
    return fut

  let errCode = osLastError()
  if errCode.int == EINPROGRESS or errCode.int == EWOULDBLOCK:
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
        fut.complete(newUnixStream(fd))
    )
  else:
    fd.close()
    fut.fail(newException(streams.AsyncIoError, "Connect failed: " & osErrorMsg(errCode)))

  result = fut

# ============================================================
# UnixListener - Unix domain socket server
# ============================================================

type
  UnixListener* = ref object
    fd*: SocketHandle
    path*: string
    closed*: bool

proc unixListen*(path: string, backlog: int = 128): UnixListener =
  ## Create a Unix domain socket listener. Binds to the given path and
  ## starts listening. This is a synchronous operation -- the socket is
  ## ready for accept() calls.
  ## If the socket file already exists it will be unlinked first.

  let fd = createNativeSocket(AF_UNIX_C, SOCK_STREAM.cint, 0)
  if fd == osInvalidSocket:
    raise newException(streams.AsyncIoError, "Failed to create Unix socket")

  fd.setBlocking(false)

  # Unlink existing socket file if present
  discard posix.unlink(path.cstring)

  var addr_un = fillSockaddrUn(path)

  if bindAddr(fd, cast[ptr SockAddr](addr addr_un),
              sizeof(addr_un).SockLen) != 0:
    let err = osLastError()
    fd.close()
    raise newException(streams.AsyncIoError, "Bind failed: " & osErrorMsg(err))

  if nativesockets.listen(fd, backlog.cint) != 0:
    let err = osLastError()
    fd.close()
    raise newException(streams.AsyncIoError, "Listen failed: " & osErrorMsg(err))

  result = UnixListener(fd: fd, path: path, closed: false)

proc accept*(listener: UnixListener): CpsFuture[UnixStream] =
  ## Accept a new connection asynchronously. Returns a UnixStream.
  let fut = newCpsFuture[UnixStream]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  proc tryAccept() =
    var clientAddr: SockaddrUn
    var addrLen: SockLen = sizeof(clientAddr).SockLen
    let clientFd = posix.accept(listener.fd, cast[ptr SockAddr](addr clientAddr), addr addrLen)
    if clientFd == osInvalidSocket:
      let err = osLastError()
      if err.int == EAGAIN or err.int == EWOULDBLOCK:
        loop.registerRead(listener.fd, proc() =
          loop.unregister(listener.fd)
          tryAccept()
        )
        return
      else:
        fut.fail(newException(streams.AsyncIoError, "Accept failed: " & osErrorMsg(err)))
        return

    # Set accepted fd non-blocking
    clientFd.setBlocking(false)

    fut.complete(newUnixStream(clientFd))

  tryAccept()
  result = fut

proc close*(listener: UnixListener) =
  ## Close the listening socket and unlink the socket file.
  if not listener.closed:
    listener.closed = true
    try:
      let loop = getEventLoop()
      loop.unregister(listener.fd)
    except Exception:
      discard
    listener.fd.close()
    # Remove the socket file
    discard posix.unlink(listener.path.cstring)
