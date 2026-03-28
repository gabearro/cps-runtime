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

when isMainModule:
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

  echo "Compiling..."
  var pool = initJitMemPool()
  let compiled = pool.compileTier2(module, funcIdx = 0)
  let fn = cast[FnPtr](compiled.address)
  echo "Compiled OK"

  # Test sum(0, 0) = 0  (no loop iterations)
  echo "Testing sum(0, 0)..."
  var vstack0: array[64, uint64]
  var locals0: array[4, uint64] = [0'u64, 0'u64, 0'u64, 0'u64]
  let ret0 = fn(vstack0[0].addr, locals0[0].addr, nil, 0)
  let count0 = (cast[uint](ret0) - cast[uint](vstack0[0].addr)) div 8
  let result0 = cast[int32](vstack0[0] and 0xFFFFFFFF'u64)
  echo "sum(0,0): count=", count0, " result=", result0
  assert count0 == 1 and result0 == 0, "Expected 1 val = 0"
  echo "PASS: sum(0, 0) = 0"

  # Test sum(1, 0) = 1
  echo "Testing sum(1, 0)..."
  var vstack1: array[64, uint64]
  var locals1: array[4, uint64] = [1'u64, 0'u64, 0'u64, 0'u64]
  let ret1 = fn(vstack1[0].addr, locals1[0].addr, nil, 0)
  let count1 = (cast[uint](ret1) - cast[uint](vstack1[0].addr)) div 8
  let result1 = cast[int32](vstack1[0] and 0xFFFFFFFF'u64)
  echo "sum(1,0): count=", count1, " result=", result1
  assert count1 == 1 and result1 == 1, "Expected 1 val = 1"
  echo "PASS: sum(1, 0) = 1"

  # Test sum(2, 0) = 3
  echo "Testing sum(2, 0)..."
  var vstack2: array[64, uint64]
  var locals2: array[4, uint64] = [2'u64, 0'u64, 0'u64, 0'u64]
  let ret2 = fn(vstack2[0].addr, locals2[0].addr, nil, 0)
  let count2 = (cast[uint](ret2) - cast[uint](vstack2[0].addr)) div 8
  let result2 = cast[int32](vstack2[0] and 0xFFFFFFFF'u64)
  echo "sum(2,0): count=", count2, " result=", result2
  assert count2 == 1 and result2 == 3, "Expected 1 val = 3"
  echo "PASS: sum(2, 0) = 3"

  pool.destroy()
  echo "All minimal tests passed!"
