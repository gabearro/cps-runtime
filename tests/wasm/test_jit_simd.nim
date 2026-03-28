## Test: SIMD v128 codegen (NEON on AArch64) — Tier 2 optimizing JIT
##
## Verifies that the Tier 2 backend correctly emits NEON instructions for:
##   - i32x4.splat (broadcast i32 to all 4 lanes)
##   - i32x4.add/sub/mul (lane-wise integer arithmetic)
##   - v128.and/or/xor/not (bitwise ops)
##   - v128.const (load 128-bit constant)
##   - i32x4.extract_lane (extract an i32 lane)
##   - i32x4.replace_lane (replace a lane in a vector)
##   - f32x4.splat / f32x4.add / f32x4.extract_lane
##
## Each test function takes i32 inputs (avoiding v128 ABI complexity),
## performs SIMD operations internally, and returns an i32 result.

import cps/wasm/binary
import cps/wasm/jit/memory
import cps/wasm/jit/pipeline

# ---------------------------------------------------------------------------
# WASM binary builder helpers
# ---------------------------------------------------------------------------

proc leb(v: uint32): seq[byte] =
  var x = v
  while true:
    var b = byte(x and 0x7F); x = x shr 7
    if x != 0: b = b or 0x80
    result.add(b)
    if x == 0: break

proc simdOp(subOp: uint32): seq[byte] =
  ## Encode a SIMD instruction: 0xFD prefix + LEB128 sub-opcode
  result.add(0xFD'u8)
  result.add(leb(subOp))

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id); result.add(leb(uint32(content.len))); result.add(content)

proc wasmHdr(): seq[byte] =
  @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

proc typeSection(types: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]; c.add(leb(uint32(types.len)))
  for t in types: c.add(t)
  section(1, c)

proc funcType(params, results: seq[byte]): seq[byte] =
  result.add(0x60)
  result.add(leb(uint32(params.len))); result.add(params)
  result.add(leb(uint32(results.len))); result.add(results)

proc funcSection(idxs: seq[uint32]): seq[byte] =
  var c: seq[byte]; c.add(leb(uint32(idxs.len)))
  for i in idxs: c.add(leb(i))
  section(3, c)

proc exportSection(exps: seq[tuple[name: string, kind: byte, idx: uint32]]): seq[byte] =
  var c: seq[byte]; c.add(leb(uint32(exps.len)))
  for e in exps:
    c.add(leb(uint32(e.name.len)))
    for ch in e.name: c.add(byte(ch))
    c.add(e.kind); c.add(leb(e.idx))
  section(7, c)

proc codeSection(bodies: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]; c.add(leb(uint32(bodies.len)))
  for b in bodies:
    c.add(leb(uint32(b.len))); c.add(b)
  section(10, c)

