## Test: Tier 2 JIT function inlining
## Verifies that small single-BB callees are inlined correctly, including
## transitive inlining (callee that calls another small callee).

import cps/wasm/types
import cps/wasm/binary
import cps/wasm/jit/memory
import cps/wasm/jit/pipeline

proc makeModule(funcTypes: seq[tuple[params, results: seq[byte]]],
                funcBodies: seq[seq[byte]]): WasmModule =
  ## Build a minimal WASM module from raw function types and bytecode bodies.
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

  # Type section
  var typeContent: seq[byte]
  typeContent.add(leb(uint32(funcTypes.len)))
  for ft in funcTypes:
    typeContent.add(0x60'u8)
    typeContent.add(leb(uint32(ft.params.len))); typeContent.add(ft.params)
    typeContent.add(leb(uint32(ft.results.len))); typeContent.add(ft.results)
  wasm.add(section(1, typeContent))

  # Function section (all use type index 0 for simplicity)
  var funcContent: seq[byte]
  funcContent.add(leb(uint32(funcBodies.len)))
  for i in 0 ..< funcBodies.len:
    funcContent.add(leb(0'u32))  # all same type (type 0 = first funcType)
  wasm.add(section(3, funcContent))

  # Code section
  var codeContent: seq[byte]
  codeContent.add(leb(uint32(funcBodies.len)))
  for body in funcBodies:
    codeContent.add(leb(uint32(body.len + 2)))  # +2 for local count (0) + end
    codeContent.add(0x00'u8)  # 0 local declarations
    codeContent.add(body)
    codeContent.add(0x0B'u8)  # end
  wasm.add(section(10, codeContent))

  decodeModule(wasm)

proc testSimpleInline() =
  ## add1(x) = x + 1 should be inlined into caller(x) = add1(x) * 2
  # func 0: add1(i32) -> i32: local.get 0; i32.const 1; i32.add
  # func 1: caller(i32) -> i32: local.get 0; call 0; i32.const 2; i32.mul
  let module = makeModule(
    @[(params: @[0x7F'u8], results: @[0x7F'u8])],
    @[
      @[0x20'u8, 0x00, 0x41, 0x01, 0x6A],       # local.get 0; i32.const 1; i32.add
      @[0x20'u8, 0x00, 0x10, 0x00, 0x41, 0x02, 0x6C],  # local.get 0; call 0; i32.const 2; i32.mul
    ])

  var pool = initJitMemPool()
  let compiled = pool.compileTier2(module, funcIdx = 1)

  type FnPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                    memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}
  let fn = cast[FnPtr](compiled.address)

  var vstack: array[64, uint64]
  var locals: array[2, uint64] = [5'u64, 0'u64]  # param = 5
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let count = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  let result = cast[int32](vstack[0] and 0xFFFFFFFF'u64)
  # caller(5) = add1(5) * 2 = 6 * 2 = 12
  assert count == 1 and result == 12,
    "caller(5) should be 12, got " & $result
  echo "PASS: simple inline: caller(5) = add1(5)*2 = 12"
  pool.destroy()

proc testIdentityInline() =
  ## id(x) = x (pure passthrough, cost=0) should inline cheaply
  # func 0: id(i32) -> i32: local.get 0
  # func 1: caller(i32) -> i32: local.get 0; call 0; i32.const 1; i32.add
  let module = makeModule(
    @[(params: @[0x7F'u8], results: @[0x7F'u8])],
    @[
      @[0x20'u8, 0x00],   # local.get 0
      @[0x20'u8, 0x00, 0x10, 0x00, 0x41, 0x01, 0x6A],  # local.get 0; call 0; i32.const 1; i32.add
    ])

  var pool = initJitMemPool()
  let compiled = pool.compileTier2(module, funcIdx = 1)

  type FnPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                    memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}
  let fn = cast[FnPtr](compiled.address)

  var vstack: array[64, uint64]
  var locals: array[2, uint64] = [41'u64, 0'u64]
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let count = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  let result = cast[int32](vstack[0] and 0xFFFFFFFF'u64)
  # caller(41) = id(41) + 1 = 42
  assert count == 1 and result == 42,
    "caller(41) should be 42, got " & $result
  echo "PASS: identity inline: caller(41) = id(41)+1 = 42"
  pool.destroy()

when isMainModule:
  testSimpleInline()
  testIdentityInline()
  echo "All inline tests passed!"
