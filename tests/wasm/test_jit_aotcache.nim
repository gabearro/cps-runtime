## Test: persistent AOT JIT cache — save compiled code to disk, reload on next run.
##
## Uses a temp directory so the test is self-contained.

import std/[os, strutils]
import cps/wasm/types   # WasmVal, wvkI32, wasmI32
import cps/wasm/binary   # decodeModule
import cps/wasm/jit/tier
import cps/wasm/jit/aotcache

# ---------------------------------------------------------------------------
# Minimal WASM builder helpers (copied from test_jit_tiered.nim)
# ---------------------------------------------------------------------------

proc leb128U32(v: uint32): seq[byte] =
  var val = v
  while true:
    var b = byte(val and 0x7F); val = val shr 7
    if val != 0: b = b or 0x80
    result.add(b)
    if val == 0: break

proc leb128S32(v: int32): seq[byte] =
  var val = v; var more = true
  while more:
    var b = byte(val and 0x7F); val = val shr 7
    if (val == 0 and (b and 0x40) == 0) or (val == -1 and (b and 0x40) != 0): more = false
    else: b = b or 0x80
    result.add(b)

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id); result.add(leb128U32(uint32(content.len))); result.add(content)

proc wasmHeader(): seq[byte] = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

proc funcType(p, r: seq[byte]): seq[byte] =
  result.add(0x60); result.add(leb128U32(uint32(p.len))); result.add(p)
  result.add(leb128U32(uint32(r.len))); result.add(r)

proc typeSection(types: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]; c.add(leb128U32(uint32(types.len)))
  for t in types: c.add(t)
  section(1, c)

proc funcSection(idxs: seq[uint32]): seq[byte] =
  var c = leb128U32(uint32(idxs.len))
  for i in idxs: c.add(leb128U32(i))
  section(3, c)

proc exportSection(exps: seq[tuple[name: string, kind: byte, idx: uint32]]): seq[byte] =
  var c: seq[byte]; c.add(leb128U32(uint32(exps.len)))
  for e in exps:
    c.add(leb128U32(uint32(e.name.len)))
    for ch in e.name: c.add(byte(ch))
    c.add(e.kind); c.add(leb128U32(e.idx))
  section(7, c)

proc codeSection(bodies: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]; c.add(leb128U32(uint32(bodies.len)))
  for b in bodies:
    c.add(leb128U32(uint32(b.len))); c.add(b)
  section(10, c)

proc funcBody(locals: seq[tuple[count: uint32, valType: byte]], code: seq[byte]): seq[byte] =
  var b: seq[byte]; b.add(leb128U32(uint32(locals.len)))
  for l in locals: b.add(leb128U32(l.count)); b.add(l.valType)
  b.add(code); b.add(0x0B); b

# ---------------------------------------------------------------------------
# Build a simple WASM module: sum(i32, i32) -> i32
# ---------------------------------------------------------------------------

