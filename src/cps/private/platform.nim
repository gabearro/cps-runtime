## CPS Platform Abstraction Layer
##
## Cross-platform abstractions for POSIX-specific APIs used throughout the
## CPS runtime. On POSIX (macOS/Linux), these delegate to std/posix. On
## Windows, they use WinSock2 / Win32 equivalents.
##
## Provides:
##   - Error code classification (isWouldBlock, isInProgress, isInterrupted, isEPipe)
##   - Wake pipe creation and signaling (pipe on POSIX, loopback socket pair on Windows)
##   - Socket helpers (inet_pton, inet_ntop, getsockname, getnameinfo, etc.)
##   - Process ID retrieval
##   - System file paths (hosts file, resolv.conf)
##
## On POSIX, this module re-exports std/posix (except close) so that all
## POSIX symbols (Sockaddr_in, inet_pton, EAGAIN, etc.) are available to
## importers. On Windows, equivalent symbols are provided directly.

import std/[nativesockets, os]

when defined(posix):
  import std/posix
  export posix except close
elif defined(windows):
  import std/winlean

# ============================================================
# Error code helpers
# ============================================================

proc isWouldBlock*(err: OSErrorCode): bool {.inline.} =
  ## True if the error indicates a non-blocking operation would block.
  when defined(posix):
    err.int == EAGAIN or err.int == EWOULDBLOCK
  elif defined(windows):
    err.int == 10035  # WSAEWOULDBLOCK
  else:
    false

proc isInProgress*(err: OSErrorCode): bool {.inline.} =
  ## True if the error indicates a connect() is in progress.
  when defined(posix):
    err.int == EINPROGRESS or err.int == EWOULDBLOCK
  elif defined(windows):
    err.int == 10035 or err.int == 10036  # WSAEWOULDBLOCK or WSAEINPROGRESS
  else:
    false

proc isInterrupted*(err: OSErrorCode): bool {.inline.} =
  ## True if the error indicates a syscall was interrupted (EINTR).
  when defined(posix):
    err.int == EINTR
  else:
    false  # Windows doesn't have EINTR for socket operations

proc isEPipe*(err: OSErrorCode): bool {.inline.} =
  ## True if the error indicates a broken pipe / connection reset.
  when defined(posix):
    err.int == EPIPE
  elif defined(windows):
    err.int == 10054  # WSAECONNRESET
  else:
    false

# ============================================================
# Wake pipe abstraction
# ============================================================

