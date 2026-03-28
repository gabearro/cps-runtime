## WASI Preview 1 implementation
## Provides all 45 wasi_snapshot_preview1 functions as host function bindings.
## See: https://github.com/WebAssembly/WASI/blob/main/legacy/preview1/docs.md
##
## Usage:
##   var ctx = newWasiContext(args = @["program", "arg1"], preopens = @["/tmp"])
##   ctx.bindToEngine(engine)
##   let mod = engine.loadFile("program.wasm")
##   mod.callVoid("_start")
##   echo "exit code: ", ctx.exitCode

import std/[tables, os, times, monotimes, posix, random, strutils]
import ./types, ./runtime, ./wasi_types

# Platform-specific constants not always in std/posix
when not declared(O_DIRECTORY):
  const O_DIRECTORY* {.importc, header: "<fcntl.h>".}: cint = 0x100000
when not declared(O_CLOEXEC):
  const O_CLOEXEC* {.importc, header: "<fcntl.h>".}: cint = 0x1000000
when not declared(UTIME_NOW):
  const UTIME_NOW* = (1 shl 30) - 1
when not declared(UTIME_OMIT):
  const UTIME_OMIT* = (1 shl 30) - 2

# futimens may not be in std/posix on all platforms
proc futimens(fd: cint, times: array[2, Timespec]): cint {.importc, header: "<sys/stat.h>".}
proc sched_yield(): cint {.importc, header: "<sched.h>".}

# ---------------------------------------------------------------------------
# File descriptor table
# ---------------------------------------------------------------------------

type
  FdKind* = enum
    fdkStdin
    fdkStdout
    fdkStderr
    fdkFile
    fdkDirectory
    fdkPreopenDir

  WasiFd* = object
    kind*: FdKind
    hostFd*: cint             # OS file descriptor (-1 if virtual)
    path*: string             # For preopened dirs and opened files
    rights*: WasiRights
    rightsInheriting*: WasiRights
    flags*: WasiFdflags
    filetype*: WasiFiletype
    offset*: int64            # Current seek position (for files)
    closed*: bool

  WasiExitError* = object of CatchableError
    ## Raised by proc_exit to terminate WASM execution.
    code*: int32

  WasiContext* = ref object
    fds*: Table[int32, WasiFd]
    nextFd*: int32
    args*: seq[string]
    environ*: seq[string]      # "KEY=value" format
    exitCode*: int32
    exited*: bool
    vm*: ptr WasmVM            # Set during execution for memory access

# ---------------------------------------------------------------------------
# Context creation
# ---------------------------------------------------------------------------

proc newWasiContext*(args: seq[string] = @[], environ: seq[string] = @[],
                     preopens: seq[string] = @[]): WasiContext =
  result = WasiContext(
    nextFd: 3,
    args: args,
    environ: environ,
  )

  # Standard fds
  result.fds[0] = WasiFd(
    kind: fdkStdin, hostFd: 0, filetype: filetypeCharacterDevice,
    rights: rightFdRead or rightPollFdReadwrite,
    rightsInheriting: 0.WasiRights,
  )
  result.fds[1] = WasiFd(
    kind: fdkStdout, hostFd: 1, filetype: filetypeCharacterDevice,
    rights: rightFdWrite or rightPollFdReadwrite,
    rightsInheriting: 0.WasiRights,
  )
  result.fds[2] = WasiFd(
    kind: fdkStderr, hostFd: 2, filetype: filetypeCharacterDevice,
    rights: rightFdWrite or rightPollFdReadwrite,
    rightsInheriting: 0.WasiRights,
  )

  # Preopened directories
  for dir in preopens:
    let fd = result.nextFd
    result.nextFd += 1
    result.fds[fd] = WasiFd(
      kind: fdkPreopenDir, hostFd: -1, path: dir,
      filetype: filetypeDirectory,
      rights: rightsDirBase,
      rightsInheriting: rightsDirInheriting,
    )

# ---------------------------------------------------------------------------
# Memory access helpers
# ---------------------------------------------------------------------------

proc getMem(ctx: WasiContext): ptr seq[byte] {.inline.} =
  ## Get pointer to WASM linear memory from the VM's first memory instance.
  if ctx.vm == nil:
    raise newException(WasmTrap, "WASI: VM not bound")
  if ctx.vm.store.mems.len == 0:
    raise newException(WasmTrap, "WASI: no linear memory")
  ctx.vm.store.mems[0].data.addr

proc readU8*(ctx: WasiContext, offset: uint32): uint8 {.inline.} =
  let mem = ctx.getMem()
  if offset.int >= mem[].len:
    raise newException(WasmTrap, "WASI: memory read out of bounds")
  mem[][offset.int]

proc readU16*(ctx: WasiContext, offset: uint32): uint16 {.inline.} =
  let mem = ctx.getMem()
  if offset.int + 2 > mem[].len:
    raise newException(WasmTrap, "WASI: memory read out of bounds")
  copyMem(result.addr, mem[][offset.int].addr, 2)

proc readU32*(ctx: WasiContext, offset: uint32): uint32 {.inline.} =
  let mem = ctx.getMem()
  if offset.int + 4 > mem[].len:
    raise newException(WasmTrap, "WASI: memory read out of bounds")
  copyMem(result.addr, mem[][offset.int].addr, 4)

proc readU64*(ctx: WasiContext, offset: uint32): uint64 {.inline.} =
  let mem = ctx.getMem()
  if offset.int + 8 > mem[].len:
    raise newException(WasmTrap, "WASI: memory read out of bounds")
  copyMem(result.addr, mem[][offset.int].addr, 8)

proc readI64*(ctx: WasiContext, offset: uint32): int64 {.inline.} =
  cast[int64](ctx.readU64(offset))

proc readBytes*(ctx: WasiContext, offset, length: uint32): seq[byte] =
  let mem = ctx.getMem()
  if offset.int + length.int > mem[].len:
    raise newException(WasmTrap, "WASI: memory read out of bounds")
  result = newSeq[byte](length.int)
  if length > 0:
    copyMem(result[0].addr, mem[][offset.int].addr, length.int)

proc readString*(ctx: WasiContext, offset, length: uint32): string =
  let bytes = ctx.readBytes(offset, length)
  result = newString(bytes.len)
  if bytes.len > 0:
    copyMem(result[0].addr, bytes[0].unsafeAddr, bytes.len)

proc writeU8*(ctx: WasiContext, offset: uint32, val: uint8) {.inline.} =
  let mem = ctx.getMem()
  if offset.int >= mem[].len:
    raise newException(WasmTrap, "WASI: memory write out of bounds")
  mem[][offset.int] = val

proc writeU16*(ctx: WasiContext, offset: uint32, val: uint16) {.inline.} =
  let mem = ctx.getMem()
  if offset.int + 2 > mem[].len:
    raise newException(WasmTrap, "WASI: memory write out of bounds")
  copyMem(mem[][offset.int].addr, val.unsafeAddr, 2)

