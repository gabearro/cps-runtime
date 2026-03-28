## High-level WASM VM API
##
## Provides a clean, ergonomic interface for loading and running WebAssembly
## modules with automatic JIT compilation.
##
## Usage:
##   import cps/wasm/api
##
##   # Load and run a .wasm file
##   var engine = newWasmEngine()
##   let mod = engine.loadFile("program.wasm")
##   let result = mod.call("add", 10'i32, 32'i32)
##   echo result.i32  # 42
##
##   # With host functions
##   engine.addHostFunc("env", "log", proc(x: int32) = echo x)
##   let mod2 = engine.loadFile("with_imports.wasm")
##   mod2.call("main")

import std/tables
import types, binary, runtime, wasi

when defined(macosx) and defined(arm64):
  import jit/memory, jit/compiler, jit/tier, jit/cache

# ---------------------------------------------------------------------------
# Engine — the top-level runtime
# ---------------------------------------------------------------------------

type
  WasmEngine* = ref object
    ## The WebAssembly runtime engine. Manages modules, JIT compilation,
    ## and host function bindings.
    vm: WasmVM
    modules: seq[LoadedModule]
    hostFuncs: Table[string, ExternalVal]  # "module.name" -> ExternalVal
    jitEnabled: bool
    wasiCtx*: WasiContext                   # nil if WASI not enabled
    when defined(macosx) and defined(arm64):
      jitPool: JitMemPool
      codeCache: CodeCache

  LoadedModule* = ref object
    ## A loaded and instantiated WASM module.
    engine: WasmEngine
    wasmModule: WasmModule
    instanceIdx: int
    exports: Table[string, ExportInfo]

  ExportInfo = object
    kind: ExportKind
    idx: int

  WasmResult* = object
    ## Result of a WASM function call. Provides typed accessors.
    values: seq[WasmValue]

  WasmError* = object of CatchableError
    ## Error from WASM execution (traps, link errors, etc.)

# ---------------------------------------------------------------------------
# WasmResult — typed accessors
# ---------------------------------------------------------------------------

proc len*(r: WasmResult): int = r.values.len

proc i32*(r: WasmResult, idx: int = 0): int32 =
  ## Get an i32 result value.
  if idx >= r.values.len:
    raise newException(WasmError, "result index out of range")
  r.values[idx].i32

proc i64*(r: WasmResult, idx: int = 0): int64 =
  if idx >= r.values.len:
    raise newException(WasmError, "result index out of range")
  r.values[idx].i64

proc f32*(r: WasmResult, idx: int = 0): float32 =
  if idx >= r.values.len:
    raise newException(WasmError, "result index out of range")
  r.values[idx].f32

proc f64*(r: WasmResult, idx: int = 0): float64 =
  if idx >= r.values.len:
    raise newException(WasmError, "result index out of range")
  r.values[idx].f64

proc isVoid*(r: WasmResult): bool = r.values.len == 0

proc `$`*(r: WasmResult): string =
  if r.values.len == 0: return "(void)"
  if r.values.len == 1:
    let v = r.values[0]
    case v.kind
    of wvkI32: return $v.i32
    of wvkI64: return $v.i64
    of wvkF32: return $v.f32
    of wvkF64: return $v.f64
    else: return $v
  result = "("
  for i, v in r.values:
    if i > 0: result &= ", "
    case v.kind
    of wvkI32: result &= $v.i32
    of wvkI64: result &= $v.i64
    of wvkF32: result &= $v.f32
    of wvkF64: result &= $v.f64
    else: result &= $v
  result &= ")"

# ---------------------------------------------------------------------------
# Engine lifecycle
# ---------------------------------------------------------------------------

proc newWasmEngine*(jit: bool = true): WasmEngine =
  ## Create a new WASM engine.
  ## Set `jit=false` to use interpreter-only mode.
  result = WasmEngine(
    vm: initWasmVM(),
    jitEnabled: jit,
  )
  when defined(macosx) and defined(arm64):
    if jit:
      result.jitPool = initJitMemPool()
      result.codeCache = initCodeCache(result.jitPool.addr)

