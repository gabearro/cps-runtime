## Test: JIT compile WASM functions and execute them natively

import std/[times, strutils]
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/jit/memory
import cps/wasm/jit/codegen
import cps/wasm/jit/compiler

# WASM builder helpers
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

type JitFuncPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                       memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

proc testJitAdd() =
  # WASM: (i32, i32) -> i32 = a + b
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("add", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0
    0x20, 0x01,      # local.get 1
    0x6A,            # i32.add
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let compiled = pool.compileFunction(module, 0)

  # Set up locals: [a=10, b=32]
  var locals: array[2, uint64] = [10'u64, 32'u64]
  # Value stack (pre-allocated)
  var vstack: array[64, uint64]
  let vsp = vstack[0].addr

  let f = cast[JitFuncPtr](compiled.code.address)
  let resultVsp = f(vsp, locals[0].addr, nil, 0)

  # Result is on the value stack
  let resultCount = (cast[uint](resultVsp) - cast[uint](vsp)) div 8
  assert resultCount == 1, "Expected 1 result on stack, got " & $resultCount
  assert cast[int32](vstack[0] and 0xFFFFFFFF'u64) == 42, "Expected 42, got " & $cast[int32](vstack[0])
  echo "PASS: JIT add(10, 32) = 42"
  pool.destroy()

proc testJitLoop() =
  # WASM: (i32) -> i32 = sum 1..n (loop with local.get/set/tee, i32.add/sub, br_if)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("sum", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[(1'u32, 0x7F'u8)], @[
    0x03'u8, 0x40,        # loop []
      0x20, 0x00,          # local.get 0 (n)
      0x20, 0x01,          # local.get 1 (sum)
      0x6A,                # i32.add
      0x21, 0x01,          # local.set 1
      0x20, 0x00,          # local.get 0
      0x41, 0x01,          # i32.const 1
      0x6B,                # i32.sub
      0x22, 0x00,          # local.tee 0
      0x0D, 0x00,          # br_if 0
    0x0B,                  # end
    0x20, 0x01,            # local.get 1
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let compiled = pool.compileFunction(module, 0)

  var locals: array[2, uint64] = [100'u64, 0'u64]
  var vstack: array[64, uint64]

  let f = cast[JitFuncPtr](compiled.code.address)
  let resultVsp = f(vstack[0].addr, locals[0].addr, nil, 0)

  let resultCount = (cast[uint](resultVsp) - cast[uint](vstack[0].addr)) div 8
  assert resultCount == 1
  let result = cast[int32](vstack[0] and 0xFFFFFFFF'u64)
  assert result == 5050, "Expected 5050, got " & $result
  echo "PASS: JIT sum(100) = 5050"

  # Benchmark: 1M iterations
  locals = [1_000_000'u64, 0'u64]
  let t = cpuTime()
  discard f(vstack[0].addr, locals[0].addr, nil, 0)
  let elapsed = cpuTime() - t
  echo "PASS: JIT 1M loop: " & formatFloat(elapsed * 1000, ffDecimal, 2) & " ms"

  pool.destroy()

proc testJitIfElse() =
  # WASM: (i32) -> i32 = if param > 0 then 1 else -1
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("sign", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,        # local.get 0
    0x41, 0x00,            # i32.const 0
    0x4A,                  # i32.gt_s
    0x04, 0x7F,            # if [i32]
      0x41, 0x01,          # i32.const 1
    0x05,                  # else
      0x41, 0x7F,          # i32.const -1
    0x0B,                  # end
  ])]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()
  let compiled = pool.compileFunction(module, 0)

  let f = cast[JitFuncPtr](compiled.code.address)

  # Test positive
  var locals: array[1, uint64] = [42'u64]
  var vstack: array[64, uint64]
  discard f(vstack[0].addr, locals[0].addr, nil, 0)
  assert cast[int32](vstack[0] and 0xFFFFFFFF'u64) == 1, "Expected 1 for positive"

  # Test negative
  locals = [cast[uint64](-5'i64)]
  discard f(vstack[0].addr, locals[0].addr, nil, 0)
  assert cast[int32](vstack[0] and 0xFFFFFFFF'u64) == -1, "Expected -1 for negative"

  echo "PASS: JIT if/else sign"
  pool.destroy()

# ---- Run ----
testJitAdd()
testJitLoop()
testJitIfElse()

echo ""
echo "All JIT WASM tests passed!"
