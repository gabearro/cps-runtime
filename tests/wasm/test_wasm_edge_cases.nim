## WebAssembly VM edge case tests
## Tests: trapping behavior, float edge cases, sign extension, saturating truncation

import std/math
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

# ---- WASM builder helpers ----

proc leb128U32(v: uint32): seq[byte] =
  var val = v
  while true:
    var b = byte(val and 0x7F)
    val = val shr 7
    if val != 0: b = b or 0x80
    result.add(b)
    if val == 0: break

proc leb128S32(v: int32): seq[byte] =
  var val = v
  var more = true
  while more:
    var b = byte(val and 0x7F)
    val = val shr 7
    if (val == 0 and (b and 0x40) == 0) or (val == -1 and (b and 0x40) != 0): more = false
    else: b = b or 0x80
    result.add(b)

proc leb128S64(v: int64): seq[byte] =
  var val = v
  var more = true
  while more:
    var b = byte(val and 0x7F)
    val = val shr 7
    if (val == 0 and (b and 0x40) == 0) or (val == -1 and (b and 0x40) != 0): more = false
    else: b = b or 0x80
    result.add(b)

proc vecU32(items: seq[uint32]): seq[byte] =
  result = leb128U32(uint32(items.len))
  for item in items: result.add(leb128U32(item))

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id)
  result.add(leb128U32(uint32(content.len)))
  result.add(content)

proc wasmHeader(): seq[byte] =
  @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

proc funcType(params: seq[byte], results: seq[byte]): seq[byte] =
  result.add(0x60)
  result.add(leb128U32(uint32(params.len)))
  result.add(params)
  result.add(leb128U32(uint32(results.len)))
  result.add(results)

proc typeSection(types: seq[seq[byte]]): seq[byte] =
  var content: seq[byte]
  content.add(leb128U32(uint32(types.len)))
  for t in types: content.add(t)
  result = section(1, content)

proc funcSection(typeIdxs: seq[uint32]): seq[byte] =
  result = section(3, vecU32(typeIdxs))

proc exportSection(exports: seq[tuple[name: string, kind: byte, idx: uint32]]): seq[byte] =
  var content: seq[byte]
  content.add(leb128U32(uint32(exports.len)))
  for exp in exports:
    content.add(leb128U32(uint32(exp.name.len)))
    for c in exp.name: content.add(byte(c))
    content.add(exp.kind)
    content.add(leb128U32(exp.idx))
  result = section(7, content)

proc codeSection(bodies: seq[seq[byte]]): seq[byte] =
  var content: seq[byte]
  content.add(leb128U32(uint32(bodies.len)))
  for body in bodies:
    content.add(leb128U32(uint32(body.len)))
    content.add(body)
  result = section(10, content)

proc funcBody(locals: seq[tuple[count: uint32, valType: byte]], code: seq[byte]): seq[byte] =
  var body: seq[byte]
  body.add(leb128U32(uint32(locals.len)))
  for l in locals:
    body.add(leb128U32(l.count))
    body.add(l.valType)
  body.add(code)
  body.add(0x0B)
  result = body

proc f32Bytes(v: float32): seq[byte] =
  result = newSeq[byte](4)
  copyMem(result[0].addr, v.unsafeAddr, 4)

proc f64Bytes(v: float64): seq[byte] =
  result = newSeq[byte](8)
  copyMem(result[0].addr, v.unsafeAddr, 8)

