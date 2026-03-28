## WebAssembly spec compliance tests
## Programmatic tests covering core MVP instruction semantics.
## Each test builds a WASM module from hand-crafted binary bytes,
## runs it through the interpreter, and asserts the result matches the spec.

import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

# ---- LEB128 encoding helpers ----

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

proc leb128S64(v: int64): seq[byte] =
  var val = v; var more = true
  while more:
    var b = byte(val and 0x7F); val = val shr 7
    if (val == 0 and (b and 0x40) == 0) or (val == -1 and (b and 0x40) != 0): more = false
    else: b = b or 0x80
    result.add(b)

# ---- WASM binary construction helpers ----

proc section(id: byte, c: seq[byte]): seq[byte] =
  result.add(id); result.add(leb128U32(uint32(c.len))); result.add(c)

proc funcType(params, results: seq[byte]): seq[byte] =
  result.add(0x60)
  result.add(leb128U32(uint32(params.len))); result.add(params)
  result.add(leb128U32(uint32(results.len))); result.add(results)

proc buildModule(paramTypes, resultTypes: seq[byte],
                 locals: seq[tuple[count: uint32, ty: byte]],
                 code: seq[byte], memPages: int = 0): seq[byte] =
  ## Build a minimal valid WASM binary with one function exported as "f".
  result = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]  # magic + version
  # Type section
  var ts: seq[byte]; ts.add(leb128U32(1)); ts.add(funcType(paramTypes, resultTypes))
  result.add(section(1, ts))
  # Function section
  var fs: seq[byte]; fs.add(leb128U32(1)); fs.add(leb128U32(0))
  result.add(section(3, fs))
  # Memory section (optional)
  if memPages > 0:
    var ms: seq[byte]; ms.add(leb128U32(1)); ms.add(0x00); ms.add(leb128U32(memPages.uint32))
    result.add(section(5, ms))
  # Export section: export function 0 as "f"
  var es: seq[byte]
  es.add(leb128U32(1))
  es.add(leb128U32(1)); es.add(byte('f'))
  es.add(0x00); es.add(leb128U32(0))
  result.add(section(7, es))
  # Code section
  var body: seq[byte]
  body.add(leb128U32(uint32(locals.len)))
  for l in locals: body.add(leb128U32(l.count)); body.add(l.ty)
  body.add(code); body.add(0x0B)  # end
  var cs: seq[byte]; cs.add(leb128U32(1)); cs.add(leb128U32(uint32(body.len))); cs.add(body)
  result.add(section(10, cs))

# ---- Runner helpers ----

