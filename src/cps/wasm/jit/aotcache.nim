## Persistent AOT JIT code cache.
##
## Serialises compiled Tier-2 machine-code blobs to disk so they can be
## re-loaded on the next run without going through the full optimising
## pipeline.  A per-module FNV-1a hash is used as the cache key — if the
## module changes the cache is silently discarded.
##
## Format (little-endian, no padding):
##   Header:
##     magic    : u32  = 0x57414A43  ("WAJC")
##     version  : u32  = 4
##     hash     : u64  (FNV-1a 64 of module bytes)
##     numFuncs : u32
##   Per-function record (repeated numFuncs times):
##     funcIdx  : u32
##     tier     : u8   (1 = baseline, 2 = optimising)
##     numLocals: u32
##     codeSize : u32
##     numRelocs: u32
##     code     : codeSize bytes
##     relocs   : numRelocs × Relocation
##   Relocation:
##     offset   : u32  (byte offset within code where imm64 address lives)
##     kind     : u8   (0 = dispatch-func, 1 = call-indirect cache slot N)
##     siteIdx  : u32  (for kind=1: call_indirect site index; 0 otherwise)
##
## Absolute addresses embedded in the code are patched on load:
##   kind=0  → patched with the current address of tier2CallIndirectDispatch
##   kind=1  → patched with a freshly-allocated CallIndirectCache*

import std/[os, streams, strutils]
import memory

const
  CacheMagic*   = 0x57414A43'u32   # "WAJC"
  CacheVersion* = 4'u32

# ---------------------------------------------------------------------------
# Relocation records
# ---------------------------------------------------------------------------

type
  RelocKind* = enum
    relocDispatch   = 0  ## absolute address of tier2CallIndirectDispatch
    relocCallCache  = 1  ## freshly-allocated ptr CallIndirectCache

  Relocation* = object
    offset*:  uint32   ## byte offset within the function code blob
    kind*:    RelocKind
    siteIdx*: uint32   ## for relocCallCache: which call_indirect site

  CachedFunc* = object
    funcIdx*:   uint32
    tier*:      uint8
    numLocals*: uint32
    code*:      seq[byte]
    relocs*:    seq[Relocation]

  AotCache* = object
    moduleHash*: uint64
    funcs*:      seq[CachedFunc]

# ---------------------------------------------------------------------------
# Module hashing: FNV-1a 64-bit
# ---------------------------------------------------------------------------

proc fnv1a64*(data: openArray[byte]): uint64 =
  result = 0xcbf29ce484222325'u64
  for b in data:
    result = result xor b.uint64
    result = result * 0x00000100000001b3'u64

# ---------------------------------------------------------------------------
# Serialise
# ---------------------------------------------------------------------------

proc writeCacheFile*(path: string, cache: AotCache) =
  ## Write cache to *path* atomically (write to tmp, then rename).
  let tmp = path & ".tmp"
  let s = newFileStream(tmp, fmWrite)
  if s == nil:
    raise newException(IOError, "Cannot create cache file: " & tmp)
  try:
    s.write(CacheMagic)
    s.write(CacheVersion)
    s.write(cache.moduleHash)
    s.write(cache.funcs.len.uint32)
    for f in cache.funcs:
      s.write(f.funcIdx)
      s.write(f.tier)
      s.write(f.numLocals)
      s.write(f.code.len.uint32)
      s.write(f.relocs.len.uint32)
      if f.code.len > 0:
        s.writeData(unsafeAddr f.code[0], f.code.len)
      for r in f.relocs:
        s.write(r.offset)
        s.write(r.kind.uint8)
        s.write(r.siteIdx)
  finally:
    s.close()
  moveFile(tmp, path)   # atomic on POSIX (same filesystem)

# ---------------------------------------------------------------------------
# Deserialise
# ---------------------------------------------------------------------------

proc readCacheFile*(path: string, expectedHash: uint64): AotCache =
  ## Read and verify cache.  Raises IOError on missing file, wrong format,
  ## or hash mismatch (caller should catch and treat as cache-miss).
  let s = newFileStream(path, fmRead)
  if s == nil:
    raise newException(IOError, "Cannot open cache file: " & path)
  defer: s.close()

  let magic   = s.readUInt32()
  let version = s.readUInt32()
  if magic != CacheMagic or version != CacheVersion:
    raise newException(IOError, "Cache format mismatch (stale cache?)")
  let storedHash = s.readUInt64()
  if storedHash != expectedHash:
    raise newException(IOError, "Cache module hash mismatch — recompiling")

  let n = s.readUInt32().int
  result.moduleHash = storedHash
  result.funcs.setLen(n)
  for i in 0 ..< n:
    let funcIdx  = s.readUInt32()
    let tier     = s.readUInt8()
    let nlocs    = s.readUInt32()
    let csz      = s.readUInt32().int
    let nrelocs  = s.readUInt32().int
    var code: seq[byte]
    if csz > 0:
      code.setLen(csz)
      let got = s.readData(addr code[0], csz)
      if got != csz:
        raise newException(IOError, "Cache truncated reading func code")
    var relocs: seq[Relocation]
    relocs.setLen(nrelocs)
    for j in 0 ..< nrelocs:
      let off  = s.readUInt32()
      let kind = RelocKind(s.readUInt8())
      let si   = s.readUInt32()
      relocs[j] = Relocation(offset: off, kind: kind, siteIdx: si)
    result.funcs[i] = CachedFunc(funcIdx: funcIdx, tier: tier,
                                  numLocals: nlocs, code: code, relocs: relocs)

