## Test: profile-guided optimization (PGO) data collection
##
## Tests:
##   1. Branch profiler records taken/not-taken counts correctly
##   2. call_indirect profiler records target frequencies correctly
##   3. getPgoData API returns correct data after interpreter runs
##   4. Branch probabilities propagate to irBrIf (branchProb field)
##   5. Tier 2 compilation with PGO data produces correct results
##   6. Re-instantiation resets stale profile data
##
## Module layout (branch test):
##   func 0: countTo(n: i32) -> i32
##     ;; loop from 0 to n-1, counting iterations.
##     ;; The loop-back BrIf is taken n times, not-taken once.
##     local.get 0      ;; i (= 0 initially)
##     i32.const 0
##     i32.eq           ;; n == 0?
##     if               ;; skip loop if n==0
##       i32.const 0
##       return
##     end
##     ;; loop body
##     block $exit
##       loop $top
##         local.get 1   ;; i
##         i32.const 1
##         i32.add
##         local.set 1   ;; i++
##         local.get 1
##         local.get 0
##         i32.lt_s      ;; i < n?
##         br_if $top    ;; taken n-1 times, not-taken once
##       end
##     end
##     local.get 1
##
## This test builds the WASM binary manually and uses the PGO API directly.

import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime
import cps/wasm/pgo
import cps/wasm/jit/memory
import cps/wasm/jit/pipeline
import cps/wasm/jit/lower
import cps/wasm/jit/ir

# ---------------------------------------------------------------------------
# Tiny WASM binary builders
# ---------------------------------------------------------------------------

proc leb(v: uint32): seq[byte] =
  var x = v
  while true:
    var b = byte(x and 0x7F); x = x shr 7
    if x != 0: b = b or 0x80
    result.add(b)
    if x == 0: break

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id); result.add(leb(uint32(content.len))); result.add(content)

# ---------------------------------------------------------------------------
# Build a simple branch-heavy module:
#   func 0: countUp(n: i32) -> i32
#   Counts from 0 to n and returns n (loop iterates n times).
# Bytecode: local.get 0; i32.const 0; i32.le_s; br_if $exit_early; loop ...
#
# We use a simpler module: plain countdown loop.
#   func 0: sumN(n: i32) -> i32
#     local 1: i32 (accumulator)
#     local.get 0        ;; n
#     block $out
#       loop $top
#         local.get 0    ;; n
#         i32.eqz        ;; n == 0?
#         br_if $out     ;; branch OUT when n==0 (taken once, not-taken n-1 times)
#         local.get 1    ;; acc
#         local.get 0    ;; n
#         i32.add
#         local.set 1    ;; acc += n
#         local.get 0    ;; n
#         i32.const 1
#         i32.sub
#         local.set 0    ;; n--
#         br $top        ;; always loop back
#       end
#     end
#     local.get 1        ;; return acc = sum(1..n) = n*(n+1)/2
# ---------------------------------------------------------------------------

