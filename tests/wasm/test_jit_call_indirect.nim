## Test: call_indirect with inline caching (Tier 1 JIT)
##
## Builds a module with:
##   func 0: double(x: i32) -> i32  = x * 2
##   func 1: triple(x: i32) -> i32  = x * 3
##   func 2: dispatch(idx: i32, x: i32) -> i32 = call_indirect(type 0, table 0)[idx](x)
##   table 0: [funcref double, funcref triple]
##
## The test manually JIT-compiles double and triple first, then supplies their
## addresses as pre-resolved tableData to compileFunction for dispatch.

import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime
import cps/wasm/jit/memory
import cps/wasm/jit/compiler

# ---------------------------------------------------------------------------
# Module builder
# ---------------------------------------------------------------------------

proc buildModule(): seq[byte] =
  proc leb(v: uint32): seq[byte] =
    var x = v
    while true:
      var b = byte(x and 0x7F); x = x shr 7
      if x != 0: b = b or 0x80
      result.add(b)
      if x == 0: break
  proc section(id: byte, content: seq[byte]): seq[byte] =
    result.add(id); result.add(leb(uint32(content.len))); result.add(content)

  result = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

  # Type section: type 0 = (i32)->i32, type 1 = (i32,i32)->i32
  var typeContent: seq[byte]
  typeContent.add(leb(2'u32))
  typeContent.add(0x60'u8); typeContent.add(leb(1'u32)); typeContent.add(0x7F'u8)
  typeContent.add(leb(1'u32)); typeContent.add(0x7F'u8)   # type 0
  typeContent.add(0x60'u8); typeContent.add(leb(2'u32))
  typeContent.add(0x7F'u8); typeContent.add(0x7F'u8)
  typeContent.add(leb(1'u32)); typeContent.add(0x7F'u8)   # type 1
  result.add(section(1, typeContent))

  # Function section: [type0, type0, type1]
  var funcContent: seq[byte]
  funcContent.add(leb(3'u32))
  funcContent.add(leb(0'u32)); funcContent.add(leb(0'u32)); funcContent.add(leb(1'u32))
  result.add(section(3, funcContent))

  # Table section: 1 funcref table with min 2
  var tableContent: seq[byte]
  tableContent.add(leb(1'u32))
  tableContent.add(0x70'u8)   # funcref
  tableContent.add(0x00'u8)   # limits: min only
  tableContent.add(leb(2'u32))
  result.add(section(4, tableContent))

  # Element section: active, table 0, offset 0, [func 0, func 1]
  var elemContent: seq[byte]
  elemContent.add(leb(1'u32))  # 1 segment
  elemContent.add(0x00'u8)     # flags=0: active, table 0, func indices
  # offset expression: i32.const 0; end
  elemContent.add(0x41'u8); elemContent.add(0x00'u8); elemContent.add(0x0B'u8)
  elemContent.add(leb(2'u32))  # 2 elements
  elemContent.add(leb(0'u32))  # func 0 (double)
  elemContent.add(leb(1'u32))  # func 1 (triple)
  result.add(section(9, elemContent))

  # Code section: double, triple, dispatch
  var codeContent: seq[byte]
  codeContent.add(leb(3'u32))

  let doubleBody = @[0x20'u8, 0x00, 0x41, 0x02, 0x6C]   # local.get 0; i32.const 2; i32.mul
  codeContent.add(leb(uint32(doubleBody.len + 2)))
  codeContent.add(0x00'u8); codeContent.add(doubleBody); codeContent.add(0x0B'u8)

  let tripleBody = @[0x20'u8, 0x00, 0x41, 0x03, 0x6C]   # local.get 0; i32.const 3; i32.mul
  codeContent.add(leb(uint32(tripleBody.len + 2)))
  codeContent.add(0x00'u8); codeContent.add(tripleBody); codeContent.add(0x0B'u8)

  # dispatch(idx, x): push x, push idx, call_indirect type=0 table=0
  let dispBody = @[0x20'u8, 0x01, 0x20, 0x00, 0x11, 0x00, 0x00]
  codeContent.add(leb(uint32(dispBody.len + 2)))
  codeContent.add(0x00'u8); codeContent.add(dispBody); codeContent.add(0x0B'u8)

  result.add(section(10, codeContent))

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

type JitFnPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                      memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

proc callJit1(fn: JitFnPtr, arg0: uint64): int32 =
  var vstack: array[8, uint64]
  var locals: array[4, uint64] = [arg0, 0, 0, 0]
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

proc callJit2(fn: JitFnPtr, arg0, arg1: uint64): int32 =
  var vstack: array[8, uint64]
  var locals: array[4, uint64] = [arg0, arg1, 0, 0]
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

when isMainModule:
  let wasmBytes = buildModule()
  let module = decodeModule(wasmBytes)

  # Instantiate the module to populate the table
  var vm = initWasmVM()
  discard vm.instantiate(module, [])

  var pool = initJitMemPool()

  # JIT-compile double (func 0) and triple (func 1)
  let doubleCompiled = pool.compileFunction(module, funcIdx = 0)
  let tripleCompiled = pool.compileFunction(module, funcIdx = 1)
  let doubleAddr = doubleCompiled.code.address
  let tripleAddr = tripleCompiled.code.address

  # Verify double and triple work on their own
  let doubleFn = cast[JitFnPtr](doubleAddr)
  let tripleFn = cast[JitFnPtr](tripleAddr)
  assert callJit1(doubleFn, 5) == 10, "double(5) should be 10"
  assert callJit1(tripleFn, 5) == 15, "triple(5) should be 15"
  echo "PASS: double(5) = 10, triple(5) = 15"

  # Build tableData from the resolved JIT addresses
  let tableData = @[
    TableElem(jitAddr: doubleAddr, paramCount: 1, localCount: 1, resultCount: 1),
    TableElem(jitAddr: tripleAddr, paramCount: 1, localCount: 1, resultCount: 1),
  ]

  # JIT-compile dispatch (func 2) with the pre-resolved table data
  let dispCompiled = pool.compileFunction(module, funcIdx = 2, tableData = tableData)
  let dispFn = cast[JitFnPtr](dispCompiled.code.address)

  # dispatch(0, 5) = double(5) = 10
  let r0 = callJit2(dispFn, 0, 5)
  assert r0 == 10, "dispatch(0, 5) should be 10 (double), got " & $r0
  echo "PASS: dispatch(0, 5) = double(5) = 10"

  # dispatch(1, 5) = triple(5) = 15
  let r1 = callJit2(dispFn, 1, 5)
  assert r1 == 15, "dispatch(1, 5) should be 15 (triple), got " & $r1
  echo "PASS: dispatch(1, 5) = triple(5) = 15"

  # Multiple calls with same idx hit the IC (monomorphic fast path)
  for _ in 0 ..< 5:
    let r = callJit2(dispFn, 0, 7)
    assert r == 14, "dispatch(0, 7) should be 14"
  echo "PASS: repeated dispatch(0, 7) = 14 (IC fast path)"

  # Switch to different target to test IC update
  let r2 = callJit2(dispFn, 1, 7)
  assert r2 == 21, "dispatch(1, 7) should be 21 (triple), got " & $r2
  echo "PASS: dispatch(1, 7) = triple(7) = 21 (IC update)"

  pool.destroy()
  echo "All call_indirect tests passed!"
