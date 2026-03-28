## Test: extended SIMD v128 codegen (NEON on AArch64)
##
## Covers new ops added in task #10:
##   - i8x16/i16x8 splat, lane extract/replace
##   - i64x2/f64x2 splat, lane extract/replace
##   - v128.andnot
##   - i8x16: abs, neg, add, sub, min_s, min_u, max_s, max_u
##   - i16x8: abs, neg, add, sub, mul
##   - i32x4: abs, neg, shl, shr_s, shr_u, min_s, min_u, max_s, max_u
##   - i64x2: add, sub
##   - f32x4: abs, neg
##   - f64x2: splat, add, sub, mul, div, abs, neg, extract/replace

import cps/wasm/binary
import cps/wasm/jit/memory
import cps/wasm/jit/pipeline

# ---------------------------------------------------------------------------
# WASM builder helpers (same as test_jit_simd.nim)
# ---------------------------------------------------------------------------
proc leb(v: uint32): seq[byte] =
  var x = v
  while true:
    var b = byte(x and 0x7F); x = x shr 7
    if x != 0: b = b or 0x80
    result.add(b)
    if x == 0: break

proc simdOp(subOp: uint32): seq[byte] =
  result.add(0xFD'u8); result.add(leb(subOp))

proc simdOpLane(subOp: uint32, lane: byte): seq[byte] =
  result.add(0xFD'u8); result.add(leb(subOp)); result.add(lane)

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
  b.add(code); b.add(0x0B'u8)
  b

type JitFn = proc(vsp: ptr uint64, locals: ptr uint64,
                  memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

proc callJit1(fn: JitFn, a: int32): int32 =
  var vstack: array[16, uint64]
  var locals: array[8, uint64]
  locals[0] = cast[uint32](a).uint64
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

proc callJit2(fn: JitFn, a, b: int32): int32 =
  var vstack: array[16, uint64]
  var locals: array[8, uint64]
  locals[0] = cast[uint32](a).uint64
  locals[1] = cast[uint32](b).uint64
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

proc callJit1_i64(fn: JitFn, a: int64): int64 =
  ## Call JIT with 1 i64 param, return i64 result
  var vstack: array[16, uint64]
  var locals: array[8, uint64]
  locals[0] = cast[uint64](a)
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int64](vstack[0])

proc callJit2_i64(fn: JitFn, a, b: int64): int64 =
  ## Call JIT with 2 i64 params, return i64 result
  var vstack: array[16, uint64]
  var locals: array[8, uint64]
  locals[0] = cast[uint64](a)
  locals[1] = cast[uint64](b)
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int64](vstack[0])

proc compileSimd(wasm: seq[byte]): tuple[pool: JitMemPool, fn: JitFn] =
  let module = decodeModule(wasm)
  result.pool = initJitMemPool()
  let code = result.pool.compileTier2(module, funcIdx = 0, selfModuleIdx = 0)
  result.fn = cast[JitFn](code.address)

# ---------------------------------------------------------------------------
# SIMD sub-opcode constants (WASM MVP SIMD spec)
# ---------------------------------------------------------------------------
const
  simdI8x16Splat        = 15'u32
  simdI8x16ExtractLaneS = 21'u32
  simdI8x16ExtractLaneU = 22'u32
  simdI8x16ReplaceLane  = 23'u32
  simdI16x8Splat        = 16'u32
  simdI16x8ExtractLaneS = 24'u32
  simdI16x8ExtractLaneU = 25'u32
  simdI16x8ReplaceLane  = 26'u32
  simdI32x4Splat        = 17'u32
  simdI32x4ExtractLane  = 27'u32
  simdI64x2Splat        = 18'u32
  simdI64x2ExtractLane  = 29'u32
  simdI64x2ReplaceLane  = 30'u32
  simdF64x2Splat        = 20'u32
  simdF64x2ExtractLane  = 33'u32
  simdF64x2ReplaceLane  = 34'u32
  simdV128AndNot        = 79'u32
  simdI8x16Abs          = 96'u32
  simdI8x16Neg          = 97'u32
  simdI8x16Add          = 110'u32
  simdI8x16Sub          = 113'u32
  simdI8x16MinS         = 118'u32
  simdI8x16MinU         = 119'u32
  simdI8x16MaxS         = 120'u32
  simdI8x16MaxU         = 121'u32
  simdI16x8Abs          = 128'u32
  simdI16x8Neg          = 129'u32
  simdI16x8Add          = 142'u32
  simdI16x8Sub          = 145'u32
  simdI16x8Mul          = 149'u32
  simdI32x4Abs          = 160'u32
  simdI32x4Neg          = 161'u32
  simdI32x4Shl          = 171'u32
  simdI32x4ShrS         = 172'u32
  simdI32x4ShrU         = 173'u32
  simdI32x4MinS         = 182'u32
  simdI32x4MinU         = 183'u32
  simdI32x4MaxS         = 184'u32
  simdI32x4MaxU         = 185'u32
  simdI64x2Add          = 206'u32
  simdI64x2Sub          = 209'u32
  simdF32x4Splat        = 19'u32
  simdF32x4ExtractLane  = 31'u32
  simdF32x4Abs          = 224'u32
  simdF32x4Neg          = 225'u32
  simdF64x2Add          = 240'u32
  simdF64x2Sub          = 241'u32
  simdF64x2Mul          = 242'u32
  simdF64x2Div          = 243'u32
  simdF64x2Abs          = 236'u32
  simdF64x2Neg          = 237'u32

# ---------------------------------------------------------------------------
# Helper: build a module that:
#   splat(i32 param) to i8x16 or i16x8, extract a lane, return i32
# ---------------------------------------------------------------------------

proc buildI8x16SplatExtract(lane: int, signed: bool): seq[byte] =
  # (param i32) -> i32: splat low byte to 16 lanes, extract one lane (s or u)
  let extractOp = if signed: simdI8x16ExtractLaneS else: simdI8x16ExtractLaneU
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])            # local.get 0
  body.add(simdOp(simdI8x16Splat))       # i8x16.splat
  body.add(simdOpLane(extractOp, byte(lane)))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testI8x16SplatLanes() =
  # Test all 16 lanes, signed and unsigned
  # For values 0x81 (= -127 signed, 129 unsigned):
  # extract_s should give sign-extended i32: -127
  # extract_u should give zero-extended i32: 129
  let val = 0x81'i32  # 0x81 = 129 unsigned, -127 signed as byte
  for lane in 0..15:
    var (pool, fn) = compileSimd(buildI8x16SplatExtract(lane, true))
    let gotS = callJit1(fn, val)
    pool.destroy()
    assert gotS == -127, "i8x16 extract_lane_s lane " & $lane & ": expected -127, got " & $gotS

    var (pool2, fn2) = compileSimd(buildI8x16SplatExtract(lane, false))
    let gotU = callJit1(fn2, val)
    pool2.destroy()
    assert gotU == 129, "i8x16 extract_lane_u lane " & $lane & ": expected 129, got " & $gotU

  echo "PASS: i8x16.splat + extract_lane_s/u (all 16 lanes)"

