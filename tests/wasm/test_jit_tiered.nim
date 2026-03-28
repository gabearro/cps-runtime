## Test: tiered compilation — interpreter auto-promotes to JIT

import std/[times, strutils]
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/jit/tier

proc leb128U32(v: uint32): seq[byte] =
  var val = v
  while true:
    var b = byte(val and 0x7F); val = val shr 7
    if val != 0: b = b or 0x80
    result.add(b); if val == 0: break

proc leb128S32(v: int32): seq[byte] =
  var val = v; var more = true
  while more:
    var b = byte(val and 0x7F); val = val shr 7
    if (val == 0 and (b and 0x40) == 0) or (val == -1 and (b and 0x40) != 0): more = false
    else: b = b or 0x80
    result.add(b)

proc vecU32(items: seq[uint32]): seq[byte] =
  result = leb128U32(uint32(items.len))
  for item in items: result.add(leb128U32(item))

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id); result.add(leb128U32(uint32(content.len))); result.add(content)

proc wasmHeader(): seq[byte] = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

proc funcType(p, r: seq[byte]): seq[byte] =
  result.add(0x60); result.add(leb128U32(uint32(p.len))); result.add(p)
  result.add(leb128U32(uint32(r.len))); result.add(r)

proc typeSection(types: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]; c.add(leb128U32(uint32(types.len)))
  for t in types: c.add(t); result = section(1, c)

proc funcSection(idxs: seq[uint32]): seq[byte] = section(3, vecU32(idxs))

proc exportSection(exps: seq[tuple[name: string, kind: byte, idx: uint32]]): seq[byte] =
  var c: seq[byte]; c.add(leb128U32(uint32(exps.len)))
  for e in exps:
    c.add(leb128U32(uint32(e.name.len)))
    for ch in e.name: c.add(byte(ch))
    c.add(e.kind); c.add(leb128U32(e.idx))
  section(7, c)

proc codeSection(bodies: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]; c.add(leb128U32(uint32(bodies.len)))
  for b in bodies: c.add(leb128U32(uint32(b.len))); c.add(b)
  section(10, c)

proc funcBody(locals: seq[tuple[count: uint32, valType: byte]], code: seq[byte]): seq[byte] =
  var b: seq[byte]; b.add(leb128U32(uint32(locals.len)))
  for l in locals: b.add(leb128U32(l.count)); b.add(l.valType)
  b.add(code); b.add(0x0B); b

proc testTieredCompilation() =
  # Sum function: loop that sums 1..n
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("sum", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[(1'u32, 0x7F'u8)], @[
    0x03'u8, 0x40,
      0x20, 0x00, 0x20, 0x01, 0x6A, 0x21, 0x01,
      0x20, 0x00, 0x41, 0x01, 0x6B, 0x22, 0x00,
      0x0D, 0x00,
    0x0B, 0x20, 0x01,
  ])]))

  let module = decodeModule(wasm)
  var tvm = initTieredVM()
  let modIdx = tvm.instantiate(module, @[])

  # First calls use interpreter (below adaptive threshold)
  # With adaptive tiering: small function + loop → threshold = 10
  let threshold = tvm.jitThresholds[tvm.vm.store.modules[modIdx].funcAddrs[0]]
  for i in 1 ..< threshold:
    let r = tvm.invoke(modIdx, "sum", @[wasmI32(10)])
    assert r[0].i32 == 55, "Interpreter: expected 55, got " & $r[0].i32
  echo "PASS: " & $(threshold - 1) & " interpreter calls correct (adaptive threshold=" & $threshold & ")"

  # Next call triggers JIT compilation
  let r50 = tvm.invoke(modIdx, "sum", @[wasmI32(100)])
  assert r50[0].i32 == 5050, "JIT: expected 5050, got " & $r50[0].i32
  echo "PASS: JIT promotion at call #" & $threshold & ", sum(100)=5050"

  # Subsequent calls use JIT
  let r = tvm.invoke(modIdx, "sum", @[wasmI32(1000)])
  assert r[0].i32 == 500500
  echo "PASS: JIT call sum(1000)=500500"

  tvm.destroy()