when defined(posix):
  proc createWakePipe*(): (SocketHandle, SocketHandle) =
    ## Create a wake pipe for event loop cross-thread signaling.
    ## Returns (readEnd, writeEnd) as SocketHandles.
    var pipeFds: array[2, cint]
    if posix.pipe(pipeFds) != 0:
      raise newException(OSError, "Failed to create wake pipe")
    let readFlags = posix.fcntl(pipeFds[0], F_GETFL, 0)
    discard posix.fcntl(pipeFds[0], F_SETFL, readFlags or O_NONBLOCK)
    let writeFlags = posix.fcntl(pipeFds[1], F_GETFL, 0)
    discard posix.fcntl(pipeFds[1], F_SETFL, writeFlags or O_NONBLOCK)
    result = (SocketHandle(pipeFds[0]), SocketHandle(pipeFds[1]))

  proc wakePipeSignal*(fd: SocketHandle) =
    ## Write 1 byte to the wake pipe to unblock the reactor's select().
    var buf: array[1, byte] = [1'u8]
    while true:
      let n = posix.write(fd.cint, addr buf[0], 1)
      if n == 1:
        return
      let err = osLastError()
      if err.int == EINTR:
        continue
      # Pipe full or other error — reactor is already signaled
      return

  proc wakePipeDrain*(fd: SocketHandle) =
    ## Read all pending bytes from the wake pipe.
    var buf: array[64, byte]
    while posix.read(fd.cint, addr buf[0], 64) > 0:
      discard

  proc closePipeFd*(fd: SocketHandle) =
    ## Close a wake pipe file descriptor.
    discard posix.close(fd.cint)

elif defined(windows):
  proc createWakePipe*(): (SocketHandle, SocketHandle) =
    ## Create a wake "pipe" using a TCP loopback socket pair.
    ## Windows has no pipe() that works with select(); use a connected
    ## TCP socket pair on 127.0.0.1 instead.
    let listener = createNativeSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if listener == osInvalidSocket:
      raise newException(OSError, "Failed to create wake pipe listener")

    var yes: cint = 1
    discard setsockopt(listener, SOL_SOCKET.cint, SO_REUSEADDR.cint,
                       addr yes, sizeof(yes).SockLen)

    var sAddr: Sockaddr_in
    zeroMem(addr sAddr, sizeof(sAddr))
    sAddr.sin_family = AF_INET.TSa_Family
    sAddr.sin_port = 0  # OS assigns port
    sAddr.sin_addr.s_addr = 0x0100007F'u32  # 127.0.0.1 in network byte order

    if bindAddr(listener, cast[ptr SockAddr](addr sAddr),
                sizeof(sAddr).SockLen) != 0:
      listener.close()
      raise newException(OSError, "Failed to bind wake pipe listener")

    if nativesockets.listen(listener, 1) != 0:
      listener.close()
      raise newException(OSError, "Failed to listen on wake pipe")

    # Get the bound port
    var localAddr: Sockaddr_in
    var addrLen: SockLen = sizeof(localAddr).SockLen
    discard getsockname(listener, cast[ptr SockAddr](addr localAddr), addr addrLen)

    let writer = createNativeSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if writer == osInvalidSocket:
      listener.close()
      raise newException(OSError, "Failed to create wake pipe writer")

    var connAddr: Sockaddr_in
    zeroMem(addr connAddr, sizeof(connAddr))
    connAddr.sin_family = AF_INET.TSa_Family
    connAddr.sin_port = localAddr.sin_port
    connAddr.sin_addr.s_addr = 0x0100007F'u32

    if connect(writer, cast[ptr SockAddr](addr connAddr),
               sizeof(connAddr).SockLen) != 0:
      writer.close()
      listener.close()
      raise newException(OSError, "Failed to connect wake pipe")

    var clientAddr: Sockaddr_in
    addrLen = sizeof(clientAddr).SockLen
    let reader = accept(listener, cast[ptr SockAddr](addr clientAddr), addr addrLen)
    listener.close()  # No longer needed

    if reader == osInvalidSocket:
      writer.close()
      raise newException(OSError, "Failed to accept wake pipe connection")

    reader.setBlocking(false)
    writer.setBlocking(false)
    result = (reader, writer)

  proc wakePipeSignal*(fd: SocketHandle) =
    ## Send 1 byte on the wake socket to unblock select().
    var buf: array[1, byte] = [1'u8]
    discard send(fd, addr buf[0], 1, 0'i32)

  proc wakePipeDrain*(fd: SocketHandle) =
    ## Recv all pending bytes from the wake socket.
    var buf: array[64, byte]
    while recv(fd, addr buf[0], 64, 0'i32) > 0:
      discard

  proc closePipeFd*(fd: SocketHandle) =
    ## Close a wake pipe socket handle.
    fd.close()

# ============================================================
# Socket helpers (Windows only — POSIX gets these from std/posix re-export)
# ============================================================

when defined(windows):
  proc inet_pton*(af: cint, src: cstring, dst: pointer): cint
    {.importc: "inet_pton", header: "<ws2tcpip.h>".}

  proc inet_ntop*(af: cint, src: pointer, dst: cstring, size: int32): cstring
    {.importc: "inet_ntop", header: "<ws2tcpip.h>".}

  proc getsockname*(fd: SocketHandle, a: ptr SockAddr, alen: ptr SockLen): cint
    {.importc: "getsockname", header: "<winsock2.h>".}

  proc getnameinfo*(sa: ptr SockAddr, salen: SockLen,
                    host: cstring, hostlen: SockLen,
                    serv: cstring, servlen: SockLen,
                    flags: cint): cint
    {.importc: "getnameinfo", header: "<ws2tcpip.h>".}

  const NI_NUMERICHOST* = 1.cint
  const NI_NUMERICSERV* = 2.cint

  var TCP_NODELAY* {.importc: "TCP_NODELAY", header: "<winsock2.h>".}: cint

# ============================================================
# Process ID
# ============================================================

proc getProcessId*(): int =
  ## Get the current process ID.
  when defined(posix):
    posix.getpid().int
  elif defined(windows):
    proc GetCurrentProcessId(): uint32 {.importc, stdcall, header: "<windows.h>".}
    GetCurrentProcessId().int
  else:
    0

# ============================================================
# File system paths
# ============================================================

proc hostsFilePath*(): string =
  ## Path to the system hosts file.
  when defined(windows):
    r"C:\Windows\System32\drivers\etc\hosts"
  else:
    "/etc/hosts"

proc resolvConfPath*(): string =
  ## Path to the DNS resolver config. Empty on Windows (no resolv.conf).
  when defined(windows):
    ""
  else:
    "/etc/resolv.conf"
