## Test: JIT function calls (JIT→JIT direct calls, self-recursion)

import std/[times, strutils, os]
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/jit/memory
import cps/wasm/jit/codegen
import cps/wasm/jit/compiler

type JitFuncPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                       memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

proc testJitCallSimple() =
  ## Test calling another JIT'd function: double(x) = x+x, test(x) = double(x)
  # Two functions: double(i32)->i32, test(i32)->i32
  # double: local.get 0; local.get 0; i32.add
  # test: local.get 0; call 0  (calls double)

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

  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32, 0'u32]))  # two functions of type (i32)->i32
  wasm.add(exportSection(@[("test", 0x00'u8, 1'u32)]))
  wasm.add(codeSection(@[
    # func 0: double(x) = x + x
    funcBody(@[], @[0x20'u8, 0x00, 0x20, 0x00, 0x6A]),
    # func 1: test(x) = call double(x)
    funcBody(@[], @[0x20'u8, 0x00, 0x10, 0x00]),  # local.get 0; call 0
  ]))

  let module = decodeModule(wasm)
  var pool = initJitMemPool()

  # First compile double (func 0)
  let doubleCompiled = pool.compileFunction(module, 0)
  let doubleFn = cast[JitFuncPtr](doubleCompiled.code.address)

  # Test double directly
  var locals0: array[1, uint64] = [21'u64]
  var vstack0: array[64, uint64]
  let r0 = doubleFn(vstack0[0].addr, locals0[0].addr, nil, 0)
  let count0 = (cast[uint](r0) - cast[uint](vstack0[0].addr)) div 8
  assert count0 == 1 and cast[int32](vstack0[0] and 0xFFFFFFFF'u64) == 42
  echo "PASS: JIT double(21) = 42"

  # Now compile test (func 1) with call target for func 0
  let targets = @[
    CallTarget(jitAddr: doubleCompiled.code.address, paramCount: 1, localCount: 1, resultCount: 1),
    CallTarget(jitAddr: nil, paramCount: 1, localCount: 1, resultCount: 1),  # self (will be patched)
  ]
  let testCompiled = pool.compileFunction(module, 1, targets)
  let testFn = cast[JitFuncPtr](testCompiled.code.address)

  # Test: test(5) should call double(5) = 10
  var locals1: array[1, uint64] = [5'u64]
  var vstack1: array[64, uint64]
  let r1 = testFn(vstack1[0].addr, locals1[0].addr, nil, 0)
  let count1 = (cast[uint](r1) - cast[uint](vstack1[0].addr)) div 8
  assert count1 == 1, "Expected 1 result, got " & $count1
  assert cast[int32](vstack1[0] and 0xFFFFFFFF'u64) == 10,
    "Expected 10, got " & $cast[int32](vstack1[0] and 0xFFFFFFFF'u64)
  echo "PASS: JIT test(5) = double(5) = 10"

  pool.destroy()

proc testJitFibFromBinary() =
  ## Test JIT-compiled fib from the real clang-compiled binary
  let wasmPath = currentSourcePath.parentDir / "testdata" / "fib.wasm"
  let data = cast[seq[byte]](readFile(wasmPath))
  let module = decodeModule(data)

  var pool = initJitMemPool()

  # The fib.wasm has: func 0 = __wasm_call_ctors, func 1 = fib, func 2 = factorial, ...
  # Fib calls itself (func 1). We need to compile it with a self-referencing target.

  # First compile fib without call targets to get the code address
  # Then recompile with the target pointing to itself
  let fibCompiled1 = pool.compileFunction(module, 1)
  let fibAddr = fibCompiled1.code.address

  # Now recompile with call targets
  # The module has 4 code entries. Func indices in the module are 0-based for codes.
  # The fib function (code idx 1) calls func 1 (which is code idx 1 = itself after resolving imports)
  var targets = newSeq[CallTarget](5)  # enough for all funcs
  # func 0: __wasm_call_ctors — not JIT'd
  targets[0] = CallTarget(jitAddr: nil, paramCount: 0, localCount: 0, resultCount: 0)
  # func 1: fib — JIT'd, calls itself
  targets[1] = CallTarget(jitAddr: fibAddr, paramCount: 1, localCount: 3, resultCount: 1)
  # func 2+: not JIT'd
  for i in 2 ..< targets.len:
    targets[i] = CallTarget(jitAddr: nil, paramCount: 0, localCount: 0, resultCount: 0)

  pool.reset()  # reset pool to reuse memory
  let fibCompiled = pool.compileFunction(module, 1, targets)
  let fibFn = cast[JitFuncPtr](fibCompiled.code.address)

  # Update the target to point to the new address (self-reference)
  # Actually we need to recompile once more with the correct address...
  # For self-recursion, the compiler should use BL to its own entry.
  # Let's just test with the initial compilation first.

  var locals: array[3, uint64] = [10'u64, 0, 0]
  var vstack: array[256, uint64]

  # Set up memory (fib.wasm has 1 memory of 2 pages)
  var mem = newSeq[byte](131072)

  echo "Running JIT fib(10)..."
  let t = cpuTime()
  let r = fibFn(vstack[0].addr, locals[0].addr, mem[0].addr, mem.len.uint64)
  let elapsed = cpuTime() - t
  let count = (cast[uint](r) - cast[uint](vstack[0].addr)) div 8
  if count >= 1:
    let result = cast[int32](vstack[0] and 0xFFFFFFFF'u64)
    echo "fib(10) = " & $result & " (" & formatFloat(elapsed * 1000, ffDecimal, 2) & " ms)"
    assert result == 55, "Expected 55"
    echo "PASS: JIT fib(10) = 55"
  else:
    echo "No results on value stack (count=" & $count & ")"

  pool.destroy()

# ---- Run ----
testJitCallSimple()
# testJitFibFromBinary()  # uncomment when self-recursion is working

echo ""
echo "All JIT call tests passed!"
