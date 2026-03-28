## Benchmark: Interpreter vs JIT Tier 1 vs JIT Tier 2
##
## Shows the speed progression across execution tiers:
##   Tier 0  — switch-dispatch interpreter (~13 ns/instr, with superinstructions)
##   Tier 1  — baseline JIT (stack-machine → AArch64, no register alloc)
##   Tier 2  — optimizing JIT (SSA IR → regalloc → scheduled AArch64) [experimental]
##
## Compile:  nim c -r -d:release --mm:atomicArc tests/wasm/test_tier_comparison.nim

import std/[times, os, strutils]
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

when defined(macosx) and defined(arm64):
  import cps/wasm/jit/memory
  import cps/wasm/jit/compiler
  import cps/wasm/jit/pipeline
  import cps/wasm/jit/tier
  import cps/wasm/jit/ir
  import cps/wasm/jit/lower
  import cps/wasm/jit/cost
  import cps/wasm/jit/optimize  # for OptGating

# ---------------------------------------------------------------------------
# WASM builder helpers
# ---------------------------------------------------------------------------

proc leb128U32(v: uint32): seq[byte] =
  var val = v
  while true:
    var b = byte(val and 0x7F); val = val shr 7
    if val != 0: b = b or 0x80
    result.add(b); if val == 0: break

proc leb128S32(v: int32): seq[byte] =
  var val = v
  var more = true
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

proc wasmHeader(): seq[byte] =
  @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

proc funcType(params, results: seq[byte]): seq[byte] =
  result.add(0x60)
  result.add(leb128U32(uint32(params.len))); result.add(params)
  result.add(leb128U32(uint32(results.len))); result.add(results)

proc typeSection(types: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]
  c.add(leb128U32(uint32(types.len)))
  for t in types: c.add(t)
  result = section(1, c)

proc funcSection(typeIdxs: seq[uint32]): seq[byte] =
  result = section(3, vecU32(typeIdxs))

proc exportSection(exports: seq[tuple[name: string, kind: byte, idx: uint32]]): seq[byte] =
  var c: seq[byte]
  c.add(leb128U32(uint32(exports.len)))
  for exp in exports:
    c.add(leb128U32(uint32(exp.name.len)))
    for ch in exp.name: c.add(byte(ch))
    c.add(exp.kind); c.add(leb128U32(exp.idx))
  result = section(7, c)

proc memorySection(min: uint32): seq[byte] =
  var c: seq[byte]
  c.add(leb128U32(1)); c.add(0x00); c.add(leb128U32(min))
  result = section(5, c)

proc codeSection(bodies: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]
  c.add(leb128U32(uint32(bodies.len)))
  for b in bodies: c.add(leb128U32(uint32(b.len))); c.add(b)
  result = section(10, c)

proc funcBody(locals: seq[tuple[count: uint32, valType: byte]], code: seq[byte]): seq[byte] =
  var b: seq[byte]
  b.add(leb128U32(uint32(locals.len)))
  for l in locals: b.add(leb128U32(l.count)); b.add(l.valType)
  b.add(code); b.add(0x0B)
  result = b

# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

proc fmtMs(secs: float): string =
  if secs < 0.001:
    formatFloat(secs * 1_000_000, ffDecimal, 1) & " us"
  elif secs < 1.0:
    formatFloat(secs * 1000, ffDecimal, 2) & " ms"
  else:
    formatFloat(secs, ffDecimal, 3) & " s"

proc fmtSpeedup(base, fast: float): string =
  if fast > 0 and base > fast:
    formatFloat(base / fast, ffDecimal, 1) & "x faster"
  elif fast > 0:
    "1.0x"
  else:
    ""

