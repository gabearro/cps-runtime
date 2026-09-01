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

import std/[nativesockets, os, strutils]

when defined(posix):
  import std/posix
  export posix except close
elif defined(windows):
  import std/winlean

when defined(linux):
  {.emit: """
  #define _GNU_SOURCE
  #include <sched.h>

  static int cps_allowed_cpu_ids(int *out, int capacity) {
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set) != 0) return 0;
    int count = 0;
    for (int cpu = 0; cpu < CPU_SETSIZE && count < capacity; ++cpu) {
      if (CPU_ISSET(cpu, &set)) out[count++] = cpu;
    }
    return count;
  }

  static int cps_pin_current_thread(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    return sched_setaffinity(0, sizeof(set), &set) == 0;
  }
  """.}

  proc cpsAllowedCpuIds(outIds: ptr cint, capacity: cint): cint
    {.importc: "cps_allowed_cpu_ids", nodecl.}
  proc cpsPinCurrentThread(cpu: cint): cint
    {.importc: "cps_pin_current_thread", nodecl.}

  proc allowedCpuIds*(): seq[int] =
    ## Return the CPUs available to this process's affinity/cgroup mask.
    var ids: array[1024, cint]
    let count = cpsAllowedCpuIds(addr ids[0], ids.len.cint).int
    result = newSeq[int](count)
    for i in 0 ..< count:
      result[i] = ids[i].int

  proc pinCurrentThreadToCpu*(cpu: int): bool =
    ## Pin the calling Linux thread to one allowed logical CPU.
    cpsPinCurrentThread(cpu.cint) != 0

  proc networkRxQueueCount*(): int =
    ## Return the largest receive-queue count exposed by an active interface.
    ## A zero result means queue topology is unavailable and callers should
    ## retain their platform-neutral default.
    try:
      for _, ifacePath in walkDir("/sys/class/net"):
        let statePath = ifacePath / "operstate"
        if fileExists(statePath):
          let state = readFile(statePath).strip()
          if state != "up" and state != "unknown":
            continue
        var queues = 0
        let queuePath = ifacePath / "queues"
        if dirExists(queuePath):
          for _, entry in walkDir(queuePath):
            if extractFilename(entry).startsWith("rx-"):
              inc queues
        result = max(result, queues)
    except OSError:
      result = 0

# ============================================================
# Windows socket error codes
# ============================================================

when defined(windows):
  const
    WSAEWOULDBLOCK* = 10035.cint
    WSAEINPROGRESS* = 10036.cint
    WSAECONNRESET* = 10054.cint

# ============================================================
# Error code helpers
# ============================================================

proc isWouldBlock*(err: OSErrorCode): bool {.inline.} =
  ## True if the error indicates a non-blocking operation would block.
  when defined(posix):
    err.int == EAGAIN or err.int == EWOULDBLOCK
  elif defined(windows):
    err.int == WSAEWOULDBLOCK
  else:
    false

proc isInProgress*(err: OSErrorCode): bool {.inline.} =
  ## True if the error indicates a connect() is in progress.
  ## Includes EWOULDBLOCK/WSAEWOULDBLOCK — some BSD implementations
  ## return it for non-blocking connect().
  when defined(posix):
    err.int == EINPROGRESS or err.int == EWOULDBLOCK
  elif defined(windows):
    err.int == WSAEWOULDBLOCK or err.int == WSAEINPROGRESS
  else:
    false

proc isInterrupted*(err: OSErrorCode): bool {.inline.} =
  ## True if the error indicates a syscall was interrupted (EINTR).
  when defined(posix):
    err.int == EINTR
  else:
    false

proc isEPipe*(err: OSErrorCode): bool {.inline.} =
  ## True if the error indicates a broken pipe / connection reset.
  when defined(posix):
    err.int == EPIPE
  elif defined(windows):
    err.int == WSAECONNRESET
  else:
    false

# ============================================================
# Wake pipe abstraction
# ============================================================

const WakeBufSize = 4096

