## Test: detect tail-call candidates in WASM binaries compiled without TCO
## Verifies that -O0 compiled recursive functions use opCall (not opReturnCall),
## then benchmarks them as a baseline for the automatic TCO pass.

import std/[times, os, strutils, sequtils]
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime
when defined(macosx) and defined(arm64):
  import cps/wasm/jit/ir
  import cps/wasm/jit/lower
  import cps/wasm/jit/optimize
  import cps/wasm/jit/cost
  import cps/wasm/jit/memory
  import cps/wasm/jit/pipeline
  import cps/wasm/jit/compiler

proc main() =
  let wasmPath = currentSourcePath.parentDir / "testdata" / "tco_simple_o0.wasm"
  if not fileExists(wasmPath):
    echo "SKIP: tco_simple_o0.wasm not found"
    return

  let data = readFile(wasmPath)
  let module = decodeModule(cast[seq[byte]](data))

  echo "Module: " & wasmPath
  echo "  types: " & $module.types.len & "  local_funcs: " & $module.codes.len
  echo "  exports: " & module.exports.mapIt(it.name).join(", ")
  echo ""

  # Count import functions
  var numImportFuncs = 0
  for imp in module.imports:
    if imp.kind == ikFunc: inc numImportFuncs

  # Scan each function for call/return_call patterns
  echo "── Bytecode Analysis ──"
  for exp in module.exports:
    if exp.kind != ekFunc: continue
    let funcIdx = exp.idx.int
    let codeIdx = funcIdx - numImportFuncs
    if codeIdx < 0 or codeIdx >= module.codes.len: continue

    let code = module.codes[codeIdx].code.code
    var callSelf = 0
    var returnCallSelf = 0
    var callOther = 0
    for i, instr in code:
      if instr.op == opCall and instr.imm1.int == funcIdx:
        inc callSelf
        # Check if next non-nop instruction is return or end
        var j = i + 1
        while j < code.len and code[j].op in {opNop, opEnd}:
          inc j
        let nextOp = if j < code.len: code[j].op else: opEnd
        if nextOp in {opReturn, opEnd}:
          echo "  " & exp.name & ": opCall self at pc=" & $i &
               " → " & $nextOp & " at pc=" & $j & "  *** TAIL CALL CANDIDATE ***"
        else:
          echo "  " & exp.name & ": opCall self at pc=" & $i &
               " → " & $nextOp & " at pc=" & $j & "  (not tail position)"
      elif instr.op == opCall:
        inc callOther
      elif instr.op == opReturnCall and instr.imm1.int == funcIdx:
        inc returnCallSelf
        echo "  " & exp.name & ": opReturnCall self at pc=" & $i &
             "  (already optimized)"
    if callSelf == 0 and returnCallSelf == 0 and callOther == 0:
      echo "  " & exp.name & ": no calls (leaf function)"
  echo ""

  # Instantiate and benchmark
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])

  echo "── Interpreter Benchmarks (no TCO) ──"

  # factorial_tail(20, 1) = 2432902008176640000... overflows i32. Use smaller.
  # factorial_tail(12, 1) = 479001600
  block:
    let r = vm.invoke(modIdx, "factorial_tail", @[wasmI32(12), wasmI32(1)])
    assert r[0].i32 == 479001600, "factorial_tail(12,1) = " & $r[0].i32
    echo "  factorial_tail(12,1) = " & $r[0].i32 & " ✓"

    # Benchmark: call it many times
    let t0 = cpuTime()
    for i in 0 ..< 100_000:
      discard vm.invoke(modIdx, "factorial_tail", @[wasmI32(12), wasmI32(1)])
    let elapsed = cpuTime() - t0
    echo "  factorial_tail x 100K: " & $(elapsed * 1000) & " ms (" &
         $(elapsed * 1e6 / 100_000) & " µs/call)"

  # sum_tail(100, 0) = 5050 (shallow recursion to avoid stack overflow without TCO)
  block:
    let r = vm.invoke(modIdx, "sum_tail", @[wasmI32(100), wasmI32(0)])
    assert r[0].i32 == 5050, "sum_tail(100,0) = " & $r[0].i32
    echo "  sum_tail(100,0) = " & $r[0].i32 & " ✓"

    let t0 = cpuTime()
    for i in 0 ..< 100_000:
      discard vm.invoke(modIdx, "sum_tail", @[wasmI32(100), wasmI32(0)])
    let elapsed = cpuTime() - t0
    echo "  sum_tail(100) x 100K: " & $(elapsed * 1000) & " ms (" &
         $(elapsed * 1e6 / 100_000) & " µs/call)"
    echo "  NOTE: limited to n=100 because -O0 recursion overflows stack at ~200"

  # gcd(1071, 462) = 21
  block:
    let r = vm.invoke(modIdx, "gcd_tail", @[wasmI32(1071), wasmI32(462)])
    assert r[0].i32 == 21, "gcd(1071,462) = " & $r[0].i32
    echo "  gcd(1071,462) = " & $r[0].i32 & " ✓"

    let t0 = cpuTime()
    for i in 0 ..< 1_000_000:
      discard vm.invoke(modIdx, "gcd_tail", @[wasmI32(1071), wasmI32(462)])
    let elapsed = cpuTime() - t0
    echo "  gcd x 1M: " & $(elapsed * 1000) & " ms (" &
         $(elapsed * 1e6 / 1_000_000) & " µs/call)"

  # fib_tree(30) = 832040 — this should NOT be TCO'd
  block:
    let r = vm.invoke(modIdx, "fib_tree", @[wasmI32(30)])
    assert r[0].i32 == 832040, "fib_tree(30) = " & $r[0].i32
    echo "  fib_tree(30) = " & $r[0].i32 & " ✓"

    let t0 = cpuTime()
    let r2 = vm.invoke(modIdx, "fib_tree", @[wasmI32(30)])
    let elapsed = cpuTime() - t0
    echo "  fib_tree(30): " & $(elapsed * 1000) & " ms"

  # IR analysis: check if optimizer reveals call→return patterns
  when defined(macosx) and defined(arm64):
    echo "── IR Analysis (after optimization) ──"
    for exp in module.exports:
      if exp.kind != ekFunc: continue
      let funcIdx2 = exp.idx.int
      let codeIdx2 = funcIdx2 - numImportFuncs
      if codeIdx2 < 0 or codeIdx2 >= module.codes.len: continue

      var irFunc = lowerFunction(module, funcIdx2)
      optimizeIr(irFunc)

      # Scan for irCall to self followed by irReturn in the same or next BB
      var tcoCandidate = false
      for bi, bb in irFunc.blocks:
        for ii, instr in bb.instrs:
          if instr.op == irCall and instr.imm == funcIdx2.int64:
            # Check: is the call result used only by irReturn?
            let callResult = instr.result
            if callResult < 0: continue
            # Search forward in this block for irReturn using callResult
            for jj in (ii + 1) ..< bb.instrs.len:
              if bb.instrs[jj].op == irReturn and
                 bb.instrs[jj].operands[0] == callResult:
                echo "  " & exp.name & ": BB" & $bi &
                     " irCall self → irReturn (same BB)  *** TCO CANDIDATE ***"
                tcoCandidate = true
                break
              elif bb.instrs[jj].op in {irStore32, irStore64, irCall, irCallIndirect}:
                break  # intervening side effect, not a simple tail call
            # Also check: call is last value-producing instr, next BB returns it
            if not tcoCandidate and ii == bb.instrs.len - 2:
              let lastInstr = bb.instrs[^1]
              if lastInstr.op == irBr:
                let targetBb = lastInstr.imm.int
                if targetBb < irFunc.blocks.len:
                  for ti in irFunc.blocks[targetBb].instrs:
                    if ti.op == irReturn and ti.operands[0] == callResult:
                      echo "  " & exp.name & ": BB" & $bi &
                           " irCall self → BB" & $targetBb &
                           " irReturn  *** TCO CANDIDATE ***"
                      tcoCandidate = true
                      break
      if not tcoCandidate:
        # Check if there were any self-calls at all
        var hasSelfCall = false
        for bb in irFunc.blocks:
          for instr in bb.instrs:
            if instr.op == irCall and instr.imm == funcIdx2.int64:
              hasSelfCall = true
        if hasSelfCall:
          echo "  " & exp.name & ": has self-call but NOT in tail position"
        else:
          echo "  " & exp.name & ": no self-calls"
    echo ""

  # ---- Tier 2 JIT benchmarks (auto-TCO applied during lowering) ----
  when defined(macosx) and defined(arm64):
    echo "── Tier 2 JIT Benchmarks (with auto-TCO) ──"

    type JitFuncPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                           memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

    var pool = initJitMemPool()

    # Get memory base for functions that use linear memory
    let memInst = vm.getMemory(modIdx)
    let memBase = if memInst.data.len > 0: memInst.data[0].addr else: nil
    let memSize = memInst.data.len.uint64

    # Helper: compile and benchmark a function
    proc benchTier2(name: string, funcIdx: int, args: seq[int32],
                    expectedResult: int32, iterations: int) =
      let jitCode = compileTier2(pool, module, funcIdx, selfModuleIdx = funcIdx)
      let fPtr = cast[JitFuncPtr](jitCode.address)
      let nLocals = jitCode.numLocals

      # Correctness check
      var locals = newSeq[uint64](nLocals)
      for i, a in args:
        locals[i] = cast[uint64](a.int64) and 0xFFFFFFFF'u64
      var vstack: array[64, uint64]
      discard fPtr(vstack[0].addr, locals[0].addr,
                   cast[ptr byte](memBase), memSize)
      let result0 = cast[int32](vstack[0])
      assert result0 == expectedResult,
        name & " JIT result: " & $result0 & " (expected " & $expectedResult & ")"

      # Benchmark
      let t0 = cpuTime()
      for i in 0 ..< iterations:
        for j, a in args:
          locals[j] = cast[uint64](a.int64) and 0xFFFFFFFF'u64
        for j in args.len ..< nLocals:
          locals[j] = 0
        discard fPtr(vstack[0].addr, locals[0].addr,
                     cast[ptr byte](memBase), memSize)
      let elapsed = cpuTime() - t0
      echo "  " & name & ": " & $(elapsed * 1000 / iterations.float) & " ms/call" &
           " (" & $(elapsed * 1e6 / iterations.float) & " µs/call)" &
           "  [" & $iterations & " calls]"

    try:
      benchTier2("factorial_tail(12,1)", 1, @[12'i32, 1], 479001600, 1_000_000)
    except CatchableError as e:
      echo "  factorial_tail JIT FAILED: " & e.msg

    # THE KEY TEST: sum_tail can now handle n=1,000,000 (was crashing at n>200)
    # With TCO, the recursion becomes a loop — no stack overflow.
    block:
      let jitCode = compileTier2(pool, module, 2, selfModuleIdx = 2)
      let fPtr = cast[JitFuncPtr](jitCode.address)
      let nLocals = jitCode.numLocals
      var locals = newSeq[uint64](nLocals)
      var vstack: array[64, uint64]

      # Test with n=100 first (same as interpreter baseline)
      locals[0] = 100; locals[1] = 0
      for i in 2 ..< nLocals: locals[i] = 0
      discard fPtr(vstack[0].addr, locals[0].addr,
                   cast[ptr byte](memBase), memSize)
      assert cast[int32](vstack[0]) == 5050,
        "sum_tail(100,0) JIT = " & $cast[int32](vstack[0])

      # Now the big test: n=1,000,000 (impossible without TCO!)
      locals[0] = 1_000_000'u64; locals[1] = 0
      for i in 2 ..< nLocals: locals[i] = 0
      discard fPtr(vstack[0].addr, locals[0].addr,
                   cast[ptr byte](memBase), memSize)
      let bigResult = cast[int32](vstack[0])
      # sum(1..1M) = 1000000*1000001/2 = 500000500000, but i32 wraps
      echo "  sum_tail(1000000,0) = " & $bigResult &
           "  ✓ (no stack overflow — TCO works!)"

      # Benchmark
      let t0 = cpuTime()
      for i in 0 ..< 1000:
        locals[0] = 100; locals[1] = 0
        for j in 2 ..< nLocals: locals[j] = 0
        discard fPtr(vstack[0].addr, locals[0].addr,
                     cast[ptr byte](memBase), memSize)
      let elapsed = cpuTime() - t0
      echo "  sum_tail(100) x 1K JIT: " & $(elapsed * 1e6 / 1000) & " µs/call"

    benchTier2("gcd_tail(1071,462)", 3, @[1071'i32, 462], 21, 1_000_000)

    pool.destroy()
    echo ""

  echo "Done."

when isMainModule:
  main()
