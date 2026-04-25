## Test: RV32 Tier 2 WASM JIT backend.
## These tests validate code generation byte patterns. They do not execute RV32
## code on non-RISC-V hosts.

import cps/wasm/binary
import cps/wasm/jit/compiler
import cps/wasm/jit/codegen_rv64
import cps/wasm/jit/memory
import cps/wasm/jit/pipeline

proc leb128U32(v: uint32): seq[byte] =
  var val = v
  while true:
    var b = byte(val and 0x7F)
    val = val shr 7
    if val != 0: b = b or 0x80
    result.add(b)
    if val == 0: break

proc vecU32(items: seq[uint32]): seq[byte] =
  result = leb128U32(uint32(items.len))
  for item in items: result.add(leb128U32(item))

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id)
  result.add(leb128U32(uint32(content.len)))
  result.add(content)

proc wasmHeader(): seq[byte] =
  @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

proc funcType(p, r: seq[byte]): seq[byte] =
  result.add(0x60)
  result.add(leb128U32(uint32(p.len)))
  result.add(p)
  result.add(leb128U32(uint32(r.len)))
  result.add(r)

proc typeSection(types: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]
  c.add(leb128U32(uint32(types.len)))
  for t in types: c.add(t)
  section(1, c)

proc funcSection(idxs: seq[uint32]): seq[byte] = section(3, vecU32(idxs))