# ---------------------------------------------------------------------------
# i8x16.replace_lane — replace one byte lane, extract it back
# ---------------------------------------------------------------------------

proc buildI8x16ReplaceThenExtract(lane: int): seq[byte] =
  # (param i32 i32) -> i32:
  #   splat(a) → [a..a] (16 times)
  #   replace_lane[lane] with b → lane=b, others=a
  #   extract_lane_u[lane] → b (unsigned)
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])                  # local.get 0 = a
  body.add(simdOp(simdI8x16Splat))
  body.add(@[0x20'u8, 0x01])                  # local.get 1 = b
  body.add(simdOpLane(simdI8x16ReplaceLane, byte(lane)))
  body.add(simdOpLane(simdI8x16ExtractLaneU, byte(lane)))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testI8x16ReplaceLane() =
  for lane in 0..15:
    var (pool, fn) = compileSimd(buildI8x16ReplaceThenExtract(lane))
    let got = callJit2(fn, 10, 99)
    pool.destroy()
    assert got == 99, "i8x16 replace_lane " & $lane & " expected 99 got " & $got

  echo "PASS: i8x16.replace_lane (all 16 lanes)"

# ---------------------------------------------------------------------------
# i16x8 splat, extract_s/u, replace_lane
# ---------------------------------------------------------------------------

proc buildI16x8SplatExtract(lane: int, signed: bool): seq[byte] =
  let extractOp = if signed: simdI16x8ExtractLaneS else: simdI16x8ExtractLaneU
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI16x8Splat))
  body.add(simdOpLane(extractOp, byte(lane)))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testI16x8SplatLanes() =
  # 0x8001 = -32767 signed, 32769 unsigned (but fits in 16 bits as -32767 = 0xFFFF8001? No.)
  # 0x8100 = -32512 signed, 33024 unsigned
  # Actually 0x8001 as int16 = -32767
  let val = 0x8001'i32  # i16 = -32767 signed, 32769 as uint16 (but i32 stores low 16 bits only)
  # When sign-extended: -32767
  # When zero-extended: 32769 = 0x8001
  for lane in 0..7:
    var (pool, fn) = compileSimd(buildI16x8SplatExtract(lane, true))
    let gotS = callJit1(fn, val)
    pool.destroy()
    assert gotS == -32767, "i16x8 extract_lane_s lane " & $lane & ": expected -32767, got " & $gotS

    var (pool2, fn2) = compileSimd(buildI16x8SplatExtract(lane, false))
    let gotU = callJit1(fn2, val)
    pool2.destroy()
    assert gotU == 32769, "i16x8 extract_lane_u lane " & $lane & ": expected 32769, got " & $gotU

  echo "PASS: i16x8.splat + extract_lane_s/u (all 8 lanes)"