proc runI32(code: seq[byte], args: openArray[int32] = [],
            locals: seq[tuple[count: uint32, ty: byte]] = @[]): int32 =
  var params: seq[byte]
  for _ in args: params.add(0x7F)
  let wasm = buildModule(params, @[0x7F'u8], locals, code)
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  var wasmArgs: seq[WasmValue]
  for a in args: wasmArgs.add(wasmI32(a))
  vm.invoke(modIdx, "f", wasmArgs)[0].i32

proc runI64(code: seq[byte], args: openArray[int64] = [],
            locals: seq[tuple[count: uint32, ty: byte]] = @[]): int64 =
  var params: seq[byte]
  for _ in args: params.add(0x7E)
  let wasm = buildModule(params, @[0x7E'u8], locals, code)
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  var wasmArgs: seq[WasmValue]
  for a in args: wasmArgs.add(wasmI64(a))
  vm.invoke(modIdx, "f", wasmArgs)[0].i64

proc runF32(code: seq[byte], args: openArray[float32] = [],
            locals: seq[tuple[count: uint32, ty: byte]] = @[]): float32 =
  var params: seq[byte]
  for _ in args: params.add(0x7D)
  let wasm = buildModule(params, @[0x7D'u8], locals, code)
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  var wasmArgs: seq[WasmValue]
  for a in args: wasmArgs.add(wasmF32(a))
  vm.invoke(modIdx, "f", wasmArgs)[0].f32

proc runF64(code: seq[byte], args: openArray[float64] = [],
            locals: seq[tuple[count: uint32, ty: byte]] = @[]): float64 =
  var params: seq[byte]
  for _ in args: params.add(0x7C)
  let wasm = buildModule(params, @[0x7C'u8], locals, code)
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  var wasmArgs: seq[WasmValue]
  for a in args: wasmArgs.add(wasmF64(a))
  vm.invoke(modIdx, "f", wasmArgs)[0].f64

proc runTraps(code: seq[byte], args: openArray[int32] = []): bool =
  var params: seq[byte]
  for _ in args: params.add(0x7F)
  let wasm = buildModule(params, @[0x7F'u8], @[], code)
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  var wasmArgs: seq[WasmValue]
  for a in args: wasmArgs.add(wasmI32(a))
  try: discard vm.invoke(modIdx, "f", wasmArgs); false
  except WasmTrap: true

proc runTrapsI64(code: seq[byte], args: openArray[int64] = []): bool =
  var params: seq[byte]
  for _ in args: params.add(0x7E)
  let wasm = buildModule(params, @[0x7E'u8], @[], code)
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  var wasmArgs: seq[WasmValue]
  for a in args: wasmArgs.add(wasmI64(a))
  try: discard vm.invoke(modIdx, "f", wasmArgs); false
  except WasmTrap: true

proc runMemI32(code: seq[byte], memPages: int = 1,
               locals: seq[tuple[count: uint32, ty: byte]] = @[]): int32 =
  let wasm = buildModule(@[], @[0x7F'u8], locals, code, memPages)
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  vm.invoke(modIdx, "f", @[])[0].i32

proc runMemTraps(code: seq[byte], memPages: int = 1): bool =
  let wasm = buildModule(@[], @[0x7F'u8], @[], code, memPages)
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  try: discard vm.invoke(modIdx, "f", @[]); false
  except WasmTrap: true

proc f32Bytes(v: float32): seq[byte] =
  let bits = cast[uint32](v)
  @[byte(bits and 0xFF), byte((bits shr 8) and 0xFF),
    byte((bits shr 16) and 0xFF), byte((bits shr 24) and 0xFF)]

proc f64Bytes(v: float64): seq[byte] =
  let bits = cast[uint64](v)
  var r = newSeq[byte](8)
  for i in 0..7: r[i] = byte((bits shr (i * 8)) and 0xFF)
  r

# Instruction byte shortcuts
const
  I32Const = 0x41'u8
  I64Const = 0x42'u8
  F32Const = 0x43'u8
  F64Const = 0x44'u8

# ============================================================================
# Integer arithmetic edge cases
# ============================================================================

# 1. i32.div_s: MIN_INT / -1 should trap (signed overflow)
block:
  assert runTraps(@[I32Const] & leb128S32(int32.low) & @[I32Const, 0x7F, 0x6D])
  echo "PASS: i32.div_s MIN_INT / -1 traps"

# 2. i32.div_u: division by zero should trap
block:
  assert runTraps(@[I32Const, 0x01, I32Const, 0x00, 0x6E])
  echo "PASS: i32.div_u division by zero traps"

# 3. i32.div_s: division by zero should trap
block:
  assert runTraps(@[I32Const, 0x01, I32Const, 0x00, 0x6D])
  echo "PASS: i32.div_s division by zero traps"

# 4. i32.rem_s: MIN_INT % -1 should return 0
block:
  assert runI32(@[I32Const] & leb128S32(int32.low) & @[I32Const, 0x7F, 0x6F]) == 0
  echo "PASS: i32.rem_s MIN_INT % -1 = 0"

# 5. i32.rem_u: division by zero should trap
block:
  assert runTraps(@[I32Const, 0x0A, I32Const, 0x00, 0x70])
  echo "PASS: i32.rem_u division by zero traps"

# 6. i32.rem_s: division by zero should trap
block:
  assert runTraps(@[I32Const, 0x0A, I32Const, 0x00, 0x6F])
  echo "PASS: i32.rem_s division by zero traps"

# 7. i32.clz(0) = 32, i32.ctz(0) = 32
block:
  assert runI32(@[I32Const, 0x00, 0x67]) == 32  # clz(0)
  assert runI32(@[I32Const, 0x00, 0x68]) == 32  # ctz(0)
  # clz(0x80000000) = 0 (leading bit is set)
  assert runI32(@[I32Const] & leb128S32(cast[int32](0x80000000'u32)) & @[0x67'u8]) == 0
  # ctz(0x80000000) = 31
  assert runI32(@[I32Const] & leb128S32(cast[int32](0x80000000'u32)) & @[0x68'u8]) == 31
  # clz(1) = 31
  assert runI32(@[I32Const, 0x01, 0x67]) == 31
  # ctz(1) = 0
  assert runI32(@[I32Const, 0x01, 0x68]) == 0
  echo "PASS: i32.clz and i32.ctz"

# 8. i32.popcnt for known values
block:
  assert runI32(@[I32Const, 0x00, 0x69]) == 0       # popcnt(0) = 0
  assert runI32(@[I32Const, 0x01, 0x69]) == 1       # popcnt(1) = 1
  # popcnt(127) = 7  (127 = 0b01111111)
  assert runI32(@[I32Const] & leb128S32(127) & @[0x69'u8]) == 7
  assert runI32(@[I32Const] & leb128S32(-1) & @[0x69'u8]) == 32  # popcnt(-1) = 32
  echo "PASS: i32.popcnt"

# 9. i32.rotl and i32.rotr
block:
  # rotl(0x80000001, 1) = 0x00000003
  assert runI32(@[I32Const] & leb128S32(cast[int32](0x80000001'u32)) &
    @[I32Const, 0x01, 0x77]) == cast[int32](0x00000003'u32)
  # rotr(0x80000001, 1) = 0xC0000000
  assert runI32(@[I32Const] & leb128S32(cast[int32](0x80000001'u32)) &
    @[I32Const, 0x01, 0x78]) == cast[int32](0xC0000000'u32)
  # rotl with shift >= 32: rotl(1, 33) = rotl(1, 1) = 2
  assert runI32(@[I32Const, 0x01, I32Const] & leb128S32(33) & @[0x77'u8]) == 2
  # rotr with shift 0: identity
  assert runI32(@[I32Const, 0x2A, I32Const, 0x00, 0x78]) == 42
  echo "PASS: i32.rotl and i32.rotr"

# 10. i64.div_s: MIN_INT / -1 should trap
block:
  assert runTrapsI64(@[I64Const] & leb128S64(int64.low) & @[I64Const, 0x7F, 0x7F])
  echo "PASS: i64.div_s MIN_INT / -1 traps"

# 11. i64.div_u: division by zero should trap
block:
  assert runTrapsI64(@[I64Const, 0x01, I64Const, 0x00, 0x80'u8])
  echo "PASS: i64.div_u division by zero traps"

# 12. i64.rem_s: MIN_INT % -1 should return 0
block:
  assert runI64(@[I64Const] & leb128S64(int64.low) & @[I64Const, 0x7F, 0x81'u8]) == 0'i64
  echo "PASS: i64.rem_s MIN_INT % -1 = 0"

# 13. i64.clz(0) = 64, i64.ctz(0) = 64
block:
  assert runI64(@[I64Const, 0x00, 0x79]) == 64  # clz(0)
  assert runI64(@[I64Const, 0x00, 0x7A]) == 64  # ctz(0)
  assert runI64(@[I64Const, 0x01, 0x79]) == 63  # clz(1) = 63
  assert runI64(@[I64Const, 0x01, 0x7A]) == 0   # ctz(1) = 0
  echo "PASS: i64.clz and i64.ctz"

# 14. i64.popcnt
block:
  assert runI64(@[I64Const, 0x00, 0x7B]) == 0   # popcnt(0)
  assert runI64(@[I64Const] & leb128S64(-1) & @[0x7B'u8]) == 64  # popcnt(-1) = 64
  echo "PASS: i64.popcnt"

# 15. i64.rotl and i64.rotr
block:
  assert runI64(@[I64Const, 0x01, I64Const] & leb128S64(63) & @[0x89'u8]) ==
    cast[int64](0x8000000000000000'u64)  # rotl(1, 63) = 0x8000000000000000
  assert runI64(@[I64Const, 0x01, I64Const, 0x01, 0x8A'u8]) ==
    cast[int64](0x8000000000000000'u64)  # rotr(1, 1) = 0x8000000000000000
  echo "PASS: i64.rotl and i64.rotr"

# ============================================================================
# Conversions
# ============================================================================

# 16. i32.wrap_i64 truncates correctly
block:
  # wrap(0x1_0000_0001) = 1
  let code = @[I64Const] & leb128S64(0x1_0000_0001'i64) & @[0xA7'u8]
  assert runI32(code) == 1  # buildModule ignores args, but runI32 re-interprets
  # Need to build manually since param is empty and result is i32
  let wasm = buildModule(@[], @[0x7F'u8], @[], code)
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  assert vm.invoke(modIdx, "f", @[])[0].i32 == 1
  echo "PASS: i32.wrap_i64"

# 17. i64.extend_i32_s sign-extends
block:
  # extend_s(-1) = -1 as i64
  let code = @[I32Const, 0x7F, 0xAC'u8]  # i32.const -1, i64.extend_i32_s
  let wasm = buildModule(@[], @[0x7E'u8], @[], code)  # result type i64
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  assert vm.invoke(modIdx, "f", @[])[0].i64 == -1'i64
  echo "PASS: i64.extend_i32_s"

# 18. i64.extend_i32_u zero-extends
block:
  let code = @[I32Const] & leb128S32(-1) & @[0xAD'u8]  # i64.extend_i32_u
  let wasm = buildModule(@[], @[0x7E'u8], @[], code)
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  assert vm.invoke(modIdx, "f", @[])[0].i64 == 0xFFFFFFFF'i64
  echo "PASS: i64.extend_i32_u"

# 19. i32.extend8_s, i32.extend16_s
block:
  # extend8_s(0xFF) = -1
  assert runI32(@[I32Const] & leb128S32(0xFF'i32) & @[0xC0'u8]) == -1
  # extend8_s(0x7F) = 127
  assert runI32(@[I32Const] & leb128S32(0x7F) & @[0xC0'u8]) == 127
  # extend8_s(0x80) = -128
  assert runI32(@[I32Const] & leb128S32(0x80'i32) & @[0xC0'u8]) == -128
  # extend16_s(0xFFFF) = -1
  assert runI32(@[I32Const] & leb128S32(0xFFFF'i32) & @[0xC1'u8]) == -1
  # extend16_s(0x7FFF) = 32767
  assert runI32(@[I32Const] & leb128S32(0x7FFF'i32) & @[0xC1'u8]) == 32767
  # extend16_s(0x8000) = -32768
  assert runI32(@[I32Const] & leb128S32(0x8000'i32) & @[0xC1'u8]) == -32768
  echo "PASS: i32.extend8_s and i32.extend16_s"

# ============================================================================
# Control flow
# ============================================================================

# 20. block/end with result value
block:
  # (block (result i32) (i32.const 42) (br 0))
  assert runI32(@[0x02'u8, 0x7F, I32Const, 0x2A, 0x0C, 0x00, 0x0B]) == 42
  echo "PASS: block with result"

# 21. loop with br_if back-edge (sum 1..10)
block:
  let code = @[I32Const, 0x00] &         # sum = 0
    @[I32Const, 0x01] &                  # i = 1
    @[0x03'u8, 0x40] &                   # loop (void)
    @[0x20'u8, 0x00, 0x20, 0x01, 0x6A, 0x21, 0x00] &  # sum += i
    @[0x20'u8, 0x01, I32Const, 0x01, 0x6A, 0x22, 0x01] &  # i = i+1, tee
    @[0x20'u8, 0x01, I32Const, 0x0B, 0x48] &  # i < 11
    @[0x0D'u8, 0x00] &                   # br_if 0 (back to loop)
    @[0x0B'u8] &                          # end loop
    @[0x20'u8, 0x00]                      # local.get 0 (sum)
  assert runI32(code, locals = @[(2'u32, 0x7F'u8)]) == 55
  echo "PASS: loop with br_if (sum 1..10)"

# 22. if/else with results
block:
  # true branch
  assert runI32(@[I32Const, 0x01, 0x04, 0x7F, I32Const, 0x0A, 0x05, I32Const, 0x14, 0x0B]) == 10
  # false branch
  assert runI32(@[I32Const, 0x00, 0x04, 0x7F, I32Const, 0x0A, 0x05, I32Const, 0x14, 0x0B]) == 20
  echo "PASS: if/else with results"

# 23. br_table dispatch
block:
  # (func (param i32) (result i32)
  #   (block $b2
  #     (block $b1
  #       (block $b0
  #         (local.get 0)
  #         (br_table $b0 $b1 $b2 $b2))  ;; idx 0->$b0, 1->$b1, 2->$b2, default->$b2
  #       (return (i32.const 10)))        ;; after $b0
  #     (return (i32.const 20)))          ;; after $b1
  #   (i32.const 30))                     ;; after $b2
  let code =
    @[0x02'u8, 0x40] &       # block $b2 (void)
    @[0x02'u8, 0x40] &       # block $b1 (void)
    @[0x02'u8, 0x40] &       # block $b0 (void)
    @[0x20'u8, 0x00] &       # local.get 0
    @[0x0E'u8, 0x03] &       # br_table count=3
    @[0x00'u8, 0x01, 0x02] & # labels: $b0, $b1, $b2
    @[0x02'u8] &              # default: $b2
    @[0x0B'u8] &              # end $b0
    @[I32Const, 0x0A] &      # 10
    @[0x0F'u8] &              # return
    @[0x0B'u8] &              # end $b1
    @[I32Const, 0x14] &      # 20
    @[0x0F'u8] &              # return
    @[0x0B'u8] &              # end $b2
    @[I32Const, 0x1E]         # 30
  assert runI32(code, [0'i32]) == 10
  assert runI32(code, [1'i32]) == 20
  assert runI32(code, [2'i32]) == 30
  assert runI32(code, [99'i32]) == 30  # default
  echo "PASS: br_table dispatch"

# 24. nested blocks with multi-level br
block:
  # (block $outer (result i32)
  #   (block $inner (result i32)
  #     (i32.const 99)
  #     (br $outer)))   ; br 1 skips $inner, exits $outer
  let code = @[0x02'u8, 0x7F] &  # block $outer (result i32)
    @[0x02'u8, 0x7F] &           # block $inner (result i32)
    @[I32Const] & leb128S32(99) & # i32.const 99
    @[0x0C'u8, 0x01] &           # br 1 (to $outer)
    @[0x0B'u8] &                  # end $inner
    @[0x0B'u8]                    # end $outer
  assert runI32(code) == 99
  echo "PASS: nested blocks with multi-level br"

# 25. unreachable traps
block:
  assert runTraps(@[0x00'u8])
  echo "PASS: unreachable traps"

# ============================================================================
# Memory operations
# ============================================================================

# 26. i32.load/store round-trip
block:
  let code = @[I32Const, 0x00, I32Const, 0x2A, 0x36, 0x02, 0x00,  # store 42 at [0]
               I32Const, 0x00, 0x28, 0x02, 0x00]                    # load from [0]
  assert runMemI32(code) == 42
  echo "PASS: i32.load/store round-trip"

# 27. sub-word loads: i32.load8_u, i32.load8_s, i32.load16_u, i32.load16_s
block:
  # Store 0xFF at byte 0, then load8_u and load8_s
  let storeFF = @[I32Const, 0x00, I32Const] & leb128S32(0xFF'i32) & @[0x3A'u8, 0x00, 0x00]  # i32.store8
  # load8_u(0) should be 255
  let code_u = storeFF & @[I32Const, 0x00, 0x2D'u8, 0x00, 0x00]  # i32.load8_u
  assert runMemI32(code_u) == 255
  # load8_s(0) should be -1
  let code_s = storeFF & @[I32Const, 0x00, 0x2C'u8, 0x00, 0x00]  # i32.load8_s
  assert runMemI32(code_s) == -1

  # Store 0xFFFE at offset 8, then load16_u and load16_s
  let storeFFFE = @[I32Const, 0x08, I32Const] & leb128S32(0xFFFE'i32) & @[0x3B'u8, 0x01, 0x00]  # i32.store16
  let code16_u = storeFFFE & @[I32Const, 0x08, 0x2F'u8, 0x01, 0x00]  # i32.load16_u
  assert runMemI32(code16_u) == 0xFFFE
  let code16_s = storeFFFE & @[I32Const, 0x08, 0x2E'u8, 0x01, 0x00]  # i32.load16_s
  assert runMemI32(code16_s) == -2
  echo "PASS: sub-word loads (load8_u, load8_s, load16_u, load16_s)"

# 28. out-of-bounds memory access traps
block:
  # Load from address 65536 with 1 page (65536 bytes) should trap
  let code = @[I32Const] & leb128S32(65536) & @[0x28'u8, 0x02, 0x00]
  assert runMemTraps(code, 1)
  # Load from address 65533 (needs 4 bytes, only 3 available) should trap
  let code2 = @[I32Const] & leb128S32(65533) & @[0x28'u8, 0x02, 0x00]
  assert runMemTraps(code2, 1)
  echo "PASS: out-of-bounds memory access traps"

# 29. memory.size returns correct page count
block:
  let code = @[0x3F'u8, 0x00]  # memory.size 0
  assert runMemI32(code, memPages = 1) == 1
  assert runMemI32(code, memPages = 3) == 3
  echo "PASS: memory.size"

# 30. memory.grow succeeds and returns old size
block:
  # memory.grow(1) with initial 1 page should return 1 (old size)
  # Then memory.size should return 2
  let code = @[I32Const, 0x01, 0x40'u8, 0x00,  # memory.grow(1) -> old_size
               0x1A'u8,                          # drop the result
               0x3F'u8, 0x00]                    # memory.size -> new size
  assert runMemI32(code) == 2
  # Also verify the return value of grow is the old size
  let code2 = @[I32Const, 0x01, 0x40'u8, 0x00]  # memory.grow(1) -> returns old size
  assert runMemI32(code2) == 1
  echo "PASS: memory.grow"

# ============================================================================
# Floating point
# ============================================================================

# 31. f32 basic arithmetic
block:
  # f32.add(1.5, 2.5) = 4.0
  assert runF32(@[F32Const] & f32Bytes(1.5f) & @[F32Const] & f32Bytes(2.5f) & @[0x92'u8]) == 4.0f
  # f32.sub(5.0, 3.0) = 2.0
  assert runF32(@[F32Const] & f32Bytes(5.0f) & @[F32Const] & f32Bytes(3.0f) & @[0x93'u8]) == 2.0f
  # f32.mul(3.0, 4.0) = 12.0
  assert runF32(@[F32Const] & f32Bytes(3.0f) & @[F32Const] & f32Bytes(4.0f) & @[0x94'u8]) == 12.0f
  # f32.div(10.0, 4.0) = 2.5
  assert runF32(@[F32Const] & f32Bytes(10.0f) & @[F32Const] & f32Bytes(4.0f) & @[0x95'u8]) == 2.5f
  echo "PASS: f32 basic arithmetic"

# 32. f64 basic arithmetic
block:
  assert runF64(@[F64Const] & f64Bytes(1.5) & @[F64Const] & f64Bytes(2.5) & @[0xA0'u8]) == 4.0
  assert runF64(@[F64Const] & f64Bytes(10.0) & @[F64Const] & f64Bytes(3.0) & @[0xA1'u8]) == 7.0
  assert runF64(@[F64Const] & f64Bytes(6.0) & @[F64Const] & f64Bytes(7.0) & @[0xA2'u8]) == 42.0
  assert runF64(@[F64Const] & f64Bytes(10.0) & @[F64Const] & f64Bytes(4.0) & @[0xA3'u8]) == 2.5
  echo "PASS: f64 basic arithmetic"

# 33. NaN propagation
block:
  let nan32 = 0x7FC00000'u32  # canonical NaN for f32
  var nanBytes32: seq[byte] = @[byte(nan32 and 0xFF), byte((nan32 shr 8) and 0xFF),
                                 byte((nan32 shr 16) and 0xFF), byte((nan32 shr 24) and 0xFF)]
  # NaN + 1.0 = NaN
  let r1 = runF32(@[F32Const] & nanBytes32 & @[F32Const] & f32Bytes(1.0f) & @[0x92'u8])
  assert r1 != r1  # NaN != NaN

  let nan64 = 0x7FF8000000000000'u64  # canonical NaN for f64
  var nanBytes64 = newSeq[byte](8)
  for i in 0..7: nanBytes64[i] = byte((nan64 shr (i * 8)) and 0xFF)
  # NaN * 2.0 = NaN
  let r2 = runF64(@[F64Const] & nanBytes64 & @[F64Const] & f64Bytes(2.0) & @[0xA2'u8])
  assert r2 != r2  # NaN != NaN
  echo "PASS: NaN propagation"

# 34. f32.min/f32.max signed zero handling
block:
  # min(-0.0, 0.0) = -0.0 per spec
  let negZero32 = cast[float32](0x80000000'u32)
  let rMin = runF32(@[F32Const] & f32Bytes(negZero32) & @[F32Const] & f32Bytes(0.0f) & @[0x96'u8])
  assert rMin == 0.0f  # value is zero
  assert cast[uint32](rMin) == 0x80000000'u32  # but it's -0.0

  # max(-0.0, 0.0) = 0.0 per spec
  let rMax = runF32(@[F32Const] & f32Bytes(negZero32) & @[F32Const] & f32Bytes(0.0f) & @[0x97'u8])
  assert rMax == 0.0f
  assert cast[uint32](rMax) == 0x00000000'u32  # positive zero
  echo "PASS: f32.min/f32.max signed zero"

# 35. f64.min/f64.max signed zero handling
block:
  let negZero64 = cast[float64](0x8000000000000000'u64)
  let rMin = runF64(@[F64Const] & f64Bytes(negZero64) & @[F64Const] & f64Bytes(0.0) & @[0xA4'u8])
  assert rMin == 0.0
  assert cast[uint64](rMin) == 0x8000000000000000'u64  # -0.0

  let rMax = runF64(@[F64Const] & f64Bytes(negZero64) & @[F64Const] & f64Bytes(0.0) & @[0xA5'u8])
  assert rMax == 0.0
  assert cast[uint64](rMax) == 0x0000000000000000'u64  # +0.0
  echo "PASS: f64.min/f64.max signed zero"

# 36. f32.copysign
block:
  # copysign(1.0, -2.0) = -1.0
  assert runF32(@[F32Const] & f32Bytes(1.0f) & @[F32Const] & f32Bytes(-2.0f) & @[0x98'u8]) == -1.0f
  # copysign(-1.0, 2.0) = 1.0
  assert runF32(@[F32Const] & f32Bytes(-1.0f) & @[F32Const] & f32Bytes(2.0f) & @[0x98'u8]) == 1.0f
  # copysign(1.0, 2.0) = 1.0 (same sign)
  assert runF32(@[F32Const] & f32Bytes(1.0f) & @[F32Const] & f32Bytes(2.0f) & @[0x98'u8]) == 1.0f
  echo "PASS: f32.copysign"

# 37. f64.copysign
block:
  assert runF64(@[F64Const] & f64Bytes(1.0) & @[F64Const] & f64Bytes(-2.0) & @[0xA6'u8]) == -1.0
  assert runF64(@[F64Const] & f64Bytes(-1.0) & @[F64Const] & f64Bytes(2.0) & @[0xA6'u8]) == 1.0
  echo "PASS: f64.copysign"

# ============================================================================
# Select instruction
# ============================================================================

# 38. select with true condition (non-zero) returns first value
block:
  # select(10, 20, 1) = 10
  assert runI32(@[I32Const, 0x0A, I32Const, 0x14, I32Const, 0x01, 0x1B]) == 10
  # select(10, 20, 42) = 10 (any non-zero)
  assert runI32(@[I32Const, 0x0A, I32Const, 0x14, I32Const, 0x2A, 0x1B]) == 10
  echo "PASS: select true condition"

# 39. select with false condition (zero) returns second value
block:
  assert runI32(@[I32Const, 0x0A, I32Const, 0x14, I32Const, 0x00, 0x1B]) == 20
  echo "PASS: select false condition"

# ============================================================================
# Additional integer arithmetic
# ============================================================================

# 40. i32 basic arithmetic
block:
  assert runI32(@[I32Const, 0x01, I32Const, 0x02, 0x6A]) == 3     # 1 + 2
  assert runI32(@[I32Const, 0x0A, I32Const, 0x03, 0x6B]) == 7     # 10 - 3
  assert runI32(@[I32Const, 0x06, I32Const, 0x07, 0x6C]) == 42    # 6 * 7
  assert runI32(@[I32Const, 0x0A, I32Const, 0x03, 0x6D]) == 3     # 10 /s 3
  assert runI32(@[I32Const, 0x0A, I32Const, 0x03, 0x6F]) == 1     # 10 %s 3
  assert runI32(@[I32Const, 0x0F, I32Const, 0x03, 0x71]) == 3     # 15 & 3
  assert runI32(@[I32Const, 0x0A, I32Const, 0x05, 0x72]) == 15    # 10 | 5
  assert runI32(@[I32Const, 0x0F, I32Const, 0x06, 0x73]) == 9     # 15 ^ 6
  assert runI32(@[I32Const, 0x01, I32Const, 0x04, 0x74]) == 16    # 1 << 4
  assert runI32(@[I32Const, 0x10, I32Const, 0x02, 0x76]) == 4     # 16 >>u 2
  echo "PASS: i32 basic arithmetic"

# 41. i32 comparisons
block:
  assert runI32(@[I32Const, 0x00, 0x45]) == 1                      # eqz(0) = 1
  assert runI32(@[I32Const, 0x05, 0x45]) == 0                      # eqz(5) = 0
  assert runI32(@[I32Const, 0x03, I32Const, 0x03, 0x46]) == 1     # 3 == 3
  assert runI32(@[I32Const, 0x03, I32Const, 0x04, 0x46]) == 0     # 3 == 4
  assert runI32(@[I32Const, 0x02, I32Const, 0x05, 0x48]) == 1     # 2 <s 5
  assert runI32(@[I32Const, 0x05, I32Const, 0x02, 0x48]) == 0     # 5 <s 2
  echo "PASS: i32 comparisons"

# 42. i32.shr_s (arithmetic shift right)
block:
  # -16 >>s 2 = -4
  assert runI32(@[I32Const] & leb128S32(-16) & @[I32Const, 0x02, 0x75]) == -4
  # -1 >>s 31 = -1 (sign extends)
  assert runI32(@[I32Const, 0x7F, I32Const] & leb128S32(31) & @[0x75'u8]) == -1
  echo "PASS: i32.shr_s"

# 43. nop/drop
block:
  assert runI32(@[I32Const, 0x2A, 0x01, 0x01, 0x01]) == 42  # nop nop nop
  assert runI32(@[I32Const, 0x01, I32Const, 0x2A, 0x1A]) == 1  # drop top
  echo "PASS: nop/drop"

# 44. i64 arithmetic edge cases
block:
  assert runI64(@[I64Const] & leb128S64(10) & @[I64Const] & leb128S64(20) & @[0x7C'u8]) == 30
  assert runI64(@[I64Const] & leb128S64(100) & @[I64Const] & leb128S64(25) & @[0x7D'u8]) == 75
  assert runI64(@[I64Const] & leb128S64(6) & @[I64Const] & leb128S64(7) & @[0x7E'u8]) == 42
  echo "PASS: i64 basic arithmetic"

# 45. f32.abs, f32.neg, f32.sqrt
block:
  assert runF32(@[F32Const] & f32Bytes(-5.0f) & @[0x8B'u8]) == 5.0f   # abs(-5) = 5
  assert runF32(@[F32Const] & f32Bytes(3.0f) & @[0x8C'u8]) == -3.0f   # neg(3) = -3
  assert runF32(@[F32Const] & f32Bytes(9.0f) & @[0x91'u8]) == 3.0f    # sqrt(9) = 3
  echo "PASS: f32.abs, f32.neg, f32.sqrt"

# 46. f64.abs, f64.neg, f64.sqrt
block:
  assert runF64(@[F64Const] & f64Bytes(-7.0) & @[0x99'u8]) == 7.0
  assert runF64(@[F64Const] & f64Bytes(4.0) & @[0x9A'u8]) == -4.0
  assert runF64(@[F64Const] & f64Bytes(25.0) & @[0x9F'u8]) == 5.0
  echo "PASS: f64.abs, f64.neg, f64.sqrt"

# 47. i32.rem_s with negative values
block:
  # -7 %s 2 = -1 (sign of dividend)
  assert runI32(@[I32Const] & leb128S32(-7) & @[I32Const, 0x02, 0x6F]) == -1
  # 7 %s -2 = 1
  assert runI32(@[I32Const, 0x07, I32Const, 0x7E, 0x6F]) == 1  # 0x7E = -2 in LEB128
  echo "PASS: i32.rem_s with negative values"

# 48. i32.div_u with large unsigned values
block:
  # 0xFFFFFFFF /u 2 = 0x7FFFFFFF = 2147483647
  assert runI32(@[I32Const] & leb128S32(-1) & @[I32Const, 0x02, 0x6E]) ==
    cast[int32](0x7FFFFFFF'u32)
  echo "PASS: i32.div_u large unsigned"

# 49. f32/f64 NaN in min/max returns NaN
block:
  let nan32 = 0x7FC00000'u32
  var nanB: seq[byte] = @[byte(nan32 and 0xFF), byte((nan32 shr 8) and 0xFF),
                           byte((nan32 shr 16) and 0xFF), byte((nan32 shr 24) and 0xFF)]
  let r = runF32(@[F32Const] & nanB & @[F32Const] & f32Bytes(1.0f) & @[0x96'u8])  # min(NaN, 1)
  assert r != r  # NaN
  let r2 = runF32(@[F32Const] & f32Bytes(1.0f) & @[F32Const] & nanB & @[0x97'u8])  # max(1, NaN)
  assert r2 != r2  # NaN
  echo "PASS: NaN in min/max"

# 50. return exits function
block:
  # (i32.const 42) (return) (i32.const 99)  -- should return 42, not 99
  let code = @[I32Const, 0x2A, 0x0F, I32Const, 0x63]
  assert runI32(code) == 42
  echo "PASS: return exits function"

echo ""
echo "All spec compliance tests passed!"
