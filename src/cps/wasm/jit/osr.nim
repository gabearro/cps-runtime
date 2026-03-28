## On-Stack Replacement (OSR) for hot loop promotion
## When the interpreter detects a hot loop (many iterations), it can
## transfer execution to JIT-compiled code at the loop header.

import std/tables
import ../types
import memory, compiler

const OsrLoopThreshold* = 1000  # iterations before triggering OSR

type
  OsrState* = object
    ## Captured interpreter state for transfer to JIT
    locals*: seq[uint64]     # WASM local variable values
    stackValues*: seq[uint64] # values on the WASM value stack
    pc*: int                  # program counter (loop header position)
    funcIdx*: int             # function being executed

  OsrEntry* = object
    ## JIT entry point for a loop header
    code*: JitCode
    loopPc*: int             # WASM PC of the loop header

  OsrCompileCache* = object
    ## Cache of compiled OSR entries keyed by (funcIdx, loopPc).
    ## Avoids recompiling the same loop entry multiple times.
    entries: Table[tuple[funcIdx: int, loopPc: int], JitCode]

  DeoptReason* = enum
    drUnimplemented   # hit a BRK (unimplemented opcode)
    drBoundsCheck     # memory bounds violation
    drDivByZero       # integer division by zero
    drCallIndirect    # indirect call (needs runtime)

  DeoptState* = object
    ## State captured when JIT code needs to bail out to interpreter
    reason*: DeoptReason
    pc*: int                 # WASM PC to resume at
    locals*: seq[uint64]
    stackValues*: seq[uint64]

proc initOsrCompileCache*(): OsrCompileCache =
  result.entries = initTable[tuple[funcIdx: int, loopPc: int], JitCode]()

proc canOsr*(loopCount: int): bool =
  ## Check if a loop is hot enough for OSR
  loopCount >= OsrLoopThreshold

proc captureState*(locals: openArray[uint64], stack: openArray[uint64],
                   pc: int, funcIdx: int): OsrState =
  ## Capture the interpreter state at a loop header for OSR
  result.locals = @locals
  result.stackValues = @stack
  result.pc = pc
  result.funcIdx = funcIdx

proc checkOsrEligible*(code: ptr Expr, pc: int): bool =
  ## Returns true if the instruction at `pc` is opLoop (a valid OSR entry point).
  if code == nil: return false
  if pc < 0 or pc >= code.code.len: return false
  code.code[pc].op == opLoop

proc compileOsrEntry*(pool: var JitMemPool, module: WasmModule,
                      funcIdx: int, loopPc: int,
                      cache: var OsrCompileCache,
                      callTargets: seq[CallTarget] = @[]): OsrEntry =
  ## Compile a JIT entry point at a specific loop header.
  ## Uses the cache to avoid recompilation. The entry point receives locals
  ## and stack values and jumps directly into the loop body.
  let key = (funcIdx: funcIdx, loopPc: loopPc)
  if key in cache.entries:
    result.code = cache.entries[key]
    result.loopPc = loopPc
    return

  let compiled = pool.compileFunction(module, funcIdx,
                                       callTargets = callTargets)
  cache.entries[key] = compiled.code
  result.code = compiled.code
  result.loopPc = loopPc

proc executeOsr*(state: OsrState, pool: var JitMemPool, module: WasmModule,
                 callTargets: seq[CallTarget]): seq[uint64] =
  ## Execute JIT code via OSR from captured interpreter state.
  ## Looks up or compiles the function, sets up locals and value stack
  ## from the captured state, calls the JIT code, and returns results.
  var cache = initOsrCompileCache()
  let entry = compileOsrEntry(pool, module, state.funcIdx, state.pc,
                               cache, callTargets)
  let funcPtr = cast[JitFuncPtr](entry.code.address)

  # Allocate locals array and populate from captured state
  var locals = newSeq[uint64](state.locals.len)
  for i in 0 ..< state.locals.len:
    locals[i] = state.locals[i]

  # Allocate value stack with space for captured values plus headroom
  let stackCapacity = state.stackValues.len + 1024
  var stack = newSeq[uint64](stackCapacity)

  # Copy captured stack values to the bottom of our stack buffer
  for i in 0 ..< state.stackValues.len:
    stack[i] = state.stackValues[i]

  # VSP points one past the top of the stack (post-increment convention)
  let vspBase = cast[ptr uint64](stack[0].addr)
  let vspStart = cast[ptr uint64](cast[uint64](vspBase) +
                                   uint64(state.stackValues.len * 8))
  let localsPtr = if locals.len > 0: locals[0].addr else: nil
  let memBase: ptr byte = nil
  let memSize: uint64 = 0

  let retVsp = funcPtr(vspStart, localsPtr, memBase, memSize)

  # Calculate how many results the JIT left on the stack
  let retAddr = cast[uint64](retVsp)
  let baseAddr = cast[uint64](vspBase)
  let resultCount = int((retAddr - baseAddr) div 8)

  result = newSeq[uint64](resultCount)
  for i in 0 ..< resultCount:
    result[i] = cast[ptr uint64](baseAddr + uint64(i * 8))[]