proc makeUnaryI32(opcode: byte): seq[byte] =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[0x20'u8, 0x00, opcode])]))
  wasm

proc makeBinI32(opcode: byte): seq[byte] =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[0x20'u8, 0x00, 0x20, 0x01, opcode])]))
  wasm

# ---- Tests ----

proc testI32Rotations() =
  # i32.rotl: rotate left
  let wasm = makeBinI32(0x77)  # i32.rotl
  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  # rotl(0xFF000000, 4) = 0xF000000F
  let r = vm.invoke(modIdx, "f", @[wasmI32(0xFF000000'i32), wasmI32(4)])
  assert r[0].i32 == cast[int32](0xF000000F'u32), "rotl failed"

  # i32.rotr: rotate right
  let wasm2 = makeBinI32(0x78)  # i32.rotr
  let m2 = decodeModule(wasm2)
  var vm2 = initWasmVM()
  let mod2 = vm2.instantiate(m2, @[])
  let r2 = vm2.invoke(mod2, "f", @[wasmI32(0xFF000000'i32), wasmI32(4)])
  assert r2[0].i32 == cast[int32](0x0FF00000'u32), "rotr failed"
  echo "PASS: testI32Rotations"

proc testI32SignExtend() =
  # i32.extend8_s: sign-extend from 8 bits
  let wasm = makeUnaryI32(0xC0)  # i32.extend8_s
  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  assert vm.invoke(modIdx, "f", @[wasmI32(0x7F)])[0].i32 == 127
  assert vm.invoke(modIdx, "f", @[wasmI32(0x80)])[0].i32 == -128
  assert vm.invoke(modIdx, "f", @[wasmI32(0xFF)])[0].i32 == -1
  assert vm.invoke(modIdx, "f", @[wasmI32(0x100)])[0].i32 == 0  # only looks at low 8 bits

  # i32.extend16_s
  let wasm2 = makeUnaryI32(0xC1)
  let m2 = decodeModule(wasm2)
  var vm2 = initWasmVM()
  let mod2 = vm2.instantiate(m2, @[])
  assert vm2.invoke(mod2, "f", @[wasmI32(0x7FFF)])[0].i32 == 32767
  assert vm2.invoke(mod2, "f", @[wasmI32(0x8000)])[0].i32 == -32768
  echo "PASS: testI32SignExtend"

proc testSaturatingTrunc() =
  # i32.trunc_sat_f32_s (0xFC 0x00)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7D'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0
    0xFC, 0x00,      # i32.trunc_sat_f32_s
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  # Normal value
  assert vm.invoke(modIdx, "f", @[wasmF32(42.9f)])[0].i32 == 42
  # Saturate at max
  assert vm.invoke(modIdx, "f", @[wasmF32(3.0e9f)])[0].i32 == int32.high
  # Saturate at min
  assert vm.invoke(modIdx, "f", @[wasmF32(-3.0e9f)])[0].i32 == int32.low
  # NaN → 0
  assert vm.invoke(modIdx, "f", @[wasmF32(NaN.float32)])[0].i32 == 0
  echo "PASS: testSaturatingTrunc"

proc testUnreachableTrap() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[0x00'u8])]))  # unreachable

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  var trapped = false
  try:
    discard vm.invoke(modIdx, "f", @[])
  except WasmTrap:
    trapped = true
  assert trapped
  echo "PASS: testUnreachableTrap"

proc testNestedBlocks() =
  # Test deeply nested blocks with branches
  # block $a [i32]
  #   block $b [i32]
  #     block $c [i32]
  #       i32.const 42
  #       br 2        ;; jump to $a with 42
  #     end
  #     i32.const 0
  #   end
  #   i32.const 0
  # end
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[],
    @[0x02'u8, 0x7F,          # block [i32] $a
      0x02, 0x7F,              # block [i32] $b
        0x02, 0x7F,            # block [i32] $c
    ] & @[0x41'u8] & leb128S32(42) & @[  # i32.const 42
          0x0C'u8, 0x02,      # br 2 ($a)
        0x0B,                  # end $c
    ] & @[0x41'u8] & leb128S32(0) & @[   # i32.const 0 (unreachable)
      0x0B'u8,                 # end $b
    ] & @[0x41'u8] & leb128S32(0) & @[   # i32.const 0 (unreachable)
    0x0B'u8,                   # end $a
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  assert vm.invoke(modIdx, "f", @[])[0].i32 == 42
  echo "PASS: testNestedBlocks"

proc testI64Const() =
  # Test large i64 constant
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7E'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[],
    @[0x42'u8] & leb128S64(0x0102030405060708'i64)
  )]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let r = vm.invoke(modIdx, "f", @[])
  assert r[0].i64 == 0x0102030405060708'i64
  echo "PASS: testI64Const"

proc testF32Const() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7D'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[],
    @[0x43'u8] & f32Bytes(3.14159f)
  )]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let r = vm.invoke(modIdx, "f", @[])
  assert abs(r[0].f32 - 3.14159f) < 1e-5
  echo "PASS: testF32Const"

proc testF64Const() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7C'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[],
    @[0x44'u8] & f64Bytes(2.718281828459045)
  )]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let r = vm.invoke(modIdx, "f", @[])
  assert abs(r[0].f64 - 2.718281828459045) < 1e-12
  echo "PASS: testF64Const"

proc testReinterpret() =
  # f32.reinterpret_i32 (0xBE) and i32.reinterpret_f32 (0xBC)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[
    funcType(@[0x7F'u8], @[0x7D'u8]),  # (i32) -> f32
    funcType(@[0x7D'u8], @[0x7F'u8]),  # (f32) -> i32
  ]))
  wasm.add(funcSection(@[0'u32, 1'u32]))
  wasm.add(exportSection(@[
    ("i2f", 0x00'u8, 0'u32),
    ("f2i", 0x00'u8, 1'u32),
  ]))
  wasm.add(codeSection(@[
    funcBody(@[], @[0x20'u8, 0x00, 0xBE]),  # f32.reinterpret_i32
    funcBody(@[], @[0x20'u8, 0x00, 0xBC]),  # i32.reinterpret_f32
  ]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  # IEEE 754: 1.0f = 0x3F800000
  let r1 = vm.invoke(modIdx, "i2f", @[wasmI32(0x3F800000'i32)])
  assert r1[0].f32 == 1.0f

  let r2 = vm.invoke(modIdx, "f2i", @[wasmF32(1.0f)])
  assert r2[0].i32 == 0x3F800000'i32
  echo "PASS: testReinterpret"

proc testMemoryBoundsCheck() =
  # Memory out-of-bounds should trap
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  var memContent: seq[byte]
  memContent.add(leb128U32(1))  # 1 memory
  memContent.add(0x01)           # has max
  memContent.add(leb128U32(1))   # min = 1
  memContent.add(leb128U32(1))   # max = 1
  wasm.add(section(5, memContent))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,        # local.get 0 (address)
    0x28, 0x02, 0x00,      # i32.load align=4 offset=0
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  # Reading at address 65532 (last valid i32 in 1 page): should succeed
  let r = vm.invoke(modIdx, "f", @[wasmI32(65532)])
  assert r[0].i32 == 0  # zero-initialized memory

  # Reading at address 65533: out of bounds (needs 4 bytes, only 3 left)
  var trapped = false
  try:
    discard vm.invoke(modIdx, "f", @[wasmI32(65533)])
  except WasmTrap:
    trapped = true
  assert trapped, "Expected trap on OOB memory access"
  echo "PASS: testMemoryBoundsCheck"

# ---- Run all tests ----
testI32Rotations()
testI32SignExtend()
testSaturatingTrunc()
testUnreachableTrap()
testNestedBlocks()
testI64Const()
testF32Const()
testF64Const()
testReinterpret()
testMemoryBoundsCheck()

echo ""
echo "All edge case tests passed!"
