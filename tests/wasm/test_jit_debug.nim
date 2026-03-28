## Test: JIT debugging tools (disassembler, source maps, code cache, optimizer)

import std/strutils
import cps/wasm/types, cps/wasm/binary
import cps/wasm/jit/memory, cps/wasm/jit/codegen, cps/wasm/jit/compiler
import cps/wasm/jit/debug, cps/wasm/jit/cache, cps/wasm/jit/ir, cps/wasm/jit/optimize

proc testDisassembler() =
  ## Generate some code and disassemble it
  var pool = initJitMemPool(64 * 1024)
  var buf = initAsmBuffer()
  buf.addImm(x0, x0, 1)
  buf.subImm(x1, x1, 2)
  buf.movReg(x2, x0)
  buf.ret()

  let code = pool.writeCode(buf.code)
  let disasm = disasmAarch64(code)
  assert disasm.len == 4
  assert "add" in disasm[0].mnemonic
  assert "sub" in disasm[1].mnemonic
  assert "mov" in disasm[2].mnemonic
  assert "ret" in disasm[3].mnemonic
  echo "PASS: disassembler (" & $disasm.len & " instructions)"
  pool.destroy()

proc testSourceMap() =
  var sm = initSourceMap()
  sm.addEntry(0, 0, 1)     # native 0 → WASM pc 0, func 1
  sm.addEntry(16, 3, 1)    # native 16 → WASM pc 3
  sm.addEntry(32, 7, 1)    # native 32 → WASM pc 7

  let e1 = sm.lookup(0)
  assert e1.wasmPc == 0
  let e2 = sm.lookup(20)
  assert e2.wasmPc == 3  # closest entry <= 20
  let e3 = sm.lookup(100)
  assert e3.wasmPc == 7
  echo "PASS: source map lookup"

proc testCodeCache() =
  var pool = initJitMemPool(64 * 1024)
  var cc = initCodeCache(pool.addr, maxEntries = 3)

  # Add entries
  cc.put(0, CacheEntry(funcIdx: 0, tier: 1, codeSize: 100, compileTimeMs: 0.5))
  cc.put(1, CacheEntry(funcIdx: 1, tier: 1, codeSize: 200, compileTimeMs: 0.3))
  cc.put(2, CacheEntry(funcIdx: 2, tier: 2, codeSize: 80, compileTimeMs: 1.2))

  assert cc.contains(0)
  assert cc.contains(1)
  assert cc.contains(2)

  # Cache hit
  let e = cc.get(1)
  assert e != nil
  assert e[].funcIdx == 1

  # Eviction on overflow
  cc.put(3, CacheEntry(funcIdx: 3, tier: 1, codeSize: 50, compileTimeMs: 0.1))
  assert cc.contains(3)
  # One entry should have been evicted

  let stats = cc.getStats()
  assert stats.totalCompilations == 4
  assert stats.tier1Compilations == 3
  assert stats.tier2Compilations == 1
  assert stats.evictions == 1
  echo "PASS: code cache (4 compilations, 1 eviction)"
  pool.destroy()

proc testOptimizer() =
  # Create a simple IR function with constant folding opportunity
  var f = IrFunc(numValues: 5, numLocals: 0, numParams: 0, numResults: 1)
  f.blocks = @[BasicBlock(id: 0)]

  # v0 = const 3
  f.blocks[0].instrs.add(IrInstr(op: irConst32, result: 0.IrValue, imm: 3))
  # v1 = const 4
  f.blocks[0].instrs.add(IrInstr(op: irConst32, result: 1.IrValue, imm: 4))
  # v2 = v0 + v1 (should fold to const 7)
  f.blocks[0].instrs.add(IrInstr(op: irAdd32, result: 2.IrValue,
    operands: [0.IrValue, 1.IrValue, -1.IrValue]))
  # v3 = v2 (unused — should be eliminated if v2 is folded)
  f.blocks[0].instrs.add(IrInstr(op: irConst32, result: 3.IrValue, imm: 99))
  # return v2
  f.blocks[0].instrs.add(IrInstr(op: irReturn, result: -1.IrValue,
    operands: [2.IrValue, -1.IrValue, -1.IrValue]))

  let instrsBefore = f.blocks[0].instrs.len
  optimizeIr(f)
  let instrsAfter = f.blocks[0].instrs.len

  # v0 and v1 should be eliminated (folded into v2)
  # v3 should be eliminated (dead code)
  assert instrsAfter < instrsBefore, "Optimizer should reduce instruction count"

  # v2 should now be a constant 7
  var foundConst7 = false
  for instr in f.blocks[0].instrs:
    if instr.op == irConst32 and instr.imm == 7:
      foundConst7 = true
  assert foundConst7, "Constant folding should produce const 7"
  echo "PASS: optimizer (constant fold + DCE: " & $instrsBefore & " → " & $instrsAfter & " instrs)"

testDisassembler()
testSourceMap()
testCodeCache()
testOptimizer()
echo ""
echo "All debug/tools tests passed!"