proc destroy*(engine: WasmEngine) =
  ## Release all resources.
  when defined(macosx) and defined(arm64):
    if engine.jitEnabled:
      engine.jitPool.destroy()

proc enableWasi*(engine: WasmEngine, args: seq[string] = @[],
                  environ: seq[string] = @[],
                  preopens: seq[string] = @[]) =
  ## Enable WASI support with the given arguments, environment, and
  ## preopened directories. Must be called before loading WASI modules.
  engine.wasiCtx = newWasiContext(args, environ, preopens)

proc wasiExitCode*(engine: WasmEngine): int32 =
  ## Get the exit code from the last WASI proc_exit call.
  if engine.wasiCtx != nil:
    engine.wasiCtx.exitCode
  else:
    0

# ---------------------------------------------------------------------------
# Host function binding
# ---------------------------------------------------------------------------

proc addHostFunc*(engine: WasmEngine, module, name: string,
                  funcType: FuncType, callback: HostFunc) =
  ## Register a host function that WASM modules can import.
  let key = module & "." & name
  engine.hostFuncs[key] = ExternalVal(
    kind: ekFunc,
    funcType: funcType,
    hostFunc: callback
  )

proc addHostFunc*(engine: WasmEngine, module, name: string,
                  callback: proc(args: openArray[WasmValue]): seq[WasmValue]) =
  ## Register a host function with automatic type wrapping.
  let cb: HostFunc = proc(args: openArray[WasmValue]): seq[WasmValue] =
    callback(args)
  # We don't know the type signature, so use a generic one
  let ft = FuncType(params: @[], results: @[])
  engine.addHostFunc(module, name, ft, cb)

# Convenience overloads for common signatures

proc addHostFunc*(engine: WasmEngine, module, name: string,
                  callback: proc(x: int32)) =
  ## Register a void(i32) host function.
  let ft = FuncType(params: @[vtI32], results: @[])
  let cb: HostFunc = proc(args: openArray[WasmValue]): seq[WasmValue] =
    callback(args[0].i32)
    @[]
  engine.addHostFunc(module, name, ft, cb)

proc addHostFunc*(engine: WasmEngine, module, name: string,
                  callback: proc(x: int32): int32) =
  ## Register an i32(i32) host function.
  let ft = FuncType(params: @[vtI32], results: @[vtI32])
  let cb: HostFunc = proc(args: openArray[WasmValue]): seq[WasmValue] =
    @[wasmI32(callback(args[0].i32))]
  engine.addHostFunc(module, name, ft, cb)

proc addHostFunc*(engine: WasmEngine, module, name: string,
                  callback: proc(a, b: int32): int32) =
  ## Register an i32(i32, i32) host function.
  let ft = FuncType(params: @[vtI32, vtI32], results: @[vtI32])
  let cb: HostFunc = proc(args: openArray[WasmValue]): seq[WasmValue] =
    @[wasmI32(callback(args[0].i32, args[1].i32))]
  engine.addHostFunc(module, name, ft, cb)

proc addHostFunc*(engine: WasmEngine, module, name: string,
                  callback: proc()) =
  ## Register a void() host function.
  let ft = FuncType(params: @[], results: @[])
  let cb: HostFunc = proc(args: openArray[WasmValue]): seq[WasmValue] =
    callback()
    @[]
  engine.addHostFunc(module, name, ft, cb)

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

proc needsWasi(module: WasmModule): bool =
  ## Check if a module imports from wasi_snapshot_preview1 or wasi_unstable.
  for imp in module.imports:
    if imp.module == "wasi_snapshot_preview1" or imp.module == "wasi_unstable":
      return true
  false