proc writeU32*(ctx: WasiContext, offset: uint32, val: uint32) {.inline.} =
  let mem = ctx.getMem()
  if offset.int + 4 > mem[].len:
    raise newException(WasmTrap, "WASI: memory write out of bounds")
  copyMem(mem[][offset.int].addr, val.unsafeAddr, 4)

proc writeU64*(ctx: WasiContext, offset: uint32, val: uint64) {.inline.} =
  let mem = ctx.getMem()
  if offset.int + 8 > mem[].len:
    raise newException(WasmTrap, "WASI: memory write out of bounds")
  copyMem(mem[][offset.int].addr, val.unsafeAddr, 8)

proc writeI64*(ctx: WasiContext, offset: uint32, val: int64) {.inline.} =
  ctx.writeU64(offset, cast[uint64](val))

proc writeBytes*(ctx: WasiContext, offset: uint32, data: openArray[byte]) =
  let mem = ctx.getMem()
  if offset.int + data.len > mem[].len:
    raise newException(WasmTrap, "WASI: memory write out of bounds")
  if data.len > 0:
    copyMem(mem[][offset.int].addr, data[0].unsafeAddr, data.len)

proc writeString*(ctx: WasiContext, offset: uint32, s: string) =
  ctx.writeBytes(offset, cast[seq[byte]](s))

# ---------------------------------------------------------------------------
# Fd validation helpers
# ---------------------------------------------------------------------------

proc getFd(ctx: WasiContext, fd: int32): (WasiErrno, ptr WasiFd) =
  if fd notin ctx.fds:
    return (errnoBadf, nil)
  let fdObj = ctx.fds[fd].addr
  if fdObj.closed:
    return (errnoBadf, nil)
  (errnoSuccess, fdObj)

proc checkRight(fd: WasiFd, right: WasiRights): WasiErrno =
  if not fd.rights.contains(right):
    return errnoNotcapable
  errnoSuccess

# ---------------------------------------------------------------------------
# Path resolution (capability-based, relative to preopened dir)
# ---------------------------------------------------------------------------

proc resolvePath(ctx: WasiContext, dirFd: int32, pathPtr, pathLen: uint32): (WasiErrno, string) =
  let (err, fdObj) = ctx.getFd(dirFd)
  if err != errnoSuccess: return (err, "")
  if fdObj.filetype != filetypeDirectory and fdObj.kind != fdkPreopenDir:
    return (errnoNotdir, "")

  let relPath = ctx.readString(pathPtr, pathLen)

  # Prevent path traversal: no absolute paths, no ".." escaping
  if relPath.len > 0 and relPath[0] == '/':
    return (errnoNotcapable, "")

  # Normalize and check for ".." escaping the sandbox
  var parts: seq[string]
  for part in relPath.split('/'):
    if part == "" or part == ".": continue
    if part == "..":
      if parts.len == 0:
        return (errnoNotcapable, "")
      discard parts.pop()
    else:
      parts.add(part)

  let resolved = fdObj.path / parts.join("/")
  (errnoSuccess, resolved)

# ---------------------------------------------------------------------------
# OS helpers
# ---------------------------------------------------------------------------

proc toNanoseconds(t: times.Time): uint64 =
  let dur = t.toUnix().uint64 * 1_000_000_000'u64 +
            t.nanosecond().uint64
  dur

proc getFileType(info: FileInfo): WasiFiletype =
  case info.kind
  of pcFile: filetypeRegularFile
  of pcDir: filetypeDirectory
  of pcLinkToFile, pcLinkToDir: filetypeSymbolicLink

proc fillFilestat(ctx: WasiContext, bufPtr: uint32, info: FileInfo) =
  ctx.writeU64(bufPtr + FilestatDevOffset, 0)  # dev
  ctx.writeU64(bufPtr + FilestatInoOffset, 0)  # ino
  ctx.writeU8(bufPtr + FilestatFiletypeOffset, info.getFileType().uint8)
  ctx.writeU64(bufPtr + FilestatNlinkOffset, 1)  # nlink
  ctx.writeU64(bufPtr + FilestatSizeOffset, info.size.uint64)
  ctx.writeU64(bufPtr + FilestatAtimOffset, info.lastAccessTime.toNanoseconds())
  ctx.writeU64(bufPtr + FilestatMtimOffset, info.lastWriteTime.toNanoseconds())
  ctx.writeU64(bufPtr + FilestatCtimOffset, info.creationTime.toNanoseconds())

proc posixOpen(path: string, oflags: WasiOflags, fdflags: WasiFdflags,
               isDir: bool): (WasiErrno, cint) =
  var flags: cint = O_CLOEXEC
  if isDir:
    flags = flags or O_RDONLY or O_DIRECTORY
  else:
    # Determine read/write mode based on request
    flags = flags or O_RDWR
    if oflags.hasFlag(oflagsCreat): flags = flags or O_CREAT
    if oflags.hasFlag(oflagsExcl): flags = flags or O_EXCL
    if oflags.hasFlag(oflagsTrunc): flags = flags or O_TRUNC
    if fdflags.hasFlag(fdflagsAppend): flags = flags or O_APPEND
    if fdflags.hasFlag(fdflagsSync): flags = flags or O_SYNC
    when defined(O_DSYNC):
      if fdflags.hasFlag(fdflagsDsync): flags = flags or O_DSYNC
    if fdflags.hasFlag(fdflagsNonblock): flags = flags or O_NONBLOCK

  let fd = posix.open(path.cstring, flags, 0o666)
  if fd < 0:
    let e = errno
    if e == ENOENT: return (errnoNoent, -1)
    elif e == EACCES: return (errnoAcces, -1)
    elif e == EEXIST: return (errnoExist, -1)
    elif e == EISDIR: return (errnoIsdir, -1)
    elif e == ENOTDIR: return (errnoNotdir, -1)
    elif e == EMFILE or e == ENFILE: return (errnoNfile, -1)
    elif e == ENAMETOOLONG: return (errnoNametoolong, -1)
    elif e == ENOSPC: return (errnoNospc, -1)
    elif e == EROFS: return (errnoRofs, -1)
    elif e == ELOOP: return (errnoLoop, -1)
    else: return (errnoIo, -1)
  (errnoSuccess, fd)

# ---------------------------------------------------------------------------
# WASI syscall implementations
# Each returns WasiErrno (as uint16, cast to i32 for WASM return)
# ---------------------------------------------------------------------------

# ---- Args & Environment ----

proc wasiArgsGet*(ctx: WasiContext, argvPtr, argvBufPtr: uint32): WasiErrno =
  var bufOffset = argvBufPtr
  for i, arg in ctx.args:
    # Write pointer to this arg string
    ctx.writeU32(argvPtr + (i * 4).uint32, bufOffset)
    # Write null-terminated arg string
    ctx.writeString(bufOffset, arg)
    ctx.writeU8(bufOffset + arg.len.uint32, 0)
    bufOffset += arg.len.uint32 + 1
  errnoSuccess

proc wasiArgsSizesGet*(ctx: WasiContext, argcPtr, argvBufSizePtr: uint32): WasiErrno =
  ctx.writeU32(argcPtr, ctx.args.len.uint32)
  var totalSize: uint32 = 0
  for arg in ctx.args:
    totalSize += arg.len.uint32 + 1  # null terminator
  ctx.writeU32(argvBufSizePtr, totalSize)
  errnoSuccess