proc buildSumNModule(): seq[byte] =
  result = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
  # Type section: 1 type (i32)->i32
  var tc: seq[byte]
  tc.add(leb(1'u32))
  tc.add(0x60'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8)
  tc.add(leb(1'u32)); tc.add(0x7F'u8)
  result.add(section(1, tc))
  # Function section
  var fc: seq[byte]
  fc.add(leb(1'u32)); fc.add(leb(0'u32))
  result.add(section(3, fc))
  # Code section: sumN body
  var body: seq[byte]
  # 1 local: i32 (accumulator at local 1)
  body.add(0x01'u8); body.add(0x01'u8); body.add(0x7F'u8)  # 1 local of type i32
  # block $out (0x02 block type void)
  body.add(0x02'u8); body.add(0x40'u8)
  # loop $top
  body.add(0x03'u8); body.add(0x40'u8)
  # local.get 0 (n)
  body.add(0x20'u8); body.add(0x00'u8)
  # i32.eqz
  body.add(0x45'u8)
  # br_if 1  (break out of block $out — distance 1 = skip loop + block)
  body.add(0x0D'u8); body.add(0x01'u8)
  # local.get 1 (acc)
  body.add(0x20'u8); body.add(0x01'u8)
  # local.get 0 (n)
  body.add(0x20'u8); body.add(0x00'u8)
  # i32.add
  body.add(0x6A'u8)
  # local.set 1 (acc += n)
  body.add(0x21'u8); body.add(0x01'u8)
  # local.get 0 (n)
  body.add(0x20'u8); body.add(0x00'u8)
  # i32.const 1
  body.add(0x41'u8); body.add(0x01'u8)
  # i32.sub
  body.add(0x6B'u8)
  # local.set 0 (n--)
  body.add(0x21'u8); body.add(0x00'u8)
  # br 0 (loop back to $top)
  body.add(0x0C'u8); body.add(0x00'u8)
  # end (loop)
  body.add(0x0B'u8)
  # end (block)
  body.add(0x0B'u8)
  # local.get 1 (return acc)
  body.add(0x20'u8); body.add(0x01'u8)
  # end (function)
  body.add(0x0B'u8)

  var cc: seq[byte]
  cc.add(leb(1'u32))
  cc.add(leb(uint32(body.len))); cc.add(body)
  result.add(section(10, cc))

# ---------------------------------------------------------------------------
# Test 1: PgoProfiler API correctness
# ---------------------------------------------------------------------------

proc testProfilerApi() =
  var p: PgoProfiler
  p.ensureFunc(0, 20)  # funcAddr=0, 20 instruction slots

  # Record branch at PC=5: taken twice, not-taken once
  p.recordBranch(0, 5, true)
  p.recordBranch(0, 5, true)
  p.recordBranch(0, 5, false)

  let data = p.getFuncData(0)
  assert data != nil, "getFuncData should return non-nil"
  assert data.branchProfiles[5].taken == 2, "taken count should be 2"
  assert data.branchProfiles[5].notTaken == 1, "notTaken count should be 1"

  let prob = branchTakenProb(data.branchProfiles[5])
  # 2 taken out of 3 total → prob ≈ 170 (2/3 * 255 = 170)
  assert prob in 168'u8 .. 172'u8, "prob should be ~170, got " & $prob

  # Out-of-range accesses should not crash
  p.recordBranch(99, 999, true)  # funcAddr not ensured
  p.recordBranch(0, 999, true)   # pc beyond allocated range

  echo "PASS: profiler API (recordBranch, branchTakenProb)"

  # Test call_indirect recording
  p.ensureFunc(1, 10)
  p.recordCallIndirect(1, 3, 42)
  p.recordCallIndirect(1, 3, 42)
  p.recordCallIndirect(1, 3, 99)

  let data2 = p.getFuncData(1)
  assert data2 != nil
  let prof = addr data2.callIndirectProfiles[3]
  assert prof.totalCount == 3, "totalCount should be 3"
  let hot = hotCalleeOf(prof)
  assert hot == 42, "hot callee should be 42, got " & $hot
  echo "PASS: profiler API (recordCallIndirect, hotCalleeOf)"

  # uint16 saturation
  p.ensureFunc(2, 5)
  for _ in 0 ..< 70000:
    p.recordBranch(2, 0, true)
  let data3 = p.getFuncData(2)
  assert data3.branchProfiles[0].taken == 0xFFFF'u16,
    "taken should saturate at 65535"
  echo "PASS: uint16 saturation"

  # Reset
  p.resetFunc(0)
  let data4 = p.getFuncData(0)
  assert data4.branchProfiles.len == 0 or data4.branchProfiles[5].taken == 0,
    "after reset, taken should be 0"
  echo "PASS: resetFunc"

# ---------------------------------------------------------------------------
# Test 2: Interpreter collects branch profiles via execute()
# ---------------------------------------------------------------------------

proc testInterpreterProfiling() =
  let wasm = buildSumNModule()
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  discard vm.instantiate(module, [])

  var profiler: PgoProfiler
  profiler.ensureFunc(0, 100)  # func 0 = sumN

  # Run sumN(5) = 15 through interpreter with profiler active
  let r = vm.execute(0, [WasmValue(kind: wvkI32, i32: 5'i32)], addr profiler)
  assert r.len == 1 and r[0].i32 == 15, "sumN(5) should be 15, got " & $r[0].i32

  let data = profiler.getFuncData(0)
  assert data != nil, "PGO data should exist for funcAddr 0"

  # The loop-exit br_if was taken once (when n decrements to 0)
  # and not-taken 5 times (once per iteration before that).
  # Find the br_if instruction — it's the conditional branch in the loop.
  var totalTaken = 0'u32
  var totalNotTaken = 0'u32
  for bp in data.branchProfiles:
    totalTaken    += bp.taken.uint32
    totalNotTaken += bp.notTaken.uint32
  # sumN(5): the br_if fires 6 times total: 1 taken (exit) + 5 not-taken (loop back)
  assert totalTaken    >= 1, "at least 1 taken branch expected"
  assert totalNotTaken >= 5, "at least 5 not-taken branches expected"

  echo "PASS: interpreter profiling (taken=" & $totalTaken &
       ", notTaken=" & $totalNotTaken & ")"

# ---------------------------------------------------------------------------
# Test 3: branchProb propagates through lowerFunction
# ---------------------------------------------------------------------------

proc testBranchProbLowering() =
  let wasm = buildSumNModule()
  let module = decodeModule(wasm)

  # Find the actual PC of the opBrIf in the decoded instruction stream.
  var numImportFuncs = 0
  for imp in module.imports:
    if imp.kind == ikFunc: inc numImportFuncs
  let body = module.codes[0]  # func 0 = sumN (no imports)
  var brIfPc = -1
  for pc in 0 ..< body.code.code.len:
    if body.code.code[pc].op == opBrIf:
      brIfPc = pc
      break
  assert brIfPc >= 0, "opBrIf not found in sumN body"

  # Build PGO data manually: this branch is highly biased
  # (taken once = loop exit, not-taken many times = loop continues).
  var profiler: PgoProfiler
  profiler.ensureFunc(0, body.code.code.len)
  for _ in 0 ..< 1:   profiler.recordBranch(0, brIfPc, true)
  for _ in 0 ..< 50:  profiler.recordBranch(0, brIfPc, false)

  let pgoData = profiler.getFuncData(0)
  let irFunc = lowerFunction(module, 0, pgoData)

  # Check that at least one irBrIf in the lowered IR has a non-default branchProb.
  var foundNonDefault = false
  for bb in irFunc.blocks:
    for instr in bb.instrs:
      if instr.op == irBrIf and instr.branchProb != 128:
        foundNonDefault = true
        break
    if foundNonDefault: break

  assert foundNonDefault,
    "lowerFunction should propagate PGO branchProb to irBrIf"
  echo "PASS: branchProb propagated to irBrIf by lowerFunction"

# ---------------------------------------------------------------------------
# Test 4: End-to-end — PGO-guided Tier 2 compilation gives correct results
# ---------------------------------------------------------------------------

proc testPgoTier2Compilation() =
  let wasm = buildSumNModule()
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  discard vm.instantiate(module, [])

  # Build PGO data by running through interpreter multiple times
  var profiler: PgoProfiler
  profiler.ensureFunc(0, 100)
  for n in 1..10:
    discard vm.execute(0, [WasmValue(kind: wvkI32, i32: n.int32)], addr profiler)

  let pgoData = profiler.getFuncData(0)
  var pool = initJitMemPool()

  # Compile with PGO guidance
  let code = pool.compileTier2(module, funcIdx = 0, selfModuleIdx = 0,
                               pgoData = pgoData)
  assert code.address != nil, "Tier 2 compilation with PGO data should succeed"

  # Verify correctness: results must be identical regardless of PGO hints
  type JitFnPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                       memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}
  let fn = cast[JitFnPtr](code.address)

  proc callJit(n: int32): int32 =
    var vs: array[8, uint64]
    var locs: array[4, uint64] = [n.uint64, 0, 0, 0]
    let r = fn(vs[0].addr, locs[0].addr, nil, 0)
    let cnt = (cast[uint](r) - cast[uint](vs[0].addr)) div 8
    assert cnt == 1
    cast[int32](vs[0] and 0xFFFFFFFF'u64)

  assert callJit(0) == 0,  "sumN(0) = 0"
  assert callJit(1) == 1,  "sumN(1) = 1"
  assert callJit(5) == 15, "sumN(5) = 15"
  assert callJit(10) == 55, "sumN(10) = 55"

  echo "PASS: Tier 2 with PGO data gives correct results"
  pool.destroy()

# ---------------------------------------------------------------------------
# Test 5: isMegamorphic detection
# ---------------------------------------------------------------------------

proc testMegamorphic() =
  var p: PgoProfiler
  p.ensureFunc(0, 10)

  # Monomorphic: one callee dominates
  for _ in 0 ..< 90: p.recordCallIndirect(0, 0, 1)
  for _ in 0 ..< 10: p.recordCallIndirect(0, 0, 2)
  let data = p.getFuncData(0)
  assert not isMegamorphic(addr data.callIndirectProfiles[0]),
    "single dominant callee should not be megamorphic"

  # Reset and make it megamorphic: 4 callees, roughly equal distribution
  p.resetFunc(0)
  p.ensureFunc(0, 10)
  for i in 1..4:
    for _ in 0 ..< 25: p.recordCallIndirect(0, 0, i.int32)
  let data2 = p.getFuncData(0)
  assert isMegamorphic(addr data2.callIndirectProfiles[0]),
    "4 equal callees should be megamorphic"

  echo "PASS: isMegamorphic detection"

# ---------------------------------------------------------------------------
when isMainModule:
  testProfilerApi()
  testInterpreterProfiling()
  testBranchProbLowering()
  testPgoTier2Compilation()
  testMegamorphic()
  echo "All PGO tests passed!"
