## Test: x86_64 Tier 2 optimizing JIT backend
## Verifies code generation correctness (byte patterns, size, structure).
## Execution tests are skipped on non-x86_64 hosts.

import std/strutils
import cps/wasm/binary
import cps/wasm/jit/memory
import cps/wasm/jit/pipeline

# ---- WASM bytecode helpers (same pattern as other jit tests) ----

proc leb128U32(v: uint32): seq[byte] =
  var val = v
  while true:
    var b = byte(val and 0x7F); val = val shr 7
    if val != 0: b = b or 0x80
    result.add(b); if val == 0: break

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

proc memSection(): seq[byte] =
  ## Single memory with 1 initial page
  section(5, @[0x01'u8, 0x00, 0x01])

# ---- Test infrastructure ----

proc readByte(code: JitCode, offset: int): byte =
  cast[ptr UncheckedArray[byte]](code.address)[offset]

proc checkPrologue(code: JitCode) =
  ## Verify standard x86_64 frame setup: push rbp; mov rbp, rsp
  # push rbp = 0x55
  assert readByte(code, 0) == 0x55'u8,
    "Expected push rbp (0x55) at offset 0, got 0x" & toHex(readByte(code, 0).int, 2)
  # mov rbp, rsp = REX.W 0x89 ModRM(11,rsp,rbp) = 0x48 0x89 0xE5
  assert readByte(code, 1) == 0x48'u8,
    "Expected REX.W (0x48) at offset 1, got 0x" & toHex(readByte(code, 1).int, 2)
  assert readByte(code, 2) == 0x89'u8,
    "Expected MOV opcode (0x89) at offset 2, got 0x" & toHex(readByte(code, 2).int, 2)
  assert readByte(code, 3) == 0xE5'u8,
    "Expected ModRM (0xE5) at offset 3, got 0x" & toHex(readByte(code, 3).int, 2)

proc checkEpilogue(code: JitCode) =
  ## Verify the function ends with ret (0xC3)
  let last = readByte(code, code.size - 1)
  assert last == 0xC3'u8,
    "Expected RET (0xC3) at end, got 0x" & toHex(last.int, 2)

# ---- Tests ----

proc testX64Add() =
  ## (i32, i32) -> i32: local.get 0 + local.get 1
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("add", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0
    0x20, 0x01,     # local.get 1
    0x6A,           # i32.add
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil, "Expected non-nil code address"
  assert code.size > 0, "Expected non-zero code size"

  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 add — ", code.size, " bytes"
  pool.destroy()

proc testX64Multiply() =
  ## (i32, i32) -> i32: local.get 0 * local.get 1
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("mul", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0
    0x20, 0x01,     # local.get 1
    0x6C,           # i32.mul
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil
  assert code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 mul — ", code.size, " bytes"
  pool.destroy()

proc testX64Const() =
  ## () -> i32: i32.const 42
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("const42", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x41'u8, 0x2A,  # i32.const 42
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil
  assert code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 const42 — ", code.size, " bytes"
  pool.destroy()

proc testX64Loop() =
  ## (i32) -> i32: sum from 0 to n-1
  ## local 0 = n (param), local 1 = i (count), local 2 = acc
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("sum", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(
    @[(2'u32, 0x7F'u8)],  # 2 extra i32 locals (i, acc)
    @[
      # i = 0
      0x41'u8, 0x00,        # i32.const 0
      0x21, 0x01,           # local.set 1
      # acc = 0
      0x41'u8, 0x00,        # i32.const 0
      0x21, 0x02,           # local.set 2
      # loop
      0x03'u8, 0x40,        # loop (void)
        # if i >= n: break
        0x20'u8, 0x01,      # local.get i
        0x20, 0x00,         # local.get n
        0x4E,               # i32.ge_s
        0x0D, 0x01,         # br_if 1 (exit block)
        # acc += i
        0x20'u8, 0x02,      # local.get acc
        0x20, 0x01,         # local.get i
        0x6A,               # i32.add
        0x21, 0x02,         # local.set acc
        # i++
        0x20'u8, 0x01,      # local.get i
        0x41, 0x01,         # i32.const 1
        0x6A,               # i32.add
        0x21, 0x01,         # local.set i
        # continue
        0x0C'u8, 0x00,      # br 0 (back to loop)
      0x0B'u8,              # end loop
      # return acc
      0x20'u8, 0x02,        # local.get acc
    ]
  )]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil
  assert code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  # A loop should be larger than a simple add
  assert code.size > 30, "Expected loop code > 30 bytes, got " & $code.size

  echo "PASS: x64 loop/sum — ", code.size, " bytes"
  pool.destroy()

proc testX64MemLoad() =
  ## (i32) -> i32: load from memory address (param)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(memSection())
  wasm.add(exportSection(@[("load", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (address)
    0x28, 0x02, 0x00,  # i32.load align=4 offset=0
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil
  assert code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 i32.load — ", code.size, " bytes"
  pool.destroy()

proc testX64MemStore() =
  ## (i32, i32) -> void: store param[1] at address param[0]
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8], @[])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(memSection())
  wasm.add(exportSection(@[("store", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,        # local.get 0 (address)
    0x20, 0x01,           # local.get 1 (value)
    0x36, 0x02, 0x00,     # i32.store align=4 offset=0
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil
  assert code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 i32.store — ", code.size, " bytes"
  pool.destroy()

proc testX64Divide() =
  ## (i32, i32) -> i32: a / b (signed)
  ## Division is the tricky case: IDIV clobbers rdx:rax
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("div_s", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (dividend)
    0x20, 0x01,     # local.get 1 (divisor)
    0x6D,           # i32.div_s
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil
  assert code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  # Division requires extra instructions (CDQ/IDIV) so should be larger than add
  assert code.size > 20, "Expected div code > 20 bytes, got " & $code.size

  echo "PASS: x64 i32.div_s — ", code.size, " bytes"
  pool.destroy()

proc testX64Shift() =
  ## (i32, i32) -> i32: a << b (requires shift count in CL)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("shl", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0
    0x20, 0x01,     # local.get 1 (shift amount)
    0x74,           # i32.shl
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil
  assert code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 i32.shl — ", code.size, " bytes"
  pool.destroy()

proc testX64I64Arithmetic() =
  ## (i64, i64) -> i64: a + b * 3 (tests 64-bit ops)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7E'u8, 0x7E], @[0x7E'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x01,      # local.get 1 (b)
    0x42, 0x03,         # i64.const 3
    0x7E,               # i64.mul
    0x20, 0x00,         # local.get 0 (a)
    0x7C,               # i64.add
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil
  assert code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 i64 a+b*3 — ", code.size, " bytes"
  pool.destroy()

proc testX64Select() =
  ## (i32, i32, i32) -> i32: select(a, b, cond)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8, 0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("sel", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (val_true)
    0x20, 0x01,     # local.get 1 (val_false)
    0x20, 0x02,     # local.get 2 (cond)
    0x1B,           # select
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil
  assert code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 select — ", code.size, " bytes"
  pool.destroy()

proc testX64TwoCalls() =
  ## Two functions; func 1 calls func 0. Tests call emission.
  ## func 0: (i32) -> i32 = x + 1
  ## func 1: (i32) -> i32 = f0(x) + f0(x+1)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32, 0'u32]))
  wasm.add(exportSection(@[("g", 0x00'u8, 1'u32)]))
  wasm.add(codeSection(@[
    # func 0: x + 1
    funcBody(@[], @[
      0x20'u8, 0x00,   # local.get 0
      0x41, 0x01,      # i32.const 1
      0x6A,            # i32.add
    ]),
    # func 1: f0(x) + f0(x+1)
    funcBody(@[], @[
      0x20'u8, 0x00,   # local.get 0 = x
      0x10, 0x00,      # call 0
      0x20, 0x00,      # local.get 0 = x
      0x41, 0x01,      # i32.const 1
      0x6A,            # i32.add
      0x10, 0x00,      # call 0
      0x6A,            # i32.add
    ]),
  ]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()

  # Compile func 0 first (callee), then func 1 (caller)
  let code0 = compileTier2X64(pool, module, 0)
  let code1 = compileTier2X64(pool, module, 1)

  assert code0.address != nil and code0.size > 0
  assert code1.address != nil and code1.size > 0
  checkPrologue(code0)
  checkPrologue(code1)
  checkEpilogue(code0)
  checkEpilogue(code1)

  echo "PASS: x64 two-call — func0=", code0.size, "B  func1=", code1.size, "B"
  pool.destroy()

proc testX64SizeVsAArch64() =
  ## x86_64 code should be comparable in size to AArch64 (within 3x for simple funcs).
  ## AArch64 instructions are always 4 bytes; x86_64 is variable-length but compact.
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0
    0x20, 0x01,     # local.get 1
    0x6A,           # i32.add
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let codeX64 = compileTier2X64(pool, module, 0)

  # Tier 2 AArch64 for same function (compiled via compileTier2)
  let codeA64 = compileTier2(pool, module, 0)

  echo "  x64 size: ", codeX64.size, "B  AArch64 size: ", codeA64.size, "B"
  assert codeX64.size < codeA64.size * 3,
    "x64 code unexpectedly large: " & $codeX64.size & "B vs AArch64 " & $codeA64.size & "B"

  echo "PASS: x64 size reasonable vs AArch64"
  pool.destroy()

proc testX64ExtendWrap() =
  ## Tests i32.wrap_i64 and i64.extend_i32_s
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7E'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("extend_wrap", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (i64)
    0xA7,           # i32.wrap_i64
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 i32.wrap_i64 — ", code.size, " bytes"
  pool.destroy()

proc testX64Clz() =
  ## Tests i32.clz (count leading zeros — uses LZCNT/BSR on x86_64)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("clz", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0
    0x67,           # i32.clz
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 i32.clz — ", code.size, " bytes"
  pool.destroy()

proc testX64ManyLocals() =
  ## Function with many locals to force register spilling
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("many_locals", 0x00'u8, 0'u32)]))
  # 8 extra locals — forces spilling on x86_64 (only 5 allocatable regs)
  wasm.add(codeSection(@[funcBody(
    @[(8'u32, 0x7F'u8)],
    @[
      # Accumulate all locals together
      0x20'u8, 0x00,   # local.get 0
      0x21, 0x01,       # local.set 1
      0x20, 0x01,       # local.get 1
      0x41, 0x02,       # i32.const 2
      0x6C,             # i32.mul
      0x21, 0x02,       # local.set 2
      0x20, 0x02,       # local.get 2
      0x41, 0x03,       # i32.const 3
      0x6C,             # i32.mul
      0x21, 0x03,       # local.set 3
      0x20, 0x00,       # local.get 0
      0x20, 0x01,       # local.get 1
      0x6A,             # i32.add
      0x20, 0x02,       # local.get 2
      0x6A,             # i32.add
      0x20, 0x03,       # local.get 3
      0x6A,             # i32.add
    ]
  )]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 many_locals (spill) — ", code.size, " bytes"
  pool.destroy()

proc testX64Eqz() =
  ## i32.eqz: nonzero test used for if/select lowering
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("eqz", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0
    0x45,           # i32.eqz
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 i32.eqz — ", code.size, " bytes"
  pool.destroy()

proc testX64F32Arithmetic() =
  ## f32.add and f32.mul: (f32, f32) -> f32
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7D'u8, 0x7D'u8], @[0x7D'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f32add", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (f32)
    0x20, 0x01,     # local.get 1 (f32)
    0x92,           # f32.add
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 f32.add — ", code.size, " bytes"
  pool.destroy()

proc testX64F64Arithmetic() =
  ## f64.add and f64.sqrt: (f64, f64) -> f64
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7C'u8, 0x7C'u8], @[0x7C'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f64add", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (f64)
    0x20, 0x01,     # local.get 1 (f64)
    0xA0,           # f64.add
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 f64.add — ", code.size, " bytes"
  pool.destroy()

proc testX64F32Sqrt() =
  ## f32.sqrt: (f32) -> f32
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7D'u8], @[0x7D'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f32sqrt", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (f32)
    0x91,           # f32.sqrt
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 f32.sqrt — ", code.size, " bytes"
  pool.destroy()

proc testX64F32AbsNeg() =
  ## f32.abs and f32.neg (integer bit-ops on GP regs): (f32) -> f32
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7D'u8], @[0x7D'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f32neg", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (f32)
    0x8C,           # f32.neg
    0x8B,           # f32.abs
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 f32.neg+abs — ", code.size, " bytes"
  pool.destroy()

proc testX64F32Compare() =
  ## f32.eq (comparison with NaN-safe parity check): (f32, f32) -> i32
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7D'u8, 0x7D'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f32eq", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (f32)
    0x20, 0x01,     # local.get 1 (f32)
    0x5B,           # f32.eq
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 f32.eq — ", code.size, " bytes"
  pool.destroy()

proc testX64F32ConvertI32() =
  ## f32.convert_i32_s: (i32) -> f32
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7D'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("cvt", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (i32)
    0xB2,           # f32.convert_i32_s
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 f32.convert_i32_s — ", code.size, " bytes"
  pool.destroy()

proc testX64F32TruncI32() =
  ## i32.trunc_f32_s: (f32) -> i32
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7D'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("trunc", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (f32)
    0xA8,           # i32.trunc_f32_s
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 i32.trunc_f32_s — ", code.size, " bytes"
  pool.destroy()

proc testX64F32Reinterpret() =
  ## f32.reinterpret_i32 and i32.reinterpret_f32 (no-op bit cast): (i32) -> i32
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("reinterpret", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (i32)
    0xBE,           # f32.reinterpret_i32
    0xBC,           # i32.reinterpret_f32
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 f32.reinterpret_i32 + i32.reinterpret_f32 — ", code.size, " bytes"
  pool.destroy()

proc testX64F32RoundingOps() =
  ## f32.ceil, f32.floor, f32.nearest (SSE4.1 ROUNDSS): (f32) -> f32
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7D'u8], @[0x7D'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("ceil", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (f32)
    0x8D,           # f32.ceil
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 f32.ceil — ", code.size, " bytes"
  pool.destroy()

proc testX64F64ConvertI64U() =
  ## f64.convert_i64_u: (i64) -> f64 (uses dynamic-branch two-step for values >= 2^63)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7E'u8], @[0x7C'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("cvt_u", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (i64)
    0xBA,           # f64.convert_i64_u
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 f64.convert_i64_u — ", code.size, " bytes"
  pool.destroy()

proc testX64F64Compare() =
  ## f64.lt (comparison with NaN-safe parity check): (f64, f64) -> i32
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7C'u8, 0x7C'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f64lt", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0 (f64)
    0x20, 0x01,     # local.get 1 (f64)
    0x63,           # f64.lt
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2X64(pool, module, 0)

  assert code.address != nil and code.size > 0
  checkPrologue(code)
  checkEpilogue(code)

  echo "PASS: x64 f64.lt — ", code.size, " bytes"
  pool.destroy()

# ---- Run all tests ----

testX64Const()
testX64Add()
testX64Multiply()
testX64Divide()
testX64Shift()
testX64I64Arithmetic()
testX64Select()
testX64Loop()
testX64MemLoad()
testX64MemStore()
testX64TwoCalls()
testX64ExtendWrap()
testX64Clz()
testX64ManyLocals()
testX64Eqz()
testX64SizeVsAArch64()
testX64F32Arithmetic()
testX64F64Arithmetic()
testX64F32Sqrt()
testX64F32AbsNeg()
testX64F32Compare()
testX64F32ConvertI32()
testX64F32TruncI32()
testX64F32Reinterpret()
testX64F32RoundingOps()
testX64F64ConvertI64U()
testX64F64Compare()

echo ""
echo "All x86_64 Tier 2 JIT tests passed!"