proc importFuncSection(moduleName, name: string, typeIdx: uint32): seq[byte] =
  var c: seq[byte]
  c.add(leb128U32(1))
  c.add(leb128U32(uint32(moduleName.len)))
  for ch in moduleName: c.add(byte(ch))
  c.add(leb128U32(uint32(name.len)))
  for ch in name: c.add(byte(ch))
  c.add(0x00'u8)
  c.add(leb128U32(typeIdx))
  section(2, c)

proc exportSection(exps: seq[tuple[name: string, kind: byte, idx: uint32]]): seq[byte] =
  var c: seq[byte]
  c.add(leb128U32(uint32(exps.len)))
  for e in exps:
    c.add(leb128U32(uint32(e.name.len)))
    for ch in e.name: c.add(byte(ch))
    c.add(e.kind)
    c.add(leb128U32(e.idx))
  section(7, c)

proc codeSection(bodies: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]
  c.add(leb128U32(uint32(bodies.len)))
  for b in bodies:
    c.add(leb128U32(uint32(b.len)))
    c.add(b)
  section(10, c)

proc funcBody(locals: seq[tuple[count: uint32, valType: byte]], code: seq[byte]): seq[byte] =
  var b: seq[byte]
  b.add(leb128U32(uint32(locals.len)))
  for l in locals:
    b.add(leb128U32(l.count))
    b.add(l.valType)
  b.add(code)
  b.add(0x0B)
  b

proc memSection(): seq[byte] =
  section(5, @[0x01'u8, 0x00, 0x01])

proc tableSection(minSize: uint32): seq[byte] =
  var c: seq[byte]
  c.add(leb128U32(1))
  c.add(0x70'u8)
  c.add(0x00'u8)
  c.add(leb128U32(minSize))
  section(4, c)

proc elemSection(funcIdxs: seq[uint32]): seq[byte] =
  var c: seq[byte]
  c.add(leb128U32(1))
  c.add(0x00'u8)
  c.add(0x41'u8)
  c.add(0x00'u8)
  c.add(0x0B'u8)
  c.add(leb128U32(uint32(funcIdxs.len)))
  for idx in funcIdxs:
    c.add(leb128U32(idx))
  section(9, c)

proc simdOp(subOp: uint32): seq[byte] =
  result.add(0xFD'u8)
  result.add(leb128U32(subOp))

proc wordAt(code: JitCode, idx: int): uint32 =
  cast[ptr UncheckedArray[uint32]](code.address)[idx]

proc hasInstr(code: JitCode, mask, value: uint32): bool =
  for i in 0 ..< (code.size div 4):
    if (wordAt(code, i) and mask) == value:
      return true

proc usesOnlyRv32ERegs(code: JitCode): bool =
  for i in 0 ..< (code.size div 4):
    let inst = wordAt(code, i)
    let opcode = inst and 0x7F'u32
    let rd = (inst shr 7) and 0x1F'u32
    let rs1 = (inst shr 15) and 0x1F'u32
    let rs2 = (inst shr 20) and 0x1F'u32
    case opcode
    of 0x33'u32:
      if rd > 15 or rs1 > 15 or rs2 > 15: return false
    of 0x13'u32, 0x03'u32, 0x67'u32:
      if rd > 15 or rs1 > 15: return false
    of 0x23'u32, 0x63'u32:
      if rs1 > 15 or rs2 > 15: return false
    of 0x37'u32, 0x17'u32, 0x6F'u32:
      if rd > 15: return false
    else:
      discard
  true

proc testEncoderBasics() =
  var buf = initRv32AsmBuffer()
  buf.addi(sp, sp, -32)
  buf.sw(ra, sp, 0)
  buf.ret()
  assert buf.code[0] == 0xFE010113'u32
  assert buf.code[1] == 0x00112023'u32
  assert buf.code[2] == 0x00008067'u32

  var ext = initRv32AsmBuffer()
  ext.sh1add(t0, t1, t2)
  ext.andn(t0, t1, t2)
  ext.bset(t0, t1, t2)
  assert (ext.code[0] and 0xFE00707F'u32) == 0x20002033'u32
  assert (ext.code[1] and 0xFE00707F'u32) == 0x40007033'u32
  assert (ext.code[2] and 0xFE00707F'u32) == 0x28001033'u32
  echo "PASS: rv32 encoder basics"

proc testRv32AddGeneric() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("add", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0x6A,
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2Rv32(pool, module, 0)
  assert code.address != nil
  assert code.size > 0
  assert wordAt(code, code.size div 4 - 1) == 0x00008067'u32
  echo "PASS: rv32 generic add - ", code.size, " bytes"
  pool.destroy()

proc testBl808Rv32Targets() =
  assert bl808Target(bl808M0) == rv32BL808M0Target
  assert rv32TheadE907Target == rv32BL808M0Target
  assert rv32BL808M0Target.xlen == rv32
  assert rvExtM in rv32BL808M0Target.features
  assert rvExtA in rv32BL808M0Target.features
  assert rvExtF in rv32BL808M0Target.features
  assert rvExtC in rv32BL808M0Target.features
  assert rvExtP in rv32BL808M0Target.features
  assert rv32XTheadCmo in rv32BL808M0Target.features
  assert rv32XTheadInt in rv32BL808M0Target.features
  assert rv32BL808M0Target.supportsNativeRv32Jit

  assert bl808Target(bl808LP) == rv32BL808LPTarget
  assert rv32TheadE902Target == rv32BL808LPTarget
  assert rv32BL808LPTarget.xlen == rv32
  assert rvExtE in rv32BL808LPTarget.features
  assert rvExtM in rv32BL808LPTarget.features
  assert rvExtC in rv32BL808LPTarget.features
  assert rv32BL808LPTarget.supportsNativeRv32Jit

  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("add", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0x6A,
  ])]))

  let module = decodeModule(wasm)
  var m0Pool = initJitMemPool()
  let code = compileTier2Rv32(m0Pool, module, 0, target = rv32BL808M0Target)
  assert code.address != nil
  m0Pool.destroy()

  var lpPool = initJitMemPool()
  let lpCode = compileTier2Rv32(lpPool, module, 0, target = rv32BL808LPTarget)
  assert lpCode.address != nil
  assert lpCode.usesOnlyRv32ERegs
  lpPool.destroy()
  echo "PASS: rv32 BL808 M0/LP target profiles"

proc testRv32CommonZbbClz() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("clz", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x67, # i32.clz
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2Rv32(pool, module, 0, target = rv32CommonTarget)
  assert code.address != nil
  assert code.hasInstr(0xFFF0707F'u32, 0x60001013'u32) # clz
  echo "PASS: rv32 common Zbb clz - ", code.size, " bytes"
  pool.destroy()

proc testRv32BL808BitCountFallbacksCompile() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("clz", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x67, # i32.clz
  ])]))

  let module = decodeModule(wasm)
  var m0Pool = initJitMemPool()
  let m0 = compileTier2Rv32(m0Pool, module, 0, target = rv32BL808M0Target)
  assert m0.address != nil
  assert not m0.hasInstr(0xFFF0707F'u32, 0x60001013'u32) # no Zbb clz
  m0Pool.destroy()

  var lpPool = initJitMemPool()
  let lp = compileTier2Rv32(lpPool, module, 0, target = rv32BL808LPTarget)
  assert lp.address != nil
  assert lp.usesOnlyRv32ERegs
  lpPool.destroy()
  echo "PASS: rv32 BL808 bit-count fallbacks"

proc testRv32BL808M0F32AddCompiles() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7D'u8, 0x7D], @[0x7D'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f32add", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0x92, # f32.add
  ])]))

  let module = decodeModule(wasm)
  var m0Pool = initJitMemPool()
  let code = compileTier2Rv32(m0Pool, module, 0, target = rv32BL808M0Target)
  assert code.address != nil
  assert code.hasInstr(0xFE00007F'u32, 0x00000053'u32) # fadd.s
  m0Pool.destroy()

  var lpPool = initJitMemPool()
  var rejected = false
  try:
    discard compileTier2Rv32(lpPool, module, 0, target = rv32BL808LPTarget)
  except ValueError:
    rejected = true
  assert rejected
  lpPool.destroy()
  echo "PASS: rv32 BL808 M0 f32.add"

proc testRv32BL808M0F32FmaRoundingAndI64ConversionsCompile() =
  var fmaWasm = wasmHeader()
  fmaWasm.add(typeSection(@[funcType(@[0x7D'u8, 0x7D, 0x7D], @[0x7D'u8])]))
  fmaWasm.add(funcSection(@[0'u32]))
  fmaWasm.add(exportSection(@[("fma", 0x00'u8, 0'u32)]))
  fmaWasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0x94, # f32.mul
    0x20, 0x02,
    0x92, # f32.add
  ])]))

  let fmaModule = decodeModule(fmaWasm)
  var fmaPool = initJitMemPool()
  let fmaCode = compileTier2Rv32(fmaPool, fmaModule, 0, target = rv32BL808M0Target)
  assert fmaCode.address != nil
  assert fmaCode.hasInstr(0x0000007F'u32, 0x00000043'u32) # fmadd.s
  fmaPool.destroy()

  var roundWasm = wasmHeader()
  roundWasm.add(typeSection(@[funcType(@[0x7D'u8], @[0x7D'u8])]))
  roundWasm.add(funcSection(@[0'u32]))
  roundWasm.add(exportSection(@[("ceil", 0x00'u8, 0'u32)]))
  roundWasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x8D, # f32.ceil
  ])]))

  let roundModule = decodeModule(roundWasm)
  var roundPool = initJitMemPool()
  let roundCode = compileTier2Rv32(roundPool, roundModule, 0, target = rv32BL808M0Target)
  assert roundCode.address != nil
  assert roundCode.hasInstr(0xFFFF_FFFF'u32, 0x000780E7'u32) # jalr ra, a5, 0
  roundPool.destroy()

  var toF32 = wasmHeader()
  toF32.add(typeSection(@[funcType(@[0x7E'u8], @[0x7D'u8])]))
  toF32.add(funcSection(@[0'u32]))
  toF32.add(exportSection(@[("tof32", 0x00'u8, 0'u32)]))
  toF32.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0xB4, # f32.convert_i64_s
  ])]))

  let toModule = decodeModule(toF32)
  var toPool = initJitMemPool()
  let toCode = compileTier2Rv32(toPool, toModule, 0, target = rv32BL808M0Target)
  assert toCode.address != nil
  assert toCode.hasInstr(0xFFFF_FFFF'u32, 0x000780E7'u32)
  toPool.destroy()

  var fromF32 = wasmHeader()
  fromF32.add(typeSection(@[funcType(@[0x7D'u8], @[0x7E'u8])]))
  fromF32.add(funcSection(@[0'u32]))
  fromF32.add(exportSection(@[("toi64", 0x00'u8, 0'u32)]))
  fromF32.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0xAE, # i64.trunc_f32_s
  ])]))

  let fromModule = decodeModule(fromF32)
  var fromPool = initJitMemPool()
  let fromCode = compileTier2Rv32(fromPool, fromModule, 0, target = rv32BL808M0Target)
  assert fromCode.address != nil
  assert fromCode.hasInstr(0xFFFF_FFFF'u32, 0x000780E7'u32)
  fromPool.destroy()
  echo "PASS: rv32 BL808 M0 f32 FMA/rounding/i64 conversions"

