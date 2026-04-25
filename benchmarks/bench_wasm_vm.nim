## WebAssembly VM benchmarks
## Measures: instruction dispatch, function calls, memory access, numeric ops

import std/[times, os, strutils]
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

# ---- WASM builder helpers (same as test) ----

proc leb128U32(v: uint32): seq[byte] =
  var val = v
  while true:
    var b = byte(val and 0x7F)
    val = val shr 7
    if val != 0: b = b or 0x80
    result.add(b)
    if val == 0: break

proc leb128S32(v: int32): seq[byte] =
  var val = v
  var more = true
  while more:
    var b = byte(val and 0x7F)
    val = val shr 7
    if (val == 0 and (b and 0x40) == 0) or (val == -1 and (b and 0x40) != 0): more = false
    else: b = b or 0x80
    result.add(b)

proc vecU32(items: seq[uint32]): seq[byte] =
  result = leb128U32(uint32(items.len))
  for item in items: result.add(leb128U32(item))

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id)
  result.add(leb128U32(uint32(content.len)))
  result.add(content)

proc wasmHeader(): seq[byte] =
  @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

proc funcType(params: seq[byte], results: seq[byte]): seq[byte] =
  result.add(0x60)
  result.add(leb128U32(uint32(params.len)))
  result.add(params)
  result.add(leb128U32(uint32(results.len)))
  result.add(results)

proc typeSection(types: seq[seq[byte]]): seq[byte] =
  var content: seq[byte]
  content.add(leb128U32(uint32(types.len)))
  for t in types: content.add(t)
  result = section(1, content)

proc funcSection(typeIdxs: seq[uint32]): seq[byte] =
  result = section(3, vecU32(typeIdxs))

proc exportSection(exports: seq[tuple[name: string, kind: byte, idx: uint32]]): seq[byte] =
  var content: seq[byte]
  content.add(leb128U32(uint32(exports.len)))
  for exp in exports:
    content.add(leb128U32(uint32(exp.name.len)))
    for c in exp.name: content.add(byte(c))
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

proc memorySection(min: uint32): seq[byte] =
  var content: seq[byte]
  content.add(leb128U32(1))
  content.add(0x00)
  content.add(leb128U32(min))
  result = section(5, content)

proc funcBody(locals: seq[tuple[count: uint32, valType: byte]], code: seq[byte]): seq[byte] =
  var body: seq[byte]
  body.add(leb128U32(uint32(locals.len)))
  for l in locals:
    body.add(leb128U32(l.count))
    body.add(l.valType)
  body.add(code)
  body.add(0x0B)
  result = body

template bench(name: string, body: untyped) =
  block:
    let start = cpuTime()
    body
    let elapsed = cpuTime() - start
    echo "  " & name & ": " & formatFloat(elapsed*1000, ffDecimal, 2) & " ms"

# ---- Benchmark: Recursive Fibonacci ----

proc benchFib() =
  echo "--- Fibonacci (recursive) ---"

  # Use the real clang-compiled binary
  let wasmPath = currentSourcePath.parentDir.parentDir / "tests" / "wasm" / "testdata" / "fib.wasm"
  let data = readFile(wasmPath)
  let module = decodeModule(cast[seq[byte]](data))
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])

  bench "fib(30) [clang -O2]":
    let r = vm.invoke(modIdx, "fib", @[wasmI32(30)])
    assert r[0].i32 == 832040

  bench "fib(35) [clang -O2]":
    let r = vm.invoke(modIdx, "fib", @[wasmI32(35)])
    assert r[0].i32 == 9227465

  # Also test hand-written WASM fib for comparison
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

  let m2 = decodeModule(wasm)
  var vm2 = initWasmVM()
  let mod2 = vm2.instantiate(m2, @[])

  bench "fib(30) [hand-written]":
    let r = vm2.invoke(mod2, "fib", @[wasmI32(30)])
    assert r[0].i32 == 832040

  bench "fib(35) [hand-written]":
    let r = vm2.invoke(mod2, "fib", @[wasmI32(35)])
    assert r[0].i32 == 9227465

# ---- Benchmark: Tight Loop ----

