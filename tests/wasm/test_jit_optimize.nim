## Test: alias-aware BCE and register promotion passes
##
## 1. boundsCheckElimAlias: struct-field accesses share a single bounds check
## 2. promoteLocals: dead irLocalSet instructions are eliminated
## Both passes are verified by running compiled functions and checking output.

import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime
import cps/wasm/jit/memory
import cps/wasm/jit/pipeline
import cps/wasm/jit/ir
import cps/wasm/jit/lower
import cps/wasm/jit/optimize

# ---- Helpers ----

proc leb(v: uint32): seq[byte] =
  var x = v
  while true:
    var b = byte(x and 0x7F); x = x shr 7
    if x != 0: b = b or 0x80
    result.add(b)
    if x == 0: break

proc sleb(v: int32): seq[byte] =
  var x = v; var more = true
  while more:
    var b = byte(x and 0x7F); x = x shr 7
    let sign = (b and 0x40) != 0
    if (x == 0 and not sign) or (x == -1 and sign): more = false
    else: b = b or 0x80
    result.add(b)

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id); result.add(leb(uint32(content.len))); result.add(content)

proc buildModule(typeBytes, funcBytes, memBytes, codeBytes: seq[byte]): WasmModule =
  var wasm = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
  wasm.add(section(1, typeBytes))
  wasm.add(section(3, funcBytes))
  if memBytes.len > 0: wasm.add(section(5, memBytes))
  wasm.add(section(10, codeBytes))
  decodeModule(wasm)

proc buildModuleNoMem(typeBytes, funcBytes, codeBytes: seq[byte]): WasmModule =
  buildModule(typeBytes, funcBytes, @[], codeBytes)

type JitFnPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                     memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

proc callJit(pool: var JitMemPool, module: WasmModule, funcIdx: int,
             args: openArray[int32],
             memBase: ptr byte = nil, memSize: uint64 = 0): int32 =
  let compiled = pool.compileTier2(module, funcIdx)
  let fn = cast[JitFnPtr](compiled.address)
  var vstack: array[16, uint64]
  var locals: array[16, uint64]
  for i in 0 ..< min(args.len, locals.len):
    locals[i] = cast[uint64](args[i])
  let ret = fn(vstack[0].addr, locals[0].addr, memBase, memSize)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "Expected 1 return value, got " & $cnt
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

proc runInterp(module: WasmModule, funcIdx: int, args: seq[WasmValue],
               mem: seq[byte] = @[]): seq[WasmValue] =
  var vm = initWasmVM()
  let instIdx = vm.instantiate(module, [])
  if mem.len > 0 and vm.store.modules[instIdx].memAddrs.len > 0:
    let memAddr = vm.store.modules[instIdx].memAddrs[0]
    let copyLen = min(mem.len, vm.store.mems[memAddr].data.len)
    for i in 0 ..< copyLen:
      vm.store.mems[memAddr].data[i] = mem[i]
  let modInst = vm.store.modules[instIdx]
  let funcAddr = modInst.funcAddrs[funcIdx]
  vm.execute(funcAddr, args)