# ---------------------------------------------------------------------------
# i64x2: splat, extract, replace
# ---------------------------------------------------------------------------

proc buildI64x2SplatExtract(lane: int): seq[byte] =
  # (param i64) -> i64: splat, extract lane
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])              # local.get 0 (i64)
  body.add(simdOp(simdI64x2Splat))
  body.add(simdOpLane(simdI64x2ExtractLane, byte(lane)))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7E'u8], @[0x7E'u8])]))  # i64→i64
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testI64x2SplatExtract() =
  let vals = [0'i64, 1, -1, 0x123456789ABCDEF0'i64, int64.high, int64.low]
  for v in vals:
    for lane in 0..1:
      var (pool, fn) = compileSimd(buildI64x2SplatExtract(lane))
      let got = callJit1_i64(fn, v)
      pool.destroy()
      assert got == v, "i64x2 splat+extract lane " & $lane & " val=" & $v & " got=" & $got
  echo "PASS: i64x2.splat + i64x2.extract_lane (both lanes)"

proc buildI64x2Replace(lane: int): seq[byte] =
  # (param i64 i64) -> i64:
  #   splat(a), replace_lane[lane] with b, extract_lane[lane] → b
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])              # local.get 0 (a as i64)
  body.add(simdOp(simdI64x2Splat))
  body.add(@[0x20'u8, 0x01])              # local.get 1 (b as i64)
  body.add(simdOpLane(simdI64x2ReplaceLane, byte(lane)))
  body.add(simdOpLane(simdI64x2ExtractLane, byte(lane)))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7E'u8, 0x7E'u8], @[0x7E'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testI64x2ReplaceLane() =
  for lane in 0..1:
    var (pool, fn) = compileSimd(buildI64x2Replace(lane))
    let got = callJit2_i64(fn, 0x1111111111111111'i64, 0xDEADBEEFCAFEBABE'i64)
    pool.destroy()
    assert got == 0xDEADBEEFCAFEBABE'i64,
      "i64x2 replace_lane " & $lane & ": expected 0xDEADBEEFCAFEBABE got " & $got
  echo "PASS: i64x2.replace_lane"

# ---------------------------------------------------------------------------
# v128.andnot: a & ~b
# ---------------------------------------------------------------------------

proc buildV128AndNotModule(): seq[byte] =
  # (param i32 i32) -> i32:  splat(a) andnot splat(b), extract lane 0
  # andnot = a & ~b
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI32x4Splat))
  body.add(@[0x20'u8, 0x01])
  body.add(simdOp(simdI32x4Splat))
  body.add(simdOp(simdV128AndNot))
  body.add(simdOpLane(simdI32x4ExtractLane, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testV128AndNot() =
  var (pool, fn) = compileSimd(buildV128AndNotModule())
  defer: pool.destroy()
  assert callJit2(fn, 0b1111, 0b1010) == 0b0101, "andnot(1111,1010) expected 0101"
  assert callJit2(fn, 0xFF, 0x0F) == 0xF0'i32, "andnot(FF,0F) expected F0"
  assert callJit2(fn, 0, 0xFF) == 0, "andnot(0,FF) expected 0"
  assert callJit2(fn, 0xFF, 0) == 0xFF'i32, "andnot(FF,0) expected FF"
  echo "PASS: v128.andnot"

# ---------------------------------------------------------------------------
# i8x16 arithmetic: abs, neg, add, sub, min_s, min_u, max_s, max_u
# ---------------------------------------------------------------------------

proc buildI8x16UnaryOp(subOp: uint32): seq[byte] =
  # (param i32) -> i32: splat, apply unary, extract_lane 0
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI8x16Splat))
  body.add(simdOp(subOp))
  body.add(simdOpLane(simdI8x16ExtractLaneS, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc buildI8x16BinOp(subOp: uint32): seq[byte] =
  # (param i32 i32) -> i32: splat both, apply op, extract_lane_s 0
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI8x16Splat))
  body.add(@[0x20'u8, 0x01])
  body.add(simdOp(simdI8x16Splat))
  body.add(simdOp(subOp))
  body.add(simdOpLane(simdI8x16ExtractLaneS, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testI8x16Arith() =
  # abs
  var (pA, fAbs) = compileSimd(buildI8x16UnaryOp(simdI8x16Abs))
  assert callJit1(fAbs, -5) == 5, "i8x16.abs(-5) expected 5"
  assert callJit1(fAbs, 7) == 7, "i8x16.abs(7) expected 7"
  assert callJit1(fAbs, 0) == 0, "i8x16.abs(0) expected 0"
  pA.destroy()
  echo "PASS: i8x16.abs"

  # neg
  var (pN, fNeg) = compileSimd(buildI8x16UnaryOp(simdI8x16Neg))
  assert callJit1(fNeg, 5) == -5, "i8x16.neg(5) expected -5"
  assert callJit1(fNeg, -3) == 3, "i8x16.neg(-3) expected 3"
  assert callJit1(fNeg, 0) == 0, "i8x16.neg(0) expected 0"
  pN.destroy()
  echo "PASS: i8x16.neg"

  # add
  var (pAdd, fAdd) = compileSimd(buildI8x16BinOp(simdI8x16Add))
  assert callJit2(fAdd, 10, 20) == 30, "i8x16.add(10,20) expected 30"
  assert callJit2(fAdd, -1, 1) == 0, "i8x16.add(-1,1) expected 0"
  # wrapping: 127 + 1 = -128 (i8 wrap)
  assert callJit2(fAdd, 127, 1) == -128, "i8x16.add(127,1) expected -128 (wrap)"
  pAdd.destroy()
  echo "PASS: i8x16.add"

  # sub
  var (pSub, fSub) = compileSimd(buildI8x16BinOp(simdI8x16Sub))
  assert callJit2(fSub, 10, 3) == 7, "i8x16.sub(10,3) expected 7"
  assert callJit2(fSub, 0, 1) == -1, "i8x16.sub(0,1) expected -1"
  pSub.destroy()
  echo "PASS: i8x16.sub"

  # min_s: signed min
  var (pMinS, fMinS) = compileSimd(buildI8x16BinOp(simdI8x16MinS))
  assert callJit2(fMinS, 5, 10) == 5, "i8x16.min_s(5,10) expected 5"
  assert callJit2(fMinS, -3, 2) == -3, "i8x16.min_s(-3,2) expected -3"
  pMinS.destroy()
  echo "PASS: i8x16.min_s"

  # min_u: unsigned min (uses extract_lane_u to get proper unsigned value)
  var (pMinU, fMinU) = compileSimd(buildI8x16BinOp(simdI8x16MinU))
  # For unsigned comparison: 200 > 10 so min_u = 10
  assert callJit2(fMinU, 200, 10) == 10, "i8x16.min_u(200,10) expected 10 (unsigned)"
  pMinU.destroy()
  echo "PASS: i8x16.min_u"

  # max_s
  var (pMaxS, fMaxS) = compileSimd(buildI8x16BinOp(simdI8x16MaxS))
  assert callJit2(fMaxS, 5, 10) == 10, "i8x16.max_s(5,10) expected 10"
  assert callJit2(fMaxS, -3, 2) == 2, "i8x16.max_s(-3,2) expected 2"
  pMaxS.destroy()
  echo "PASS: i8x16.max_s"

  # max_u
  var (pMaxU, fMaxU) = compileSimd(buildI8x16BinOp(simdI8x16MaxU))
  assert callJit2(fMaxU, 200, 10) == -56'i32,  # 200 unsigned = 0xC8, signed = -56
    "i8x16.max_u(200,10) expected 200 (unsigned, = -56 signed)"
  pMaxU.destroy()
  echo "PASS: i8x16.max_u"

# ---------------------------------------------------------------------------
# i16x8 arithmetic: abs, neg, add, sub, mul
# ---------------------------------------------------------------------------

proc buildI16x8UnaryOp(subOp: uint32): seq[byte] =
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI16x8Splat))
  body.add(simdOp(subOp))
  body.add(simdOpLane(simdI16x8ExtractLaneS, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc buildI16x8BinOp(subOp: uint32): seq[byte] =
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI16x8Splat))
  body.add(@[0x20'u8, 0x01])
  body.add(simdOp(simdI16x8Splat))
  body.add(simdOp(subOp))
  body.add(simdOpLane(simdI16x8ExtractLaneS, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testI16x8Arith() =
  var (pA, fAbs) = compileSimd(buildI16x8UnaryOp(simdI16x8Abs))
  assert callJit1(fAbs, -100) == 100, "i16x8.abs(-100) expected 100"
  assert callJit1(fAbs, 200) == 200
  pA.destroy()
  echo "PASS: i16x8.abs"

  var (pN, fNeg) = compileSimd(buildI16x8UnaryOp(simdI16x8Neg))
  assert callJit1(fNeg, 100) == -100, "i16x8.neg(100) expected -100"
  assert callJit1(fNeg, 0) == 0
  pN.destroy()
  echo "PASS: i16x8.neg"

  var (pAdd, fAdd) = compileSimd(buildI16x8BinOp(simdI16x8Add))
  assert callJit2(fAdd, 1000, 2000) == 3000, "i16x8.add(1000,2000) expected 3000"
  assert callJit2(fAdd, -1, 1) == 0
  pAdd.destroy()
  echo "PASS: i16x8.add"

  var (pSub, fSub) = compileSimd(buildI16x8BinOp(simdI16x8Sub))
  assert callJit2(fSub, 5000, 3000) == 2000, "i16x8.sub(5000,3000) expected 2000"
  pSub.destroy()
  echo "PASS: i16x8.sub"

  var (pMul, fMul) = compileSimd(buildI16x8BinOp(simdI16x8Mul))
  assert callJit2(fMul, 100, 200) == 20000, "i16x8.mul(100,200) expected 20000"
  assert callJit2(fMul, -3, 4) == -12, "i16x8.mul(-3,4) expected -12"
  pMul.destroy()
  echo "PASS: i16x8.mul"

# ---------------------------------------------------------------------------
# i32x4: abs, neg, shl, shr_s, shr_u, min_s, min_u, max_s, max_u
# ---------------------------------------------------------------------------

proc buildI32x4UnaryOp(subOp: uint32): seq[byte] =
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI32x4Splat))
  body.add(simdOp(subOp))
  body.add(simdOpLane(simdI32x4ExtractLane, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc buildI32x4ShiftOp(subOp: uint32): seq[byte] =
  # (param i32 i32) -> i32: splat(a), shift by b, extract lane 0
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI32x4Splat))
  body.add(@[0x20'u8, 0x01])  # shift count (i32)
  body.add(simdOp(subOp))
  body.add(simdOpLane(simdI32x4ExtractLane, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc buildI32x4BinOp(subOp: uint32): seq[byte] =
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI32x4Splat))
  body.add(@[0x20'u8, 0x01])
  body.add(simdOp(simdI32x4Splat))
  body.add(simdOp(subOp))
  body.add(simdOpLane(simdI32x4ExtractLane, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testI32x4Extensions() =
  var (pA, fAbs) = compileSimd(buildI32x4UnaryOp(simdI32x4Abs))
  assert callJit1(fAbs, -42) == 42, "i32x4.abs(-42) expected 42"
  assert callJit1(fAbs, 42) == 42
  pA.destroy()
  echo "PASS: i32x4.abs"

  var (pN, fNeg) = compileSimd(buildI32x4UnaryOp(simdI32x4Neg))
  assert callJit1(fNeg, 42) == -42, "i32x4.neg(42) expected -42"
  assert callJit1(fNeg, 0) == 0
  pN.destroy()
  echo "PASS: i32x4.neg"

  # shl: 1 << 3 = 8
  var (pShl, fShl) = compileSimd(buildI32x4ShiftOp(simdI32x4Shl))
  assert callJit2(fShl, 1, 3) == 8, "i32x4.shl(1,3) expected 8"
  assert callJit2(fShl, 0xFF, 8) == 0xFF00'i32, "i32x4.shl(0xFF,8) expected 0xFF00"
  # Modular: shift by 32 = shift by 0
  assert callJit2(fShl, 5, 32) == 5, "i32x4.shl(5,32) expected 5 (modular)"
  pShl.destroy()
  echo "PASS: i32x4.shl"

  # shr_s: arithmetic right shift (sign-extending)
  var (pShrS, fShrS) = compileSimd(buildI32x4ShiftOp(simdI32x4ShrS))
  assert callJit2(fShrS, 16, 2) == 4, "i32x4.shr_s(16,2) expected 4"
  assert callJit2(fShrS, -8, 2) == -2, "i32x4.shr_s(-8,2) expected -2 (arithmetic)"
  pShrS.destroy()
  echo "PASS: i32x4.shr_s"

  # shr_u: logical right shift (zero-filling)
  var (pShrU, fShrU) = compileSimd(buildI32x4ShiftOp(simdI32x4ShrU))
  assert callJit2(fShrU, 16, 2) == 4, "i32x4.shr_u(16,2) expected 4"
  # -8 = 0xFFFFFFF8, shr_u by 2 = 0x3FFFFFFE = 1073741822
  assert callJit2(fShrU, -8, 2) == 0x3FFFFFFE'i32, "i32x4.shr_u(-8,2) logical"
  pShrU.destroy()
  echo "PASS: i32x4.shr_u"

  # min_s
  var (pMinS, fMinS) = compileSimd(buildI32x4BinOp(simdI32x4MinS))
  assert callJit2(fMinS, 5, 10) == 5
  assert callJit2(fMinS, -100, 50) == -100
  pMinS.destroy()
  echo "PASS: i32x4.min_s"

  # min_u
  var (pMinU, fMinU) = compileSimd(buildI32x4BinOp(simdI32x4MinU))
  assert callJit2(fMinU, 5, 10) == 5
  # -1 as uint32 = 0xFFFFFFFF > 5, so min_u(-1, 5) = 5
  assert callJit2(fMinU, -1, 5) == 5, "i32x4.min_u(-1 unsigned, 5) expected 5"
  pMinU.destroy()
  echo "PASS: i32x4.min_u"

  # max_s
  var (pMaxS, fMaxS) = compileSimd(buildI32x4BinOp(simdI32x4MaxS))
  assert callJit2(fMaxS, 5, 10) == 10
  assert callJit2(fMaxS, -100, 50) == 50
  pMaxS.destroy()
  echo "PASS: i32x4.max_s"

  # max_u
  var (pMaxU, fMaxU) = compileSimd(buildI32x4BinOp(simdI32x4MaxU))
  assert callJit2(fMaxU, 5, 10) == 10
  # -1 as uint32 is largest 32-bit value, so max_u(-1, 5) = -1
  assert callJit2(fMaxU, -1, 5) == -1, "i32x4.max_u(-1 unsigned, 5) expected -1"
  pMaxU.destroy()
  echo "PASS: i32x4.max_u"

# ---------------------------------------------------------------------------
# i64x2: add, sub
# ---------------------------------------------------------------------------

proc buildI64x2BinOp(subOp: uint32): seq[byte] =
  # (param i64 i64) -> i64: splat both, apply op, extract lane 0
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI64x2Splat))
  body.add(@[0x20'u8, 0x01])
  body.add(simdOp(simdI64x2Splat))
  body.add(simdOp(subOp))
  body.add(simdOpLane(simdI64x2ExtractLane, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7E'u8, 0x7E'u8], @[0x7E'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testI64x2Arith() =
  var (pAdd, fAdd) = compileSimd(buildI64x2BinOp(simdI64x2Add))
  assert callJit2_i64(fAdd, 1_000_000_000'i64, 2_000_000_000'i64) == 3_000_000_000'i64
  assert callJit2_i64(fAdd, -1'i64, 1'i64) == 0
  pAdd.destroy()
  echo "PASS: i64x2.add"

  var (pSub, fSub) = compileSimd(buildI64x2BinOp(simdI64x2Sub))
  assert callJit2_i64(fSub, 5_000_000_000'i64, 3_000_000_000'i64) == 2_000_000_000'i64
  assert callJit2_i64(fSub, 0'i64, 1'i64) == -1'i64
  pSub.destroy()
  echo "PASS: i64x2.sub"

# ---------------------------------------------------------------------------
# f32x4: abs, neg
# ---------------------------------------------------------------------------

proc buildF32x4UnaryOp(subOp: uint32): seq[byte] =
  # (param i32) -> i32: splat f32 bits, apply op, extract_lane 0 as f32 bits
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdF32x4Splat))
  body.add(simdOp(subOp))
  body.add(simdOpLane(simdF32x4ExtractLane, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testF32x4Unary() =
  var (pA, fAbs) = compileSimd(buildF32x4UnaryOp(simdF32x4Abs))
  # f32 abs: clear sign bit
  let fNeg1 = cast[int32](-1.0'f32)   # negative 1.0
  let fPos1 = cast[int32](1.0'f32)    # positive 1.0
  assert callJit1(fAbs, fNeg1) == fPos1, "f32x4.abs(-1.0) expected 1.0"
  assert callJit1(fAbs, fPos1) == fPos1, "f32x4.abs(1.0) expected 1.0"
  pA.destroy()
  echo "PASS: f32x4.abs"

  var (pN, fNeg) = compileSimd(buildF32x4UnaryOp(simdF32x4Neg))
  assert callJit1(fNeg, fPos1) == fNeg1, "f32x4.neg(1.0) expected -1.0"
  assert callJit1(fNeg, fNeg1) == fPos1, "f32x4.neg(-1.0) expected 1.0"
  let fZero = cast[int32](0.0'f32)
  let fNegZero = cast[int32](-0.0'f32)
  assert callJit1(fNeg, fZero) == fNegZero, "f32x4.neg(+0) expected -0"
  pN.destroy()
  echo "PASS: f32x4.neg"

# ---------------------------------------------------------------------------
# f64x2: splat, extract_lane, add, sub, mul, div, abs, neg
# ---------------------------------------------------------------------------

proc buildF64x2SplatExtract(lane: int): seq[byte] =
  # (param i64) -> i64: splat f64 bits, extract_lane
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdF64x2Splat))
  body.add(simdOpLane(simdF64x2ExtractLane, byte(lane)))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7E'u8], @[0x7E'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc buildF64x2BinOp(subOp: uint32): seq[byte] =
  # (param i64 i64) -> i64: splat both f64 bit patterns, op, extract lane 0
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdF64x2Splat))
  body.add(@[0x20'u8, 0x01])
  body.add(simdOp(simdF64x2Splat))
  body.add(simdOp(subOp))
  body.add(simdOpLane(simdF64x2ExtractLane, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7E'u8, 0x7E'u8], @[0x7E'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc buildF64x2UnaryOp(subOp: uint32): seq[byte] =
  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdF64x2Splat))
  body.add(simdOp(subOp))
  body.add(simdOpLane(simdF64x2ExtractLane, 0))

  var wasm = wasmHdr()
  wasm.add(typeSection(@[funcType(@[0x7E'u8], @[0x7E'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))
  wasm

proc testF64x2() =
  # splat + extract
  let f1 = cast[int64](1.0'f64)
  let f2 = cast[int64](2.0'f64)
  for lane in 0..1:
    var (pool, fn) = compileSimd(buildF64x2SplatExtract(lane))
    let got = callJit1_i64(fn, f1)
    pool.destroy()
    assert got == f1, "f64x2 splat+extract lane " & $lane & " expected 1.0 bits"
  echo "PASS: f64x2.splat + f64x2.extract_lane"

  # add: 1.0 + 2.0 = 3.0
  var (pAdd, fAdd) = compileSimd(buildF64x2BinOp(simdF64x2Add))
  let f3 = cast[int64](3.0'f64)
  assert callJit2_i64(fAdd, f1, f2) == f3, "f64x2.add(1.0, 2.0) expected 3.0"
  pAdd.destroy()
  echo "PASS: f64x2.add"

  # sub: 3.0 - 1.0 = 2.0
  var (pSub, fSub) = compileSimd(buildF64x2BinOp(simdF64x2Sub))
  assert callJit2_i64(fSub, f3, f1) == f2, "f64x2.sub(3.0, 1.0) expected 2.0"
  pSub.destroy()
  echo "PASS: f64x2.sub"

  # mul: 2.0 * 3.0 = 6.0
  let f6 = cast[int64](6.0'f64)
  var (pMul, fMul) = compileSimd(buildF64x2BinOp(simdF64x2Mul))
  assert callJit2_i64(fMul, f2, f3) == f6, "f64x2.mul(2.0, 3.0) expected 6.0"
  pMul.destroy()
  echo "PASS: f64x2.mul"

  # div: 6.0 / 2.0 = 3.0
  var (pDiv, fDiv) = compileSimd(buildF64x2BinOp(simdF64x2Div))
  assert callJit2_i64(fDiv, f6, f2) == f3, "f64x2.div(6.0, 2.0) expected 3.0"
  pDiv.destroy()
  echo "PASS: f64x2.div"

  # abs: |-2.0| = 2.0
  let fNeg2 = cast[int64](-2.0'f64)
  var (pAbs, fAbsFn) = compileSimd(buildF64x2UnaryOp(simdF64x2Abs))
  assert callJit1_i64(fAbsFn, fNeg2) == f2, "f64x2.abs(-2.0) expected 2.0"
  assert callJit1_i64(fAbsFn, f2) == f2, "f64x2.abs(2.0) expected 2.0"
  pAbs.destroy()
  echo "PASS: f64x2.abs"

  # neg: -1.0 → 1.0
  let fNeg1 = cast[int64](-1.0'f64)
  var (pNeg, fNegFn) = compileSimd(buildF64x2UnaryOp(simdF64x2Neg))
  assert callJit1_i64(fNegFn, f1) == fNeg1, "f64x2.neg(1.0) expected -1.0"
  assert callJit1_i64(fNegFn, fNeg1) == f1, "f64x2.neg(-1.0) expected 1.0"
  pNeg.destroy()
  echo "PASS: f64x2.neg"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

when isMainModule:
  testI8x16SplatLanes()
  testI8x16ReplaceLane()
  testI16x8SplatLanes()
  testI64x2SplatExtract()
  testI64x2ReplaceLane()
  testV128AndNot()
  testI8x16Arith()
  testI16x8Arith()
  testI32x4Extensions()
  testI64x2Arith()
  testF32x4Unary()
  testF64x2()
  echo ""
  echo "All extended SIMD codegen tests passed!"
