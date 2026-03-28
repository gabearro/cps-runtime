## WebAssembly VM comprehensive test suite
## Tests: binary decoding, instantiation, execution of all instruction categories

import std/[math, strformat]
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

# ---- WASM binary builder helpers ----
# These construct valid .wasm byte sequences for testing

proc leb128U32(v: uint32): seq[byte] =
  var val = v
  while true:
    var b = byte(val and 0x7F)
    val = val shr 7
    if val != 0:
      b = b or 0x80
    result.add(b)
    if val == 0:
      break

proc leb128S32(v: int32): seq[byte] =
  var val = v
  var more = true
  while more:
    var b = byte(val and 0x7F)
    val = val shr 7
    if (val == 0 and (b and 0x40) == 0) or (val == -1 and (b and 0x40) != 0):
      more = false
    else:
      b = b or 0x80
    result.add(b)

proc leb128S64(v: int64): seq[byte] =
  var val = v
  var more = true
  while more:
    var b = byte(val and 0x7F)
    val = val shr 7
    if (val == 0 and (b and 0x40) == 0) or (val == -1 and (b and 0x40) != 0):
      more = false
    else:
      b = b or 0x80
    result.add(b)

proc vecU32(items: seq[uint32]): seq[byte] =
  result = leb128U32(uint32(items.len))
  for item in items:
    result.add(leb128U32(item))

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id)
  result.add(leb128U32(uint32(content.len)))
  result.add(content)

proc wasmHeader(): seq[byte] =
  @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

proc funcType(params: seq[byte], results: seq[byte]): seq[byte] =
  result.add(0x60)  # func type tag
  result.add(leb128U32(uint32(params.len)))
  result.add(params)
  result.add(leb128U32(uint32(results.len)))
  result.add(results)

proc typeSection(types: seq[seq[byte]]): seq[byte] =
  var content: seq[byte]
  content.add(leb128U32(uint32(types.len)))
  for t in types:
    content.add(t)
  result = section(1, content)

proc funcSection(typeIdxs: seq[uint32]): seq[byte] =
  result = section(3, vecU32(typeIdxs))

proc exportSection(exports: seq[tuple[name: string, kind: byte, idx: uint32]]): seq[byte] =
  var content: seq[byte]
  content.add(leb128U32(uint32(exports.len)))
  for exp in exports:
    content.add(leb128U32(uint32(exp.name.len)))
    for c in exp.name:
      content.add(byte(c))
    content.add(exp.kind)
    content.add(leb128U32(exp.idx))
  result = section(7, content)

proc codeSection(bodies: seq[seq[byte]]): seq[byte] =
  var content: seq[byte]
  content.add(leb128U32(uint32(bodies.len)))
  for body in bodies:
    content.add(leb128U32(uint32(body.len)))
    content.add(body)
  result = section(10, content)

proc memorySection(min: uint32, hasMax: bool = false, max: uint32 = 0): seq[byte] =
  var content: seq[byte]
  content.add(leb128U32(1))  # 1 memory
  if hasMax:
    content.add(0x01)
    content.add(leb128U32(min))
    content.add(leb128U32(max))
  else:
    content.add(0x00)
    content.add(leb128U32(min))
  result = section(5, content)

proc globalSection(globals: seq[tuple[valType: byte, mut: byte, init: seq[byte]]]): seq[byte] =
  var content: seq[byte]
  content.add(leb128U32(uint32(globals.len)))
  for g in globals:
    content.add(g.valType)  # valtype
    content.add(g.mut)      # mutability
    content.add(g.init)     # init expr
  result = section(6, content)

proc funcBody(locals: seq[tuple[count: uint32, valType: byte]], code: seq[byte]): seq[byte] =
  var body: seq[byte]
  body.add(leb128U32(uint32(locals.len)))
  for l in locals:
    body.add(leb128U32(l.count))
    body.add(l.valType)
  body.add(code)
  body.add(0x0B)  # end
  result = body

# ---- Tests ----

proc testMinimalModule() =
  # Minimal valid module: just header
  let data = wasmHeader()
  let m = decodeModule(data)
  assert m.types.len == 0
  assert m.imports.len == 0
  assert m.exports.len == 0
  echo "PASS: testMinimalModule"