# ============================================================================
# Test 1: Alias-aware BCE — struct field access pattern
# ============================================================================
# WASM: load i32 at base+0, base+4, base+8 and return sum.
# Without alias analysis, 3 bounds checks; with alias analysis, only the
# widest one (base+8+4=12) should remain — the others are subsumed.
# We verify functional correctness (the optimizer must not change the result).
#
# Function signature: (i32 base_offset) -> i32
# Memory: [0..11] contains {10, 20, 30} as i32 little-endian
# Returns: sum = 60
block testAliasBce:
  # Type section: (i32) -> i32
  var tc: seq[byte]
  tc.add(leb(1'u32))
  tc.add(0x60'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8)
  tc.add(leb(1'u32)); tc.add(0x7F'u8)

  var fc: seq[byte]
  fc.add(leb(1'u32)); fc.add(leb(0'u32))

  # Memory section: 1 page (64KB)
  var mc: seq[byte]
  mc.add(leb(1'u32))           # 1 memory
  mc.add(0x00'u8)              # min only
  mc.add(leb(1'u32))           # 1 page

  # Function body: 0 extra locals
  # local.get 0  (base_offset)
  # i32.load offset=0 → field0
  # local.get 0
  # i32.load offset=4 → field1
  # i32.add
  # local.get 0
  # i32.load offset=8 → field2
  # i32.add
  var body: seq[byte]
  body.add(0x00'u8)   # 0 local groups
  body &= @[
    0x20'u8, 0x00,         # local.get 0
    0x28'u8, 0x02, 0x00,   # i32.load align=2 offset=0
    0x20'u8, 0x00,         # local.get 0
    0x28'u8, 0x02, 0x04,   # i32.load align=2 offset=4
    0x6A'u8,               # i32.add
    0x20'u8, 0x00,         # local.get 0
    0x28'u8, 0x02, 0x08,   # i32.load align=2 offset=8
    0x6A'u8,               # i32.add
    0x0B'u8]               # end

  var cc: seq[byte]
  cc.add(leb(1'u32))
  cc.add(leb(uint32(body.len))); cc.add(body)

  let module = buildModule(tc, fc, mc, cc)

  # Set up memory with three i32 fields: 10, 20, 30
  var mem: array[64 * 1024, byte]
  # field0 @ offset 0: value 10
  mem[0] = 10; mem[1] = 0; mem[2] = 0; mem[3] = 0
  # field1 @ offset 4: value 20
  mem[4] = 20; mem[5] = 0; mem[6] = 0; mem[7] = 0
  # field2 @ offset 8: value 30
  mem[8] = 30; mem[9] = 0; mem[10] = 0; mem[11] = 0

  # Interpreter baseline
  var memData = newSeq[byte](65536)
  for i in 0 ..< 12: memData[i] = mem[i]
  let r_interp = runInterp(module, 0, @[WasmValue(kind: wvkI32, i32: 0)], memData)
  assert r_interp.len == 1 and r_interp[0].i32 == 60,
    "interp: struct_sum = " & $r_interp[0].i32 & " (expected 60)"

  # Tier 2 JIT
  var pool = initJitMemPool()
  let r_jit = callJit(pool, module, 0, [0'i32],
                      cast[ptr byte](mem[0].addr), uint64(mem.len))
  assert r_jit == 60, "JIT: struct_sum = " & $r_jit & " (expected 60)"
  pool.destroy()
  echo "PASS: alias BCE — struct field access (base+0, base+4, base+8): sum=60"

# ============================================================================
# Test 2: Alias BCE with base offset — verify non-zero base works
# ============================================================================
# Same struct but accessed at base_offset = 8 (fields at 8, 12, 16).
# Verifies origin tracking with non-zero pointer values.
block testAliasBceOffset:
  var tc: seq[byte]
  tc.add(leb(1'u32))
  tc.add(0x60'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8)
  tc.add(leb(1'u32)); tc.add(0x7F'u8)
  var fc: seq[byte]
  fc.add(leb(1'u32)); fc.add(leb(0'u32))
  var mc: seq[byte]
  mc.add(leb(1'u32)); mc.add(0x00'u8); mc.add(leb(1'u32))
  var body: seq[byte]
  body.add(0x00'u8)
  body &= @[
    0x20'u8, 0x00,
    0x28'u8, 0x02, 0x00,
    0x20'u8, 0x00,
    0x28'u8, 0x02, 0x04,
    0x6A'u8,
    0x20'u8, 0x00,
    0x28'u8, 0x02, 0x08,
    0x6A'u8,
    0x0B'u8]
  var cc: seq[byte]
  cc.add(leb(1'u32))
  cc.add(leb(uint32(body.len))); cc.add(body)
  let module = buildModule(tc, fc, mc, cc)
  var mem: array[64 * 1024, byte]
  # Fields at 8, 12, 16 with values 100, 200, 300
  mem[8] = 100; mem[12] = 200; mem[16] = 0x2C; mem[17] = 0x01  # 300 = 0x012C
  var memData = newSeq[byte](65536)
  for i in 0 ..< 65536: memData[i] = mem[i]
  let r_interp = runInterp(module, 0, @[WasmValue(kind: wvkI32, i32: 8)], memData)
  assert r_interp.len == 1 and r_interp[0].i32 == 600,
    "interp: struct_sum(base=8) = " & $r_interp[0].i32
  var pool = initJitMemPool()
  let r_jit = callJit(pool, module, 0, [8'i32],
                      cast[ptr byte](mem[0].addr), uint64(mem.len))
  assert r_jit == 600, "JIT: struct_sum(base=8) = " & $r_jit & " (expected 600)"
  pool.destroy()
  echo "PASS: alias BCE — non-zero base offset, struct sum=600"

# ============================================================================
# Test 3: Register promotion — function with many locals, all arithmetic
# ============================================================================
# WASM: (a, b, c) -> ((a + b) * c) - a
# Uses local.get/local.set for temporaries.  promoteLocals should remove
# dead irLocalSet instructions without changing results.
block testPromoteLocals:
  var tc: seq[byte]
  tc.add(leb(1'u32))
  tc.add(0x60'u8); tc.add(leb(3'u32))
  tc.add(0x7F'u8); tc.add(0x7F'u8); tc.add(0x7F'u8)
  tc.add(leb(1'u32)); tc.add(0x7F'u8)
  var fc: seq[byte]
  fc.add(leb(1'u32)); fc.add(leb(0'u32))
  # Body: 2 extra locals (temp0, temp1)
  # temp0 = a + b
  # temp1 = temp0 * c
  # result = temp1 - a
  var body: seq[byte]
  body.add(0x01'u8)   # 1 local group
  body.add(0x02'u8)   # 2 locals
  body.add(0x7F'u8)   # i32
  body &= @[
    0x20'u8, 0x00,   # local.get 0 (a)
    0x20'u8, 0x01,   # local.get 1 (b)
    0x6A'u8,         # i32.add (a+b)
    0x21'u8, 0x03,   # local.set 3 (temp0 = a+b)
    0x20'u8, 0x03,   # local.get 3 (temp0)
    0x20'u8, 0x02,   # local.get 2 (c)
    0x6C'u8,         # i32.mul (temp0 * c)
    0x21'u8, 0x04,   # local.set 4 (temp1 = temp0*c)
    0x20'u8, 0x04,   # local.get 4 (temp1)
    0x20'u8, 0x00,   # local.get 0 (a)
    0x6B'u8,         # i32.sub
    0x0B'u8]         # end
  var cc: seq[byte]
  cc.add(leb(1'u32))
  cc.add(leb(uint32(body.len))); cc.add(body)
  let module = buildModuleNoMem(tc, fc, cc)
  # (3+7)*5 - 3 = 50 - 3 = 47
  let r_interp = runInterp(module, 0,
    @[WasmValue(kind: wvkI32, i32: 3),
      WasmValue(kind: wvkI32, i32: 7),
      WasmValue(kind: wvkI32, i32: 5)])
  assert r_interp.len == 1 and r_interp[0].i32 == 47,
    "interp: ((3+7)*5)-3 = " & $r_interp[0].i32
  var pool = initJitMemPool()
  let r_jit = callJit(pool, module, 0, [3'i32, 7'i32, 5'i32])
  assert r_jit == 47, "JIT: ((3+7)*5)-3 = " & $r_jit & " (expected 47)"
  pool.destroy()
  echo "PASS: promoteLocals — ((3+7)*5)-3 = 47"

# ============================================================================
# Test 4: IR-level promoteLocals pass (unit test)
# ============================================================================
# Directly call lowerFunction + promoteLocals to verify that dead irLocalSet
# instructions are removed.  Build a sum(n) loop function and confirm that
# the pass runs without error and the IR has fewer irLocalSet after promotion.
block testPromoteLocalsUnit:
  # Build the same sum(n) WASM module used in other tests
  var tc: seq[byte]
  tc.add(leb(1'u32))
  tc.add(0x60'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8)
  tc.add(leb(1'u32)); tc.add(0x7F'u8)
  var fc: seq[byte]
  fc.add(leb(1'u32)); fc.add(leb(0'u32))
  var body: seq[byte]
  body.add(0x01'u8); body.add(0x01'u8); body.add(0x7F'u8)   # 1 extra i32 local
  body &= @[
    0x03'u8, 0x40,                                  # loop []
      0x20'u8, 0x00, 0x20'u8, 0x01, 0x6A'u8, 0x21'u8, 0x01,  # acc += n
      0x20'u8, 0x00, 0x41'u8, 0x01, 0x6B'u8, 0x22'u8, 0x00,  # n--
      0x0D'u8, 0x00,                                # br_if 0
    0x0B'u8,                                        # end loop
    0x20'u8, 0x01,                                  # local.get acc
    0x0B'u8,                                        # end function
  ]
  var cc: seq[byte]
  cc.add(leb(1'u32))
  cc.add(leb(uint32(body.len))); cc.add(body)
  var wasm = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
  wasm.add(section(1, tc)); wasm.add(section(3, fc)); wasm.add(section(10, cc))
  let module = decodeModule(wasm)

  # Lower to IR and count irLocalSet BEFORE promotion
  var irBefore = lowerFunction(module, 0)
  var setsBefore = 0
  for bb in irBefore.blocks:
    for instr in bb.instrs:
      if instr.op == irLocalSet: inc setsBefore

  # Run DCE first (mirrors optimizeIr ordering) then promoteLocals.
  # DCE removes dead irLocalGet (e.g., the loop variable 'n' reload that is
  # never returned), and promoteLocals then eliminates the orphaned irLocalSet.
  var irAfter = lowerFunction(module, 0)
  deadCodeElim(irAfter)
  promoteLocals(irAfter)
  var setsAfter = 0
  for bb in irAfter.blocks:
    for instr in bb.instrs:
      if instr.op == irLocalSet: inc setsAfter

  # sum(n) returns only local 1 (accumulator).  local 0 (n) is decremented in
  # the loop but its exit-value irLocalGet is dead → DCE removes it → promoteLocals
  # removes the corresponding irLocalSet.  So setsAfter should be < setsBefore.
  assert setsAfter < setsBefore,
    "promoteLocals should reduce irLocalSet: before=" & $setsBefore & " after=" & $setsAfter
  echo "PASS: promoteLocals unit — irLocalSet reduced from " & $setsBefore & " to " & $setsAfter

# ============================================================================
# Test 5: IR-level boundsCheckElimAlias (unit test)
# ============================================================================
# Build a WASM function that first does a WIDE access (base+8, reach=12) and
# then a narrower access via a DERIVED pointer (ptr2 = base + 4; load ptr2+0,
# reach=8).  Because ptr2 is a different SSA value, basic BCE misses the
# redundancy — but alias BCE traces ptr2's origin back to base and eliminates
# the second bounds check.
#
# WASM body (i32 base) -> i32:
#   local.get 0             ; push base
#   i32.load offset=8       ; wide load (base+8..12)  — reach = 12
#   local.get 0             ; push base
#   i32.const 4             ; push 4
#   i32.add                 ; ptr2 = base + 4  (new SSA value!)
#   i32.load offset=0       ; narrow load (ptr2+0 = base+4..8) — reach = 8 ≤ 12
#   i32.add                 ; sum of both
block testAliasBceUnit:
  var tc: seq[byte]
  tc.add(leb(1'u32))
  tc.add(0x60'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8)
  tc.add(leb(1'u32)); tc.add(0x7F'u8)
  var fc: seq[byte]
  fc.add(leb(1'u32)); fc.add(leb(0'u32))
  var mc: seq[byte]
  mc.add(leb(1'u32)); mc.add(0x00'u8); mc.add(leb(1'u32))
  var body: seq[byte]
  body.add(0x00'u8)
  body &= @[
    0x20'u8, 0x00,         # local.get 0 (base)
    0x28'u8, 0x02, 0x08,   # i32.load align=2 offset=8   — wide, reach=12
    0x20'u8, 0x00,         # local.get 0 (base)
    0x41'u8, 0x04,         # i32.const 4
    0x6A'u8,               # i32.add  → ptr2 = base + 4  (different SSA value)
    0x28'u8, 0x02, 0x00,   # i32.load align=2 offset=0   — narrow via ptr2, reach=8
    0x6A'u8,               # i32.add (sum)
    0x0B'u8]               # end
  var cc: seq[byte]
  cc.add(leb(1'u32))
  cc.add(leb(uint32(body.len))); cc.add(body)
  let module = buildModule(tc, fc, mc, cc)

  const boundsCheckedFlag = 0x40000000'i32

  proc countFlagged(f: IrFunc): int =
    for bb in f.blocks:
      for instr in bb.instrs:
        if (instr.imm2 and boundsCheckedFlag) != 0: inc result

  # Baseline: only boundsCheckElim (per-block, same SSA base).
  # ptr2 is a different SSA value → basic BCE cannot eliminate the second load.
  var irBase = lowerFunction(module, 0)
  boundsCheckElim(irBase)
  let flaggedBase = countFlagged(irBase)

  # With alias BCE added on top:
  # ptr2 = add(base, 4) → origin=(base, 4), totalOffset=4, reach=8 ≤ 12 → COVERED.
  var irAlias = lowerFunction(module, 0)
  boundsCheckElim(irAlias)
  boundsCheckElimAlias(irAlias)
  let flaggedAlias = countFlagged(irAlias)

  # Alias BCE must flag strictly more checks than the basic pass.
  assert flaggedAlias > flaggedBase,
    "alias BCE should flag > base BCE: base=" & $flaggedBase & " alias=" & $flaggedAlias
  echo "PASS: alias BCE unit — base=" & $flaggedBase & " alias=" & $flaggedAlias &
       " (alias eliminates derived-pointer access, base does not)"

echo ""
echo "All optimizer tests passed!"
