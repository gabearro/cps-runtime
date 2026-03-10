## CPS I/O Unix Domain Sockets
##
## Provides Unix domain socket client (UnixStream) and server (UnixListener)
## for local IPC, integrated with the CPS event loop.

when not defined(posix):
  {.error: "Unix domain sockets are only available on POSIX systems".}

import std/[nativesockets, os]
import ../runtime
import ../eventloop
import ../private/platform
import ./streams

const AF_UNIX_C = 1.cint  ## AF_UNIX / AF_LOCAL — same value on Linux and macOS

type
  SockaddrUn {.importc: "struct sockaddr_un", header: "<sys/un.h>".} = object
    sun_family {.importc.}: uint16
    sun_path {.importc.}: array[104, char]  # 104 on macOS, 108 on Linux — importc uses real C size

# ============================================================
# UnixStream - connected Unix socket as AsyncStream
# ============================================================

type
  UnixStream* = ref object of AsyncStream
    fd*: SocketHandle

proc unixStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let us = UnixStream(s)

  # Fast path: try non-blocking recv immediately
  var buf = newString(size)
  let n = recv(us.fd, addr buf[0], size.cint, 0'i32)
  if n > 0:
    buf.setLen(n)
    return completedFuture(buf)
  elif n == 0:
    return completedFuture("")  # EOF

  let firstErr = osLastError()
  if not firstErr.isWouldBlock():
    return failedFuture[string](newException(streams.AsyncIoError,
      "Read failed: " & osErrorMsg(firstErr)))

  # Async path: register for readability, reuse buf across retries
  let fut = newCpsFuture[string]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  proc tryRecv() =
    let n = recv(us.fd, addr buf[0], size.cint, 0'i32)
    if n < 0:
      let err = osLastError()
      if err.isWouldBlock():
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

  loop.registerRead(us.fd, proc() =
    loop.unregister(us.fd)
    tryRecv()
  )
  result = fut

var gSyncWriteCompleted: CpsVoidFuture

proc getSyncWriteCompleted(): CpsVoidFuture {.inline.} =
  if gSyncWriteCompleted.isNil:
    gSyncWriteCompleted = newCpsVoidFuture()
    gSyncWriteCompleted.complete()
  gSyncWriteCompleted

proc unixStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let us = UnixStream(s)
  let totalLen = data.len

  # Fast path: try synchronous send first (common for local IPC)
  var sent = 0
  while sent < totalLen:
    let n = send(us.fd, unsafeAddr data[sent], (totalLen - sent).cint, 0'i32)
    if n < 0:
      let err = osLastError()
      if err.isWouldBlock():
        break  # Need async path
      else:
        return failedVoidFuture(newException(streams.AsyncIoError,
          "Write failed: " & osErrorMsg(err)))
    elif n == 0:
      return failedVoidFuture(newException(streams.ConnectionClosedError,
        "Connection closed during write"))
    else:
      sent += n

  if sent >= totalLen:
    return getSyncWriteCompleted()

  # Async path: need to wait for writability
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  proc trySend() =
    while sent < totalLen:
      let remaining = totalLen - sent
      let n = send(us.fd, unsafeAddr data[sent], remaining.cint, 0'i32)
      if n < 0:
        let err = osLastError()
        if err.isWouldBlock():
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

proc unixStreamReadInto(s: AsyncStream, buf: pointer, size: int): int =
  ## Zero-copy read: recv directly into caller's buffer.
  ## Returns >0 = bytes read, 0 = EOF, -1 = EAGAIN, < -1 = error.
  let us = UnixStream(s)
  let n = recv(us.fd, buf, size.cint, 0'i32)
  if n > 0: return n
  if n == 0: return 0
  let err = osLastError()
  if err.isWouldBlock(): return -1
  return -2

proc unixStreamWaitReadable(s: AsyncStream): CpsVoidFuture =
  ## Wait until the socket is readable (data available or EOF).
  let us = UnixStream(s)
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  try: loop.unregister(us.fd)
  except Exception: discard
  loop.registerRead(us.fd, proc() =
    loop.unregister(us.fd)
    fut.complete()
  )
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
  result.readIntoProc = unixStreamReadInto
  result.waitReadableProc = unixStreamWaitReadable

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
  when defined(macosx) or defined(bsd):
    var nosigpipe: cint = 1
    const SO_NOSIGPIPE_C {.importc: "SO_NOSIGPIPE", header: "<sys/socket.h>".}: cint = 0
    discard setsockopt(fd, SOL_SOCKET.cint, SO_NOSIGPIPE_C,
                       addr nosigpipe, sizeof(nosigpipe).SockLen)

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

  var addr_un = fillSockaddrUn(path)

  let res = connect(fd, cast[ptr SockAddr](addr addr_un), sizeof(addr_un).SockLen)

  if res == 0.cint:
    fdClosed = true
    fut.complete(newUnixStream(fd))
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
        fut.fail(newException(streams.AsyncIoError, "Connection failed: " & $optVal))
      else:
        fdClosed = true
        fut.complete(newUnixStream(fd))
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
  discard unlink(path.cstring)

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
    discard unlink(listener.path.cstring)