when defined(posix):
  proc setNonBlocking(fd: cint) {.inline.} =
    let flags = posix.fcntl(fd, F_GETFL, 0)
    discard posix.fcntl(fd, F_SETFL, flags or O_NONBLOCK)

  proc createWakePipe*(): (SocketHandle, SocketHandle) =
    ## Create a wake pipe for event loop cross-thread signaling.
    ## Returns (readEnd, writeEnd) as SocketHandles.
    var pipeFds: array[2, cint]
    if posix.pipe(pipeFds) != 0:
      raise newException(OSError, "Failed to create wake pipe")
    setNonBlocking(pipeFds[0])
    setNonBlocking(pipeFds[1])
    result = (SocketHandle(pipeFds[0]), SocketHandle(pipeFds[1]))

  proc wakePipeSignal*(fd: SocketHandle) =
    ## Write 1 byte to the wake pipe to unblock the reactor's select().
    ## Best-effort: if the pipe is full or closed, the reactor is already
    ## signaled (or shutting down).
    var buf: array[1, byte] = [1'u8]
    while true:
      let n = posix.write(fd.cint, addr buf[0], 1)
      if n == 1: return
      if osLastError().isInterrupted: continue
      return

  proc wakePipeDrain*(fd: SocketHandle) =
    ## Read all pending bytes from the wake pipe.
    var buf: array[WakeBufSize, byte]
    while posix.read(fd.cint, addr buf[0], WakeBufSize) > 0:
      discard

  proc closePipeFd*(fd: SocketHandle) =
    ## Close a wake pipe file descriptor.
    discard posix.close(fd.cint)

elif defined(windows):
  const LoopbackAddr = 0x0100007F'u32  ## 127.0.0.1 in network byte order

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
    sAddr.sin_family = uint16(toInt(AF_INET))
    sAddr.sin_addr.s_addr = LoopbackAddr

    if bindAddr(listener, cast[ptr SockAddr](addr sAddr),
                sizeof(sAddr).SockLen) != 0:
      listener.close()
      raise newException(OSError, "Failed to bind wake pipe listener")

    if nativesockets.listen(listener, 1) != 0:
      listener.close()
      raise newException(OSError, "Failed to listen on wake pipe")

    var localAddr: Sockaddr_in
    var addrLen: SockLen = sizeof(localAddr).SockLen
    if getsockname(listener, cast[ptr SockAddr](addr localAddr), addr addrLen) != 0:
      listener.close()
      raise newException(OSError, "Failed to get wake pipe bound address")

    let writer = createNativeSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if writer == osInvalidSocket:
      listener.close()
      raise newException(OSError, "Failed to create wake pipe writer")

    var connAddr: Sockaddr_in
    zeroMem(addr connAddr, sizeof(connAddr))
    connAddr.sin_family = uint16(toInt(AF_INET))
    connAddr.sin_port = localAddr.sin_port
    connAddr.sin_addr.s_addr = LoopbackAddr

    if connect(writer, cast[ptr SockAddr](addr connAddr),
               sizeof(connAddr).SockLen) != 0:
      writer.close()
      listener.close()
      raise newException(OSError, "Failed to connect wake pipe")

    var clientAddr: Sockaddr_in
    addrLen = sizeof(clientAddr).SockLen
    let reader = accept(listener, cast[ptr SockAddr](addr clientAddr), addr addrLen)
    listener.close()

    if reader == osInvalidSocket:
      writer.close()
      raise newException(OSError, "Failed to accept wake pipe connection")

    # Disable Nagle and set non-blocking for minimal signal latency
    var nodelay: cint = 1
    discard setsockopt(writer, IPPROTO_TCP.cint, TCP_NODELAY,
                       addr nodelay, sizeof(nodelay).SockLen)
    reader.setBlocking(false)
    writer.setBlocking(false)
    result = (reader, writer)

  proc wakePipeSignal*(fd: SocketHandle) =
    ## Send 1 byte on the wake socket to unblock select().
    ## Best-effort: if the buffer is full, the reactor is already signaled.
    var buf: array[1, byte] = [1'u8]
    discard send(fd, addr buf[0], 1, 0'i32)

  proc wakePipeDrain*(fd: SocketHandle) =
    ## Recv all pending bytes from the wake socket.
    var buf: array[WakeBufSize, byte]
    while recv(fd, addr buf[0], WakeBufSize, 0'i32) > 0:
      discard

  proc closePipeFd*(fd: SocketHandle) =
    ## Close a wake pipe socket handle.
    fd.close()

# ============================================================
# Socket helpers (Windows only — POSIX gets these from std/posix re-export)
# ============================================================

when defined(windows):
  ## Parse a presentation-format IP address into its network representation.
  proc inet_pton*(af: cint, src: cstring, dst: pointer): cint
    {.importc: "inet_pton", header: "<ws2tcpip.h>".}

  ## Format a network-format IP address for presentation.
  proc inet_ntop*(af: cint, src: pointer, dst: cstring, size: int32): cstring
    {.importc: "inet_ntop", header: "<ws2tcpip.h>".}

  ## Read the local address bound to a socket.
  proc getsockname*(fd: SocketHandle, a: ptr SockAddr, alen: ptr SockLen): cint
    {.importc: "getsockname", header: "<winsock2.h>".}

  ## Resolve a socket address into numeric host and service strings.
  proc getnameinfo*(sa: ptr SockAddr, salen: SockLen,
                    host: cstring, hostlen: SockLen,
                    serv: cstring, servlen: SockLen,
                    flags: cint): cint
    {.importc: "getnameinfo", header: "<ws2tcpip.h>".}

  const NI_NUMERICHOST* = 1.cint
  const NI_NUMERICSERV* = 2.cint

  var TCP_NODELAY* {.importc: "TCP_NODELAY", header: "<winsock2.h>".}: cint
  var IPV6_V6ONLY* {.importc: "IPV6_V6ONLY", header: "<ws2tcpip.h>".}: cint

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

func hostsFilePath*(): string =
  ## Path to the system hosts file.
  when defined(windows):
    r"C:\Windows\System32\drivers\etc\hosts"
  else:
    "/etc/hosts"

func resolvConfPath*(): string =
  ## Path to the DNS resolver config. Empty on Windows (no resolv.conf).
  when defined(windows):
    ""
  else:
    "/etc/resolv.conf"
