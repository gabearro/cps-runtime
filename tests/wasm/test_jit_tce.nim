## Test: self-recursive tail call elimination (TCE) in Tier 2 JIT
##
## return_call <self> is converted to a back-edge loop rather than a real call,
## eliminating stack growth for self-recursive WASM functions.

import cps/wasm/types
import cps/wasm/binary
import cps/wasm/jit/memory
import cps/wasm/jit/pipeline

proc makeModule(funcTypes: seq[tuple[params, results: seq[byte]]],
                funcBodies: seq[seq[byte]]): WasmModule =
  proc leb(v: uint32): seq[byte] =
    var x = v
    while true:
      var b = byte(x and 0x7F); x = x shr 7
      if x != 0: b = b or 0x80
      result.add(b)
      if x == 0: break
  proc section(id: byte, content: seq[byte]): seq[byte] =
    result.add(id); result.add(leb(uint32(content.len))); result.add(content)

  var wasm = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

  var typeContent: seq[byte]
  typeContent.add(leb(uint32(funcTypes.len)))
  for ft in funcTypes:
    typeContent.add(0x60'u8)
    typeContent.add(leb(uint32(ft.params.len))); typeContent.add(ft.params)
    typeContent.add(leb(uint32(ft.results.len))); typeContent.add(ft.results)
  wasm.add(section(1, typeContent))

  var funcContent: seq[byte]
  funcContent.add(leb(uint32(funcBodies.len)))
  for i in 0 ..< funcBodies.len:
    funcContent.add(leb(0'u32))
  wasm.add(section(3, funcContent))

  var codeContent: seq[byte]
  codeContent.add(leb(uint32(funcBodies.len)))
  for body in funcBodies:
    codeContent.add(leb(uint32(body.len + 2)))
    codeContent.add(0x00'u8)
    codeContent.add(body)
    codeContent.add(0x0B'u8)
  wasm.add(section(10, codeContent))

  decodeModule(wasm)

proc callCompiled(module: WasmModule, funcIdx: int, arg0: uint64): int32 =
  type FnPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                    memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}
  var pool = initJitMemPool()
  let compiled = pool.compileTier2(module, funcIdx = funcIdx)
  let fn = cast[FnPtr](compiled.address)
  var vstack: array[64, uint64]
  var locals: array[4, uint64] = [arg0, 0'u64, 0'u64, 0'u64]
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let count = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert count == 1, "expected 1 return value, got " & $count
  pool.destroy()
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

proc testCountdown() =
  ## countdown(n): if n==0 return 0, else return_call countdown(n-1)
  ## Tests: n=0 (no iteration), n=1 (one iteration), n=5 (five)
  ##
  ## Bytecode:
  ##   local.get 0; i32.eqz; if i32; i32.const 0
  ##   else; local.get 0; i32.const 1; i32.sub; return_call 0; end
  let module = makeModule(
    @[(params: @[0x7F'u8], results: @[0x7F'u8])],
    @[@[
      0x20'u8, 0x00,        # local.get 0
      0x45'u8,              # i32.eqz
      0x04'u8, 0x7F'u8,     # if i32
        0x41'u8, 0x00'u8,   #   i32.const 0
      0x05'u8,              # else
        0x20'u8, 0x00'u8,   #   local.get 0
        0x41'u8, 0x01'u8,   #   i32.const 1
        0x6B'u8,            #   i32.sub
        0x12'u8, 0x00'u8,   #   return_call 0
      0x0B'u8,              # end
    ]])

  let r0 = callCompiled(module, 0, 0'u64)
  assert r0 == 0, "countdown(0) should be 0, got " & $r0
  echo "PASS: countdown(0) = 0"

  let r1 = callCompiled(module, 0, 1'u64)
  assert r1 == 0, "countdown(1) should be 0, got " & $r1
  echo "PASS: countdown(1) = 0"

  let r5 = callCompiled(module, 0, 5'u64)
  assert r5 == 0, "countdown(5) should be 0, got " & $r5
  echo "PASS: countdown(5) = 0"

  let rBig = callCompiled(module, 0, 100_000'u64)
  assert rBig == 0, "countdown(100000) should be 0, got " & $rBig
  echo "PASS: countdown(100000) = 0 (no stack overflow)"

proc testAccumulator() =
  ## sum(n, acc) = if n==0: acc else: return_call sum(n-1, acc+n)
  ## sum(10, 0) = 55
  ##
  ## Bytecode for (i32, i32) -> i32:
  ##   local.get 0; i32.eqz; if i32
  ##     local.get 1
  ##   else
  ##     local.get 0; i32.const 1; i32.sub
  ##     local.get 1; local.get 0; i32.add
  ##     return_call 0
  ##   end
  let module = makeModule(
    @[(params: @[0x7F'u8, 0x7F'u8], results: @[0x7F'u8])],
    @[@[
      0x20'u8, 0x00'u8,     # local.get 0  (n)
      0x45'u8,              # i32.eqz
      0x04'u8, 0x7F'u8,     # if i32
        0x20'u8, 0x01'u8,   #   local.get 1 (acc)
      0x05'u8,              # else
        0x20'u8, 0x00'u8,   #   local.get 0 (n)
        0x41'u8, 0x01'u8,   #   i32.const 1
        0x6B'u8,            #   i32.sub  → n-1
        0x20'u8, 0x01'u8,   #   local.get 1 (acc)
        0x20'u8, 0x00'u8,   #   local.get 0 (n)
        0x6A'u8,            #   i32.add  → acc+n
        0x12'u8, 0x00'u8,   #   return_call 0
      0x0B'u8,              # end
    ]])

  type FnPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                    memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

  var pool = initJitMemPool()
  let compiled = pool.compileTier2(module, funcIdx = 0)
  let fn = cast[FnPtr](compiled.address)

  var vstack: array[64, uint64]
  var locals10: array[4, uint64] = [10'u64, 0'u64, 0'u64, 0'u64]
  let ret10 = fn(vstack[0].addr, locals10[0].addr, nil, 0)
  let count10 = (cast[uint](ret10) - cast[uint](vstack[0].addr)) div 8
  let result10 = cast[int32](vstack[0] and 0xFFFFFFFF'u64)
  assert count10 == 1 and result10 == 55,
    "sum(10,0) should be 55, got count=" & $count10 & " result=" & $result10
  echo "PASS: sum(10, 0) = 55"
  pool.destroy()

when isMainModule:
  testCountdown()
  testAccumulator()
  echo "All TCE tests passed!"