proc testRv32BL808RejectsF64Signature() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7C'u8, 0x7C], @[0x7C'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("f64add", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0xA0, # f64.add
  ])]))

  let module = decodeModule(wasm)
  var m0Pool = initJitMemPool()
  var m0Rejected = false
  try:
    discard compileTier2Rv32(m0Pool, module, 0, target = rv32BL808M0Target)
  except ValueError:
    m0Rejected = true
  assert m0Rejected
  m0Pool.destroy()

  var lpPool = initJitMemPool()
  var lpRejected = false
  try:
    discard compileTier2Rv32(lpPool, module, 0, target = rv32BL808LPTarget)
  except ValueError:
    lpRejected = true
  assert lpRejected
  lpPool.destroy()
  echo "PASS: rv32 BL808 rejects f64 signature"

proc testRv32CommonF64OpsCompile() =
  var addWasm = wasmHeader()
  addWasm.add(typeSection(@[funcType(@[0x7C'u8, 0x7C], @[0x7C'u8])]))
  addWasm.add(funcSection(@[0'u32]))
  addWasm.add(exportSection(@[("f64add", 0x00'u8, 0'u32)]))
  addWasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0xA0, # f64.add
  ])]))

  let addModule = decodeModule(addWasm)
  var addPool = initJitMemPool()
  let addCode = compileTier2Rv32(addPool, addModule, 0, target = rv32CommonTarget)
  assert addCode.address != nil
  assert addCode.hasInstr(0xFFFF_FFFF'u32, 0x000280E7'u32) # jalr ra, t0, 0
  addPool.destroy()

  var roundWasm = wasmHeader()
  roundWasm.add(typeSection(@[funcType(@[0x7C'u8], @[0x7C'u8])]))
  roundWasm.add(funcSection(@[0'u32]))
  roundWasm.add(exportSection(@[("ceil64", 0x00'u8, 0'u32)]))
  roundWasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x9B, # f64.ceil
  ])]))

  let roundModule = decodeModule(roundWasm)
  var roundPool = initJitMemPool()
  let roundCode = compileTier2Rv32(roundPool, roundModule, 0, target = rv32CommonTarget)
  assert roundCode.address != nil
  assert roundCode.hasInstr(0xFFFF_FFFF'u32, 0x000280E7'u32) # jalr ra, t0, 0
  roundPool.destroy()
  echo "PASS: rv32 common f64 helpers"

