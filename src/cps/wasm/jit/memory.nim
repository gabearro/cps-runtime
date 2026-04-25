## JIT executable memory management
## Handles mmap with W^X protection on macOS and RWX JIT pages on POSIX.

const
  PROT_READ = 0x01
  PROT_WRITE = 0x02
  PROT_EXEC = 0x04
  MAP_PRIVATE = 0x0002
  MAP_ANON = when defined(macosx): 0x1000 else: 0x0020
  MAP_JIT = when defined(macosx): 0x0800 else: 0x0000  # macOS: allow JIT code generation

proc mmap(address: pointer, length: csize_t, prot: cint, flags: cint,
          fd: cint, offset: clong): pointer {.importc, header: "<sys/mman.h>".}
proc munmap(address: pointer, length: csize_t): cint {.importc, header: "<sys/mman.h>".}

when defined(macosx):
  proc pthread_jit_write_protect_np(enabled: cint) {.importc, header: "<pthread.h>".}
  proc sys_icache_invalidate(start: pointer, length: csize_t) {.importc, header: "<libkern/OSCacheControl.h>".}
else:
  proc builtinClearCache(first, last: pointer) {.importc: "__builtin___clear_cache", nodecl.}

const JitPageSize* = 4096
const DefaultJitPoolSize* = 1024 * 1024  # 1MB initial pool

type
  JitMemPool* = object
    base*: ptr UncheckedArray[byte]  # base address of mmap'd region
    capacity*: int                    # total bytes allocated
    used*: int                        # bytes used so far
    sideData*: seq[pointer]           # heap allocations tied to pool lifetime

  JitCode* = object
    ## A compiled function's executable code
    address*: pointer   # start address of the code
    size*: int          # size in bytes
    numLocals*: int     # total locals needed (may exceed WASM locals for Tier 2 result slots)

proc initJitMemPool*(size: int = DefaultJitPoolSize): JitMemPool =
  let aligned = (size + JitPageSize - 1) and not (JitPageSize - 1)  # page-align
  let p = mmap(nil, aligned.csize_t,
               PROT_READ or PROT_WRITE or PROT_EXEC,
               MAP_PRIVATE or MAP_ANON or MAP_JIT,
               -1, 0)
  if cast[int](p) == -1:
    raise newException(OSError, "mmap failed for JIT memory pool")
  result.base = cast[ptr UncheckedArray[byte]](p)
  result.capacity = aligned
  result.used = 0

proc destroy*(pool: var JitMemPool) =
  if pool.base != nil:
    discard munmap(pool.base, pool.capacity.csize_t)
    pool.base = nil
    pool.capacity = 0
    pool.used = 0
  for p in pool.sideData:
    deallocShared(p)
  pool.sideData = @[]

proc enableWrite*(pool: JitMemPool) {.inline.} =
  ## Switch to write mode (disable execute protection)
  ## Required on Apple Silicon before writing JIT code
  when defined(macosx):
    pthread_jit_write_protect_np(0)
  else:
    discard pool

proc enableExecute*(pool: JitMemPool) {.inline.} =
  ## Switch to execute mode (disable write protection)
  ## Required on Apple Silicon before executing JIT code
  when defined(macosx):
    pthread_jit_write_protect_np(1)
  else:
    discard pool

proc invalidateICache*(address: pointer, size: int) {.inline.} =
  ## Invalidate instruction cache for the given range
  ## Required on ARM after writing code before executing it
  when defined(macosx):
    sys_icache_invalidate(address, size.csize_t)
  elif defined(amd64) or defined(i386):
    discard address
    discard size
  else:
    builtinClearCache(address, cast[pointer](cast[uint](address) + size.uint))

proc alloc*(pool: var JitMemPool, size: int): JitCode =
  ## Allocate a chunk of executable memory from the pool
  let aligned = (size + 7) and not 7  # 8-byte align
  if pool.used + aligned > pool.capacity:
    raise newException(OSError, "JIT memory pool exhausted")
  result.address = pool.base[pool.used].addr
  result.size = aligned
  pool.used += aligned

proc writeCode*(pool: var JitMemPool, code: openArray[uint32]): JitCode =
  ## Write a sequence of 32-bit fixed-width instructions to the pool
  ## Returns the JitCode handle for the written code
  ## Handles W^X transitions automatically
  let byteSize = code.len * 4
  result = pool.alloc(byteSize)

  pool.enableWrite()
  copyMem(result.address, code[0].unsafeAddr, byteSize)
  pool.enableExecute()

  invalidateICache(result.address, byteSize)

proc remaining*(pool: JitMemPool): int =
  pool.capacity - pool.used

proc reset*(pool: var JitMemPool) =
  ## Reset the pool (free all allocations but keep the mmap)
  pool.used = 0