proc resolveImports(engine: WasmEngine, module: WasmModule): seq[(string, string, ExternalVal)] =
  # If module needs WASI and it's enabled, bind WASI imports first
  var wasiImports: Table[string, ExternalVal]
  if module.needsWasi and engine.wasiCtx != nil:
    engine.wasiCtx.bindToVm(engine.vm)
    for (mod2, name, extVal) in engine.wasiCtx.makeWasiImports():
      let key = mod2 & "." & name
      wasiImports[key] = extVal
  elif module.needsWasi and engine.wasiCtx == nil:
    # Auto-enable WASI with defaults if not explicitly configured
    engine.wasiCtx = newWasiContext(args = @["wasm_program"])
    engine.wasiCtx.bindToVm(engine.vm)
    for (mod2, name, extVal) in engine.wasiCtx.makeWasiImports():
      let key = mod2 & "." & name
      wasiImports[key] = extVal

  for imp in module.imports:
    let key = imp.module & "." & imp.name
    if key in engine.hostFuncs:
      result.add((imp.module, imp.name, engine.hostFuncs[key]))
    elif key in wasiImports:
      result.add((imp.module, imp.name, wasiImports[key]))
    else:
      raise newException(WasmError,
        "unresolved import: " & imp.module & "." & imp.name)

proc loadBytes*(engine: WasmEngine, data: openArray[byte]): LoadedModule =
  ## Load a WASM module from raw bytes.
  let wasmMod = decodeModule(data)
  let imports = engine.resolveImports(wasmMod)
  let idx = engine.vm.instantiate(wasmMod, imports)

  # Update WASI context with VM pointer after instantiation (memory now allocated)
  if engine.wasiCtx != nil:
    engine.wasiCtx.bindToVm(engine.vm)

  result = LoadedModule(engine: engine, wasmModule: wasmMod, instanceIdx: idx)
  for exp in wasmMod.exports:
    result.exports[exp.name] = ExportInfo(kind: exp.kind, idx: exp.idx.int)
  engine.modules.add(result)

proc loadFile*(engine: WasmEngine, path: string): LoadedModule =
  ## Load a WASM module from a .wasm file.
  let data = readFile(path)
  engine.loadBytes(cast[seq[byte]](data))

proc loadString*(engine: WasmEngine, data: string): LoadedModule =
  ## Load a WASM module from a string (binary content).
  engine.loadBytes(cast[seq[byte]](data))

# ---------------------------------------------------------------------------
# Function calling — the core API
# ---------------------------------------------------------------------------

proc toWasmValues(args: varargs[WasmValue]): seq[WasmValue] =
  for a in args: result.add(a)

proc call*(module: LoadedModule, name: string,
           args: varargs[WasmValue]): WasmResult =
  ## Call an exported function by name.
  ##
  ## Example:
  ##   let r = module.call("add", wasmI32(10), wasmI32(32))
  ##   echo r.i32  # 42
  if name notin module.exports:
    raise newException(WasmError, "export not found: " & name)
  let info = module.exports[name]
  if info.kind != ekFunc:
    raise newException(WasmError, "export is not a function: " & name)

  let argSeq = toWasmValues(args)
  try:
    let results = module.engine.vm.execute(info.idx, argSeq)
    WasmResult(values: results)
  except WasiExitError as e:
    # Normal WASI program exit — not an error
    WasmResult(values: @[])
  except WasmTrap as e:
    raise newException(WasmError, "WASM trap: " & e.msg)

# Convenience overloads that accept native Nim types directly

proc call*(module: LoadedModule, name: string): WasmResult =
  ## Call a void function.
  module.call(name, toWasmValues())

proc callI32*(module: LoadedModule, name: string,
              args: varargs[int32]): int32 =
  ## Call a function that returns i32, with i32 arguments.
  var wasmArgs: seq[WasmValue]
  for a in args: wasmArgs.add(wasmI32(a))
  let r = module.call(name, wasmArgs)
  r.i32

proc callI64*(module: LoadedModule, name: string,
              args: varargs[int64]): int64 =
  var wasmArgs: seq[WasmValue]
  for a in args: wasmArgs.add(wasmI64(a))
  let r = module.call(name, wasmArgs)
  r.i64

proc callF32*(module: LoadedModule, name: string,
              args: varargs[float32]): float32 =
  var wasmArgs: seq[WasmValue]
  for a in args: wasmArgs.add(wasmF32(a))
  let r = module.call(name, wasmArgs)
  r.f32