when defined(macosx) and defined(arm64):
  type JitFuncPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                         memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

  proc fmtPoly(p: CostPoly): string =
    result = $p.constant
    for t in p.terms:
      result &= " + " & $t.coeff
      for i in 0 ..< MaxTermVars:
        if t.vars[i] >= 0:
          result &= "·n" & $t.vars[i].int

  proc printCostProfile(module: WasmModule, funcIdx: int, funcName: string) =
    ## Print the abstract cost domain analysis for a function.
    var numImportFuncs = 0
    for imp in module.imports:
      if imp.kind == ikFunc: inc numImportFuncs
    let codeIdx = funcIdx - numImportFuncs
    if codeIdx < 0 or codeIdx >= module.codes.len: return

    let irFunc = lowerFunction(module, funcIdx)
    let cs = analyzeCost(irFunc)
    let gating = computeOptGating(cs)

    # Use the same static bytecode analysis that the actual tiering uses
    let ft = module.types[module.funcTypeIdxs[codeIdx].int]
    var totalLocals: int16 = ft.params.len.int16
    for ld in module.codes[codeIdx].locals:
      totalLocals += ld.count.int16
    let staticProfile = analyzeStatic(
      module.codes[codeIdx].code.code, ft.params.len.int16, totalLocals)
    let (t1, t2) = computeStaticTierThresholds(staticProfile)

    let hasCalls = irFunc.callIndirectSiteCount > 0 or irFunc.nonSelfCallSiteCount > 0
    let costLabel = if hasCalls: "Frame Cost" else: "Total Cost"

    echo "  ┌─ " & funcName & ": " & costLabel & " = " & fmtPoly(cs.funcTotal.cycles) & " cycles"
    echo "  │  code_size:    " & fmtPoly(cs.funcTotal.codeSize) & " bytes"
    echo "  │  mem_traffic:  " & fmtPoly(cs.funcTotal.memOps) & " ops"
    echo "  │  reg_pressure: " & $cs.funcTotal.regPressure & " int, " &
         $cs.funcTotal.fpRegPressure & " fp" &
         (if cs.funcTotal.spillEstimate > 0:
            " (SPILL RISK: " & $cs.funcTotal.spillEstimate & " over limit)"
          else: "")
    if cs.loops.len > 0:
      for loop in cs.loops:
        var loopDesc = "  │  loop BB" & $loop.headerBb & ": " &
             fmtPoly(loop.bodyCost.cycles) & " cyc/iter, " &
             $loop.bodyCost.memOps.constant & " mem/iter"
        if loop.estimatedTrips > 0:
          loopDesc &= ", ~" & $loop.estimatedTrips & " trips"
        echo loopDesc
    # Gating: show what passes the cost model SKIPS (the interesting decision)
    var skipped: seq[string]
    if not gating.runLICM: skipped.add("loop-invariant-motion")
    if not gating.runLoopUnroll: skipped.add("loop-unroll")
    if not gating.runGlobalCSE: skipped.add("global-CSE")
    if not gating.runAliasBCE: skipped.add("alias-bounds-elim")
    if not gating.runStoreLoadForward: skipped.add("store-load-fwd")
    if not gating.runGlobalBCE: skipped.add("global-bounds-elim")
    if skipped.len > 0:
      echo "  │  skipped:      " & skipped.join(", ")
    echo "  │  tier-up: " & $t1 & " → Tier1, " & $t2 & " → Tier2"
    echo "  └─"

# ---------------------------------------------------------------------------
# Benchmark 1: Tight Loop (100M iterations)
# ---------------------------------------------------------------------------