# ---------------------------------------------------------------------------
# Link: copy code into JIT pool, apply relocations
# ---------------------------------------------------------------------------

proc patchAbsoluteAddr(dst: pointer, newVal: uint64) {.inline.} =
  ## Write a 64-bit absolute address into the code at *dst*.
  ##
  ## x86-64: the immediate sits inline as a native 64-bit value (10-byte
  ##         movabs encoding); just overwrite the 8 bytes.
  ##
  ## AArch64: the address is spread across 4 × MOVZ/MOVK instructions
  ##          (A64 encoding: bits[20:5] carry each 16-bit chunk).
  ##          We patch all 4 instructions in place.
  when defined(arm64) or defined(aarch64):
    # MOVZ / MOVK pattern emitted by loadImm64:
    #   MOVZ Xd, #imm0, LSL #0   — bits[20:5] = imm[15:0]
    #   MOVK Xd, #imm1, LSL #16  — bits[20:5] = imm[31:16]
    #   MOVK Xd, #imm2, LSL #32  — bits[20:5] = imm[47:32]
    #   MOVK Xd, #imm3, LSL #48  — bits[20:5] = imm[63:48]
    let instrs = cast[ptr UncheckedArray[uint32]](dst)
    let chunks: array[4, uint16] = [
      uint16(newVal and 0xFFFF),
      uint16((newVal shr 16) and 0xFFFF),
      uint16((newVal shr 32) and 0xFFFF),
      uint16((newVal shr 48) and 0xFFFF),
    ]
    for i in 0 ..< 4:
      # Clear old imm16 (bits 20:5) and write new chunk
      instrs[i] = (instrs[i] and 0xFFE0001F'u32) or
                  (uint32(chunks[i]) shl 5)
  else:
    # x86-64: 8-byte little-endian immediate at dst
    cast[ptr uint64](dst)[] = newVal

proc linkCachedFunc*(pool: var JitMemPool,
                     f: CachedFunc,
                     dispatchAddr: uint64,
                     siteMap: seq[pointer]): JitCode =
  ## Copy f.code into the pool, apply relocations, return JitCode.
  ## *dispatchAddr*  = address of tier2CallIndirectDispatch (cast[uint64])
  ## *siteMap*       = pre-allocated CallIndirectCache* per call_indirect site
  if f.code.len == 0: return JitCode()

  let jc = pool.alloc(f.code.len)
  pool.enableWrite()
  copyMem(jc.address, unsafeAddr f.code[0], f.code.len)

  # Apply relocations: patch the embedded absolute address at each site
  for r in f.relocs:
    let patchAddr = cast[pointer](cast[int](jc.address) + r.offset.int)
    case r.kind
    of relocDispatch:
      patchAbsoluteAddr(patchAddr, dispatchAddr)
    of relocCallCache:
      let si = r.siteIdx.int
      if si < siteMap.len and siteMap[si] != nil:
        patchAbsoluteAddr(patchAddr, cast[uint64](siteMap[si]))
      # else leave the stored 0 — dispatch will see nil cache and trap

  pool.enableExecute()
  when defined(arm64) or defined(aarch64):
    invalidateICache(jc.address, f.code.len)

  result = JitCode(address: jc.address, size: f.code.len,
                   numLocals: f.numLocals.int)

# ---------------------------------------------------------------------------
# Cache path helpers
# ---------------------------------------------------------------------------

proc defaultCacheDir*(): string =
  ## Returns ~/.cache/wasm-jit  (or $XDG_CACHE_HOME/wasm-jit if set).
  let xdg = getEnv("XDG_CACHE_HOME")
  if xdg.len > 0: return xdg / "wasm-jit"
  getHomeDir() / ".cache" / "wasm-jit"

proc cachePath*(cacheDir: string, moduleHash: uint64): string =
  ## Deterministic path for cache file: <dir>/<hex16>.wjc
  result = cacheDir / toHex(moduleHash, 16) & ".wjc"
