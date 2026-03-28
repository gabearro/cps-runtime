## Test: call_indirect support in Tier 2 optimizing JIT
##
## Module layout:
##   func 0: double(x: i32) -> i32  = x * 2
##   func 1: triple(x: i32) -> i32  = x * 3
##   func 2: dispatch(idx: i32, x: i32) -> i32  =  call_indirect [type 0][idx](x)
##   table 0: [funcref double, funcref triple]
##
## We JIT-compile double and triple to Tier 2, then compile dispatch through
## the full Tier 2 pipeline (lowering → IR → opt → regalloc → codegen).
## The test verifies that call_indirect works correctly in Tier 2.

import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime
import cps/wasm/jit/memory
import cps/wasm/jit/compiler
import cps/wasm/jit/pipeline

type JitFnPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                     memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

# ---------------------------------------------------------------------------
# WASM module builder helpers
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

proc buildDispatchModule(): seq[byte] =
  ## Build a minimal WASM module with:
  ##   func 0: double(x) = x*2       (type 0: i32->i32)
  ##   func 1: triple(x) = x*3       (type 0: i32->i32)
  ##   func 2: dispatch(idx,x)        (type 1: (i32,i32)->i32)
  ##             = call_indirect(type 0, table 0)[idx](x)
  result = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

  # Type section: type 0 = (i32)->i32,  type 1 = (i32,i32)->i32
  var tc: seq[byte]
  tc.add(leb(2'u32))
  # type 0: (i32)->i32
  tc.add(0x60'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8)
  # type 1: (i32,i32)->i32
  tc.add(0x60'u8); tc.add(leb(2'u32)); tc.add(0x7F'u8); tc.add(0x7F'u8)
  tc.add(leb(1'u32)); tc.add(0x7F'u8)
  result.add(section(1, tc))

  # Function section: [type0, type0, type1]
  var fc: seq[byte]
  fc.add(leb(3'u32))
  fc.add(leb(0'u32)); fc.add(leb(0'u32)); fc.add(leb(1'u32))
  result.add(section(3, fc))

  # Table section: 1 funcref table, min size 2
  var tabc: seq[byte]
  tabc.add(leb(1'u32)); tabc.add(0x70'u8); tabc.add(0x00'u8); tabc.add(leb(2'u32))
  result.add(section(4, tabc))

  # Element section: active, table 0, offset i32.const 0, [func0, func1]
  var ec: seq[byte]
  ec.add(leb(1'u32))    # 1 segment
  ec.add(0x00'u8)       # active, table 0, func-index elements
  ec.add(0x41'u8); ec.add(0x00'u8); ec.add(0x0B'u8)  # i32.const 0; end
  ec.add(leb(2'u32))
  ec.add(leb(0'u32)); ec.add(leb(1'u32))
  result.add(section(9, ec))

  # Code section
  var cc: seq[byte]
  cc.add(leb(3'u32))

  # func 0: double  — local.get 0; i32.const 2; i32.mul; end
  let doubleBody = @[0x00'u8,  # 0 locals
                     0x20'u8, 0x00,  # local.get 0
                     0x41'u8, 0x02,  # i32.const 2
                     0x6C'u8,        # i32.mul
                     0x0B'u8]        # end
  cc.add(leb(uint32(doubleBody.len))); cc.add(doubleBody)

  # func 1: triple  — local.get 0; i32.const 3; i32.mul; end
  let tripleBody = @[0x00'u8,
                     0x20'u8, 0x00,
                     0x41'u8, 0x03,
                     0x6C'u8,
                     0x0B'u8]
  cc.add(leb(uint32(tripleBody.len))); cc.add(tripleBody)

  # func 2: dispatch(idx, x)
  #   local.get 1   -- push x (arg for callee)
  #   local.get 0   -- push idx (element index)
  #   call_indirect type=0 table=0
  #   end
  let dispBody = @[0x00'u8,             # 0 extra locals
                   0x20'u8, 0x01,       # local.get 1 (x)
                   0x20'u8, 0x00,       # local.get 0 (idx)
                   0x11'u8, 0x00, 0x00, # call_indirect type=0 table=0
                   0x0B'u8]             # end
  cc.add(leb(uint32(dispBody.len))); cc.add(dispBody)

  result.add(section(10, cc))

# ---------------------------------------------------------------------------
# JIT call helpers
# ---------------------------------------------------------------------------

proc callJit1(fn: JitFnPtr, arg0: uint64): int32 =
  var vstack: array[8, uint64]
  var locals: array[4, uint64] = [arg0, 0, 0, 0]
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

proc callJit2(fn: JitFnPtr, arg0, arg1: uint64): int32 =
  var vstack: array[8, uint64]
  var locals: array[4, uint64] = [arg0, arg1, 0, 0]
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

when isMainModule:
  let wasmBytes = buildDispatchModule()
  let module = decodeModule(wasmBytes)

  var vm = initWasmVM()
  discard vm.instantiate(module, [])

  var pool = initJitMemPool()

  # Tier 2 compile double (func 0) and triple (func 1).
  let doubleCode = pool.compileTier2(module, funcIdx = 0, selfModuleIdx = 0)
  let tripleCode = pool.compileTier2(module, funcIdx = 1, selfModuleIdx = 1)
  let doubleFn = cast[JitFnPtr](doubleCode.address)
  let tripleFn = cast[JitFnPtr](tripleCode.address)

  assert callJit1(doubleFn, 5) == 10, "Tier2 double(5) should be 10"
  assert callJit1(tripleFn, 5) == 15, "Tier2 triple(5) should be 15"
  echo "PASS: Tier2 double(5)=10, triple(5)=15"

  # Build table data for the dispatch function.
  let tableData = @[
    TableElem(jitAddr: doubleCode.address, paramCount: 1, localCount: 1, resultCount: 1),
    TableElem(jitAddr: tripleCode.address, paramCount: 1, localCount: 1, resultCount: 1),
  ]
  let tablePtr = cast[ptr UncheckedArray[TableElem]](tableData[0].unsafeAddr)
  let tableLen = tableData.len.int32

  # Tier 2 compile dispatch (func 2) with table data.
  let dispCode = pool.compileTier2(module, funcIdx = 2, selfModuleIdx = 2,
                                   tableElems = tablePtr, tableLen = tableLen)
  let dispFn = cast[JitFnPtr](dispCode.address)

  # dispatch(0, 5) → double(5) = 10
  let r0 = callJit2(dispFn, 0, 5)
  assert r0 == 10, "Tier2 dispatch(0,5) should be 10, got " & $r0
  echo "PASS: Tier2 dispatch(0,5) = double(5) = 10"

  # dispatch(1, 5) → triple(5) = 15
  let r1 = callJit2(dispFn, 1, 5)
  assert r1 == 15, "Tier2 dispatch(1,5) should be 15, got " & $r1
  echo "PASS: Tier2 dispatch(1,5) = triple(5) = 15"

  # Multiple same-target calls (monomorphic IC fast path)
  for _ in 0 ..< 5:
    let r = callJit2(dispFn, 0, 7)
    assert r == 14, "Tier2 dispatch(0,7) should be 14, got " & $r
  echo "PASS: Tier2 repeated dispatch(0,7) = 14 (IC fast path)"

  # Switch target to test IC update
  let r2 = callJit2(dispFn, 1, 7)
  assert r2 == 21, "Tier2 dispatch(1,7) should be 21, got " & $r2
  echo "PASS: Tier2 dispatch(1,7) = triple(7) = 21 (IC update)"

  pool.destroy()
  echo "All Tier 2 call_indirect tests passed!"
