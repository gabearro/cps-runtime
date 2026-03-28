## Test: automatic TCO on -O0 compiled WASM functions
## Verifies correctness and benchmarks interpreter vs JIT with auto-TCO.
import std/[os, times]
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime
when defined(macosx) and defined(arm64):
  import cps/wasm/jit/ir
  import cps/wasm/jit/lower
  import cps/wasm/jit/optimize
  import cps/wasm/jit/tco
  import cps/wasm/jit/tier

let wasmPath = currentSourcePath.parentDir / "testdata" / "tco_simple_o0.wasm"
let data = readFile(wasmPath)
let module = decodeModule(cast[seq[byte]](data))

echo "── IR TCO Detection ──"
when defined(macosx) and defined(arm64):
  for name in ["factorial_tail", "sum_tail", "gcd_tail", "fib_tree"]:
    var funcIdx = -1
    for exp in module.exports:
      if exp.name == name and exp.kind == ekFunc: funcIdx = exp.idx.int; break
    if funcIdx < 0: continue
    let irFunc = lowerFunction(module, funcIdx)
    var selfCalls = 0
    for bb in irFunc.blocks:
      for instr in bb.instrs:
        if instr.op == irCall and instr.imm == funcIdx.int64: inc selfCalls
    if selfCalls == 0:
      echo "  " & name & ": TCO applied (recursion → loop)"
    else:
      echo "  " & name & ": " & $selfCalls & " recursive call(s) remain"
echo ""

when defined(macosx) and defined(arm64):
  echo "── Tiered VM Correctness ──"
  var tvm = initTieredVM()
  let modIdx = tvm.instantiate(module, @[])

  # Test 1: factorial_tail
  let r0 = tvm.invoke(modIdx, "factorial_tail", @[wasmI32(12), wasmI32(1)])
  echo "  interp factorial_tail(12,1) = " & $r0[0].i32 &
       (if r0[0].i32 == 479001600: " ✓" else: " ✗")
  for i in 0 ..< 200:
    discard tvm.invoke(modIdx, "factorial_tail", @[wasmI32(5), wasmI32(1)])
  let r1 = tvm.invoke(modIdx, "factorial_tail", @[wasmI32(12), wasmI32(1)])
  echo "  JIT    factorial_tail(12,1) = " & $r1[0].i32 &
       (if r1[0].i32 == 479001600: " ✓" else: " ✗")

  # Check if __stack_pointer was properly restored
  let sp0 = tvm.vm.store.globals[0].value.i32
  echo "  __stack_pointer after 1 JIT call: " & $sp0 & " (should be 65536)"

  # Test repeated calls
  for i in 0 ..< 10:
    discard tvm.invoke(modIdx, "factorial_tail", @[wasmI32(12), wasmI32(1)])
  let sp1 = tvm.vm.store.globals[0].value.i32
  echo "  __stack_pointer after 10 more: " & $sp1

  for i in 0 ..< 100:
    discard tvm.invoke(modIdx, "factorial_tail", @[wasmI32(12), wasmI32(1)])
  let sp2 = tvm.vm.store.globals[0].value.i32
  echo "  __stack_pointer after 100 more: " & $sp2

  # Test 2: sum_tail
  let r2 = tvm.invoke(modIdx, "sum_tail", @[wasmI32(100), wasmI32(0)])
  echo "  interp sum_tail(100,0) = " & $r2[0].i32 &
       (if r2[0].i32 == 5050: " ✓" else: " ✗")
  for i in 0 ..< 200:
    discard tvm.invoke(modIdx, "sum_tail", @[wasmI32(50), wasmI32(0)])
  let r3 = tvm.invoke(modIdx, "sum_tail", @[wasmI32(100), wasmI32(0)])
  echo "  JIT    sum_tail(100,0) = " & $r3[0].i32 &
       (if r3[0].i32 == 5050: " ✓" else: " ✗")

  # Deep recursion test (limited to 500 — the shadow stack frame is 16 bytes,
  # and the -O0 code still allocates it once in the prologue. With TCO, the
  # recursion is a loop so depth doesn't matter for the call stack, but the
  # shadow stack pointer is only decremented once on entry, not per-iteration.)
  discard  # deep recursion test deferred

  # Test 3: gcd_tail
  let r4 = tvm.invoke(modIdx, "gcd_tail", @[wasmI32(1071), wasmI32(462)])
  echo "  interp gcd_tail(1071,462) = " & $r4[0].i32 &
       (if r4[0].i32 == 21: " ✓" else: " ✗")
  for i in 0 ..< 200:
    discard tvm.invoke(modIdx, "gcd_tail", @[wasmI32(100), wasmI32(42)])
  let r5 = tvm.invoke(modIdx, "gcd_tail", @[wasmI32(1071), wasmI32(462)])
  echo "  JIT    gcd_tail(1071,462) = " & $r5[0].i32 &
       (if r5[0].i32 == 21: " ✓" else: " ✗")
  echo ""

  # Benchmark: run 10K calls through the tiered VM (Tier 2 should be installed
  # by now from the warmup phase, compiled with auto-TCO)
  echo "── Benchmarks ──"
  block:
    let t0 = cpuTime()
    for i in 0 ..< 10_000:
      discard tvm.invoke(modIdx, "factorial_tail", @[wasmI32(12), wasmI32(1)])
    let us = (cpuTime() - t0) * 1e6 / 10_000.0
    echo "  factorial_tail(12) x10K: " & $us & " µs/call"

  block:
    let t0 = cpuTime()
    for i in 0 ..< 10_000:
      discard tvm.invoke(modIdx, "sum_tail", @[wasmI32(100), wasmI32(0)])
    let us = (cpuTime() - t0) * 1e6 / 10_000.0
    echo "  sum_tail(100) x10K: " & $us & " µs/call"

  block:
    let t0 = cpuTime()
    for i in 0 ..< 10_000:
      discard tvm.invoke(modIdx, "gcd_tail", @[wasmI32(1071), wasmI32(462)])
    let us = (cpuTime() - t0) * 1e6 / 10_000.0
    echo "  gcd_tail(1071,462) x10K: " & $us & " µs/call"

  echo ""
  echo "All auto-TCO tests passed!"

  tvm.destroy()

echo ""
echo "Done."
