## Test: general tail call optimization (TCO) beyond self-recursion
##
## Tests:
##   1. return_call to a different function (cross-function tail call)
##   2. return_call_indirect (tail call through function table)
##
## Module layout for test 1 (cross-function):
##   func 0: double(x: i32) -> i32  = x * 2
##   func 1: proxy(x: i32) -> i32   = return_call double (→ double(x))
##
## Module layout for test 2 (return_call_indirect):
##   func 0: double(x: i32) -> i32  = x * 2
##   func 1: triple(x: i32) -> i32  = x * 3
##   func 2: dispatch(idx,x: i32) -> i32  = return_call_indirect type0[idx](x)
##   table 0: [double, triple]

import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime
import cps/wasm/jit/memory
import cps/wasm/jit/pipeline
import cps/wasm/jit/compiler

type JitFnPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                     memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

proc leb(v: uint32): seq[byte] =
  var x = v
  while true:
    var b = byte(x and 0x7F); x = x shr 7
    if x != 0: b = b or 0x80
    result.add(b)
    if x == 0: break

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id); result.add(leb(uint32(content.len))); result.add(content)

proc callJit1(fn: JitFnPtr, arg: uint64): int32 =
  var vs: array[8, uint64]
  var locs: array[4, uint64] = [arg, 0, 0, 0]
  let r = fn(vs[0].addr, locs[0].addr, nil, 0)
  let cnt = (cast[uint](r) - cast[uint](vs[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int32](vs[0] and 0xFFFFFFFF'u64)

proc callJit2(fn: JitFnPtr, a0, a1: uint64): int32 =
  var vs: array[8, uint64]
  var locs: array[4, uint64] = [a0, a1, 0, 0]
  let r = fn(vs[0].addr, locs[0].addr, nil, 0)
  let cnt = (cast[uint](r) - cast[uint](vs[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int32](vs[0] and 0xFFFFFFFF'u64)

# ---------------------------------------------------------------------------
# Test 1: return_call to different function
# ---------------------------------------------------------------------------

proc buildCrossCallModule(): seq[byte] =
  ## func 0: double(x) = x*2   (type 0: i32->i32)
  ## func 1: proxy(x)  = return_call 0  (type 0: i32->i32)
  result = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
  # Type section: 1 type: (i32)->i32
  var tc: seq[byte]
  tc.add(leb(1'u32))
  tc.add(0x60'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8)
  result.add(section(1, tc))
  # Function section: [type0, type0]
  var fc: seq[byte]
  fc.add(leb(2'u32)); fc.add(leb(0'u32)); fc.add(leb(0'u32))
  result.add(section(3, fc))
  # Code section
  var cc: seq[byte]
  cc.add(leb(2'u32))
  # func 0: double  — 0 locals; local.get 0; i32.const 2; i32.mul; end
  let f0 = @[0x00'u8, 0x20'u8, 0x00, 0x41'u8, 0x02, 0x6C'u8, 0x0B'u8]
  cc.add(leb(uint32(f0.len))); cc.add(f0)
  # func 1: proxy  — 0 locals; local.get 0; return_call 0; end
  let f1 = @[0x00'u8, 0x20'u8, 0x00, 0x12'u8, 0x00, 0x0B'u8]
  cc.add(leb(uint32(f1.len))); cc.add(f1)
  result.add(section(10, cc))

proc testCrossCall() =
  let wasm = buildCrossCallModule()
  let module = decodeModule(wasm)
  var pool = initJitMemPool()

  # Compile double (func 0) first
  let doubleCode = pool.compileTier2(module, funcIdx = 0, selfModuleIdx = 0)
  let doubleFn = cast[JitFnPtr](doubleCode.address)
  assert callJit1(doubleFn, 5) == 10, "double(5) should be 10"

  # Build funcElems: index 0 = double, index 1 = proxy (will fill in below)
  var funcData = newSeq[TableElem](2)
  funcData[0] = TableElem(jitAddr: doubleCode.address, paramCount: 1, localCount: 1, resultCount: 1)
  # func 1 (proxy) not yet compiled — will be provided as nil, proxy uses return_call 0

  let funcPtr = cast[ptr UncheckedArray[TableElem]](funcData[0].unsafeAddr)

  # Compile proxy (func 1) with funcElems so it can resolve the cross-call to double
  let proxyCode = pool.compileTier2(module, funcIdx = 1, selfModuleIdx = 1,
                                    funcElems = funcPtr, numFuncs = 2)
  let proxyFn = cast[JitFnPtr](proxyCode.address)

  let r5 = callJit1(proxyFn, 5)
  assert r5 == 10, "proxy(5) = double(5) = 10, got " & $r5
  echo "PASS: proxy(5) = double(5) = 10 (cross-function return_call)"

  let r7 = callJit1(proxyFn, 7)
  assert r7 == 14, "proxy(7) = double(7) = 14, got " & $r7
  echo "PASS: proxy(7) = double(7) = 14 (cross-function return_call)"

  pool.destroy()

# ---------------------------------------------------------------------------
# Test 2: return_call_indirect
# ---------------------------------------------------------------------------

proc buildReturnCallIndirectModule(): seq[byte] =
  ## func 0: double(x) = x*2   (type 0: i32->i32)
  ## func 1: triple(x) = x*3   (type 0: i32->i32)
  ## func 2: dispatch(idx,x) = return_call_indirect type0[idx](x)  (type 1: i32,i32->i32)
  ## table 0: [double, triple]
  result = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
  # Type section
  var tc: seq[byte]
  tc.add(leb(2'u32))
  tc.add(0x60'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8)  # type 0
  tc.add(0x60'u8); tc.add(leb(2'u32)); tc.add(0x7F'u8); tc.add(0x7F'u8)                       # type 1
  tc.add(leb(1'u32)); tc.add(0x7F'u8)
  result.add(section(1, tc))
  # Function section: [type0, type0, type1]
  var fc: seq[byte]
  fc.add(leb(3'u32)); fc.add(leb(0'u32)); fc.add(leb(0'u32)); fc.add(leb(1'u32))
  result.add(section(3, fc))
  # Table section
  var tab: seq[byte]
  tab.add(leb(1'u32)); tab.add(0x70'u8); tab.add(0x00'u8); tab.add(leb(2'u32))
  result.add(section(4, tab))
  # Element section: active, table 0, offset 0, [func0, func1]
  var ec: seq[byte]
  ec.add(leb(1'u32)); ec.add(0x00'u8)
  ec.add(0x41'u8); ec.add(0x00'u8); ec.add(0x0B'u8)
  ec.add(leb(2'u32)); ec.add(leb(0'u32)); ec.add(leb(1'u32))
  result.add(section(9, ec))
  # Code section
  var cc: seq[byte]
  cc.add(leb(3'u32))
  let f0 = @[0x00'u8, 0x20'u8, 0x00, 0x41'u8, 0x02, 0x6C'u8, 0x0B'u8]  # double
  cc.add(leb(uint32(f0.len))); cc.add(f0)
  let f1 = @[0x00'u8, 0x20'u8, 0x00, 0x41'u8, 0x03, 0x6C'u8, 0x0B'u8]  # triple
  cc.add(leb(uint32(f1.len))); cc.add(f1)
  # func 2: dispatch — 0 locals; local.get 1 (x); local.get 0 (idx); return_call_indirect type0 table0; end
  # opcode 0x13 = return_call_indirect
  let f2 = @[0x00'u8, 0x20'u8, 0x01, 0x20'u8, 0x00, 0x13'u8, 0x00, 0x00, 0x0B'u8]
  cc.add(leb(uint32(f2.len))); cc.add(f2)
  result.add(section(10, cc))

proc testReturnCallIndirect() =
  let wasm = buildReturnCallIndirectModule()
  let module = decodeModule(wasm)
  var vm = initWasmVM()
  discard vm.instantiate(module, [])
  var pool = initJitMemPool()

  let doubleCode = pool.compileTier2(module, funcIdx = 0, selfModuleIdx = 0)
  let tripleCode = pool.compileTier2(module, funcIdx = 1, selfModuleIdx = 1)
  let doubleFn = cast[JitFnPtr](doubleCode.address)
  let tripleFn = cast[JitFnPtr](tripleCode.address)
  assert callJit1(doubleFn, 5) == 10
  assert callJit1(tripleFn, 5) == 15

  let tableData = @[
    TableElem(jitAddr: doubleCode.address, paramCount: 1, localCount: 1, resultCount: 1),
    TableElem(jitAddr: tripleCode.address, paramCount: 1, localCount: 1, resultCount: 1),
  ]
  let tablePtr = cast[ptr UncheckedArray[TableElem]](tableData[0].unsafeAddr)

  let dispCode = pool.compileTier2(module, funcIdx = 2, selfModuleIdx = 2,
                                   tableElems = tablePtr, tableLen = 2)
  let dispFn = cast[JitFnPtr](dispCode.address)

  let r0 = callJit2(dispFn, 0, 5)
  assert r0 == 10, "return_call_indirect dispatch(0,5)=double(5)=10, got " & $r0
  echo "PASS: return_call_indirect dispatch(0,5) = double(5) = 10"

  let r1 = callJit2(dispFn, 1, 5)
  assert r1 == 15, "return_call_indirect dispatch(1,5)=triple(5)=15, got " & $r1
  echo "PASS: return_call_indirect dispatch(1,5) = triple(5) = 15"

  let r2 = callJit2(dispFn, 0, 7)
  assert r2 == 14, "return_call_indirect dispatch(0,7)=double(7)=14, got " & $r2
  echo "PASS: return_call_indirect dispatch(0,7) = double(7) = 14"

  pool.destroy()

# ---------------------------------------------------------------------------
when isMainModule:
  testCrossCall()
  testReturnCallIndirect()
  echo "All general TCO tests passed!"