proc benchLoop() =
  echo "--- Tight Loop (100M iterations, accumulator) ---"

  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("loop_sum", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[(2'u32, 0x7F'u8)],
    @[0x41'u8] & leb128S32(100_000_000i32) & @[
    0x21'u8, 0x00, 0x03, 0x40,
      0x20, 0x00, 0x20, 0x01, 0x6A, 0x21, 0x01,
      0x20, 0x00, 0x41, 0x01, 0x6B, 0x22, 0x00,
      0x0D, 0x00, 0x0B, 0x20, 0x01])]))

  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])

  let t0 = cpuTime()
  let r0 = vm.invoke(modIdx, "loop_sum", @[])
  let tInterp = cpuTime() - t0
  assert r0[0].i32 == 987459712
  echo "  Interpreter:  " & fmtMs(tInterp) & "  (" &
       formatFloat(tInterp * 1e9 / 1e8, ffDecimal, 1) & " ns/instr)"

  when defined(macosx) and defined(arm64):
    var pool = initJitMemPool()
    let nLocals = max(vm.store.funcs[0].localTypes.len, 1)

    let compiled = pool.compileFunction(module, 0)
    let fPtr = cast[JitFuncPtr](compiled.code.address)
    var locals1 = newSeq[uint64](nLocals)
    var vstack1 = newSeq[uint64](64)
    let t1 = cpuTime()
    discard fPtr(vstack1[0].addr, locals1[0].addr, nil, 0)
    let tT1 = cpuTime() - t1
    assert cast[int32](vstack1[0]) == 987459712
    echo "  JIT Tier 1:   " & fmtMs(tT1) & "  (" &
         formatFloat(tT1 * 1e9 / 1e8, ffDecimal, 1) & " ns/instr)  " &
         fmtSpeedup(tInterp, tT1)

    # --- Tier 2 ---
    let compiled2 = compileTier2(pool, module, 0)
    printCostProfile(module, 0, "loop_sum")
    let fPtr2 = cast[JitFuncPtr](compiled2.address)
    var locals2 = newSeq[uint64](nLocals)
    var vstack2 = newSeq[uint64](64)
    let t2 = cpuTime()
    discard fPtr2(vstack2[0].addr, locals2[0].addr, nil, 0)
    let tT2 = cpuTime() - t2
    assert cast[int32](vstack2[0]) == 987459712, "Tier 2 loop result: " & $cast[int32](vstack2[0])
    echo "  JIT Tier 2:   " & fmtMs(tT2) & "  (" &
         formatFloat(tT2 * 1e9 / 1e8, ffDecimal, 1) & " ns/instr)  " &
         fmtSpeedup(tInterp, tT2)

    pool.destroy()

  echo ""

# ---------------------------------------------------------------------------
# Benchmark 2: Arithmetic (sum of squares, 10M iterations)
# ---------------------------------------------------------------------------

proc benchArithmetic() =
  echo "--- Arithmetic (sum of squares, 10M iterations) ---"

  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("sum_sq", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[(2'u32, 0x7F'u8)],
    @[
    0x03'u8, 0x40,
      0x20, 0x01, 0x20, 0x01, 0x6C,
      0x20, 0x02, 0x6A, 0x21, 0x02,
      0x20, 0x01, 0x41, 0x01, 0x6A, 0x22, 0x01,
      0x20, 0x00, 0x48, 0x0D, 0x00,
    0x0B,
    0x20, 0x02,
  ])]))

  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  let n = 10_000_000i32

  let t0 = cpuTime()
  let r0 = vm.invoke(modIdx, "sum_sq", @[wasmI32(n)])
  let tInterp = cpuTime() - t0
  echo "  Interpreter:  " & fmtMs(tInterp)

  when defined(macosx) and defined(arm64):
    var pool = initJitMemPool()
    let expected = r0[0].i32

    let c1 = pool.compileFunction(module, 0)
    let fp1 = cast[JitFuncPtr](c1.code.address)
    var loc1 = newSeq[uint64](3); loc1[0] = n.uint64
    var vs1 = newSeq[uint64](64)
    let t1 = cpuTime()
    discard fp1(vs1[0].addr, loc1[0].addr, nil, 0)
    let tT1 = cpuTime() - t1
    assert cast[int32](vs1[0]) == expected, "Tier1: " & $cast[int32](vs1[0])
    echo "  JIT Tier 1:   " & fmtMs(tT1) & "  " & fmtSpeedup(tInterp, tT1)

    # --- Tier 2 ---
    let c2 = compileTier2(pool, module, 0)
    printCostProfile(module, 0, "sum_of_squares")
    let fp2 = cast[JitFuncPtr](c2.address)
    var loc2 = newSeq[uint64](3); loc2[0] = n.uint64
    var vs2 = newSeq[uint64](64)
    let t2 = cpuTime()
    discard fp2(vs2[0].addr, loc2[0].addr, nil, 0)
    let tT2 = cpuTime() - t2
    assert cast[int32](vs2[0]) == expected, "Tier2: " & $cast[int32](vs2[0])
    echo "  JIT Tier 2:   " & fmtMs(tT2) & "  " & fmtSpeedup(tInterp, tT2)

    pool.destroy()

  echo ""

# ---------------------------------------------------------------------------
# Benchmark 3: Memory (write + read 1M i32 values)
# ---------------------------------------------------------------------------