proc testRv32DirectAndIndirectCallsCompile() =
  var directWasm = wasmHeader()
  directWasm.add(typeSection(@[funcType(@[], @[0x7F'u8])]))
  directWasm.add(importFuncSection("env", "callee", 0))
  directWasm.add(funcSection(@[0'u32]))
  directWasm.add(exportSection(@[("caller", 0x00'u8, 1'u32)]))
  directWasm.add(codeSection(@[
    funcBody(@[], @[
      0x10'u8, 0x00, # call 0
    ]),
  ]))

  let directModule = decodeModule(directWasm)
  var directPool = initJitMemPool()
  var funcElems = @[
    TableElem(jitAddr: cast[pointer](0x1000), localCount: 0,
              paramCount: 0, resultCount: 1),
    TableElem(localCount: 0, paramCount: 0, resultCount: 1),
  ]
  let funcPtr = cast[ptr UncheckedArray[TableElem]](funcElems[0].addr)
  let callerCode = compileTier2Rv32(directPool, directModule, 1,
                                    selfModuleIdx = 1,
                                    funcElems = funcPtr,
                                    numFuncs = funcElems.len.int32)
  assert callerCode.address != nil
  assert callerCode.hasInstr(0xFFFF_FFFF'u32, 0x000280E7'u32) # jalr ra, t0, 0
  directPool.destroy()

  var indirectWasm = wasmHeader()
  indirectWasm.add(typeSection(@[
    funcType(@[0x7F'u8], @[0x7F'u8]),
    funcType(@[0x7F'u8, 0x7F], @[0x7F'u8]),
  ]))
  indirectWasm.add(funcSection(@[0'u32, 0'u32, 1'u32]))
  indirectWasm.add(tableSection(2))
  indirectWasm.add(exportSection(@[("dispatch", 0x00'u8, 2'u32)]))
  indirectWasm.add(elemSection(@[0'u32, 1'u32]))
  indirectWasm.add(codeSection(@[
    funcBody(@[], @[0x20'u8, 0x00, 0x41, 0x02, 0x6C]),
    funcBody(@[], @[0x20'u8, 0x00, 0x41, 0x03, 0x6C]),
    funcBody(@[], @[
      0x20'u8, 0x01,
      0x20, 0x00,
      0x11, 0x00, 0x00, # call_indirect type 0 table 0
    ]),
  ]))

  let indirectModule = decodeModule(indirectWasm)
  var indirectPool = initJitMemPool()
  var tableElems = @[
    TableElem(localCount: 1, paramCount: 1, resultCount: 1),
    TableElem(localCount: 1, paramCount: 1, resultCount: 1),
  ]
  let tablePtr = cast[ptr UncheckedArray[TableElem]](tableElems[0].addr)
  let dispatchCode = compileTier2Rv32(indirectPool, indirectModule, 2,
                                      selfModuleIdx = 2,
                                      tableElems = tablePtr,
                                      tableLen = tableElems.len.int32)
  assert dispatchCode.address != nil
  assert dispatchCode.hasInstr(0xFFFF_FFFF'u32, 0x000280E7'u32) # jalr ra, t0, 0
  indirectPool.destroy()
  echo "PASS: rv32 direct and indirect calls compile"

proc testRv32RejectsTrapLoweredOps() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(memSection())
  wasm.add(exportSection(@[("memsize", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x3F'u8, 0x00, # memory.size
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  var rejected = false
  try:
    discard compileTier2Rv32(pool, module, 0)
  except ValueError:
    rejected = true
  assert rejected
  pool.destroy()
  echo "PASS: rv32 rejects trap-lowered Tier 2 ops"

proc testRv32SignedByteLoadCompiles() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(memSection())
  wasm.add(exportSection(@[("load8s", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x2C, 0x00, 0x00, # i32.load8_s align=1 offset=0
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2Rv32(pool, module, 0)
  assert code.address != nil
  assert code.hasInstr(0x0000707F'u32, 0x00000003'u32) # LB opcode/funct3
  echo "PASS: rv32 signed byte load - ", code.size, " bytes"
  pool.destroy()

proc testRv32I64AddCompiles() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7E'u8, 0x7E], @[0x7E'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("add64", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0x7C, # i64.add
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2Rv32(pool, module, 0)
  assert code.address != nil
  assert code.size > 0
  assert wordAt(code, code.size div 4 - 1) == 0x00008067'u32
  assert code.hasInstr(0x0000707F'u32, 0x00003033'u32) # SLTU carry/compare
  echo "PASS: rv32 i64.add emulation - ", code.size, " bytes"
  pool.destroy()

proc testRv32I64MulCompiles() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7E'u8, 0x7E], @[0x7E'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("mul64", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0x7E, # i64.mul
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2Rv32(pool, module, 0)
  assert code.address != nil
  assert code.hasInstr(0xFE00707F'u32, 0x02003033'u32) # MULHU
  assert code.hasInstr(0xFE00707F'u32, 0x02000033'u32) # MUL
  echo "PASS: rv32 i64.mul emulation - ", code.size, " bytes"
  pool.destroy()

proc testRv32I64ShiftAndCompareCompiles() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7E'u8, 0x7E], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("cmp", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0x86, # i64.shl
    0x20, 0x00,
    0x53, # i64.lt_s
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2Rv32(pool, module, 0)
  assert code.address != nil
  assert code.hasInstr(0x0000707F'u32, 0x00001033'u32) # SLL
  assert code.hasInstr(0x0000707F'u32, 0x00002033'u32) # SLT
  echo "PASS: rv32 i64 shift/compare emulation - ", code.size, " bytes"
  pool.destroy()

proc testRv32I64DivRemRotateCompiles() =
  for op in [0x7F'u8, 0x80, 0x81, 0x82, 0x89, 0x8A]:
    var wasm = wasmHeader()
    wasm.add(typeSection(@[funcType(@[0x7E'u8, 0x7E], @[0x7E'u8])]))
    wasm.add(funcSection(@[0'u32]))
    wasm.add(exportSection(@[("op64", 0x00'u8, 0'u32)]))
    wasm.add(codeSection(@[funcBody(@[], @[
      0x20'u8, 0x00,
      0x20, 0x01,
      op,
    ])]))

    let module = decodeModule(wasm)
    var pool = initJitMemPool()
    let code = compileTier2Rv32(pool, module, 0, target = rv32BL808LPTarget)
    assert code.address != nil
    assert code.usesOnlyRv32ERegs
    if op in [0x7F'u8, 0x80, 0x81, 0x82]:
      assert code.hasInstr(0xFFFF_FFFF'u32, 0x000780E7'u32) # jalr ra, a5, 0
    pool.destroy()
  echo "PASS: rv32 i64 div/rem/rotate emulation"

proc testRv32I64MemoryCompiles() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7E], @[0x7E'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(memSection())
  wasm.add(exportSection(@[("mem64", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0x37, 0x00, 0x00, # i64.store align=1 offset=0
    0x20, 0x00,
    0x29, 0x00, 0x00, # i64.load align=1 offset=0
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2Rv32(pool, module, 0)
  assert code.address != nil
  assert code.hasInstr(0x0000707F'u32, 0x00002003'u32) # LW
  assert code.hasInstr(0x0000707F'u32, 0x00002023'u32) # SW
  echo "PASS: rv32 i64 memory emulation - ", code.size, " bytes"
  pool.destroy()

proc testRv32RejectsFloatSignature() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7D'u8], @[0x7D'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("idf32", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  var rejected = false
  try:
    discard compileTier2Rv32(pool, module, 0)
  except ValueError:
    rejected = true
  assert rejected
  echo "PASS: rv32 rejects float signature"
  pool.destroy()

proc testRv32BL808SimdI32x4AddCompiles() =
  const
    simdI32x4Splat = 17'u32
    simdI32x4Add = 174'u32
    simdI32x4ExtractLane = 27'u32

  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdI32x4Splat))
  body.add(@[0x20'u8, 0x01])
  body.add(simdOp(simdI32x4Splat))
  body.add(simdOp(simdI32x4Add))
  body.add(simdOp(simdI32x4ExtractLane))
  body.add(0x00'u8)

  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("simdadd", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))

  let module = decodeModule(wasm)
  var m0Pool = initJitMemPool()
  let m0 = compileTier2Rv32(m0Pool, module, 0, target = rv32BL808M0Target)
  assert m0.address != nil
  assert m0.hasInstr(0xFE00707F'u32, 0x00000033'u32) # ADD
  m0Pool.destroy()

  var lpPool = initJitMemPool()
  let lp = compileTier2Rv32(lpPool, module, 0, target = rv32BL808LPTarget)
  assert lp.address != nil
  assert lp.usesOnlyRv32ERegs
  lpPool.destroy()
  echo "PASS: rv32 BL808 SIMD i32x4.add lowering"

proc testRv32BL808SimdF32x4AddRequiresF() =
  const
    simdF32x4Splat = 19'u32
    simdF32x4Add = 228'u32
    simdF32x4ExtractLane = 31'u32

  var body: seq[byte]
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdF32x4Splat))
  body.add(@[0x20'u8, 0x00])
  body.add(simdOp(simdF32x4Splat))
  body.add(simdOp(simdF32x4Add))
  body.add(simdOp(simdF32x4ExtractLane))
  body.add(0x00'u8)

  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("simdf32", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], body)]))

  let module = decodeModule(wasm)
  var m0Pool = initJitMemPool()
  let code = compileTier2Rv32(m0Pool, module, 0, target = rv32BL808M0Target)
  assert code.address != nil
  assert code.hasInstr(0xFE00007F'u32, 0x00000053'u32) # fadd.s
  m0Pool.destroy()

  var lpPool = initJitMemPool()
  var rejected = false
  try:
    discard compileTier2Rv32(lpPool, module, 0, target = rv32BL808LPTarget)
  except ValueError:
    rejected = true
  assert rejected
  lpPool.destroy()
  echo "PASS: rv32 BL808 SIMD f32x4.add requires F"

proc testRv32V128ParamsResultsAndLocalsCompile() =
  var identityWasm = wasmHeader()
  identityWasm.add(typeSection(@[funcType(@[0x7B'u8], @[0x7B'u8])]))
  identityWasm.add(funcSection(@[0'u32]))
  identityWasm.add(exportSection(@[("id_v128", 0x00'u8, 0'u32)]))
  identityWasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00, # local.get 0
  ])]))

  let identityModule = decodeModule(identityWasm)
  var identityPool = initJitMemPool()
  let identityCode = compileTier2Rv32(identityPool, identityModule, 0,
                                      target = rv32BL808M0Target)
  assert identityCode.address != nil
  assert identityCode.numLocals == 2
  identityPool.destroy()

  var localWasm = wasmHeader()
  localWasm.add(typeSection(@[funcType(@[0x7B'u8], @[0x7B'u8])]))
  localWasm.add(funcSection(@[0'u32]))
  localWasm.add(exportSection(@[("spill_v128", 0x00'u8, 0'u32)]))
  localWasm.add(codeSection(@[funcBody(@[(1'u32, 0x7B'u8)], @[
    0x20'u8, 0x00, # local.get 0
    0x21, 0x01,    # local.set 1
    0x20, 0x01,    # local.get 1
  ])]))

  let localModule = decodeModule(localWasm)
  var localPool = initJitMemPool()
  let localCode = compileTier2Rv32(localPool, localModule, 0,
                                   target = rv32BL808LPTarget)
  assert localCode.address != nil
  assert localCode.numLocals == 4
  assert localCode.usesOnlyRv32ERegs
  localPool.destroy()

  var directWasm = wasmHeader()
  directWasm.add(typeSection(@[funcType(@[0x7B'u8], @[0x7B'u8])]))
  directWasm.add(importFuncSection("env", "callee_v128", 0))
  directWasm.add(funcSection(@[0'u32]))
  directWasm.add(exportSection(@[("call_v128", 0x00'u8, 1'u32)]))
  directWasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00, # local.get 0
    0x10, 0x00,    # call 0
  ])]))

  let directModule = decodeModule(directWasm)
  var directPool = initJitMemPool()
  var funcElems = @[
    TableElem(jitAddr: cast[pointer](0x1000), localCount: 2,
              paramCount: 1, resultCount: 1,
              paramSlotCount: 2, resultSlotCount: 2),
    TableElem(localCount: 2, paramCount: 1, resultCount: 1,
              paramSlotCount: 2, resultSlotCount: 2),
  ]
  let funcPtr = cast[ptr UncheckedArray[TableElem]](funcElems[0].addr)
  let directCode = compileTier2Rv32(directPool, directModule, 1,
                                    selfModuleIdx = 1,
                                    funcElems = funcPtr,
                                    numFuncs = funcElems.len.int32,
                                    target = rv32BL808M0Target)
  assert directCode.address != nil
  directPool.destroy()
  echo "PASS: rv32 v128 params/results/locals compile"

when isMainModule:
  testEncoderBasics()
  testRv32AddGeneric()
  testBl808Rv32Targets()
  testRv32CommonZbbClz()
  testRv32BL808BitCountFallbacksCompile()
  testRv32BL808M0F32AddCompiles()
  testRv32BL808M0F32FmaRoundingAndI64ConversionsCompile()
  testRv32BL808RejectsF64Signature()
  testRv32CommonF64OpsCompile()
  testRv32DirectAndIndirectCallsCompile()
  testRv32RejectsTrapLoweredOps()
  testRv32SignedByteLoadCompiles()
  testRv32I64AddCompiles()
  testRv32I64MulCompiles()
  testRv32I64ShiftAndCompareCompiles()
  testRv32I64DivRemRotateCompiles()
  testRv32I64MemoryCompiles()
  testRv32RejectsFloatSignature()
  testRv32BL808SimdI32x4AddCompiles()
  testRv32BL808SimdF32x4AddRequiresF()
  testRv32V128ParamsResultsAndLocalsCompile()
  echo "All RV32 JIT tests passed!"