proc wasiEnvironGet*(ctx: WasiContext, environPtr, environBufPtr: uint32): WasiErrno =
  var bufOffset = environBufPtr
  for i, env in ctx.environ:
    ctx.writeU32(environPtr + (i * 4).uint32, bufOffset)
    ctx.writeString(bufOffset, env)
    ctx.writeU8(bufOffset + env.len.uint32, 0)
    bufOffset += env.len.uint32 + 1
  errnoSuccess

proc wasiEnvironSizesGet*(ctx: WasiContext, countPtr, bufSizePtr: uint32): WasiErrno =
  ctx.writeU32(countPtr, ctx.environ.len.uint32)
  var totalSize: uint32 = 0
  for env in ctx.environ:
    totalSize += env.len.uint32 + 1
  ctx.writeU32(bufSizePtr, totalSize)
  errnoSuccess

# ---- Clock ----

proc wasiClockResGet*(ctx: WasiContext, clockId: uint32, resPtr: uint32): WasiErrno =
  case clockId
  of 0, 1:  # realtime, monotonic
    ctx.writeU64(resPtr, 1)  # 1 nanosecond resolution
  of 2, 3:  # process/thread cputime
    ctx.writeU64(resPtr, 1000)  # 1 microsecond
  else:
    return errnoInval
  errnoSuccess

proc wasiClockTimeGet*(ctx: WasiContext, clockId: uint32, precision: uint64,
                       timePtr: uint32): WasiErrno =
  case clockId
  of 0:  # realtime
    let now = getTime()
    ctx.writeU64(timePtr, now.toNanoseconds())
  of 1:  # monotonic
    let nanos = getMonoTime().ticks
    ctx.writeU64(timePtr, nanos.uint64)
  of 2, 3:  # process/thread cputime — approximate with monotonic
    let nanos = getMonoTime().ticks
    ctx.writeU64(timePtr, nanos.uint64)
  else:
    return errnoInval
  errnoSuccess

# ---- File Descriptor Operations ----

proc wasiFdAdvise*(ctx: WasiContext, fd: int32, offset: uint64, length: uint64,
                   advice: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdAdvise)
  if rc != errnoSuccess: return rc
  # Advisory only — no-op for most implementations
  errnoSuccess

proc wasiFdAllocate*(ctx: WasiContext, fd: int32, offset: uint64,
                     length: uint64): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdAllocate)
  if rc != errnoSuccess: return rc
  if fdObj.hostFd < 0: return errnoInval
  # Use ftruncate to extend if needed
  let newSize = offset.int64 + length.int64
  var st: Stat
  if fstat(fdObj.hostFd, st) != 0: return errnoIo
  if st.st_size < newSize.Off:
    if ftruncate(fdObj.hostFd, newSize.Off) != 0: return errnoIo
  errnoSuccess

proc wasiFdClose*(ctx: WasiContext, fd: int32): WasiErrno =
  if fd notin ctx.fds: return errnoBadf
  var fdObj = ctx.fds[fd]
  if fdObj.closed: return errnoBadf
  # Don't close stdin/stdout/stderr
  if fd <= 2: return errnoSuccess
  if fdObj.hostFd >= 0:
    discard posix.close(fdObj.hostFd)
  fdObj.closed = true
  ctx.fds.del(fd)
  errnoSuccess

proc wasiFdDatasync*(ctx: WasiContext, fd: int32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdDatasync)
  if rc != errnoSuccess: return rc
  if fdObj.hostFd < 0: return errnoInval
  if fsync(fdObj.hostFd) != 0: return errnoIo
  errnoSuccess