proc benchLoop() =
  echo "--- Tight Loop (100M iterations) ---"

  # (func (result i32) (local i32 i32)
  #   i32.const 100_000_000 -> local 0 (counter)
  #   loop
  #     local.get 0
  #     local.get 1
  #     i32.add
  #     local.set 1
  #     local.get 0
  #     i32.const 1
  #     i32.sub
  #     local.tee 0
  #     br_if 0
  #   end
  #   local.get 1
  # )
  var wasm = wasmHeader()
  wasm.add(typeSection(@[funcType(@[], @[0x7F'u8])]))
  wasm.add(funcSection(@[0'u32]))
  wasm.add(exportSection(@[("loop_sum", 0x00'u8, 0'u32)]))
  wasm.add(codeSection(@[funcBody(@[(2'u32, 0x7F'u8)],
    @[0x41'u8] & leb128S32(100_000_000i32) & @[  # i32.const 100M
    0x21'u8, 0x00,          # local.set 0
    0x03, 0x40,              # loop []
      0x20, 0x00,            # local.get 0
      0x20, 0x01,            # local.get 1
      0x6A,                  # i32.add
      0x21, 0x01,            # local.set 1
      0x20, 0x00,            # local.get 0
      0x41, 0x01,            # i32.const 1
      0x6B,                  # i32.sub
      0x22, 0x00,            # local.tee 0
      0x0D, 0x00,            # br_if 0
    0x0B,                    # end loop
    0x20, 0x01,              # local.get 1
  ])]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  bench "100M loop iterations":
    let r = vm.invoke(modIdx, "loop_sum", @[])
    assert r[0].i32 == 987459712  # sum 1..100M mod 2^32

# ---- Benchmark: Memory Operations ----

proc benchMemory() =
  echo "--- Memory Operations ---"

  # Write 1M i32 values, then read them back
  var wasm = wasmHeader()
  wasm.add(typeSection(@[
    funcType(@[0x7F'u8], @[]),       # type 0: (i32) -> void (write N values)
    funcType(@[0x7F'u8], @[0x7F'u8]),# type 1: (i32) -> i32 (read sum of N values)
  ]))
  wasm.add(funcSection(@[0'u32, 1'u32]))
  wasm.add(memorySection(256))  # 256 pages = 16MB
  wasm.add(exportSection(@[
    ("write", 0x00'u8, 0'u32),
    ("readsum", 0x00'u8, 1'u32),
  ]))
  wasm.add(codeSection(@[
    # write: store i from 0..n at offset i*4
    funcBody(@[(1'u32, 0x7F'u8)],  # local 1 = i
      @[
      0x03'u8, 0x40,          # loop []
        0x20, 0x01,            # local.get 1 (i)
        0x41, 0x02,            # i32.const 2
        0x74,                  # i32.shl (i * 4)
        0x20, 0x01,            # local.get 1 (value = i)
        0x36, 0x02, 0x00,      # i32.store align=4 offset=0
        0x20, 0x01,            # local.get 1
        0x41, 0x01,            # i32.const 1
        0x6A,                  # i32.add
        0x22, 0x01,            # local.tee 1
        0x20, 0x00,            # local.get 0 (n)
        0x48,                  # i32.lt_s
        0x0D, 0x00,            # br_if 0
      0x0B,                    # end loop
    ]),
    # readsum: load and sum n values
    funcBody(@[(2'u32, 0x7F'u8)],  # local 1=sum, local 2=i
      @[
      0x03'u8, 0x40,          # loop []
        0x20, 0x02,            # local.get 2 (i)
        0x41, 0x02,            # i32.const 2
        0x74,                  # i32.shl (i * 4)
        0x28, 0x02, 0x00,      # i32.load align=4 offset=0
        0x20, 0x01,            # local.get 1 (sum)
        0x6A,                  # i32.add
        0x21, 0x01,            # local.set 1
        0x20, 0x02,            # local.get 2
        0x41, 0x01,            # i32.const 1
        0x6A,                  # i32.add
        0x22, 0x02,            # local.tee 2
        0x20, 0x00,            # local.get 0 (n)
        0x48,                  # i32.lt_s
        0x0D, 0x00,            # br_if 0
      0x0B,                    # end loop
      0x20, 0x01,              # local.get 1
    ]),
  ]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  let n = 1_000_000i32
  bench "write " & $n & " i32 values":
    discard vm.invoke(modIdx, "write", @[wasmI32(n)])

  bench "read+sum " & $n & " i32 values":
    let r = vm.invoke(modIdx, "readsum", @[wasmI32(n)])
    discard r  # result is sum 0..999999

# ---- Benchmark: Function Call Overhead ----

proc benchCalls() =
  echo "--- Function Call Overhead ---"

  # identity function called many times in a loop
  var wasm = wasmHeader()
  wasm.add(typeSection(@[
    funcType(@[0x7F'u8], @[0x7F'u8]),   # (i32) -> i32
    funcType(@[0x7F'u8], @[]),            # (i32) -> void
  ]))
  wasm.add(funcSection(@[0'u32, 1'u32]))
  wasm.add(exportSection(@[("callbench", 0x00'u8, 1'u32)]))
  wasm.add(codeSection(@[
    # identity: return param
    funcBody(@[], @[0x20'u8, 0x00]),
    # callbench: call identity n times in a loop
    funcBody(@[(1'u32, 0x7F'u8)],  # local 1 = i
      @[
      0x03'u8, 0x40,          # loop []
        0x20, 0x01,            # local.get 1
        0x10, 0x00,            # call identity
        0x1A,                  # drop
        0x20, 0x01,            # local.get 1
        0x41, 0x01,            # i32.const 1
        0x6A,                  # i32.add
        0x22, 0x01,            # local.tee 1
        0x20, 0x00,            # local.get 0
        0x48,                  # i32.lt_s
        0x0D, 0x00,            # br_if 0
      0x0B,                    # end loop
    ]),
  ]))

  let m = decodeModule(wasm)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])

  bench "10M function calls":
    discard vm.invoke(modIdx, "callbench", @[wasmI32(10_000_000)])

# ---- Benchmark: Module Decoding ----

proc benchDecode() =
  echo "--- Module Decoding ---"
  let wasmPath = currentSourcePath.parentDir.parentDir / "tests" / "wasm" / "testdata" / "fib.wasm"
  let data = cast[seq[byte]](readFile(wasmPath))

  bench "decode fib.wasm x 10000":
    for i in 0 ..< 10000:
      let m = decodeModule(data)
      doAssert m.exports.len > 0

# ---- Run all benchmarks ----

echo "WebAssembly VM Benchmarks"
echo "========================="
echo ""
benchDecode()
echo ""
benchFib()
echo ""
benchLoop()
echo ""
benchMemory()
echo ""
benchCalls()
echo ""
echo "Done."