proc benchMemory() =
  echo "--- Memory (write + read 1M i32 values) ---"

  var wasm = wasmHeader()
  wasm.add(typeSection(@[
    funcType(@[0x7F'u8], @[]),
    funcType(@[0x7F'u8], @[0x7F'u8]),
  ]))
  wasm.add(funcSection(@[0'u32, 1'u32]))
  wasm.add(memorySection(256))
  wasm.add(exportSection(@[
    ("write", 0x00'u8, 0'u32),
    ("readsum", 0x00'u8, 1'u32),
  ]))
  wasm.add(codeSection(@[
    funcBody(@[(1'u32, 0x7F'u8)], @[
      0x03'u8, 0x40,
        0x20, 0x01, 0x41, 0x02, 0x74,
        0x20, 0x01, 0x36, 0x02, 0x00,
        0x20, 0x01, 0x41, 0x01, 0x6A, 0x22, 0x01,
        0x20, 0x00, 0x48, 0x0D, 0x00,
      0x0B]),
    funcBody(@[(2'u32, 0x7F'u8)], @[
      0x03'u8, 0x40,
        0x20, 0x02, 0x41, 0x02, 0x74,
        0x28, 0x02, 0x00,
        0x20, 0x01, 0x6A, 0x21, 0x01,
        0x20, 0x02, 0x41, 0x01, 0x6A, 0x22, 0x02,
        0x20, 0x00, 0x48, 0x0D, 0x00,
      0x0B, 0x20, 0x01]),
  ]))

  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  let n = 1_000_000i32

  let tw0 = cpuTime()
  discard vm.invoke(modIdx, "write", @[wasmI32(n)])
  let tIW = cpuTime() - tw0

  let tr0 = cpuTime()
  discard vm.invoke(modIdx, "readsum", @[wasmI32(n)])
  let tIR = cpuTime() - tr0

  echo "  Interpreter:  write " & fmtMs(tIW) & " / read " & fmtMs(tIR)

  when defined(macosx) and defined(arm64):
    var pool = initJitMemPool()
    var memBase: ptr byte = nil
    var memSize: uint64 = 0
    if vm.store.modules[0].memAddrs.len > 0:
      let memAddr = vm.store.modules[0].memAddrs[0]
      if vm.store.mems[memAddr].data.len > 0:
        memBase = vm.store.mems[memAddr].data[0].unsafeAddr
        memSize = vm.store.mems[memAddr].data.len.uint64

    let cW = pool.compileFunction(module, 0)
    let cR = pool.compileFunction(module, 1)
    let fpW = cast[JitFuncPtr](cW.code.address)
    let fpR = cast[JitFuncPtr](cR.code.address)

    block:
      var lW = newSeq[uint64](2); lW[0] = n.uint64
      var vsW = newSeq[uint64](64)
      let tw = cpuTime()
      discard fpW(vsW[0].addr, lW[0].addr, memBase, memSize)
      let tT1W = cpuTime() - tw

      var lR = newSeq[uint64](3); lR[0] = n.uint64
      var vsR = newSeq[uint64](64)
      let tr = cpuTime()
      discard fpR(vsR[0].addr, lR[0].addr, memBase, memSize)
      let tT1R = cpuTime() - tr

      echo "  JIT Tier 1:   write " & fmtMs(tT1W) & " (" & fmtSpeedup(tIW, tT1W) &
           ") / read " & fmtMs(tT1R) & " (" & fmtSpeedup(tIR, tT1R) & ")"

    # --- Tier 2 (memory) ---
    block:
      let tw2c = cpuTime()
      let cW2 = compileTier2(pool, module, 0)
      let cR2 = compileTier2(pool, module, 1)
      echo "  JIT Tier 2:   compile " & fmtMs(cpuTime() - tw2c)
      printCostProfile(module, 0, "mem_write")
      printCostProfile(module, 1, "mem_read")
      let fpW2 = cast[JitFuncPtr](cW2.address)
      let fpR2 = cast[JitFuncPtr](cR2.address)

      var lW2 = newSeq[uint64](2); lW2[0] = n.uint64
      var vsW2 = newSeq[uint64](64)
      let tw2 = cpuTime()
      discard fpW2(vsW2[0].addr, lW2[0].addr, memBase, memSize)
      let tT2W = cpuTime() - tw2

      var lR2 = newSeq[uint64](3); lR2[0] = n.uint64
      var vsR2 = newSeq[uint64](64)
      let tr2 = cpuTime()
      discard fpR2(vsR2[0].addr, lR2[0].addr, memBase, memSize)
      let tT2R = cpuTime() - tr2

      echo "  JIT Tier 2:   write " & fmtMs(tT2W) & " (" & fmtSpeedup(tIW, tT2W) &
           ") / read " & fmtMs(tT2R) & " (" & fmtSpeedup(tIR, tT2R) & ")"

    pool.destroy()

  echo ""

# ---------------------------------------------------------------------------
# Benchmark 4: Recursive Fibonacci (interpreter, clang-compiled)
# ---------------------------------------------------------------------------

proc benchFib() =
  echo "--- Recursive Fibonacci (clang -O2 WASM binary) ---"

  let wasmPath = currentSourcePath.parentDir / "testdata" / "fib.wasm"
  if not fileExists(wasmPath):
    echo "  SKIP: fib.wasm not found"
    echo ""
    return

  let data = readFile(wasmPath)
  let module = decodeModule(cast[seq[byte]](data))

  # --- Interpreter ---
  block:
    var vm = initWasmVM()
    let modIdx = vm.instantiate(module, @[])

    let t30 = cpuTime()
    let r30 = vm.invoke(modIdx, "fib", @[wasmI32(30)])
    let tI30 = cpuTime() - t30
    assert r30[0].i32 == 832040

    let t35 = cpuTime()
    let r35 = vm.invoke(modIdx, "fib", @[wasmI32(35)])
    let tI35 = cpuTime() - t35
    assert r35[0].i32 == 9227465

    echo "  Interpreter:  fib(30) " & fmtMs(tI30) & " / fib(35) " & fmtMs(tI35)

  # --- TieredVM (JIT with self-recursive calls) ---
  when defined(macosx) and defined(arm64):
    block:
      var tvm = initTieredVM()
      let modIdx = tvm.instantiate(module, @[])

      # Warm up: call fib with small values to trigger JIT compilation
      for i in 0 ..< JitCallThreshold + 5:
        discard tvm.invoke(modIdx, "fib", @[wasmI32(5)])

      # Now fib should be JIT-compiled — benchmark
      let t30 = cpuTime()
      let r30 = tvm.invoke(modIdx, "fib", @[wasmI32(30)])
      let tJ30 = cpuTime() - t30
      assert r30[0].i32 == 832040, "JIT fib(30) = " & $r30[0].i32

      let t35 = cpuTime()
      let r35 = tvm.invoke(modIdx, "fib", @[wasmI32(35)])
      let tJ35 = cpuTime() - t35
      assert r35[0].i32 == 9227465, "JIT fib(35) = " & $r35[0].i32

      echo "  JIT Tier 1:   fib(30) " & fmtMs(tJ30) & " / fib(35) " & fmtMs(tJ35)

      tvm.destroy()

    # --- Tier 2 (optimizing JIT with self-recursive calls) ---
    block:
      var pool = initJitMemPool()
      let fibCode = compileTier2(pool, module, 1, selfModuleIdx = 1)
      printCostProfile(module, 1, "fib")
      let fPtr = cast[JitFuncPtr](fibCode.address)
      let nLocals = fibCode.numLocals

      proc runFib(f: JitFuncPtr, n: int32, nl: int): int32 =
        var locals = newSeq[uint64](nl)
        locals[0] = n.uint64
        var vstack: array[1024, uint64]
        discard f(vstack[0].addr, locals[0].addr, nil, 0)
        cast[int32](vstack[0])

      let t30 = cpuTime()
      let r30 = runFib(fPtr, 30, nLocals)
      let tT230 = cpuTime() - t30
      assert r30 == 832040, "Tier2 fib(30) = " & $r30

      let t35 = cpuTime()
      let r35 = runFib(fPtr, 35, nLocals)
      let tT235 = cpuTime() - t35
      assert r35 == 9227465, "Tier2 fib(35) = " & $r35

      echo "  JIT Tier 2:   fib(30) " & fmtMs(tT230) & " / fib(35) " & fmtMs(tT235)
      pool.destroy()

  echo ""

# ---------------------------------------------------------------------------
# Benchmark 5: Binomial Coefficients (2-param self-recursive)
# ---------------------------------------------------------------------------

proc benchBinom() =
  echo "--- Binomial Coefficients C(n,k) (2-param self-recursive, clang -O2) ---"

  let wasmPath = currentSourcePath.parentDir / "testdata" / "binom.wasm"
  if not fileExists(wasmPath):
    echo "  SKIP: binom.wasm not found"
    echo ""
    return

  let data = readFile(wasmPath)
  let module = decodeModule(cast[seq[byte]](data))

  # Correctness reference: C(25,12) = 5200300, C(20,10) = 184756
  # --- Interpreter ---
  block:
    var vm = initWasmVM()
    let modIdx = vm.instantiate(module, @[])

    let t0 = cpuTime()
    let r0 = vm.invoke(modIdx, "binom", @[wasmI32(25), wasmI32(12)])
    let tI = cpuTime() - t0
    assert r0[0].i32 == 5200300, "interp binom(25,12)=" & $r0[0].i32

    echo "  Interpreter:  binom(25,12) " & fmtMs(tI)

  when defined(macosx) and defined(arm64):
    block:
      var tvm = initTieredVM()
      let modIdx = tvm.instantiate(module, @[])

      for i in 0 ..< JitCallThreshold + 5:
        discard tvm.invoke(modIdx, "binom", @[wasmI32(5), wasmI32(2)])

      let t0 = cpuTime()
      let r0 = tvm.invoke(modIdx, "binom", @[wasmI32(25), wasmI32(12)])
      let tJ = cpuTime() - t0
      assert r0[0].i32 == 5200300, "T1 binom(25,12)=" & $r0[0].i32

      echo "  JIT Tier 1:   binom(25,12) " & fmtMs(tJ) & "  " & fmtSpeedup(0.0, 0.0)
      tvm.destroy()

    block:
      var pool = initJitMemPool()
      let binomCode = compileTier2(pool, module, 0, selfModuleIdx = 0)
      printCostProfile(module, 0, "binom")
      let fPtr = cast[JitFuncPtr](binomCode.address)
      let nLocals = binomCode.numLocals

      proc runBinom(f: JitFuncPtr, n, k: int32, nl: int): int32 =
        var locals = newSeq[uint64](nl)
        locals[0] = n.uint64
        locals[1] = k.uint64
        var vstack: array[1024, uint64]
        discard f(vstack[0].addr, locals[0].addr, nil, 0)
        cast[int32](vstack[0])

      let r_chk = runBinom(fPtr, 25, 12, nLocals)
      assert r_chk == 5200300, "T2 binom(25,12)=" & $r_chk

      let t0 = cpuTime()
      let r0 = runBinom(fPtr, 25, 12, nLocals)
      let tT2 = cpuTime() - t0
      assert r0 == 5200300

      echo "  JIT Tier 2:   binom(25,12) " & fmtMs(tT2)
      pool.destroy()

  echo ""

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo ""
echo "========================================================================"
echo "       WebAssembly VM -- Interpreter vs JIT Tier Comparison"
echo "========================================================================"
echo ""
echo "  Tier 0: Switch-dispatch interpreter (with superinstructions)"
when defined(macosx) and defined(arm64):
  echo "  Tier 1: Baseline JIT (stack-machine -> AArch64)"
  echo "  Tier 2: Optimizing JIT (SSA IR -> regalloc -> AArch64)"
else:
  echo "  (JIT not available — showing interpreter only)"
echo ""

benchLoop()
benchArithmetic()
benchMemory()
benchFib()
benchBinom()

# Cleanup leftover debug files
for f in ["test_interp_fib_debug", "test_jit_fib_debug",
          "test_jit_import_check", "test_jit_100m_debug",
          "test_callJit_debug", "test_jit_loop_debug",
          "test_tier_loop_only", "test_tier_minimal"]:
  let p = currentSourcePath.parentDir / f & ".nim"
  if fileExists(p): removeFile(p)
  let b = currentSourcePath.parentDir / f
  if fileExists(b): removeFile(b)

echo "Done."