proc testTieredBenchmark() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("sum", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[(1'u32, 0x7F'u8)], @[
    0x03'u8, 0x40,
      0x20, 0x00, 0x20, 0x01, 0x6A, 0x21, 0x01,
      0x20, 0x00, 0x41, 0x01, 0x6B, 0x22, 0x00,
      0x0D, 0x00,
    0x0B, 0x20, 0x01,
  ])]))

  let module = decodeModule(wasm)
  var tvm = initTieredVM()
  let modIdx = tvm.instantiate(module, @[])

  # Warm up to trigger JIT
  for i in 1 .. 60:
    discard tvm.invoke(modIdx, "sum", @[wasmI32(10)])

  # Benchmark with JIT
  let t = cpuTime()
  let r = tvm.invoke(modIdx, "sum", @[wasmI32(1_000_000)])
  let elapsed = cpuTime() - t
  echo "PASS: Tiered JIT sum(1M): " & formatFloat(elapsed * 1000, ffDecimal, 2) & " ms"

  tvm.destroy()

proc testFrequencyWeightedTier2() =
  # ----------------------------------------------------------------
  # Part A: loop-bearing function gets a low Tier 2 threshold
  # ----------------------------------------------------------------
  # sum(n): loops n times accumulating a sum — 1 loop, tiny body
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("sum", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[(1'u32, 0x7F'u8)], @[
    0x03'u8, 0x40,
      0x20, 0x00, 0x20, 0x01, 0x6A, 0x21, 0x01,
      0x20, 0x00, 0x41, 0x01, 0x6B, 0x22, 0x00,
      0x0D, 0x00,
    0x0B, 0x20, 0x01,
  ])]))
  let loopModule = decodeModule(wasm)
  var tvmLoop = initTieredVM()
  let loopModIdx = tvmLoop.instantiate(loopModule, @[])
  let loopFuncAddr = tvmLoop.vm.store.modules[loopModIdx].funcAddrs[0]
  let loopT2 = tvmLoop.tier2Thresholds[loopFuncAddr]
  assert loopT2 < Tier2CallThreshold,
    "loop function tier2 threshold=" & $loopT2 & " should be < " & $Tier2CallThreshold
  echo "PASS: loop function tier2 threshold = " & $loopT2 & " (< Tier2CallThreshold=" & $Tier2CallThreshold & ")"

  # Drive exactly loopT2 calls — Tier 2 compile is queued after the last one
  for i in 1 .. loopT2:
    let r = tvmLoop.invoke(loopModIdx, "sum", @[wasmI32(10)])
    assert r[0].i32 == 55, "sum(10) = " & $r[0].i32 & " (expected 55) at call " & $i

  # Tier 2 compilation is now asynchronous: wait for the background thread.
  tvmLoop.waitForTier2(loopFuncAddr)

  assert tvmLoop.tier2Ptrs[loopFuncAddr] != nil,
    "Loop function not promoted to Tier 2 after " & $loopT2 & " calls"

  # Verify correctness from Tier 2
  let r2 = tvmLoop.invoke(loopModIdx, "sum", @[wasmI32(100)])
  assert r2[0].i32 == 5050, "Tier 2 sum(100) = " & $r2[0].i32 & " (expected 5050)"
  echo "PASS: loop function promoted to Tier 2 after " & $loopT2 & " calls, sum(100)=5050"
  tvmLoop.destroy()

  # ----------------------------------------------------------------
  # Part B: leaf function (no loops) gets a higher Tier 2 threshold
  # ----------------------------------------------------------------
  # add(a, b): purely arithmetic, no branches, no loops
  var wasm2 = wasmHeader()
  wasm2.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8], @[0x7F'u8])]))
  wasm2.add(funcSection(@[0'u32]))
  wasm2.add(exportSection(@[("add", 0x00'u8, 0'u32)]))
  wasm2.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,   # local.get 0
    0x20'u8, 0x01,   # local.get 1
    0x6A'u8])]))     # i32.add  (funcBody appends end 0x0B)
  let leafModule = decodeModule(wasm2)
  var tvmLeaf = initTieredVM()
  let leafModIdx = tvmLeaf.instantiate(leafModule, @[])
  let leafFuncAddr = tvmLeaf.vm.store.modules[leafModIdx].funcAddrs[0]
  let leafT2 = tvmLeaf.tier2Thresholds[leafFuncAddr]
  assert leafT2 > loopT2,
    "leaf tier2=" & $leafT2 & " should be > loop tier2=" & $loopT2
  echo "PASS: leaf function tier2 threshold = " & $leafT2 & " > loop threshold = " & $loopT2
  tvmLeaf.destroy()

testTieredCompilation()
testTieredBenchmark()
testFrequencyWeightedTier2()
echo ""
echo "All tiered compilation tests passed!"
