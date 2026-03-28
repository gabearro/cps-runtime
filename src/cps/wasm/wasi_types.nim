## WASI Preview 1 type definitions
## Covers all scalar types, bitfields, structs, and errno codes.
## See: https://github.com/WebAssembly/WASI/blob/main/legacy/preview1/docs.md

type
  WasiErrno* = enum
    errnoSuccess = 0
    errno2big = 1
    errnoAcces = 2
    errnoAddrinuse = 3
    errnoAddrnotavail = 4
    errnoAfnosupport = 5
    errnoAgain = 6
    errnoAlready = 7
    errnoBadf = 8
    errnoBadmsg = 9
    errnoBusy = 10
    errnoCanceled = 11
    errnoChild = 12
    errnoConnaborted = 13
    errnoConnrefused = 14
    errnoConnreset = 15
    errnoDeadlk = 16
    errnoDestaddrreq = 17
    errnoDom = 18
    errnoDquot = 19
    errnoExist = 20
    errnoFault = 21
    errnoFbig = 22
    errnoHostunreach = 23
    errnoIdrm = 24
    errnoIlseq = 25
    errnoInprogress = 26
    errnoIntr = 27
    errnoInval = 28
    errnoIo = 29
    errnoIsconn = 30
    errnoIsdir = 31
    errnoLoop = 32
    errnoMfile = 33
    errnoMlink = 34
    errnoMsgsize = 35
    errnoMultihop = 36
    errnoNametoolong = 37
    errnoNetdown = 38
    errnoNetreset = 39
    errnoNetunreach = 40
    errnoNfile = 41
    errnoNobufs = 42
    errnoNodev = 43
    errnoNoent = 44
    errnoNoexec = 45
    errnoNolck = 46
    errnoNolink = 47
    errnoNomem = 48
    errnoNomsg = 49
    errnoNoprotoopt = 50
    errnoNospc = 51
    errnoNosys = 52
    errnoNotconn = 53
    errnoNotdir = 54
    errnoNotempty = 55
    errnoNotrecoverable = 56
    errnoNotsock = 57
    errnoNotsup = 58
    errnoNotty = 59
    errnoNxio = 60
    errnoOverflow = 61
    errnoOwnerdead = 62
    errnoPerm = 63
    errnoPipe = 64
    errnoProto = 65
    errnoProtonosupport = 66
    errnoPrototype = 67
    errnoRange = 68
    errnoRofs = 69
    errnoSpipe = 70
    errnoSrch = 71
    errnoStale = 72
    errnoTimedout = 73
    errnoTxtbsy = 74
    errnoXdev = 75
    errnoNotcapable = 76

  WasiClockId* = enum
    clockRealtime = 0
    clockMonotonic = 1
    clockProcessCputimeId = 2
    clockThreadCputimeId = 3

  WasiFiletype* = enum
    filetypeUnknown = 0
    filetypeBlockDevice = 1
    filetypeCharacterDevice = 2
    filetypeDirectory = 3
    filetypeRegularFile = 4
    filetypeSocketDgram = 5
    filetypeSocketStream = 6
    filetypeSymbolicLink = 7

  WasiWhence* = enum
    whenceSet = 0
    whenceCur = 1
    whenceEnd = 2

  WasiAdvice* = enum
    adviceNormal = 0
    adviceSequential = 1
    adviceRandom = 2
    adviceWillneed = 3
    adviceDontneed = 4
    adviceNoreuse = 5

  WasiPreopenType* = enum
    preopenDir = 0

  WasiEventType* = enum
    eventClock = 0
    eventFdRead = 1
    eventFdWrite = 2

  # Bitfield types (stored as integers)
  WasiFdflags* = distinct uint16
  WasiOflags* = distinct uint16
  WasiLookupflags* = distinct uint32
  WasiFstflags* = distinct uint16
  WasiRights* = distinct uint64
  WasiSubclockflags* = distinct uint16
  WasiRiflags* = distinct uint16
  WasiRoflags* = distinct uint16
  WasiSdflags* = distinct uint8
  WasiEventrwflags* = distinct uint16

# Fdflags bits
const
  fdflagsAppend*: WasiFdflags = 1.WasiFdflags
  fdflagsDsync*: WasiFdflags = 2.WasiFdflags
  fdflagsNonblock*: WasiFdflags = 4.WasiFdflags
  fdflagsRsync*: WasiFdflags = 8.WasiFdflags
  fdflagsSync*: WasiFdflags = 16.WasiFdflags

# Oflags bits
const
  oflagsCreat*: WasiOflags = 1.WasiOflags
  oflagsDirectory*: WasiOflags = 2.WasiOflags
  oflagsExcl*: WasiOflags = 4.WasiOflags
  oflagsTrunc*: WasiOflags = 8.WasiOflags

# Lookup flags
const
  lookupSymlinkFollow*: WasiLookupflags = 1.WasiLookupflags