proc callF64*(module: LoadedModule, name: string,
              args: varargs[float64]): float64 =
  var wasmArgs: seq[WasmValue]
  for a in args: wasmArgs.add(wasmF64(a))
  let r = module.call(name, wasmArgs)
  r.f64

proc callVoid*(module: LoadedModule, name: string,
               args: varargs[WasmValue]) =
  ## Call a function and discard the result.
  discard module.call(name, args)

# ---------------------------------------------------------------------------
# Memory access
# ---------------------------------------------------------------------------

proc memory*(module: LoadedModule, idx: int = 0): var MemInst =
  ## Access the module's linear memory.
  module.engine.vm.getMemory(module.instanceIdx, idx)

proc readBytes*(module: LoadedModule, offset: int, length: int): seq[byte] =
  ## Read bytes from linear memory.
  let mem = module.memory()
  if offset + length > mem.data.len:
    raise newException(WasmError, "memory read out of bounds")
  result = newSeq[byte](length)
  copyMem(result[0].addr, mem.data[offset].addr, length)

proc writeBytes*(module: LoadedModule, offset: int, data: openArray[byte]) =
  ## Write bytes to linear memory.
  var mem = module.memory()
  if offset + data.len > mem.data.len:
    raise newException(WasmError, "memory write out of bounds")
  copyMem(mem.data[offset].addr, data[0].unsafeAddr, data.len)

proc readString*(module: LoadedModule, offset: int, length: int): string =
  ## Read a UTF-8 string from linear memory.
  let bytes = module.readBytes(offset, length)
  result = newString(length)
  copyMem(result[0].addr, bytes[0].unsafeAddr, length)

proc writeString*(module: LoadedModule, offset: int, s: string) =
  ## Write a string to linear memory.
  module.writeBytes(offset, cast[seq[byte]](s))

proc memorySize*(module: LoadedModule): int =
  ## Get the memory size in bytes.
  module.memory().data.len

proc memoryPages*(module: LoadedModule): int =
  ## Get the memory size in pages (64KB each).
  module.memory().data.len div 65536

# ---------------------------------------------------------------------------
# Global access
# ---------------------------------------------------------------------------

proc getGlobal*(module: LoadedModule, name: string): WasmValue =
  ## Read an exported global variable.
  if name notin module.exports:
    raise newException(WasmError, "export not found: " & name)
  let info = module.exports[name]
  if info.kind != ekGlobal:
    raise newException(WasmError, "export is not a global: " & name)
  module.engine.vm.getGlobal(module.instanceIdx, info.idx).value

proc setGlobal*(module: LoadedModule, name: string, val: WasmValue) =
  ## Write to an exported mutable global variable.
  if name notin module.exports:
    raise newException(WasmError, "export not found: " & name)
  let info = module.exports[name]
  if info.kind != ekGlobal:
    raise newException(WasmError, "export is not a global: " & name)
  module.engine.vm.getGlobal(module.instanceIdx, info.idx).value = val

# ---------------------------------------------------------------------------
# Module inspection
# ---------------------------------------------------------------------------

proc hasExport*(module: LoadedModule, name: string): bool =
  name in module.exports

proc exportNames*(module: LoadedModule): seq[string] =
  for name in module.exports.keys:
    result.add(name)

proc exportedFunctions*(module: LoadedModule): seq[string] =
  for name, info in module.exports:
    if info.kind == ekFunc:
      result.add(name)

proc exportedMemories*(module: LoadedModule): seq[string] =
  for name, info in module.exports:
    if info.kind == ekMemory:
      result.add(name)

proc exportedGlobals*(module: LoadedModule): seq[string] =
  for name, info in module.exports:
    if info.kind == ekGlobal:
      result.add(name)

# ---------------------------------------------------------------------------
# Re-exports for convenience
# ---------------------------------------------------------------------------

export types.WasmValue, types.wasmI32, types.wasmI64, types.wasmF32, types.wasmF64
export types.ValType, types.FuncType
export runtime.WasmTrap, runtime.HostFunc
export wasi.WasiContext, wasi.WasiExitError, wasi.newWasiContext