proc testI32Arithmetic() =
  # Function: (i32, i32) -> i32 = a + b
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("add", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0
    0x20, 0x01,      # local.get 1
    0x6A,            # i32.add
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let result = vm.invoke(modIdx, "add", @[wasmI32(10), wasmI32(32)])
  assert result.len == 1
  assert result[0].kind == wvkI32
  assert result[0].i32 == 42
  echo "PASS: testI32Arithmetic (add)"

proc testI32SubMulDivRem() =
  # Function: (i32, i32) -> i32 = (a * b) - (a / b) + (a % b)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("calc", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0
    0x20, 0x01,      # local.get 1
    0x6C,            # i32.mul
    0x20, 0x00,      # local.get 0
    0x20, 0x01,      # local.get 1
    0x6D,            # i32.div_s
    0x6B,            # i32.sub
    0x20, 0x00,      # local.get 0
    0x20, 0x01,      # local.get 1
    0x6F,            # i32.rem_s
    0x6A,            # i32.add
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  # 10 * 3 = 30, 10 / 3 = 3, 10 % 3 = 1 => 30 - 3 + 1 = 28
  let result = vm.invoke(modIdx, "calc", @[wasmI32(10), wasmI32(3)])
  assert result[0].i32 == 28
  echo "PASS: testI32SubMulDivRem"

proc testI64Arithmetic() =
  # Function: (i64, i64) -> i64 = a + b
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7E'u8, 0x7E], @[0x7E'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("add64", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,  # local.get 0
    0x20, 0x01,      # local.get 1
    0x7C,            # i64.add
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let result = vm.invoke(modIdx, "add64", @[wasmI64(100_000_000_000i64), wasmI64(200_000_000_000i64)])
  assert result[0].i64 == 300_000_000_000i64
  echo "PASS: testI64Arithmetic"

proc testF32Arithmetic() =
  # Function: (f32, f32) -> f32 = a + b
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7D'u8, 0x7D], @[0x7D'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("addf32", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0x92,            # f32.add
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let result = vm.invoke(modIdx, "addf32", @[wasmF32(1.5f), wasmF32(2.25f)])
  assert abs(result[0].f32 - 3.75f) < 1e-6
  echo "PASS: testF32Arithmetic"

proc testF64Arithmetic() =
  # Function: (f64, f64) -> f64 = a * b
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7C'u8, 0x7C], @[0x7C'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("mulf64", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0xA2,            # f64.mul
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let result = vm.invoke(modIdx, "mulf64", @[wasmF64(3.14), wasmF64(2.0)])
  assert abs(result[0].f64 - 6.28) < 1e-10
  echo "PASS: testF64Arithmetic"

proc testIfElse() =
  # Function: (i32) -> i32 = if param > 0 then 1 else -1
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

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  let pos = vm.invoke(modIdx, "sign", @[wasmI32(42)])
  assert pos[0].i32 == 1

  let neg = vm.invoke(modIdx, "sign", @[wasmI32(-5)])
  assert neg[0].i32 == -1
  echo "PASS: testIfElse"

proc testBlockAndBr() =
  # Function: () -> i32
  # block [i32]
  #   i32.const 42
  #   br 0
  #   i32.const 99  (unreachable)
  # end
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("blockbr", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x02'u8, 0x7F,        # block [i32]
      0x41, 0x2A,          # i32.const 42
      0x0C, 0x00,          # br 0
      0x41, 0x63,          # i32.const 99 (unreachable)
    0x0B,                  # end
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let result = vm.invoke(modIdx, "blockbr", @[])
  assert result[0].i32 == 42
  echo "PASS: testBlockAndBr"

proc testLoop() =
  # Function: (i32) -> i32 = sum 1..n
  # local i32 (sum)
  # local.get 0 => n
  # loop
  #   local.get 0      ; n (counts down)
  #   local.get 1      ; sum
  #   i32.add
  #   local.set 1      ; sum += n
  #   local.get 0
  #   i32.const 1
  #   i32.sub
  #   local.tee 0      ; n -= 1
  #   br_if 0          ; loop while n > 0
  # end
  # local.get 1         ; return sum
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

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let result = vm.invoke(modIdx, "sum", @[wasmI32(100)])
  assert result[0].i32 == 5050  # 1+2+...+100
  echo "PASS: testLoop (sum 1..100)"

proc testFunctionCall() =
  # Two functions: double(x) = x*2, quadruple(x) = double(double(x))
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32, 0'u32]))
  wasm.add(exportSection(@[("quadruple", 0x00'u8, 1'u32)]))
  wasm.add(codeSection(@[
    # func 0: double
    funcBody(@[], @[
      0x20'u8, 0x00,    # local.get 0
      0x20, 0x00,        # local.get 0
      0x6A,              # i32.add
    ]),
    # func 1: quadruple = double(double(x))
    funcBody(@[], @[
      0x20'u8, 0x00,    # local.get 0
      0x10, 0x00,        # call 0 (double)
      0x10, 0x00,        # call 0 (double)
    ]),
  ]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let result = vm.invoke(modIdx, "quadruple", @[wasmI32(5)])
  assert result[0].i32 == 20
  echo "PASS: testFunctionCall"

proc testRecursiveFibonacci() =
  # fib(n) = if n <= 1 then n else fib(n-1) + fib(n-2)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("fib", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,        # local.get 0 (n)
    0x41, 0x02,            # i32.const 2
    0x48,                  # i32.lt_s
    0x04, 0x7F,            # if [i32]
      0x20, 0x00,          # local.get 0 (return n)
    0x05,                  # else
      0x20, 0x00,          # local.get 0
      0x41, 0x01,          # i32.const 1
      0x6B,                # i32.sub
      0x10, 0x00,          # call 0 (fib(n-1))
      0x20, 0x00,          # local.get 0
      0x41, 0x02,          # i32.const 2
      0x6B,                # i32.sub
      0x10, 0x00,          # call 0 (fib(n-2))
      0x6A,                # i32.add
    0x0B,                  # end if
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  assert vm.invoke(modIdx, "fib", @[wasmI32(0)])[0].i32 == 0
  assert vm.invoke(modIdx, "fib", @[wasmI32(1)])[0].i32 == 1
  assert vm.invoke(modIdx, "fib", @[wasmI32(10)])[0].i32 == 55
  assert vm.invoke(modIdx, "fib", @[wasmI32(20)])[0].i32 == 6765
  echo "PASS: testRecursiveFibonacci"

proc testMemoryLoadStore() =
  # Function: store i32 at offset 0, load it back
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(memorySection(1))  # 1 page
  wasm.add(exportSection(@[("memtest", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x41'u8, 0x00,        # i32.const 0 (address)
    0x20, 0x00,            # local.get 0 (value)
    0x36, 0x02, 0x00,      # i32.store align=4 offset=0
    0x41, 0x00,            # i32.const 0 (address)
    0x28, 0x02, 0x00,      # i32.load align=4 offset=0
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let result = vm.invoke(modIdx, "memtest", @[wasmI32(12345)])
  assert result[0].i32 == 12345
  echo "PASS: testMemoryLoadStore"

proc testMemoryGrow() =
  # memory.grow returns old page count, or -1 on failure
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(memorySection(1, true, 10))  # 1 page min, 10 max
  wasm.add(exportSection(@[("growtest", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,        # local.get 0 (pages to grow)
    0x40, 0x00,            # memory.grow 0
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  # Grow by 2 pages from initial 1 → should return 1 (old size)
  let r1 = vm.invoke(modIdx, "growtest", @[wasmI32(2)])
  assert r1[0].i32 == 1

  # Now at 3 pages, grow by 3 → should return 3
  let r2 = vm.invoke(modIdx, "growtest", @[wasmI32(3)])
  assert r2[0].i32 == 3

  # Now at 6 pages, grow by 5 → exceeds max(10), should return -1
  let r3 = vm.invoke(modIdx, "growtest", @[wasmI32(5)])
  assert r3[0].i32 == -1
  echo "PASS: testMemoryGrow"

proc testHostFunction() =
  # Import a host function: env.log(i32) -> ()
  # Then call it from WASM
  var logged: seq[int32]

  var wasm = wasmHeader()
  # Type section: type 0 = (i32) -> (), type 1 = (i32) -> i32
  wasm.add(typeSection(@[
    funcType(@[0x7F'u8], @[]),
    funcType(@[0x7F'u8], @[0x7F'u8]),
  ]))

  # Import section: env.log is func type 0
  var importContent: seq[byte]
  importContent.add(leb128U32(1))  # 1 import
  # module name "env"
  importContent.add(leb128U32(3))
  importContent.add(@[byte('e'), byte('n'), byte('v')])
  # name "log"
  importContent.add(leb128U32(3))
  importContent.add(@[byte('l'), byte('o'), byte('g')])
  importContent.add(0x00)  # func
  importContent.add(leb128U32(0))  # type index 0
  wasm.add(section(2, importContent))

  wasm.add(funcSection(@[1'u32]))  # function 1 (idx 0 is imported) uses type 1
  wasm.add(exportSection(@[("test", 0x00'u8, 1'u32)]))  # export func idx 1

  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,        # local.get 0
    0x10, 0x00,            # call 0 (env.log)
    0x20, 0x00,            # local.get 0
    0x41, 0x01,            # i32.const 1
    0x6A,                  # i32.add
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()

  let logFunc: HostFunc = proc(args: openArray[WasmValue]): seq[WasmValue] =
    logged.add(args[0].i32)
    @[]

  let imports = @[("env", "log", ExternalVal(kind: ekFunc,
    funcType: FuncType(params: @[vtI32], results: @[]),
    hostFunc: logFunc))]
  let modIdx = vm.instantiate(m, imports)
  let result = vm.invoke(modIdx, "test", @[wasmI32(42)])
  assert result[0].i32 == 43
  assert logged == @[42'i32]
  echo "PASS: testHostFunction"

proc testSelect() =
  # select: (a, b, cond) => cond != 0 ? a : b
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("sel", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,        # local.get 0 (a)
    0x20, 0x01,            # local.get 1 (b)
    0x20, 0x02,            # local.get 2 (cond)
    0x1B,                  # select
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let r1 = vm.invoke(modIdx, "sel", @[wasmI32(10), wasmI32(20), wasmI32(1)])
  assert r1[0].i32 == 10
  let r2 = vm.invoke(modIdx, "sel", @[wasmI32(10), wasmI32(20), wasmI32(0)])
  assert r2[0].i32 == 20
  echo "PASS: testSelect"

proc testGlobals() =
  # Global: mutable i32 initialized to 100
  # Function: increment global and return old value
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(globalSection(@[(0x7F'u8, 0x01'u8, @[0x41'u8] & leb128S32(100) & @[0x0B'u8])]))  # i32, mutable, init=100
  wasm.add(exportSection(@[("inc", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x23'u8, 0x00,        # global.get 0
    0x23, 0x00,            # global.get 0
    0x41, 0x01,            # i32.const 1
    0x6A,                  # i32.add
    0x24, 0x00,            # global.set 0
    # old value is still on stack
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  assert vm.invoke(modIdx, "inc", @[])[0].i32 == 100
  assert vm.invoke(modIdx, "inc", @[])[0].i32 == 101
  assert vm.invoke(modIdx, "inc", @[])[0].i32 == 102
  echo "PASS: testGlobals"

proc testI32Constants() =
  # Test i32.const with various values including negative
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("neg", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x41'u8] & leb128S32(-42) & @[  # i32.const -42
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  assert vm.invoke(modIdx, "neg", @[])[0].i32 == -42
  echo "PASS: testI32Constants"

proc testBrTable() =
  # br_table: switch on input, returns value via block result
  # Use a block [i32] as the outer wrapper so branches carry the result value
  #
  # (func (param i32) (result i32)
  #   block $outer [i32]     ;; label 0 from inside = exit with i32
  #     block $c1 []         ;; label 0 from c0
  #       block $c0 []       ;; label 0 from dispatch
  #         local.get 0
  #         br_table 0 1 2   ;; 0->c0 fallthru, 1->c1 fallthru, 2->outer(default)
  #       end                ;; c0 fallthrough
  #       i32.const 10
  #       br 1               ;; -> outer with 10
  #     end                  ;; c1 fallthrough
  #     i32.const 20
  #     br 0                 ;; -> outer with 20
  #   end
  # )
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("switch", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x02'u8, 0x7F,        # block [i32] (outer)
      0x02, 0x40,          # block [] (c1)
        0x02, 0x40,        # block [] (c0)
          0x20, 0x00,      # local.get 0
          0x0E,            # br_table
            0x02,          # vec count = 2
            0x00,          # label[0] -> c0 end
            0x01,          # label[1] -> c1 end
            0x02,          # default  -> outer (need i32 on stack)
        0x0B,              # end c0
        0x41, 0x0A,        # i32.const 10
        0x0C, 0x01,        # br 1 (outer with 10)
      0x0B,                # end c1
      0x41, 0x14,          # i32.const 20
      0x0C, 0x00,          # br 0 (outer with 20)
    0x0B,                  # end outer
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let r0 = vm.invoke(modIdx, "switch", @[wasmI32(0)])
  assert r0[0].i32 == 10, &"expected 10 got {r0[0].i32}"
  let r1 = vm.invoke(modIdx, "switch", @[wasmI32(1)])
  assert r1[0].i32 == 20, &"expected 20 got {r1[0].i32}"
  echo "PASS: testBrTable"

proc testDivByZeroTraps() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("divs", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x00,
    0x20, 0x01,
    0x6D,            # i32.div_s
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  # Division by zero should trap
  var trapped = false
  try:
    discard vm.invoke(modIdx, "divs", @[wasmI32(10), wasmI32(0)])
  except WasmTrap:
    trapped = true
  assert trapped, "Expected trap on division by zero"

  # INT32_MIN / -1 should trap (overflow)
  trapped = false
  try:
    discard vm.invoke(modIdx, "divs", @[wasmI32(int32.low), wasmI32(-1)])
  except WasmTrap:
    trapped = true
  assert trapped, "Expected trap on i32 signed division overflow"
  echo "PASS: testDivByZeroTraps"

proc testI32Bitwise() =
  # Test clz, ctz, popcnt
  var wasm = wasmHeader()
  # Three functions: clz(x), ctz(x), popcnt(x)
  wasm.add(typeSection(@[funcType(@[0x7F'u8], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32, 0'u32, 0'u32]))
  wasm.add(exportSection(@[
    ("clz", 0x00'u8, 0'u32),
    ("ctz", 0x00'u8, 1'u32),
    ("popcnt", 0x00'u8, 2'u32),
  ]))
  wasm.add(codeSection(@[
    funcBody(@[], @[0x20'u8, 0x00, 0x67]),  # local.get 0, i32.clz
    funcBody(@[], @[0x20'u8, 0x00, 0x68]),  # local.get 0, i32.ctz
    funcBody(@[], @[0x20'u8, 0x00, 0x69]),  # local.get 0, i32.popcnt
  ]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  assert vm.invoke(modIdx, "clz", @[wasmI32(0)])[0].i32 == 32
  assert vm.invoke(modIdx, "clz", @[wasmI32(1)])[0].i32 == 31
  assert vm.invoke(modIdx, "clz", @[wasmI32(0x80000000'i32)])[0].i32 == 0

  assert vm.invoke(modIdx, "ctz", @[wasmI32(0)])[0].i32 == 32
  assert vm.invoke(modIdx, "ctz", @[wasmI32(1)])[0].i32 == 0
  assert vm.invoke(modIdx, "ctz", @[wasmI32(0x80000000'i32)])[0].i32 == 31

  assert vm.invoke(modIdx, "popcnt", @[wasmI32(0)])[0].i32 == 0
  assert vm.invoke(modIdx, "popcnt", @[wasmI32(-1)])[0].i32 == 32
  assert vm.invoke(modIdx, "popcnt", @[wasmI32(0x55555555)])[0].i32 == 16
  echo "PASS: testI32Bitwise"

proc testMemorySubWordLoadStore() =
  # Test i32.store8 / i32.load8_u / i32.load8_s
  var wasm = wasmHeader()
  wasm.add(typeSection(@[
    funcType(@[0x7F'u8], @[0x7F'u8]),  # type 0: (i32) -> i32
  ]))
  wasm.add(funcSection(@[0'u32, 0'u32]))
  wasm.add(memorySection(1))
  wasm.add(exportSection(@[
    ("store8_load8u", 0x00'u8, 0'u32),
    ("store8_load8s", 0x00'u8, 1'u32),
  ]))
  wasm.add(codeSection(@[
    # store8 then load8_u
    funcBody(@[], @[
      0x41'u8, 0x00,        # i32.const 0
      0x20, 0x00,            # local.get 0
      0x3A, 0x00, 0x00,      # i32.store8 align=0 offset=0
      0x41, 0x00,            # i32.const 0
      0x2D, 0x00, 0x00,      # i32.load8_u align=0 offset=0
    ]),
    # store8 then load8_s
    funcBody(@[], @[
      0x41'u8, 0x00,
      0x20, 0x00,
      0x3A, 0x00, 0x00,
      0x41, 0x00,
      0x2C, 0x00, 0x00,      # i32.load8_s
    ]),
  ]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  # Store 0xFF (255), load unsigned = 255, load signed = -1
  assert vm.invoke(modIdx, "store8_load8u", @[wasmI32(0xFF)])[0].i32 == 255
  assert vm.invoke(modIdx, "store8_load8s", @[wasmI32(0xFF)])[0].i32 == -1

  # Store 0x7F (127), both should be 127
  assert vm.invoke(modIdx, "store8_load8u", @[wasmI32(0x7F)])[0].i32 == 127
  assert vm.invoke(modIdx, "store8_load8s", @[wasmI32(0x7F)])[0].i32 == 127
  echo "PASS: testMemorySubWordLoadStore"

proc testConversions() =
  # Test i32.wrap_i64, i64.extend_i32_s, i64.extend_i32_u
  var wasm = wasmHeader()
  wasm.add(typeSection(@[
    funcType(@[0x7E'u8], @[0x7F'u8]),  # (i64) -> i32  (wrap)
    funcType(@[0x7F'u8], @[0x7E'u8]),  # (i32) -> i64  (extend)
  ]))
  wasm.add(funcSection(@[0'u32, 1'u32, 1'u32]))
  wasm.add(exportSection(@[
    ("wrap", 0x00'u8, 0'u32),
    ("extend_s", 0x00'u8, 1'u32),
    ("extend_u", 0x00'u8, 2'u32),
  ]))
  wasm.add(codeSection(@[
    funcBody(@[], @[0x20'u8, 0x00, 0xA7]),    # wrap_i64
    funcBody(@[], @[0x20'u8, 0x00, 0xAC]),    # extend_i32_s
    funcBody(@[], @[0x20'u8, 0x00, 0xAD]),    # extend_i32_u
  ]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  assert vm.invoke(modIdx, "wrap", @[wasmI64(0x1_0000_0042i64)])[0].i32 == 0x42
  assert vm.invoke(modIdx, "extend_s", @[wasmI32(-1)])[0].i64 == -1i64
  assert vm.invoke(modIdx, "extend_u", @[wasmI32(-1)])[0].i64 == 0xFFFFFFFF'i64
  echo "PASS: testConversions"

proc testNopAndDrop() =
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("test", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[],
    @[0x01'u8] &             # nop
    @[0x41'u8] & leb128S32(99) &  # i32.const 99
    @[0x41'u8] & leb128S32(42) &  # i32.const 42
    @[0x1A'u8] &             # drop (drops 42)
    @[0x01'u8]               # nop
  )]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  assert vm.invoke(modIdx, "test", @[])[0].i32 == 99
  echo "PASS: testNopAndDrop"

proc testMultipleReturns() =
  # Multi-value return: (i32, i32) -> (i32, i32)
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[0x7F'u8, 0x7F], @[0x7F'u8, 0x7F])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("swap", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[], @[
    0x20'u8, 0x01,        # local.get 1
    0x20, 0x00,            # local.get 0
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  let result = vm.invoke(modIdx, "swap", @[wasmI32(1), wasmI32(2)])
  assert result.len == 2
  assert result[0].i32 == 2
  assert result[1].i32 == 1
  echo "PASS: testMultipleReturns"

# ---- Run all tests ----

testMinimalModule()
testI32Arithmetic()
testI32SubMulDivRem()
testI64Arithmetic()
testF32Arithmetic()
testF64Arithmetic()
testIfElse()
testBlockAndBr()
testLoop()
testFunctionCall()
testRecursiveFibonacci()
testMemoryLoadStore()
testMemoryGrow()
testHostFunction()
testSelect()
testGlobals()
testI32Constants()
testBrTable()
testDivByZeroTraps()
testI32Bitwise()
testMemorySubWordLoadStore()
testConversions()
testNopAndDrop()
testMultipleReturns()

echo ""
echo "All WASM VM tests passed!"