proc buildSumModule(): seq[byte] =
  let i32 = 0x7F'u8
  let ty  = funcType(@[i32, i32], @[i32])
  # Body: local.get 0 + local.get 1 + end
  let body = funcBody(@[], @[0x20'u8, 0x00, 0x20, 0x01, 0x6A])
  result = wasmHeader() &
           typeSection(@[ty]) &
           funcSection(@[0'u32]) &
           exportSection(@[("sum", 0x00.byte, 0'u32)]) &
           codeSection(@[body])

# ---------------------------------------------------------------------------
# Test: compile, save, load from cache, verify result matches
# ---------------------------------------------------------------------------

proc testAotCacheSaveAndLoad() =
  let tmpDir = getTempDir() / "wasm_aot_cache_test"
  createDir(tmpDir)
  defer: removeDir(tmpDir)

  let moduleBytes = buildSumModule()
  let modHash = fnv1a64(moduleBytes)

  # --- First run: compile and save cache ---
  block firstRun:
    var tvm = initTieredVM()
    tvm.enableAotCache(tmpDir)
    tvm.setModuleBytes(moduleBytes)

    let module = decodeModule(moduleBytes)
    discard tvm.instantiate(module, @[])

    # Drive call count past Tier 2 threshold to trigger background compilation
    for _ in 0 ..< Tier2CallThreshold + 100:
      discard tvm.invoke(0, "sum", @[wasmI32(3), wasmI32(4)])

    # Wait for the background Tier 2 compilation to complete and install result
    tvm.waitForTier2(0)
    # One more invoke to trigger pollBgResults which saves codeBytes to pendingCache
    discard tvm.invoke(0, "sum", @[wasmI32(1), wasmI32(1)])

    tvm.destroy()  # flushes pendingCache to disk

  # Verify cache file was created
  let cacheFile = cachePath(tmpDir, modHash)
  assert fileExists(cacheFile), "Cache file not written: " & cacheFile

  # --- Second run: load from cache, skip recompilation ---
  block secondRun:
    var tvm = initTieredVM()
    tvm.enableAotCache(tmpDir)
    tvm.setModuleBytes(moduleBytes)

    let module = decodeModule(moduleBytes)
    let modIdx2 = tvm.instantiate(module, @[])

    # Load from cache before any invocations
    let loaded = tvm.tryLoadFromAotCache()
    assert loaded, "Expected cache to load at least one function"

    # The function should already be at Tier 2 (from cache)
    let fa = tvm.vm.store.modules[modIdx2].funcAddrs[0]
    assert tvm.tier2Ptrs[fa] != nil, "Tier 2 ptr should be set from cache"

    # Verify the loaded code produces correct results
    let result = tvm.invoke(modIdx2, "sum", @[wasmI32(10), wasmI32(32)])
    assert result.len == 1 and result[0].kind == wvkI32, "Expected i32 result"
    assert result[0].i32 == 42, "Expected 42, got " & $result[0].i32

    tvm.destroy()

  echo "PASS: AOT cache save and load"

proc testAotCacheHashMismatch() =
  ## Verify that a cache file built for a different module is rejected.
  let tmpDir = getTempDir() / "wasm_aot_hash_test"
  createDir(tmpDir)
  defer: removeDir(tmpDir)

  # Write a fake cache file keyed by realHash but with a different hash inside
  let fakeHash = 0xDEAD_BEEF_CAFE_BABE'u64
  let realHash = fnv1a64(buildSumModule())
  assert fakeHash != realHash
  let p = cachePath(tmpDir, realHash)
  writeCacheFile(p, AotCache(moduleHash: fakeHash, funcs: @[]))

  var tvm = initTieredVM()
  tvm.enableAotCache(tmpDir)
  let moduleBytes = buildSumModule()
  tvm.setModuleBytes(moduleBytes)

  let module = decodeModule(moduleBytes)
  discard tvm.instantiate(module, @[])
  let loaded = tvm.tryLoadFromAotCache()
  assert not loaded, "Should not load cache with wrong hash"
  tvm.destroy()

  echo "PASS: AOT cache hash mismatch rejected"

proc testAotCacheMissingFile() =
  let tmpDir = getTempDir() / "wasm_aot_missing_test"
  createDir(tmpDir)
  defer: removeDir(tmpDir)

  var tvm = initTieredVM()
  tvm.enableAotCache(tmpDir)
  let moduleBytes = buildSumModule()
  tvm.setModuleBytes(moduleBytes)

  let module = decodeModule(moduleBytes)
  discard tvm.instantiate(module, @[])
  let loaded = tvm.tryLoadFromAotCache()  # no file exists yet
  assert not loaded, "Should return false for missing cache"
  tvm.destroy()

  echo "PASS: AOT cache missing file handled"

testAotCacheSaveAndLoad()
testAotCacheHashMismatch()
testAotCacheMissingFile()
echo "All AOT cache tests passed!"