# Fstflags bits
const
  fstflagsAtim*: WasiFstflags = 1.WasiFstflags
  fstflagsAtimNow*: WasiFstflags = 2.WasiFstflags
  fstflagsMtim*: WasiFstflags = 4.WasiFstflags
  fstflagsMtimNow*: WasiFstflags = 8.WasiFstflags

# Subscription clock flags
const
  subclockAbstime*: WasiSubclockflags = 1.WasiSubclockflags

# Riflags
const
  riflagsRecvPeek*: WasiRiflags = 1.WasiRiflags
  riflagsRecvWaitall*: WasiRiflags = 2.WasiRiflags

# Roflags
const
  roflagsRecvDataTruncated*: WasiRoflags = 1.WasiRoflags

# Sdflags
const
  sdflagsRd*: WasiSdflags = 1.WasiSdflags
  sdflagsWr*: WasiSdflags = 2.WasiSdflags

# Rights bits (all 30 defined rights)
const
  rightFdDatasync*: WasiRights = (1'u64 shl 0).WasiRights
  rightFdRead*: WasiRights = (1'u64 shl 1).WasiRights
  rightFdSeek*: WasiRights = (1'u64 shl 2).WasiRights
  rightFdFdstatSetFlags*: WasiRights = (1'u64 shl 3).WasiRights
  rightFdSync*: WasiRights = (1'u64 shl 4).WasiRights
  rightFdTell*: WasiRights = (1'u64 shl 5).WasiRights
  rightFdWrite*: WasiRights = (1'u64 shl 6).WasiRights
  rightFdAdvise*: WasiRights = (1'u64 shl 7).WasiRights
  rightFdAllocate*: WasiRights = (1'u64 shl 8).WasiRights
  rightPathCreateDirectory*: WasiRights = (1'u64 shl 9).WasiRights
  rightPathCreateFile*: WasiRights = (1'u64 shl 10).WasiRights
  rightPathLinkSource*: WasiRights = (1'u64 shl 11).WasiRights
  rightPathLinkTarget*: WasiRights = (1'u64 shl 12).WasiRights
  rightPathOpen*: WasiRights = (1'u64 shl 13).WasiRights
  rightFdReaddir*: WasiRights = (1'u64 shl 14).WasiRights
  rightPathReadlink*: WasiRights = (1'u64 shl 15).WasiRights
  rightPathRenameSource*: WasiRights = (1'u64 shl 16).WasiRights
  rightPathRenameTarget*: WasiRights = (1'u64 shl 17).WasiRights
  rightPathFilestatGet*: WasiRights = (1'u64 shl 18).WasiRights
  rightPathFilestatSetSize*: WasiRights = (1'u64 shl 19).WasiRights
  rightPathFilestatSetTimes*: WasiRights = (1'u64 shl 20).WasiRights
  rightFdFilestatGet*: WasiRights = (1'u64 shl 21).WasiRights
  rightFdFilestatSetSize*: WasiRights = (1'u64 shl 22).WasiRights
  rightFdFilestatSetTimes*: WasiRights = (1'u64 shl 23).WasiRights
  rightPathSymlink*: WasiRights = (1'u64 shl 24).WasiRights
  rightPathRemoveDirectory*: WasiRights = (1'u64 shl 25).WasiRights
  rightPathUnlinkFile*: WasiRights = (1'u64 shl 26).WasiRights
  rightPollFdReadwrite*: WasiRights = (1'u64 shl 27).WasiRights
  rightSockShutdown*: WasiRights = (1'u64 shl 28).WasiRights
  rightSockAccept*: WasiRights = (1'u64 shl 29).WasiRights

  # Combined rights for common use
  rightsAll*: WasiRights = ((1'u64 shl 30) - 1).WasiRights
  rightsFileBase*: WasiRights = (
    rightFdDatasync.uint64 or rightFdRead.uint64 or rightFdSeek.uint64 or
    rightFdFdstatSetFlags.uint64 or rightFdSync.uint64 or rightFdTell.uint64 or
    rightFdWrite.uint64 or rightFdAdvise.uint64 or rightFdAllocate.uint64 or
    rightFdFilestatGet.uint64 or rightFdFilestatSetSize.uint64 or
    rightFdFilestatSetTimes.uint64 or rightPollFdReadwrite.uint64
  ).WasiRights
  rightsFileInheriting*: WasiRights = 0.WasiRights
  rightsDirBase*: WasiRights = (
    rightFdFdstatSetFlags.uint64 or rightFdSync.uint64 or rightFdAdvise.uint64 or
    rightPathCreateDirectory.uint64 or rightPathCreateFile.uint64 or
    rightPathLinkSource.uint64 or rightPathLinkTarget.uint64 or
    rightPathOpen.uint64 or rightFdReaddir.uint64 or rightPathReadlink.uint64 or
    rightPathRenameSource.uint64 or rightPathRenameTarget.uint64 or
    rightPathFilestatGet.uint64 or rightPathFilestatSetSize.uint64 or
    rightPathFilestatSetTimes.uint64 or rightFdFilestatGet.uint64 or
    rightFdFilestatSetTimes.uint64 or rightPathSymlink.uint64 or
    rightPathRemoveDirectory.uint64 or rightPathUnlinkFile.uint64
  ).WasiRights
  rightsDirInheriting*: WasiRights = (rightsDirBase.uint64 or rightsFileBase.uint64).WasiRights

# Operators for bitfield types
proc `or`*(a, b: WasiRights): WasiRights {.borrow.}
proc `and`*(a, b: WasiRights): WasiRights {.borrow.}
proc `not`*(a: WasiRights): WasiRights = (not a.uint64).WasiRights
proc `==`*(a, b: WasiRights): bool {.borrow.}
proc contains*(rights: WasiRights, check: WasiRights): bool =
  (rights.uint64 and check.uint64) == check.uint64

proc `or`*(a, b: WasiFdflags): WasiFdflags {.borrow.}
proc `and`*(a, b: WasiFdflags): WasiFdflags {.borrow.}
proc `==`*(a, b: WasiFdflags): bool {.borrow.}

proc `or`*(a, b: WasiOflags): WasiOflags {.borrow.}
proc `and`*(a, b: WasiOflags): WasiOflags {.borrow.}
proc `==`*(a, b: WasiOflags): bool {.borrow.}

proc `or`*(a, b: WasiLookupflags): WasiLookupflags {.borrow.}
proc `and`*(a, b: WasiLookupflags): WasiLookupflags {.borrow.}
proc `==`*(a, b: WasiLookupflags): bool {.borrow.}

proc `or`*(a, b: WasiFstflags): WasiFstflags {.borrow.}
proc `and`*(a, b: WasiFstflags): WasiFstflags {.borrow.}
proc `==`*(a, b: WasiFstflags): bool {.borrow.}

proc `or`*(a, b: WasiSubclockflags): WasiSubclockflags {.borrow.}
proc `and`*(a, b: WasiSubclockflags): WasiSubclockflags {.borrow.}
proc `==`*(a, b: WasiSubclockflags): bool {.borrow.}

proc hasFlag*(flags: WasiFdflags, check: WasiFdflags): bool =
  (flags.uint16 and check.uint16) != 0

proc hasFlag*(flags: WasiOflags, check: WasiOflags): bool =
  (flags.uint16 and check.uint16) != 0

proc hasFlag*(flags: WasiLookupflags, check: WasiLookupflags): bool =
  (flags.uint32 and check.uint32) != 0

proc hasFlag*(flags: WasiFstflags, check: WasiFstflags): bool =
  (flags.uint16 and check.uint16) != 0

proc hasFlag*(flags: WasiSubclockflags, check: WasiSubclockflags): bool =
  (flags.uint16 and check.uint16) != 0

# Struct sizes and offsets (for memory layout)
const
  # iovec/ciovec: { buf: u32, buf_len: u32 } = 8 bytes
  IoVecSize* = 8
  IoVecBufOffset* = 0
  IoVecBufLenOffset* = 4

  # fdstat: size 24, align 8
  FdstatSize* = 24
  FdstatFiletypeOffset* = 0    # u8
  FdstatFlagsOffset* = 2       # u16
  FdstatRightsBaseOffset* = 8  # u64
  FdstatRightsInhOffset* = 16  # u64

  # filestat: size 64, align 8
  FilestatSize* = 64
  FilestatDevOffset* = 0       # u64
  FilestatInoOffset* = 8       # u64
  FilestatFiletypeOffset* = 16 # u8
  FilestatNlinkOffset* = 24    # u64
  FilestatSizeOffset* = 32     # u64
  FilestatAtimOffset* = 40     # u64
  FilestatMtimOffset* = 48     # u64
  FilestatCtimOffset* = 56     # u64

  # dirent: size 24, align 8
  DirentSize* = 24
  DirentDnextOffset* = 0      # u64
  DirentDinoOffset* = 8       # u64
  DirentDnamlenOffset* = 16   # u32
  DirentDtypeOffset* = 20     # u8

  # prestat: size 8, align 4
  PrestatSize* = 8
  PrestatTagOffset* = 0       # u8
  PrestatDirNamelenOffset* = 4 # u32

  # event: size 32, align 8
  EventSize* = 32
  EventUserdataOffset* = 0     # u64
  EventErrorOffset* = 8       # u16
  EventTypeOffset* = 10       # u8
  EventFdRwNbytesOffset* = 16 # u64
  EventFdRwFlagsOffset* = 24  # u16

  # subscription: size 48, align 8
  SubscriptionSize* = 48
  SubscriptionUserdataOffset* = 0   # u64
  SubscriptionTagOffset* = 8       # u8
  # clock variant (tag=0):
  SubClockIdOffset* = 16           # u32
  SubClockTimeoutOffset* = 24     # u64
  SubClockPrecisionOffset* = 32   # u64
  SubClockFlagsOffset* = 40       # u16
  # fd_read/fd_write variant (tag=1,2):
  SubFdReadwriteFdOffset* = 16    # u32