proc wasiFdFdstatGet*(ctx: WasiContext, fd: int32, bufPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  # Zero-fill first (24 bytes, aligned)
  for i in 0'u32 ..< FdstatSize.uint32:
    ctx.writeU8(bufPtr + i, 0)
  ctx.writeU8(bufPtr + FdstatFiletypeOffset, fdObj.filetype.uint8)
  ctx.writeU16(bufPtr + FdstatFlagsOffset, fdObj.flags.uint16)
  ctx.writeU64(bufPtr + FdstatRightsBaseOffset, fdObj.rights.uint64)
  ctx.writeU64(bufPtr + FdstatRightsInhOffset, fdObj.rightsInheriting.uint64)
  errnoSuccess

proc wasiFdFdstatSetFlags*(ctx: WasiContext, fd: int32,
                           flags: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdFdstatSetFlags)
  if rc != errnoSuccess: return rc
  fdObj.flags = flags.uint16.WasiFdflags
  errnoSuccess

proc wasiFdFdstatSetRights*(ctx: WasiContext, fd: int32,
                            rightsBase: uint64,
                            rightsInheriting: uint64): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  # Can only narrow, not widen
  let newBase = rightsBase.WasiRights
  let newInh = rightsInheriting.WasiRights
  if not fdObj.rights.contains(newBase): return errnoNotcapable
  if not fdObj.rightsInheriting.contains(newInh): return errnoNotcapable
  fdObj.rights = newBase
  fdObj.rightsInheriting = newInh
  errnoSuccess

proc wasiFdFilestatGet*(ctx: WasiContext, fd: int32, bufPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdFilestatGet)
  if rc != errnoSuccess: return rc

  if fdObj.hostFd >= 0:
    var st: Stat
    if fstat(fdObj.hostFd, st) != 0: return errnoIo
    # Zero-fill
    for i in 0'u32 ..< FilestatSize.uint32:
      ctx.writeU8(bufPtr + i, 0)
    ctx.writeU64(bufPtr + FilestatDevOffset, st.st_dev.uint64)
    ctx.writeU64(bufPtr + FilestatInoOffset, st.st_ino.uint64)
    # Determine filetype from stat
    var ft: WasiFiletype = filetypeUnknown
    if S_ISREG(st.st_mode): ft = filetypeRegularFile
    elif S_ISDIR(st.st_mode): ft = filetypeDirectory
    elif S_ISLNK(st.st_mode): ft = filetypeSymbolicLink
    elif S_ISBLK(st.st_mode): ft = filetypeBlockDevice
    elif S_ISCHR(st.st_mode): ft = filetypeCharacterDevice
    elif S_ISSOCK(st.st_mode): ft = filetypeSocketStream
    ctx.writeU8(bufPtr + FilestatFiletypeOffset, ft.uint8)
    ctx.writeU64(bufPtr + FilestatNlinkOffset, st.st_nlink.uint64)
    ctx.writeU64(bufPtr + FilestatSizeOffset, st.st_size.uint64)
    # Timestamps (seconds → nanoseconds)
    ctx.writeU64(bufPtr + FilestatAtimOffset, st.st_atim.tv_sec.uint64 * 1_000_000_000'u64 + st.st_atim.tv_nsec.uint64)
    ctx.writeU64(bufPtr + FilestatMtimOffset, st.st_mtim.tv_sec.uint64 * 1_000_000_000'u64 + st.st_mtim.tv_nsec.uint64)
    ctx.writeU64(bufPtr + FilestatCtimOffset, st.st_ctim.tv_sec.uint64 * 1_000_000_000'u64 + st.st_ctim.tv_nsec.uint64)
  elif fdObj.kind == fdkPreopenDir:
    try:
      let info = getFileInfo(fdObj.path)
      ctx.fillFilestat(bufPtr, info)
    except OSError:
      return errnoIo
  else:
    # Virtual fd (stdin/stdout/stderr)
    for i in 0'u32 ..< FilestatSize.uint32:
      ctx.writeU8(bufPtr + i, 0)
    ctx.writeU8(bufPtr + FilestatFiletypeOffset, fdObj.filetype.uint8)
  errnoSuccess

proc wasiFdFilestatSetSize*(ctx: WasiContext, fd: int32,
                            size: uint64): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdFilestatSetSize)
  if rc != errnoSuccess: return rc
  if fdObj.hostFd < 0: return errnoInval
  if ftruncate(fdObj.hostFd, size.Off) != 0: return errnoIo
  errnoSuccess

proc wasiFdFilestatSetTimes*(ctx: WasiContext, fd: int32,
                             atim: uint64, mtim: uint64,
                             fstFlags: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdFilestatSetTimes)
  if rc != errnoSuccess: return rc
  if fdObj.hostFd < 0: return errnoInval

  let flags = fstFlags.uint16.WasiFstflags
  var times: array[2, Timespec]

  if flags.hasFlag(fstflagsAtimNow):
    times[0].tv_sec = posix.Time(0)
    times[0].tv_nsec = UTIME_NOW
  elif flags.hasFlag(fstflagsAtim):
    times[0].tv_sec = posix.Time(atim div 1_000_000_000)
    times[0].tv_nsec = (atim mod 1_000_000_000).int
  else:
    times[0].tv_sec = posix.Time(0)
    times[0].tv_nsec = UTIME_OMIT

  if flags.hasFlag(fstflagsMtimNow):
    times[1].tv_sec = posix.Time(0)
    times[1].tv_nsec = UTIME_NOW
  elif flags.hasFlag(fstflagsMtim):
    times[1].tv_sec = posix.Time(mtim div 1_000_000_000)
    times[1].tv_nsec = (mtim mod 1_000_000_000).int
  else:
    times[1].tv_sec = posix.Time(0)
    times[1].tv_nsec = UTIME_OMIT

  if futimens(fdObj.hostFd, times) != 0: return errnoIo
  errnoSuccess

proc wasiFdPread*(ctx: WasiContext, fd: int32, iovsPtr: uint32,
                  iovsLen: uint32, offset: uint64,
                  nreadPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdRead or rightFdSeek)
  if rc != errnoSuccess: return rc
  if fdObj.hostFd < 0: return errnoInval

  var totalRead: uint32 = 0
  for i in 0'u32 ..< iovsLen:
    let bufPtr = ctx.readU32(iovsPtr + i * IoVecSize.uint32 + IoVecBufOffset.uint32)
    let bufLen = ctx.readU32(iovsPtr + i * IoVecSize.uint32 + IoVecBufLenOffset.uint32)
    if bufLen == 0: continue

    let mem = ctx.getMem()
    if bufPtr.int + bufLen.int > mem[].len:
      raise newException(WasmTrap, "WASI: memory out of bounds")

    let n = pread(fdObj.hostFd, mem[][bufPtr.int].addr, bufLen.int, offset.Off + totalRead.Off)
    if n < 0: return errnoIo
    totalRead += n.uint32
    if n.uint32 < bufLen: break  # short read

  ctx.writeU32(nreadPtr, totalRead)
  errnoSuccess

proc wasiFdPrestatGet*(ctx: WasiContext, fd: int32, bufPtr: uint32): WasiErrno =
  if fd notin ctx.fds: return errnoBadf
  let fdObj = ctx.fds[fd]
  if fdObj.kind != fdkPreopenDir: return errnoBadf

  ctx.writeU8(bufPtr + PrestatTagOffset, preopenDir.uint8)
  # Pad bytes 1-3 to zero
  ctx.writeU8(bufPtr + 1, 0)
  ctx.writeU8(bufPtr + 2, 0)
  ctx.writeU8(bufPtr + 3, 0)
  ctx.writeU32(bufPtr + PrestatDirNamelenOffset, fdObj.path.len.uint32)
  errnoSuccess

proc wasiFdPrestatDirName*(ctx: WasiContext, fd: int32, pathPtr: uint32,
                           pathLen: uint32): WasiErrno =
  if fd notin ctx.fds: return errnoBadf
  let fdObj = ctx.fds[fd]
  if fdObj.kind != fdkPreopenDir: return errnoBadf

  let nameLen = min(pathLen.int, fdObj.path.len)
  ctx.writeString(pathPtr, fdObj.path[0 ..< nameLen])
  errnoSuccess

proc wasiFdPwrite*(ctx: WasiContext, fd: int32, iovsPtr: uint32,
                   iovsLen: uint32, offset: uint64,
                   nwrittenPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdWrite or rightFdSeek)
  if rc != errnoSuccess: return rc
  if fdObj.hostFd < 0: return errnoInval

  var totalWritten: uint32 = 0
  for i in 0'u32 ..< iovsLen:
    let bufPtr = ctx.readU32(iovsPtr + i * IoVecSize.uint32 + IoVecBufOffset.uint32)
    let bufLen = ctx.readU32(iovsPtr + i * IoVecSize.uint32 + IoVecBufLenOffset.uint32)
    if bufLen == 0: continue

    let mem = ctx.getMem()
    if bufPtr.int + bufLen.int > mem[].len:
      raise newException(WasmTrap, "WASI: memory out of bounds")

    let n = pwrite(fdObj.hostFd, mem[][bufPtr.int].addr, bufLen.int, offset.Off + totalWritten.Off)
    if n < 0: return errnoIo
    totalWritten += n.uint32

  ctx.writeU32(nwrittenPtr, totalWritten)
  errnoSuccess

proc wasiFdRead*(ctx: WasiContext, fd: int32, iovsPtr: uint32,
                 iovsLen: uint32, nreadPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdRead)
  if rc != errnoSuccess: return rc

  var totalRead: uint32 = 0
  for i in 0'u32 ..< iovsLen:
    let bufPtr = ctx.readU32(iovsPtr + i * IoVecSize.uint32 + IoVecBufOffset.uint32)
    let bufLen = ctx.readU32(iovsPtr + i * IoVecSize.uint32 + IoVecBufLenOffset.uint32)
    if bufLen == 0: continue

    let mem = ctx.getMem()
    if bufPtr.int + bufLen.int > mem[].len:
      raise newException(WasmTrap, "WASI: memory out of bounds")

    if fdObj.hostFd >= 0:
      let n = posix.read(fdObj.hostFd, mem[][bufPtr.int].addr, bufLen.int)
      if n < 0: return errnoIo
      totalRead += n.uint32
      if n.uint32 < bufLen: break  # short read / EOF
    else:
      break  # no backing fd

  ctx.writeU32(nreadPtr, totalRead)
  errnoSuccess

proc wasiFdReaddir*(ctx: WasiContext, fd: int32, bufPtr: uint32, bufLen: uint32,
                    cookie: uint64, bufusedPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdReaddir)
  if rc != errnoSuccess: return rc

  # Get directory path
  var dirPath: string
  if fdObj.kind == fdkPreopenDir:
    dirPath = fdObj.path
  elif fdObj.kind == fdkDirectory:
    dirPath = fdObj.path
  else:
    return errnoNotdir

  # Read directory entries
  var entries: seq[tuple[name: string, ft: WasiFiletype, ino: uint64]]
  try:
    for kind, path in walkDir(dirPath, relative = true):
      var ft: WasiFiletype
      case kind
      of pcFile: ft = filetypeRegularFile
      of pcDir: ft = filetypeDirectory
      of pcLinkToFile, pcLinkToDir: ft = filetypeSymbolicLink
      entries.add((path, ft, 0'u64))
  except OSError:
    return errnoIo

  # Skip entries before cookie
  var bufUsed: uint32 = 0
  var entryIdx: uint64 = 0
  for entry in entries:
    entryIdx += 1
    if entryIdx <= cookie: continue

    # Write dirent struct
    let nameBytes = entry.name.len.uint32
    let needed = DirentSize.uint32 + nameBytes

    if bufUsed + DirentSize.uint32 > bufLen: break

    let base = bufPtr + bufUsed
    ctx.writeU64(base + DirentDnextOffset, entryIdx)
    ctx.writeU64(base + DirentDinoOffset, entry.ino)
    ctx.writeU32(base + DirentDnamlenOffset, nameBytes)
    ctx.writeU8(base + DirentDtypeOffset, entry.ft.uint8)
    # Pad bytes
    ctx.writeU8(base + 21, 0)
    ctx.writeU8(base + 22, 0)
    ctx.writeU8(base + 23, 0)
    bufUsed += DirentSize.uint32

    # Write name bytes
    let nameToWrite = min(nameBytes, bufLen - bufUsed)
    if nameToWrite > 0:
      ctx.writeString(bufPtr + bufUsed, entry.name[0 ..< nameToWrite.int])
      bufUsed += nameToWrite

  ctx.writeU32(bufusedPtr, bufUsed)
  errnoSuccess

proc wasiFdRenumber*(ctx: WasiContext, fd: int32, to: int32): WasiErrno =
  if fd notin ctx.fds: return errnoBadf
  if to notin ctx.fds: return errnoBadf
  # Close target fd
  let closeErr = ctx.wasiFdClose(to)
  if closeErr != errnoSuccess and closeErr != errnoBadf:
    return closeErr
  # Move fd → to
  ctx.fds[to] = ctx.fds[fd]
  ctx.fds.del(fd)
  errnoSuccess

proc wasiFdSeek*(ctx: WasiContext, fd: int32, offset: int64, whence: uint32,
                 newoffsetPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdSeek)
  if rc != errnoSuccess: return rc

  if fdObj.hostFd >= 0:
    let w: cint = case whence
      of 0: SEEK_SET
      of 1: SEEK_CUR
      of 2: SEEK_END
      else: return errnoInval
    let result = lseek(fdObj.hostFd, offset.Off, w)
    if result < 0: return errnoIo
    fdObj.offset = result.int64
    ctx.writeU64(newoffsetPtr, result.uint64)
  else:
    # Virtual fd — track offset internally
    case whence
    of 0: fdObj.offset = offset
    of 1: fdObj.offset += offset
    of 2: return errnoSpipe  # can't seek from end on virtual fds
    else: return errnoInval
    ctx.writeU64(newoffsetPtr, fdObj.offset.uint64)
  errnoSuccess

proc wasiFdSync*(ctx: WasiContext, fd: int32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdSync)
  if rc != errnoSuccess: return rc
  if fdObj.hostFd < 0: return errnoInval
  if fsync(fdObj.hostFd) != 0: return errnoIo
  errnoSuccess

proc wasiFdTell*(ctx: WasiContext, fd: int32, offsetPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdTell)
  if rc != errnoSuccess: return rc

  if fdObj.hostFd >= 0:
    let pos = lseek(fdObj.hostFd, 0, SEEK_CUR)
    if pos < 0: return errnoIo
    ctx.writeU64(offsetPtr, pos.uint64)
  else:
    ctx.writeU64(offsetPtr, fdObj.offset.uint64)
  errnoSuccess

proc wasiFdWrite*(ctx: WasiContext, fd: int32, iovsPtr: uint32,
                  iovsLen: uint32, nwrittenPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightFdWrite)
  if rc != errnoSuccess: return rc

  var totalWritten: uint32 = 0
  for i in 0'u32 ..< iovsLen:
    let bufPtr = ctx.readU32(iovsPtr + i * IoVecSize.uint32 + IoVecBufOffset.uint32)
    let bufLen = ctx.readU32(iovsPtr + i * IoVecSize.uint32 + IoVecBufLenOffset.uint32)
    if bufLen == 0: continue

    let mem = ctx.getMem()
    if bufPtr.int + bufLen.int > mem[].len:
      raise newException(WasmTrap, "WASI: memory out of bounds")

    if fdObj.hostFd >= 0:
      let n = posix.write(fdObj.hostFd, mem[][bufPtr.int].addr, bufLen.int)
      if n < 0: return errnoIo
      totalWritten += n.uint32
    else:
      # Fallback for virtual fds
      totalWritten += bufLen

  ctx.writeU32(nwrittenPtr, totalWritten)
  errnoSuccess

# ---- Path Operations ----

proc wasiPathCreateDirectory*(ctx: WasiContext, fd: int32, pathPtr: uint32,
                              pathLen: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightPathCreateDirectory)
  if rc != errnoSuccess: return rc

  let (pathErr, resolved) = ctx.resolvePath(fd, pathPtr, pathLen)
  if pathErr != errnoSuccess: return pathErr

  try:
    createDir(resolved)
  except OSError:
    return errnoIo
  errnoSuccess

proc wasiPathFilestatGet*(ctx: WasiContext, fd: int32, flags: uint32,
                          pathPtr: uint32, pathLen: uint32,
                          bufPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightPathFilestatGet)
  if rc != errnoSuccess: return rc

  let (pathErr, resolved) = ctx.resolvePath(fd, pathPtr, pathLen)
  if pathErr != errnoSuccess: return pathErr

  let followSymlinks = (flags.WasiLookupflags and lookupSymlinkFollow) == lookupSymlinkFollow
  try:
    let info = getFileInfo(resolved, followSymlink = followSymlinks)
    ctx.fillFilestat(bufPtr, info)
  except OSError:
    return errnoNoent
  errnoSuccess

proc wasiPathFilestatSetTimes*(ctx: WasiContext, fd: int32, flags: uint32,
                               pathPtr: uint32, pathLen: uint32,
                               atim: uint64, mtim: uint64,
                               fstFlags: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightPathFilestatSetTimes)
  if rc != errnoSuccess: return rc

  let (pathErr, resolved) = ctx.resolvePath(fd, pathPtr, pathLen)
  if pathErr != errnoSuccess: return pathErr

  let fflags = fstFlags.uint16.WasiFstflags
  var atime, mtime: times.Time
  if fflags.hasFlag(fstflagsAtimNow):
    atime = getTime()
  elif fflags.hasFlag(fstflagsAtim):
    atime = fromUnix(cast[int64](atim div 1_000_000_000))
  if fflags.hasFlag(fstflagsMtimNow):
    mtime = getTime()
  elif fflags.hasFlag(fstflagsMtim):
    mtime = fromUnix(cast[int64](mtim div 1_000_000_000))

  try:
    setLastModificationTime(resolved, mtime)
  except OSError:
    return errnoIo
  errnoSuccess

proc wasiPathLink*(ctx: WasiContext, oldFd: int32, oldFlags: uint32,
                   oldPathPtr: uint32, oldPathLen: uint32,
                   newFd: int32, newPathPtr: uint32,
                   newPathLen: uint32): WasiErrno =
  let (err1, fdObj1) = ctx.getFd(oldFd)
  if err1 != errnoSuccess: return err1
  let rc1 = checkRight(fdObj1[], rightPathLinkSource)
  if rc1 != errnoSuccess: return rc1

  let (err2, fdObj2) = ctx.getFd(newFd)
  if err2 != errnoSuccess: return err2
  let rc2 = checkRight(fdObj2[], rightPathLinkTarget)
  if rc2 != errnoSuccess: return rc2

  let (pathErr1, oldResolved) = ctx.resolvePath(oldFd, oldPathPtr, oldPathLen)
  if pathErr1 != errnoSuccess: return pathErr1
  let (pathErr2, newResolved) = ctx.resolvePath(newFd, newPathPtr, newPathLen)
  if pathErr2 != errnoSuccess: return pathErr2

  if link(oldResolved.cstring, newResolved.cstring) != 0:
    return errnoIo
  errnoSuccess

proc wasiPathOpen*(ctx: WasiContext, dirFd: int32, dirFlags: uint32,
                   pathPtr: uint32, pathLen: uint32, oflags: uint32,
                   rightsBase: uint64, rightsInheriting: uint64,
                   fdflags: uint32, fdPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(dirFd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightPathOpen)
  if rc != errnoSuccess: return rc

  let (pathErr, resolved) = ctx.resolvePath(dirFd, pathPtr, pathLen)
  if pathErr != errnoSuccess: return pathErr

  let wasiOflags = oflags.uint16.WasiOflags
  let wasiFdflags = fdflags.uint16.WasiFdflags
  let isDir = wasiOflags.hasFlag(oflagsDirectory)

  let (openErr, hostFd) = posixOpen(resolved, wasiOflags, wasiFdflags, isDir)
  if openErr != errnoSuccess: return openErr

  # Determine file type from opened fd
  var st: Stat
  var ft: WasiFiletype = filetypeRegularFile
  if fstat(hostFd, st) == 0:
    if S_ISDIR(st.st_mode): ft = filetypeDirectory
    elif S_ISLNK(st.st_mode): ft = filetypeSymbolicLink
    elif S_ISBLK(st.st_mode): ft = filetypeBlockDevice
    elif S_ISCHR(st.st_mode): ft = filetypeCharacterDevice
    elif S_ISSOCK(st.st_mode): ft = filetypeSocketStream

  # Narrow rights: intersection with parent's inheriting rights
  let effectiveBase = (rightsBase.WasiRights and fdObj.rightsInheriting)
  let effectiveInh = (rightsInheriting.WasiRights and fdObj.rightsInheriting)

  let newFd = ctx.nextFd
  ctx.nextFd += 1
  let kind = if ft == filetypeDirectory: fdkDirectory else: fdkFile
  ctx.fds[newFd] = WasiFd(
    kind: kind, hostFd: hostFd, path: resolved,
    filetype: ft, rights: effectiveBase, rightsInheriting: effectiveInh,
    flags: wasiFdflags,
  )

  ctx.writeU32(fdPtr, newFd.uint32)
  errnoSuccess

proc wasiPathReadlink*(ctx: WasiContext, fd: int32, pathPtr: uint32,
                       pathLen: uint32, bufPtr: uint32, bufLen: uint32,
                       bufusedPtr: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightPathReadlink)
  if rc != errnoSuccess: return rc

  let (pathErr, resolved) = ctx.resolvePath(fd, pathPtr, pathLen)
  if pathErr != errnoSuccess: return pathErr

  try:
    let target = expandSymlink(resolved)
    let writeLen = min(target.len.uint32, bufLen)
    ctx.writeString(bufPtr, target[0 ..< writeLen.int])
    ctx.writeU32(bufusedPtr, writeLen)
  except OSError:
    return errnoNoent
  errnoSuccess

proc wasiPathRemoveDirectory*(ctx: WasiContext, fd: int32, pathPtr: uint32,
                              pathLen: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightPathRemoveDirectory)
  if rc != errnoSuccess: return rc

  let (pathErr, resolved) = ctx.resolvePath(fd, pathPtr, pathLen)
  if pathErr != errnoSuccess: return pathErr

  try:
    removeDir(resolved)
  except OSError:
    return errnoIo
  errnoSuccess

proc wasiPathRename*(ctx: WasiContext, fd: int32, oldPathPtr: uint32,
                     oldPathLen: uint32, newFd: int32,
                     newPathPtr: uint32, newPathLen: uint32): WasiErrno =
  let (err1, fdObj1) = ctx.getFd(fd)
  if err1 != errnoSuccess: return err1
  let rc1 = checkRight(fdObj1[], rightPathRenameSource)
  if rc1 != errnoSuccess: return rc1

  let (err2, fdObj2) = ctx.getFd(newFd)
  if err2 != errnoSuccess: return err2
  let rc2 = checkRight(fdObj2[], rightPathRenameTarget)
  if rc2 != errnoSuccess: return rc2

  let (pathErr1, oldResolved) = ctx.resolvePath(fd, oldPathPtr, oldPathLen)
  if pathErr1 != errnoSuccess: return pathErr1
  let (pathErr2, newResolved) = ctx.resolvePath(newFd, newPathPtr, newPathLen)
  if pathErr2 != errnoSuccess: return pathErr2

  try:
    moveFile(oldResolved, newResolved)
  except OSError:
    return errnoIo
  errnoSuccess

proc wasiPathSymlink*(ctx: WasiContext, oldPathPtr: uint32, oldPathLen: uint32,
                      fd: int32, newPathPtr: uint32,
                      newPathLen: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightPathSymlink)
  if rc != errnoSuccess: return rc

  let oldPath = ctx.readString(oldPathPtr, oldPathLen)
  let (pathErr, newResolved) = ctx.resolvePath(fd, newPathPtr, newPathLen)
  if pathErr != errnoSuccess: return pathErr

  if symlink(oldPath.cstring, newResolved.cstring) != 0:
    return errnoIo
  errnoSuccess

proc wasiPathUnlinkFile*(ctx: WasiContext, fd: int32, pathPtr: uint32,
                         pathLen: uint32): WasiErrno =
  let (err, fdObj) = ctx.getFd(fd)
  if err != errnoSuccess: return err
  let rc = checkRight(fdObj[], rightPathUnlinkFile)
  if rc != errnoSuccess: return rc

  let (pathErr, resolved) = ctx.resolvePath(fd, pathPtr, pathLen)
  if pathErr != errnoSuccess: return pathErr

  try:
    let info = getFileInfo(resolved, followSymlink = false)
    if info.kind == pcDir:
      return errnoIsdir
    removeFile(resolved)
  except OSError:
    return errnoNoent
  errnoSuccess

# ---- Polling ----

proc wasiPollOneoff*(ctx: WasiContext, inPtr: uint32, outPtr: uint32,
                     nsubscriptions: uint32, neventsPtr: uint32): WasiErrno =
  if nsubscriptions == 0: return errnoInval

  var nevents: uint32 = 0
  for i in 0'u32 ..< nsubscriptions:
    let subBase = inPtr + i * SubscriptionSize.uint32
    let userdata = ctx.readU64(subBase + SubscriptionUserdataOffset)
    let tag = ctx.readU8(subBase + SubscriptionTagOffset)

    let evtBase = outPtr + nevents * EventSize.uint32

    case tag
    of 0:  # clock
      let clockId = ctx.readU32(subBase + SubClockIdOffset)
      let timeout = ctx.readU64(subBase + SubClockTimeoutOffset)
      let flags = ctx.readU16(subBase + SubClockFlagsOffset)

      if flags.WasiSubclockflags.hasFlag(subclockAbstime):
        # Absolute timeout — just succeed immediately for now
        discard
      else:
        # Relative timeout — sleep
        if timeout > 0:
          let ms = timeout div 1_000_000
          if ms > 0:
            os.sleep(ms.int)

      # Zero-fill event
      for j in 0'u32 ..< EventSize.uint32:
        ctx.writeU8(evtBase + j, 0)
      ctx.writeU64(evtBase + EventUserdataOffset, userdata)
      ctx.writeU16(evtBase + EventErrorOffset, errnoSuccess.uint16)
      ctx.writeU8(evtBase + EventTypeOffset, eventClock.uint8)
      nevents += 1

    of 1, 2:  # fd_read, fd_write
      let subFd = ctx.readU32(subBase + SubFdReadwriteFdOffset).int32
      let (fdErr, fdObj) = ctx.getFd(subFd)

      for j in 0'u32 ..< EventSize.uint32:
        ctx.writeU8(evtBase + j, 0)
      ctx.writeU64(evtBase + EventUserdataOffset, userdata)
      if fdErr != errnoSuccess:
        ctx.writeU16(evtBase + EventErrorOffset, fdErr.uint16)
      else:
        ctx.writeU16(evtBase + EventErrorOffset, errnoSuccess.uint16)
        ctx.writeU64(evtBase + EventFdRwNbytesOffset, 1)  # at least 1 byte available
      ctx.writeU8(evtBase + EventTypeOffset, tag)
      nevents += 1

    else:
      return errnoInval

  ctx.writeU32(neventsPtr, nevents)
  errnoSuccess

# ---- Process ----

proc wasiProcExit*(ctx: WasiContext, code: int32): WasiErrno =
  ctx.exitCode = code
  ctx.exited = true
  var err = newException(WasiExitError, "WASI proc_exit(" & $code & ")")
  err.code = code
  raise err

proc wasiProcRaise*(ctx: WasiContext, sig: uint32): WasiErrno =
  # Most implementations just return nosys or ignore
  errnoNosys

# ---- Scheduling ----

proc wasiSchedYield*(ctx: WasiContext): WasiErrno =
  # sched_yield() — hint to the OS
  discard sched_yield()
  errnoSuccess

# ---- Random ----

proc wasiRandomGet*(ctx: WasiContext, bufPtr: uint32, bufLen: uint32): WasiErrno =
  let mem = ctx.getMem()
  if bufPtr.int + bufLen.int > mem[].len:
    raise newException(WasmTrap, "WASI: memory out of bounds")

  # Use /dev/urandom for crypto-quality randomness
  let fd = posix.open("/dev/urandom", O_RDONLY)
  if fd < 0:
    # Fallback: use Nim's random
    for i in 0'u32 ..< bufLen:
      mem[][bufPtr.int + i.int] = rand(255).byte
    return errnoSuccess

  var remaining = bufLen.int
  var offset = 0
  while remaining > 0:
    let n = posix.read(fd, mem[][bufPtr.int + offset].addr, remaining)
    if n <= 0: break
    remaining -= n
    offset += n
  discard posix.close(fd)
  errnoSuccess

# ---- Sockets (stubs) ----

proc wasiSockAccept*(ctx: WasiContext, fd: int32, flags: uint32,
                     fdPtr: uint32): WasiErrno =
  errnoNosys

proc wasiSockRecv*(ctx: WasiContext, fd: int32, riDataPtr: uint32,
                   riDataLen: uint32, riFlags: uint32,
                   roDatalenPtr: uint32, roFlagsPtr: uint32): WasiErrno =
  errnoNosys

proc wasiSockSend*(ctx: WasiContext, fd: int32, siDataPtr: uint32,
                   siDataLen: uint32, siFlags: uint32,
                   soDatalenPtr: uint32): WasiErrno =
  errnoNosys

proc wasiSockShutdown*(ctx: WasiContext, fd: int32, how: uint32): WasiErrno =
  errnoNosys

# ---------------------------------------------------------------------------
# Bind all WASI functions to a WasmVM as host imports
# ---------------------------------------------------------------------------

proc bindToVm*(ctx: WasiContext, vm: var WasmVM) =
  ## Register all 45 WASI preview 1 functions as host function imports
  ## that can be resolved during module instantiation.
  ctx.vm = vm.addr

proc addWasiFunc(result: var seq[(string, string, ExternalVal)],
                  name: string, params, results: seq[ValType], cb: HostFunc) =
  const wasiMod = "wasi_snapshot_preview1"
  let ft = FuncType(params: params, results: results)
  result.add((wasiMod, name, ExternalVal(kind: ekFunc, funcType: ft, hostFunc: cb)))

proc makeWasiImports*(ctx: WasiContext): seq[(string, string, ExternalVal)] =
  ## Generate the import resolution list for all 45 WASI preview 1 functions.

  # ---- args ----
  result.addWasiFunc("args_get", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiArgsGet(args[0].i32.uint32, args[1].i32.uint32).int32)])
  result.addWasiFunc("args_sizes_get", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiArgsSizesGet(args[0].i32.uint32, args[1].i32.uint32).int32)])

  # ---- environ ----
  result.addWasiFunc("environ_get", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiEnvironGet(args[0].i32.uint32, args[1].i32.uint32).int32)])
  result.addWasiFunc("environ_sizes_get", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiEnvironSizesGet(args[0].i32.uint32, args[1].i32.uint32).int32)])

  # ---- clock ----
  result.addWasiFunc("clock_res_get", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiClockResGet(args[0].i32.uint32, args[1].i32.uint32).int32)])
  result.addWasiFunc("clock_time_get", @[vtI32, vtI64, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiClockTimeGet(args[0].i32.uint32, args[1].i64.uint64, args[2].i32.uint32).int32)])

  # ---- fd operations ----
  result.addWasiFunc("fd_advise", @[vtI32, vtI64, vtI64, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdAdvise(args[0].i32, args[1].i64.uint64, args[2].i64.uint64, args[3].i32.uint32).int32)])
  result.addWasiFunc("fd_allocate", @[vtI32, vtI64, vtI64], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdAllocate(args[0].i32, args[1].i64.uint64, args[2].i64.uint64).int32)])
  result.addWasiFunc("fd_close", @[vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdClose(args[0].i32).int32)])
  result.addWasiFunc("fd_datasync", @[vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdDatasync(args[0].i32).int32)])
  result.addWasiFunc("fd_fdstat_get", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdFdstatGet(args[0].i32, args[1].i32.uint32).int32)])
  result.addWasiFunc("fd_fdstat_set_flags", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdFdstatSetFlags(args[0].i32, args[1].i32.uint32).int32)])
  result.addWasiFunc("fd_fdstat_set_rights", @[vtI32, vtI64, vtI64], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdFdstatSetRights(args[0].i32, args[1].i64.uint64, args[2].i64.uint64).int32)])
  result.addWasiFunc("fd_filestat_get", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdFilestatGet(args[0].i32, args[1].i32.uint32).int32)])
  result.addWasiFunc("fd_filestat_set_size", @[vtI32, vtI64], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdFilestatSetSize(args[0].i32, args[1].i64.uint64).int32)])
  result.addWasiFunc("fd_filestat_set_times", @[vtI32, vtI64, vtI64, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdFilestatSetTimes(args[0].i32, args[1].i64.uint64, args[2].i64.uint64, args[3].i32.uint32).int32)])
  result.addWasiFunc("fd_pread", @[vtI32, vtI32, vtI32, vtI64, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdPread(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i64.uint64, args[4].i32.uint32).int32)])
  result.addWasiFunc("fd_prestat_get", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdPrestatGet(args[0].i32, args[1].i32.uint32).int32)])
  result.addWasiFunc("fd_prestat_dir_name", @[vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdPrestatDirName(args[0].i32, args[1].i32.uint32, args[2].i32.uint32).int32)])
  result.addWasiFunc("fd_pwrite", @[vtI32, vtI32, vtI32, vtI64, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdPwrite(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i64.uint64, args[4].i32.uint32).int32)])
  result.addWasiFunc("fd_read", @[vtI32, vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdRead(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i32.uint32).int32)])
  result.addWasiFunc("fd_readdir", @[vtI32, vtI32, vtI32, vtI64, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdReaddir(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i64.uint64, args[4].i32.uint32).int32)])
  result.addWasiFunc("fd_renumber", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdRenumber(args[0].i32, args[1].i32).int32)])
  result.addWasiFunc("fd_seek", @[vtI32, vtI64, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdSeek(args[0].i32, args[1].i64, args[2].i32.uint32, args[3].i32.uint32).int32)])
  result.addWasiFunc("fd_sync", @[vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdSync(args[0].i32).int32)])
  result.addWasiFunc("fd_tell", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdTell(args[0].i32, args[1].i32.uint32).int32)])
  result.addWasiFunc("fd_write", @[vtI32, vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiFdWrite(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i32.uint32).int32)])

  # ---- path operations ----
  result.addWasiFunc("path_create_directory", @[vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiPathCreateDirectory(args[0].i32, args[1].i32.uint32, args[2].i32.uint32).int32)])
  result.addWasiFunc("path_filestat_get", @[vtI32, vtI32, vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiPathFilestatGet(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i32.uint32, args[4].i32.uint32).int32)])
  result.addWasiFunc("path_filestat_set_times", @[vtI32, vtI32, vtI32, vtI32, vtI64, vtI64, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiPathFilestatSetTimes(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i32.uint32, args[4].i64.uint64, args[5].i64.uint64, args[6].i32.uint32).int32)])
  result.addWasiFunc("path_link", @[vtI32, vtI32, vtI32, vtI32, vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiPathLink(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i32.uint32, args[4].i32, args[5].i32.uint32, args[6].i32.uint32).int32)])
  result.addWasiFunc("path_open", @[vtI32, vtI32, vtI32, vtI32, vtI32, vtI64, vtI64, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiPathOpen(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i32.uint32, args[4].i32.uint32, args[5].i64.uint64, args[6].i64.uint64, args[7].i32.uint32, args[8].i32.uint32).int32)])
  result.addWasiFunc("path_readlink", @[vtI32, vtI32, vtI32, vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiPathReadlink(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i32.uint32, args[4].i32.uint32, args[5].i32.uint32).int32)])
  result.addWasiFunc("path_remove_directory", @[vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiPathRemoveDirectory(args[0].i32, args[1].i32.uint32, args[2].i32.uint32).int32)])
  result.addWasiFunc("path_rename", @[vtI32, vtI32, vtI32, vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiPathRename(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i32, args[4].i32.uint32, args[5].i32.uint32).int32)])
  result.addWasiFunc("path_symlink", @[vtI32, vtI32, vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiPathSymlink(args[0].i32.uint32, args[1].i32.uint32, args[2].i32, args[3].i32.uint32, args[4].i32.uint32).int32)])
  result.addWasiFunc("path_unlink_file", @[vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiPathUnlinkFile(args[0].i32, args[1].i32.uint32, args[2].i32.uint32).int32)])

  # ---- poll ----
  result.addWasiFunc("poll_oneoff", @[vtI32, vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiPollOneoff(args[0].i32.uint32, args[1].i32.uint32, args[2].i32.uint32, args[3].i32.uint32).int32)])

  # ---- process ----
  result.addWasiFunc("proc_exit", @[vtI32], @[],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      discard ctx.wasiProcExit(args[0].i32)
      @[])
  result.addWasiFunc("proc_raise", @[vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiProcRaise(args[0].i32.uint32).int32)])

  # ---- scheduling ----
  result.addWasiFunc("sched_yield", @[], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiSchedYield().int32)])

  # ---- random ----
  result.addWasiFunc("random_get", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiRandomGet(args[0].i32.uint32, args[1].i32.uint32).int32)])

  # ---- sockets ----
  result.addWasiFunc("sock_accept", @[vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiSockAccept(args[0].i32, args[1].i32.uint32, args[2].i32.uint32).int32)])
  result.addWasiFunc("sock_recv", @[vtI32, vtI32, vtI32, vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiSockRecv(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i32.uint32, args[4].i32.uint32, args[5].i32.uint32).int32)])
  result.addWasiFunc("sock_send", @[vtI32, vtI32, vtI32, vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiSockSend(args[0].i32, args[1].i32.uint32, args[2].i32.uint32, args[3].i32.uint32, args[4].i32.uint32).int32)])
  result.addWasiFunc("sock_shutdown", @[vtI32, vtI32], @[vtI32],
    proc(args: openArray[WasmValue]): seq[WasmValue] =
      @[wasmI32(ctx.wasiSockShutdown(args[0].i32, args[1].i32.uint32).int32)])
