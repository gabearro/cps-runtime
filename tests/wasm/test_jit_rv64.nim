## Test: RV64 Tier 2 WASM JIT backend.
## These tests validate code generation byte patterns. They do not execute RV64
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

proc testEncoderBasics() =
  var buf = initRv64AsmBuffer()
  buf.addi(sp, sp, -48)
  buf.sd(ra, sp, 0)
  buf.ret()
  assert buf.code[0] == 0xFD010113'u32
  assert buf.code[1] == 0x00113023'u32
  assert buf.code[2] == 0x00008067'u32

  var th = initRv64AsmBuffer()
  th.thMvnez(t0, t1, t2)
  th.thSdd(ra, s0, sp, 0)
  assert (th.code[0] and 0xFE00707F'u32) == 0x4200100B'u32
  assert (th.code[1] and 0xF800707F'u32) == 0xF800500B'u32

  var ext = initRv64AsmBuffer()
  ext.sh1add(t0, t1, t2)
  ext.andn(t0, t1, t2)
  ext.bset(t0, t1, t2)
  assert (ext.code[0] and 0xFE00707F'u32) == 0x20002033'u32
  assert (ext.code[1] and 0xFE00707F'u32) == 0x40007033'u32
  assert (ext.code[2] and 0xFE00707F'u32) == 0x28001033'u32

  var vec = initRv64AsmBuffer()
  vec.vsetvli(zero, t0, 8)
  vec.vsetvli(zero, t0, 32)
  vec.vsetvliTHead07(zero, t0, 32)
  vec.vle8V(RvReg(8), t0)
  vec.vse8V(RvReg(8), t0)
  vec.vmvVx(RvReg(8), t0)
  vec.vaddVv(RvReg(10), RvReg(8), RvReg(9))
  vec.vfaddVv(RvReg(10), RvReg(8), RvReg(9))
  assert vec.code[0] == 0x0C02F057'u32
  assert vec.code[1] == 0x0D02F057'u32
  assert vec.code[2] == 0x0102F057'u32
  assert vec.code[3] == 0x02028407'u32
  assert vec.code[4] == 0x02028427'u32
  assert vec.code[5] == 0x5E02C457'u32
  assert vec.code[6] == 0x02848557'u32
  assert vec.code[7] == 0x02849557'u32

  var d = initRv64AsmBuffer()
  d.fmvDX(RvReg(0), t0)
  d.fmvXD(t0, RvReg(0))
  d.faddD(RvReg(0), RvReg(1), RvReg(2))
  assert d.code[0] == 0xF2028053'u32
  assert d.code[1] == 0xE20002D3'u32
  assert d.code[2] == 0x02208053'u32
  echo "PASS: rv64 encoder basics"

proc testBl808Rv64TargetProfile() =
  let d0 = bl808Target(bl808D0)
  assert d0 == rv64BL808D0Target
  assert rv64TheadC906Target == rv64BL808D0Target
  assert d0.supportsNativeRv64Jit
  assert rvExtM in d0.features
  assert rvExtA in d0.features
  assert rvExtF in d0.features
  assert rvExtC in d0.features
  assert rvExtV in d0.features
  assert rvExtD notin d0.features
  assert rv64XTheadBa in d0.features
  assert rv64XTheadBb in d0.features
  assert rv64XTheadBs in d0.features
  assert rv64XTheadCmo in d0.features
  assert rv64XTheadCondMov in d0.features
  assert rv64XTheadFMemIdx in d0.features
  assert rv64XTheadFmv in d0.features
  assert rv64XTheadInt in d0.features
  assert rv64XTheadMac in d0.features
  assert rv64XTheadMemIdx in d0.features
  assert rv64XTheadMemPair in d0.features
  assert rv64XTheadSync in d0.features
  assert rv64XTheadVdot in d0.features
  assert rv64XTheadVector in d0.features
  echo "PASS: rv64 BL808 D0/C906 target profile"

proc testRv64AddGeneric() =
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
  let code = compileTier2Rv64(pool, module, 0)
  assert code.address != nil
  assert code.size > 0
  assert (wordAt(code, 0) and 0x000FFFFF'u32) == 0x00010113'u32 # addi sp, sp, -frame
  assert wordAt(code, code.size div 4 - 1) == 0x00008067'u32
  assert not code.hasInstr(0xF800707F'u32, 0xF800500B'u32)
  echo "PASS: rv64 generic add - ", code.size, " bytes"
  pool.destroy()

proc testRv64BL808SelectUsesThead() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("sel", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0x20, 0x02,
    0x1B,
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let code = compileTier2Rv64(pool, module, 0, target = rv64BL808Target)
  assert code.address != nil
  assert code.hasInstr(0xF800707F'u32, 0xF800500B'u32) # th.sdd prologue save-pair
  assert code.hasInstr(0xFE00707F'u32, 0x4200100B'u32) # th.mvnez select
  echo "PASS: rv64 BL808/T-Head select - ", code.size, " bytes"
  pool.destroy()

proc testRv64SignedByteLoadCompiles() =
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
  let code = compileTier2Rv64(pool, module, 0)
  assert code.address != nil
  assert code.hasInstr(0x0000707F'u32, 0x00000003'u32) # LB opcode/funct3
  echo "PASS: rv64 signed byte load - ", code.size, " bytes"
  pool.destroy()

proc testRv64CommonZbbClz() =
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
  let code = compileTier2Rv64(pool, module, 0, target = rv64CommonTarget)
  assert code.address != nil
  assert code.hasInstr(0xFFF0707F'u32, 0x6000101B'u32) # clzw
  echo "PASS: rv64 common Zbb clz - ", code.size, " bytes"
  pool.destroy()

proc testRv64BL808BitCountFallbacksCompile() =
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
  let code = compileTier2Rv64(pool, module, 0, target = rv64BL808D0Target)
  assert code.address != nil
  assert not code.hasInstr(0xFFF0707F'u32, 0x6000101B'u32) # no Zbb clzw
  echo "PASS: rv64 BL808 bit-count fallback - ", code.size, " bytes"
  pool.destroy()

proc testRv64BL808F32AddCompiles() =
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
  var pool = initJitMemPool()
  let code = compileTier2Rv64(pool, module, 0, target = rv64BL808D0Target)
  assert code.address != nil
  assert code.hasInstr(0xFE00007F'u32, 0x00000053'u32) # fadd.s
  echo "PASS: rv64 BL808 f32.add - ", code.size, " bytes"
  pool.destroy()

proc testRv64BL808F32FmaAndRoundingCompile() =
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
  let fmaCode = compileTier2Rv64(fmaPool, fmaModule, 0, target = rv64BL808D0Target)
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
  let roundCode = compileTier2Rv64(roundPool, roundModule, 0, target = rv64BL808D0Target)
  assert roundCode.address != nil
  assert roundCode.hasInstr(0xFFFF_FFFF'u32, 0x000F80E7'u32) # jalr ra, t6, 0
  roundPool.destroy()
  echo "PASS: rv64 BL808 f32 FMA and rounding"

proc testRv64BL808F32I64ConversionsCompile() =
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
  let toCode = compileTier2Rv64(toPool, toModule, 0, target = rv64BL808D0Target)
  assert toCode.address != nil
  assert toCode.hasInstr(0xFFF0007F'u32, 0xD0200053'u32) # fcvt.s.l
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
  let fromCode = compileTier2Rv64(fromPool, fromModule, 0, target = rv64BL808D0Target)
  assert fromCode.address != nil
  assert fromCode.hasInstr(0xFFF0007F'u32, 0xC0200053'u32) # fcvt.l.s
  fromPool.destroy()
  echo "PASS: rv64 BL808 f32/i64 conversions"

proc testRv64CommonF64AddAndD0Rejects() =
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
  var commonPool = initJitMemPool()
  let code = compileTier2Rv64(commonPool, module, 0, target = rv64CommonTarget)
  assert code.address != nil
  assert code.hasInstr(0xFE00007F'u32, 0x02000053'u32) # fadd.d
  commonPool.destroy()

  var d0Pool = initJitMemPool()
  var rejected = false
  try:
    discard compileTier2Rv64(d0Pool, module, 0, target = rv64BL808D0Target)
  except ValueError:
    rejected = true
  assert rejected
  d0Pool.destroy()
  echo "PASS: rv64 common f64.add and BL808 D0 reject"

proc testRv64CommonF64FmaAndRoundingCompile() =
  var fmaWasm = wasmHeader()
  fmaWasm.add(typeSection(@[funcType(@[0x7C'u8, 0x7C, 0x7C], @[0x7C'u8])]))
  fmaWasm.add(funcSection(@[0'u32]))
  fmaWasm.add(exportSection(@[("fma64", 0x00'u8, 0'u32)]))
  fmaWasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0xA2, # f64.mul
    0x20, 0x02,
    0xA0, # f64.add
  ])]))

  let fmaModule = decodeModule(fmaWasm)
  var fmaPool = initJitMemPool()
  let fmaCode = compileTier2Rv64(fmaPool, fmaModule, 0, target = rv64CommonTarget)
  assert fmaCode.address != nil
  assert fmaCode.hasInstr(0x0000007F'u32, 0x00000043'u32) # fmadd.d
  fmaPool.destroy()

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
  let roundCode = compileTier2Rv64(roundPool, roundModule, 0, target = rv64CommonTarget)
  assert roundCode.address != nil
  assert roundCode.hasInstr(0xFFFF_FFFF'u32, 0x000F80E7'u32) # jalr ra, t6, 0
  roundPool.destroy()
  echo "PASS: rv64 common f64 FMA and rounding"

proc testRv64DirectAndIndirectCallsCompile() =
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
  let callerCode = compileTier2Rv64(directPool, directModule, 1,
                                    selfModuleIdx = 1,
                                    funcElems = funcPtr,
                                    numFuncs = funcElems.len.int32)
  assert callerCode.address != nil
  assert callerCode.hasInstr(0xFFFF_FFFF'u32, 0x000F80E7'u32) # jalr ra, t6, 0
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
  let dispatchCode = compileTier2Rv64(indirectPool, indirectModule, 2,
                                      selfModuleIdx = 2,
                                      tableElems = tablePtr,
                                      tableLen = tableElems.len.int32)
  assert dispatchCode.address != nil
  assert dispatchCode.hasInstr(0xFFFF_FFFF'u32, 0x000F80E7'u32) # jalr ra, t6, 0
  indirectPool.destroy()
  echo "PASS: rv64 direct and indirect calls compile"

proc testRv64RejectsTrapLoweredOps() =
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
    discard compileTier2Rv64(pool, module, 0)
  except ValueError:
    rejected = true
  assert rejected
  pool.destroy()
  echo "PASS: rv64 rejects trap-lowered Tier 2 ops"

proc testRv64BL808SimdI32x4AddCompiles() =
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
  var pool = initJitMemPool()
  let code = compileTier2Rv64(pool, module, 0, target = rv64BL808D0Target)
  assert code.address != nil
  assert code.hasInstr(0xFFF0707F'u32, 0x01007057'u32) # T-Head RVV 0.7 vsetvli e32,m1
  assert code.hasInstr(0xFE00707F'u32, 0x02000057'u32) # vadd.vv
  assert code.hasInstr(0xFE00707F'u32, 0x02000007'u32) # vle8.v
  assert code.hasInstr(0xFE00707F'u32, 0x02000027'u32) # vse8.v
  echo "PASS: rv64 BL808 SIMD i32x4.add - ", code.size, " bytes"
  pool.destroy()

proc testRv64V128ParamsResultsAndLocalsCompile() =
  var identityWasm = wasmHeader()
  identityWasm.add(typeSection(@[funcType(@[0x7B'u8], @[0x7B'u8])]))
  identityWasm.add(funcSection(@[0'u32]))
  identityWasm.add(exportSection(@[("id_v128", 0x00'u8, 0'u32)]))
  identityWasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00, # local.get 0
  ])]))

  let identityModule = decodeModule(identityWasm)
  var identityPool = initJitMemPool()
  let identityCode = compileTier2Rv64(identityPool, identityModule, 0,
                                      target = rv64BL808D0Target)
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
  let localCode = compileTier2Rv64(localPool, localModule, 0,
                                   target = rv64BL808D0Target)
  assert localCode.address != nil
  assert localCode.numLocals == 4
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
  let directCode = compileTier2Rv64(directPool, directModule, 1,
                                    selfModuleIdx = 1,
                                    funcElems = funcPtr,
                                    numFuncs = funcElems.len.int32,
                                    target = rv64BL808D0Target)
  assert directCode.address != nil
  directPool.destroy()
  echo "PASS: rv64 v128 params/results/locals compile"

when isMainModule:
  testEncoderBasics()
  testBl808Rv64TargetProfile()
  testRv64AddGeneric()
  testRv64BL808SelectUsesThead()
  testRv64SignedByteLoadCompiles()
  testRv64CommonZbbClz()
  testRv64BL808BitCountFallbacksCompile()
  testRv64BL808F32AddCompiles()
  testRv64BL808F32FmaAndRoundingCompile()
  testRv64BL808F32I64ConversionsCompile()
  testRv64CommonF64AddAndD0Rejects()
  testRv64CommonF64FmaAndRoundingCompile()
  testRv64DirectAndIndirectCallsCompile()
  testRv64RejectsTrapLoweredOps()
  testRv64BL808SimdI32x4AddCompiles()
  testRv64V128ParamsResultsAndLocalsCompile()
  echo "All RV64 JIT tests passed!"