proc funcBody(locals: seq[tuple[count: uint32, valType: byte]], code: seq[byte]): seq[byte] =
  var b: seq[byte]; b.add(leb(uint32(locals.len)))
  for l in locals: b.add(leb(l.count)); b.add(l.valType)
  b.add(code); b.add(0x0B'u8)  # end
  b

# ---------------------------------------------------------------------------
# JIT call convention
# ---------------------------------------------------------------------------

type JitFn = proc(vsp: ptr uint64, locals: ptr uint64,
                  memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

proc callJit2(fn: JitFn, a, b: int32): int32 =
  ## Call a JIT function with 2 i32 params, returning 1 i32 result
  var vstack: array[16, uint64]
  var locals: array[8, uint64]
  locals[0] = cast[uint32](a).uint64
  locals[1] = cast[uint32](b).uint64
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

proc callJit0(fn: JitFn): int32 =
  ## Call a JIT function with no params, returning 1 i32 result
  var vstack: array[16, uint64]
  var locals: array[8, uint64]
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

proc callJit1(fn: JitFn, a: int32): int32 =
  ## Call a JIT function with 1 i32 param, returning 1 i32 result
  var vstack: array[16, uint64]
  var locals: array[8, uint64]
  locals[0] = cast[uint32](a).uint64
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

proc compileSimd(wasm: seq[byte]): tuple[pool: JitMemPool, fn: JitFn] =
  let module = decodeModule(wasm)
  result.pool = initJitMemPool()
  let code = result.pool.compileTier2(module, funcIdx = 0, selfModuleIdx = 0)
  result.fn = cast[JitFn](code.address)

# ---------------------------------------------------------------------------
# SIMD sub-opcodes (WASM MVP SIMD spec)
# ---------------------------------------------------------------------------
const
  simdI32x4Splat        = 17'u32   # i32x4.splat
  simdI32x4ExtractLane  = 27'u32   # i32x4.extract_lane {laneidx}
  simdI32x4ReplaceLane  = 28'u32   # i32x4.replace_lane {laneidx}
  simdI32x4Add          = 174'u32  # i32x4.add
  simdI32x4Sub          = 177'u32  # i32x4.sub
  simdI32x4Mul          = 181'u32  # i32x4.mul
  simdV128Not           = 77'u32   # v128.not
  simdV128And           = 78'u32   # v128.and
  simdV128Or            = 80'u32   # v128.or
  simdV128Xor           = 81'u32   # v128.xor
  simdV128Const         = 12'u32   # v128.const {16 bytes}
  simdF32x4Splat        = 19'u32   # f32x4.splat
  simdF32x4ExtractLane  = 31'u32   # f32x4.extract_lane {laneidx}
  simdF32x4Add          = 228'u32  # f32x4.add
  simdF32x4Mul          = 230'u32  # f32x4.mul

# ---------------------------------------------------------------------------
# Test 1: i32x4.splat + i32x4.add + i32x4.extract_lane 0
#   (param i32 i32) (result i32)
#   local.get 0 → splat → v128(a,a,a,a)
#   local.get 1 → splat → v128(b,b,b,b)
#   i32x4.add   → v128(a+b, ...)
#   extract_lane 0 → i32(a+b)
# ---------------------------------------------------------------------------

proc buildI32x4AddModule(): seq[byte] =
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])               # local.get 0
  body.add(simdOp(simdI32x4Splat))          # i32x4.splat
  body.add(@[0x20'u8, 0x01])               # local.get 1
  body.add(simdOp(simdI32x4Splat))          # i32x4.splat
  body.add(simdOp(simdI32x4Add))            # i32x4.add
  body.add(simdOp(simdI32x4ExtractLane))    # i32x4.extract_lane
  body.add(0x00'u8)                          # lane 0

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testI32x4Add() =
  var (pool, fn) = compileSimd(buildI32x4AddModule())
  defer: pool.destroy()

  assert callJit2(fn, 10, 20) == 30,  "i32x4.add(10,20) lane0 expected 30"
  assert callJit2(fn, 0, 0) == 0,     "i32x4.add(0,0) expected 0"
  assert callJit2(fn, -1, 1) == 0,    "i32x4.add(-1,1) expected 0"
  assert callJit2(fn, 100, -50) == 50, "i32x4.add(100,-50) expected 50"
  echo "PASS: i32x4.splat + i32x4.add + extract_lane 0"

# ---------------------------------------------------------------------------
# Test 2: v128.const + i32x4.extract_lane (all 4 lanes)
#   () -> i32, where we extract different lanes from a constant
# ---------------------------------------------------------------------------

proc buildV128ConstModule(lane: int): seq[byte] =
  # Constant: bytes 1..16 (little-endian per lane)
  # Lane 0: [1, 2, 3, 4]    = 0x04030201 = 67305985
  # Lane 1: [5, 6, 7, 8]    = 0x08070605 = 134678021
  # Lane 2: [9, 10, 11, 12] = 0x0C0B0A09 = 202050057
  # Lane 3: [13,14,15,16]   = 0x100F0E0D = 269422093
  var body: seq[byte]
  body.add(simdOp(simdV128Const))   # v128.const
  for i in 1..16: body.add(byte(i)) # 16 literal bytes
  body.add(simdOp(simdI32x4ExtractLane))
  body.add(byte(lane))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testV128Const() =
  let expected = [
    0x04030201'i32,   # lane 0: bytes [1,2,3,4] LE = 0x04030201
    0x08070605'i32,   # lane 1
    0x0C0B0A09'i32,   # lane 2
    0x100F0E0D'i32,   # lane 3
  ]
  for lane in 0..3:
    var (pool, fn) = compileSimd(buildV128ConstModule(lane))
    let got = callJit0(fn)
    pool.destroy()
    assert got == expected[lane],
      "v128.const lane " & $lane & " expected " & $expected[lane] & " got " & $got
  echo "PASS: v128.const + extract_lane (all 4 lanes)"

# ---------------------------------------------------------------------------
# Test 3: i32x4.sub and i32x4.mul
# ---------------------------------------------------------------------------

proc buildI32x4BinOpModule(subOp: uint32): seq[byte] =
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI32x4Splat))
  body.add(@[0x20'u8, 0x01])
  body.add(simdOp(simdI32x4Splat))
  body.add(simdOp(subOp))
  body.add(simdOp(simdI32x4ExtractLane))
  body.add(0x00'u8)

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testI32x4SubMul() =
  # SUB
  var (poolS, fnSub) = compileSimd(buildI32x4BinOpModule(simdI32x4Sub))
  assert callJit2(fnSub, 10, 3) == 7,   "i32x4.sub(10,3) expected 7"
  assert callJit2(fnSub, 0, 5) == -5,   "i32x4.sub(0,5) expected -5"
  poolS.destroy()
  echo "PASS: i32x4.sub"

  # MUL
  var (poolM, fnMul) = compileSimd(buildI32x4BinOpModule(simdI32x4Mul))
  assert callJit2(fnMul, 4, 5) == 20,   "i32x4.mul(4,5) expected 20"
  assert callJit2(fnMul, -2, 3) == -6,  "i32x4.mul(-2,3) expected -6"
  assert callJit2(fnMul, 0, 99) == 0,   "i32x4.mul(0,99) expected 0"
  poolM.destroy()
  echo "PASS: i32x4.mul"

# ---------------------------------------------------------------------------
# Test 4: v128.and / v128.or / v128.xor / v128.not
# ---------------------------------------------------------------------------

proc buildV128BitOpModule(subOp: uint32): seq[byte] =
  ## For binary bitwise ops (and/or/xor): splat a and b, apply op, extract lane 0
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI32x4Splat))
  body.add(@[0x20'u8, 0x01])
  body.add(simdOp(simdI32x4Splat))
  body.add(simdOp(subOp))
  body.add(simdOp(simdI32x4ExtractLane))
  body.add(0x00'u8)

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc buildV128NotModule(): seq[byte] =
  ## v128.not: splat a, NOT, extract lane 0 → ~a
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI32x4Splat))
  body.add(simdOp(simdV128Not))
  body.add(simdOp(simdI32x4ExtractLane))
  body.add(0x00'u8)

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testBitwiseOps() =
  var (pAnd, fnAnd) = compileSimd(buildV128BitOpModule(simdV128And))
  assert callJit2(fnAnd, 0b1100, 0b1010) == 0b1000, "v128.and expected 0b1000"
  assert callJit2(fnAnd, 0xFF, 0x0F) == 0x0F,        "v128.and 0xFF & 0x0F = 0x0F"
  pAnd.destroy()
  echo "PASS: v128.and"

  var (pOr, fnOr) = compileSimd(buildV128BitOpModule(simdV128Or))
  assert callJit2(fnOr, 0b1100, 0b0011) == 0b1111, "v128.or expected 0b1111"
  pOr.destroy()
  echo "PASS: v128.or"

  var (pXor, fnXor) = compileSimd(buildV128BitOpModule(simdV128Xor))
  assert callJit2(fnXor, 0xFF, 0xFF) == 0,     "v128.xor 0xFF^0xFF = 0"
  assert callJit2(fnXor, 0b1010, 0b1100) == 0b0110, "v128.xor expected 0b0110"
  pXor.destroy()
  echo "PASS: v128.xor"

  var (pNot, fnNot) = compileSimd(buildV128NotModule())
  assert callJit1(fnNot, 0) == -1,  "v128.not(0) expected -1"
  assert callJit1(fnNot, -1) == 0,  "v128.not(-1) expected 0"
  assert callJit1(fnNot, 1) == -2,  "v128.not(1) expected -2"
  pNot.destroy()
  echo "PASS: v128.not"

# ---------------------------------------------------------------------------
# Test 5: i32x4.replace_lane — replace a lane in a vector
#   (param i32 i32) (result i32)
#   splat(a) → all lanes = a
#   replace_lane 2 with b → lane 2 = b, others = a
#   extract_lane 2 → should be b
# ---------------------------------------------------------------------------

proc buildReplaceLaneModule(): seq[byte] =
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])             # local.get 0 (= a)
  body.add(simdOp(simdI32x4Splat))        # v128(a,a,a,a)
  body.add(@[0x20'u8, 0x01])             # local.get 1 (= b)
  body.add(simdOp(simdI32x4ReplaceLane)) # i32x4.replace_lane
  body.add(0x02'u8)                        # lane 2
  body.add(simdOp(simdI32x4ExtractLane)) # extract_lane
  body.add(0x02'u8)                        # lane 2

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc buildReplaceLaneCheckOrigModule(): seq[byte] =
  ## Splat(a), replace_lane 2 with b, extract_lane 0 — should still be a
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI32x4Splat))
  body.add(@[0x20'u8, 0x01])
  body.add(simdOp(simdI32x4ReplaceLane))
  body.add(0x02'u8)
  body.add(simdOp(simdI32x4ExtractLane))
  body.add(0x00'u8)  # lane 0 (unchanged)

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testReplaceLane() =
  var (poolR, fnR) = compileSimd(buildReplaceLaneModule())
  assert callJit2(fnR, 10, 99) == 99,  "replace_lane 2 = 99 → extract lane 2 expected 99"
  assert callJit2(fnR, 5, -1) == -1,   "replace_lane 2 = -1"
  poolR.destroy()

  var (poolO, fnO) = compileSimd(buildReplaceLaneCheckOrigModule())
  assert callJit2(fnO, 42, 99) == 42, "replace_lane 2 → lane 0 unchanged (expected 42)"
  poolO.destroy()
  echo "PASS: i32x4.replace_lane"

# ---------------------------------------------------------------------------
# Test 6: f32x4.splat + f32x4.add + f32x4.extract_lane
#   Bits of float values are passed/returned as i32
#   (param i32) (result i32)  where i32 = f32 bit pattern
#   f32x4.splat(a) → [a, a, a, a]
#   f32x4.splat(a) → [a, a, a, a]  (duplicate)
#   f32x4.add      → [2a, 2a, 2a, 2a]
#   extract_lane 0 → bits of 2*float(a)
# ---------------------------------------------------------------------------

proc buildF32x4AddModule(): seq[byte] =
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])            # local.get 0 (f32 bits as i32)
  body.add(simdOp(simdF32x4Splat))       # f32x4.splat
  body.add(@[0x20'u8, 0x00])            # local.get 0 again
  body.add(simdOp(simdF32x4Splat))       # f32x4.splat
  body.add(simdOp(simdF32x4Add))         # f32x4.add
  body.add(simdOp(simdF32x4ExtractLane)) # f32x4.extract_lane
  body.add(0x00'u8)                       # lane 0

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testF32x4Add() =
  var (pool, fn) = compileSimd(buildF32x4AddModule())
  defer: pool.destroy()

  # Test with 1.0f: 1.0 + 1.0 = 2.0
  let f1 = cast[int32](1.0'f32)
  let f2 = cast[int32](2.0'f32)
  let got1 = callJit1(fn, f1)
  assert got1 == f2, "f32x4.add(1.0, 1.0) bits expected " & $f2 & " got " & $got1

  # Test with 2.0f: 2.0 + 2.0 = 4.0
  let f4 = cast[int32](4.0'f32)
  let got2 = callJit1(fn, f2)
  assert got2 == f4, "f32x4.add(2.0, 2.0) bits expected " & $f4 & " got " & $got2

  # Test with 0.0f
  let f0 = cast[int32](0.0'f32)
  let got3 = callJit1(fn, f0)
  assert got3 == f0, "f32x4.add(0.0, 0.0) expected 0.0"

  echo "PASS: f32x4.splat + f32x4.add + f32x4.extract_lane"

# ---------------------------------------------------------------------------
# Test 7: Multi-lane verification — extract all 4 lanes from splat
#   Verify the same value appears in all lanes
# ---------------------------------------------------------------------------

proc buildSplatLaneModule(lane: int): seq[byte] =
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI32x4Splat))
  body.add(simdOp(simdI32x4ExtractLane))
  body.add(byte(lane))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testSplatAllLanes() =
  for lane in 0..3:
    var (pool, fn) = compileSimd(buildSplatLaneModule(lane))
    for v in [-1'i32, 0, 1, 42, 0x12345678'i32]:
      let got = callJit1(fn, v)
      assert got == v, "splat(" & $v & ") lane " & $lane & " expected " & $v & " got " & $got
    pool.destroy()
  echo "PASS: i32x4.splat broadcasts value to all 4 lanes"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

when isMainModule:
  testI32x4Add()
  testV128Const()
  testI32x4SubMul()
  testBitwiseOps()
  testReplaceLane()
  testF32x4Add()
  testSplatAllLanes()
  echo "All SIMD codegen tests passed!"
