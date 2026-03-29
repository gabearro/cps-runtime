## JIT code cache management
## Tracks compiled functions, compilation statistics, handles eviction,
## and provides inline caching for call_indirect dispatch.

import std/[tables, times]
import memory

type
  CacheEntry* = object
    code*: JitCode
    funcIdx*: int
    tier*: int              # 1 = baseline, 2 = optimized
    callCount*: int
    compileTimeMs*: float   # milliseconds spent compiling
    codeSize*: int          # bytes of generated code
    lastUsed*: float        # timestamp of last invocation

  JitStats* = object
    totalCompilations*: int
    totalCompileTimeMs*: float
    totalCodeBytes*: int
    tier1Compilations*: int
    tier2Compilations*: int
    evictions*: int
    cacheHits*: int
    cacheMisses*: int

  # ---- Inline caching for call_indirect ----
  # Each call_indirect site caches the last-seen (typeIdx, elemIdx) → funcAddr
  # mapping to avoid the full table lookup + type check on monomorphic sites.

  IcState* = enum
    icEmpty       # no cached value yet
    icMonomorphic # one cached target
    icPolymorphic # 2-4 cached targets
    icMegamorphic # too many targets, stop caching

  IcEntry* = object
    elemIdx*: int32   # table element index that was looked up
    funcAddr*: int32  # resolved function store address
    typeOk*: bool     # type check passed

  InlineCache* = object
    state*: IcState
    entries*: array[4, IcEntry]  # up to 4 polymorphic entries
    count*: int                   # number of valid entries
    hits*: int                    # cache hit count
    misses*: int                  # cache miss count

  # Per-function inline cache table: maps call_indirect PC offset → InlineCache
  IcTable* = object
    sites*: Table[int, InlineCache]  # PC offset → cache

  CodeCache* = object
    entries*: Table[int, CacheEntry]  # funcAddr -> CacheEntry
    pool*: ptr JitMemPool
    stats*: JitStats
    maxEntries*: int

proc initCodeCache*(pool: ptr JitMemPool, maxEntries: int = 1024): CodeCache =
  result.pool = pool
  result.maxEntries = maxEntries

proc evictLRU*(cache: var CodeCache) =
  ## Evict the least recently used cache entry
  var oldestAddr = -1
  var oldestTime = float.high
  for funcAddr, entry in cache.entries:
    if entry.lastUsed < oldestTime:
      oldestTime = entry.lastUsed
      oldestAddr = funcAddr
  if oldestAddr >= 0:
    cache.entries.del(oldestAddr)
    inc cache.stats.evictions

proc get*(cache: var CodeCache, funcAddr: int): ptr CacheEntry =
  cache.entries.withValue(funcAddr, entry):
    inc cache.stats.cacheHits
    entry.lastUsed = cpuTime()
    inc entry.callCount
    return entry
  do:
    inc cache.stats.cacheMisses
    return nil

proc put*(cache: var CodeCache, funcAddr: int, entry: CacheEntry) =
  # Evict if at capacity
  if cache.entries.len >= cache.maxEntries and funcAddr notin cache.entries:
    cache.evictLRU()
  cache.entries[funcAddr] = entry
  cache.stats.totalCompilations += 1
  cache.stats.totalCodeBytes += entry.codeSize
  cache.stats.totalCompileTimeMs += entry.compileTimeMs
  if entry.tier == 1:
    inc cache.stats.tier1Compilations
  else:
    inc cache.stats.tier2Compilations

proc contains*(cache: CodeCache, funcAddr: int): bool =
  funcAddr in cache.entries

proc clear*(cache: var CodeCache) =
  cache.entries.clear()

proc getStats*(cache: CodeCache): JitStats =
  cache.stats

proc formatStats*(stats: JitStats): string =
  result = "JIT Statistics:\n"
  result &= "  Compilations: " & $stats.totalCompilations & " (T1: " & $stats.tier1Compilations & ", T2: " & $stats.tier2Compilations & ")\n"
  result &= "  Compile time: " & $stats.totalCompileTimeMs & " ms\n"
  result &= "  Code size: " & $stats.totalCodeBytes & " bytes\n"
  result &= "  Cache hits: " & $stats.cacheHits & ", misses: " & $stats.cacheMisses & "\n"
  result &= "  Evictions: " & $stats.evictions

# ---------------------------------------------------------------------------
# Inline caching for call_indirect
# ---------------------------------------------------------------------------

proc initInlineCache*(): InlineCache =
  result.state = icEmpty

proc icLookup*(ic: var InlineCache, elemIdx: int32): int32 =
  ## Look up a cached call_indirect target. Returns funcAddr (>= 0) on hit,
  ## -1 on miss. Caller must still verify the returned funcAddr is valid.
  case ic.state
  of icEmpty:
    inc ic.misses
    return -1
  of icMonomorphic:
    if ic.entries[0].elemIdx == elemIdx and ic.entries[0].typeOk:
      inc ic.hits
      return ic.entries[0].funcAddr
    inc ic.misses
    return -1
  of icPolymorphic:
    for i in 0 ..< ic.count:
      if ic.entries[i].elemIdx == elemIdx and ic.entries[i].typeOk:
        inc ic.hits
        return ic.entries[i].funcAddr
    inc ic.misses
    return -1
  of icMegamorphic:
    inc ic.misses
    return -1

proc icUpdate*(ic: var InlineCache, elemIdx: int32, funcAddr: int32, typeOk: bool) =
  ## Record a resolved call_indirect target in the cache.
  let entry = IcEntry(elemIdx: elemIdx, funcAddr: funcAddr, typeOk: typeOk)
  case ic.state
  of icEmpty:
    ic.entries[0] = entry
    ic.count = 1
    ic.state = icMonomorphic
  of icMonomorphic:
    if ic.entries[0].elemIdx == elemIdx:
      ic.entries[0] = entry  # update existing
    else:
      ic.entries[1] = entry
      ic.count = 2
      ic.state = icPolymorphic
  of icPolymorphic:
    # Check if this elemIdx already exists
    for i in 0 ..< ic.count:
      if ic.entries[i].elemIdx == elemIdx:
        ic.entries[i] = entry
        return
    if ic.count < 4:
      ic.entries[ic.count] = entry
      inc ic.count
    else:
      ic.state = icMegamorphic
  of icMegamorphic:
    discard  # stop caching

proc icGetOrCreate*(table: var IcTable, pc: int): var InlineCache =
  ## Get or create an inline cache for a call_indirect site at the given PC.
  table.sites.mgetOrPut(pc, initInlineCache())

proc icReset*(ic: var InlineCache) =
  ic.state = icEmpty
  ic.count = 0
  ic.hits = 0
  ic.misses = 0
