## Tiered compilation: integrates JIT with the interpreter runtime
## Functions start in interpreter mode and get promoted to JIT after
## reaching an adaptive call threshold, then to Tier 2 after sustained use.
##
## Background JIT (Tier 2):
## When a function reaches the Tier 2 threshold, instead of blocking the
## calling thread, a compile request is posted to a dedicated background
## thread.  The background thread compiles using its own JitMemPool and
## sends back the result (function address + numLocals).  On the next
## invoke() after compilation completes, the result is installed and the
## function starts running at Tier 2 speed.

import ../types
import ../runtime
import ../pgo
import memory, compiler, pipeline, aotcache, cost, codegen_rv64
import std/os
when defined(wasmGuardPages):
  import ../guardmem

const
  JitCallThreshold* = 50    # Default calls before Tier 1 JIT compilation
  Tier2CallThreshold* = 5000  # Default calls before Tier 2 compilation
  JitPoolSize* = 4 * 1024 * 1024  # 4MB JIT code pool
  BgJitPoolSize* = 2 * 1024 * 1024  # 2MB pool for background Tier 2

proc defaultRv64Target(): Rv64Target =
  when defined(bl808) or defined(bl808D0) or defined(theadC906) or
       defined(wasmJitBl808D0) or defined(wasmJitThead):
    rv64BL808D0Target
  elif defined(wasmJitRvCommon) or defined(riscvCommonExt):
    rv64CommonTarget
  else:
    rv64GenericTarget

proc defaultRv32Target(): RvTarget =
  when defined(bl808LP) or defined(bl808Lp) or defined(theadE902) or
       defined(wasmJitBl808LP) or defined(wasmJitBl808Lp):
    rv32BL808LPTarget
  elif defined(bl808) or defined(bl808M0) or defined(theadE907) or
       defined(wasmJitBl808M0):
    rv32BL808M0Target
  elif defined(wasmJitRvCommon) or defined(riscvCommonExt):
    rv32CommonTarget
  else:
    rv32GenericTarget

proc valueSlotCount(vt: ValType): int32 {.inline.} =
  if vt == vtV128: 2'i32 else: 1'i32

proc slotCount(types: openArray[ValType]): int32 =
  for vt in types:
    result += valueSlotCount(vt)

proc storeValueSlots(slots: var seq[uint64], slot: int, value: WasmValue) =
  if slot < 0 or slot >= slots.len:
    return
  if value.kind == wvkV128:
    var lo, hi: uint64
    copyMem(addr lo, unsafeAddr value.v128[0], 8)
    copyMem(addr hi, unsafeAddr value.v128[8], 8)
    slots[slot] = lo
    if slot + 1 < slots.len:
      slots[slot + 1] = hi
  else:
    slots[slot] = wasmValueToRaw(value)

proc loadValueSlots(slots: openArray[uint64], slot: int, vt: ValType): WasmValue =
  if slot < 0 or slot >= slots.len:
    return defaultValue(vt)
  if vt == vtV128:
    if slot + 1 >= slots.len:
      return defaultValue(vt)
    result = WasmValue(kind: wvkV128)
    copyMem(addr result.v128[0], unsafeAddr slots[slot], 8)
    copyMem(addr result.v128[8], unsafeAddr slots[slot + 1], 8)
  else:
    result = rawToWasmValue(slots[slot], vt)

# ---------------------------------------------------------------------------
# Background JIT compilation types
# ---------------------------------------------------------------------------

type
  BgRequest* {.pure.} = object
    ## A Tier 2 compilation request sent to the background thread.
    module*: WasmModule         # ref — safe to share with atomicArc
    funcAddr*: int              # store function address (index into TieredVM state)
    codeIdx*: int               # code section index inside the module
    selfModuleIdx*: int         # module-level function index (for TCO)
    tableElems*: seq[TableElem] # pre-built table entries for call_indirect
    funcElems*: seq[TableElem]  # module-indexed function entries for direct calls
    pgoData*: FuncPgoData       # snapshot of PGO profile at request time
    collectRelocs*: bool        # if true, collect relocation records for AOT cache

  BgResult* {.pure.} = object
    ## Result of background Tier 2 compilation.
    funcAddr*: int
    address*: pointer           # start of compiled code in bgPool
    size*: int
    numLocals*: int
    success*: bool
    codeBytes*: seq[byte]       # copy of compiled bytes (only when collectRelocs was true)
    relocSites*: seq[Relocation] # relocation records (only when collectRelocs was true)

  BgWorker* = object
    ## State owned by the background compilation thread.
    ## Heap-allocated (allocShared0) and shared via ptr.
    pool*: JitMemPool
    reqChan*: Channel[BgRequest]
    resChan*: Channel[BgResult]

proc bgWorkerProc(worker: ptr BgWorker) {.thread.} =
  ## Background thread: compile Tier 2 requests from the channel.
  ## A sentinel request with funcAddr = -1 signals shutdown.
  while true:
    let req = worker[].reqChan.recv()
    if req.funcAddr < 0: break   # shutdown sentinel

    # Allocate table elements into the background pool's sideData so they
    # live as long as the compiled code does.
    var tableElemsPtr: ptr UncheckedArray[TableElem] = nil
    var tableLenI32 = 0'i32
    if req.tableElems.len > 0:
      let bytes = req.tableElems.len * sizeof(TableElem)
      let rawPtr = allocShared0(bytes)
      worker[].pool.sideData.add(rawPtr)
      tableElemsPtr = cast[ptr UncheckedArray[TableElem]](rawPtr)
      tableLenI32 = req.tableElems.len.int32
      for i in 0 ..< req.tableElems.len:
        tableElemsPtr[i] = req.tableElems[i]

    var funcElemsPtr: ptr UncheckedArray[TableElem] = nil
    var numFuncsI32 = 0'i32
    if req.funcElems.len > 0:
      let bytes = req.funcElems.len * sizeof(TableElem)
      let rawPtr = allocShared0(bytes)
      worker[].pool.sideData.add(rawPtr)
      funcElemsPtr = cast[ptr UncheckedArray[TableElem]](rawPtr)
      numFuncsI32 = req.funcElems.len.int32
      for i in 0 ..< req.funcElems.len:
        funcElemsPtr[i] = req.funcElems[i]

    # Copy PGO snapshot into a local so we can take its address safely.
    var pgoSnapshot = req.pgoData
    let pgoPtr = if pgoSnapshot.branchProfiles.len > 0 or
                    pgoSnapshot.callIndirectProfiles.len > 0:
                   addr pgoSnapshot
                 else: nil

    try:
      var relocs: seq[Relocation]
      let relocPtr = if req.collectRelocs: addr relocs else: nil
      let t2code =
        when defined(riscv64):
          worker[].pool.compileTier2Rv64(req.module, req.selfModuleIdx,
                                         req.selfModuleIdx,
                                         tableElemsPtr, tableLenI32,
                                         funcElemsPtr, numFuncsI32,
                                         pgoData = pgoPtr,
                                         target = defaultRv64Target())
        elif defined(riscv32):
          worker[].pool.compileTier2Rv32(req.module, req.selfModuleIdx,
                                         req.selfModuleIdx,
                                         tableElemsPtr, tableLenI32,
                                         funcElemsPtr, numFuncsI32,
                                         pgoData = pgoPtr,
                                         target = defaultRv32Target())
        elif defined(amd64):
          worker[].pool.compileTier2X64(req.module, req.codeIdx,
                                        req.selfModuleIdx,
                                        tableElemsPtr, tableLenI32,
                                        pgoData = pgoPtr,
                                        relocSites = relocPtr)
        else:
          worker[].pool.compileTier2(req.module, req.codeIdx,
                                     req.selfModuleIdx,
                                     tableElemsPtr, tableLenI32,
                                     pgoData = pgoPtr,
                                     relocSites = relocPtr)
      var codeBytes: seq[byte]
      if req.collectRelocs and t2code.address != nil and t2code.size > 0:
        codeBytes = newSeq[byte](t2code.size)
        copyMem(addr codeBytes[0], t2code.address, t2code.size)
      worker[].resChan.send(BgResult(
        funcAddr: req.funcAddr,
        address: t2code.address,
        size: t2code.size,
        numLocals: t2code.numLocals,
        success: true,
        codeBytes: codeBytes,
        relocSites: relocs))
    except Exception:
      # Compilation failed — report failure, function stays at Tier 1
      worker[].resChan.send(BgResult(funcAddr: req.funcAddr, success: false))

proc countLoops(body: seq[Instr]): int =
  ## Count the number of loop instructions in a function body.
  for instr in body:
    if instr.op == opLoop: inc result

proc findCodeIdx(modInst: ModuleInst, module: WasmModule,
                 funcAddr: int): tuple[codeIdx, selfModuleIdx: int] =
  ## Map a store function address back to its module code index and
  ## module-level function index. Returns (-1, -1) on failure.
  result = (-1, -1)
  let importFuncCount = modInst.funcAddrs.len - module.codes.len
  for i in 0 ..< module.codes.len:
    if modInst.funcAddrs[importFuncCount + i] == funcAddr:
      return (i, importFuncCount + i)

proc computeJitThreshold*(funcInst: FuncInst, module: WasmModule,
                           codeIdx: int): int =
  ## Compute an adaptive JIT threshold based on function characteristics.
  ## Small functions tier up faster; loops halve the threshold.
  if funcInst.isHost or funcInst.code == nil or
     codeIdx < 0 or codeIdx >= module.codes.len:
    return JitCallThreshold

  let body = module.codes[codeIdx].code.code
  let size = body.len

  # Base threshold from function body size
  result = if size < 20: 20
           elif size <= 100: 50
           elif size <= 500: 200
           else: 500

  # Halve for loop-bearing functions (they benefit more from JIT)
  for instr in body:
    if instr.op == opLoop:
      result = result div 2
      break

  # Enforce minimum
  if result < 10:
    result = 10

proc computeTier2Threshold*(funcInst: FuncInst, module: WasmModule,
                             codeIdx: int): int =
  ## Compute an adaptive Tier 2 threshold based on function characteristics.
  ## Frequency-weighted: loop-heavy functions promote much faster.
  ## Rationale: a function with a tight inner loop is "hot" after just a few
  ## calls (each call does thousands of iterations), so it benefits immediately
  ## from Tier 2 optimizations (inlining, LICM, register allocation).
  if funcInst.isHost or funcInst.code == nil or
     codeIdx < 0 or codeIdx >= module.codes.len:
    return Tier2CallThreshold

  let body = module.codes[codeIdx].code.code
  let size = body.len
  let loopCount = countLoops(body)

  # Base threshold from code size
  result = if size < 20: 500
           elif size <= 100: 1000
           elif size <= 500: 2000
           else: Tier2CallThreshold

  # Each loop divides the threshold by 5 (stacked effect for nested loops).
  # A function with 1 loop needs 5× fewer calls to tier up.
  # A function with 2 loops needs 25× fewer calls.
  for _ in 0 ..< loopCount:
    result = result div 5
    if result < 5: result = 5; break

  # Enforce reasonable minimum/maximum
  result = result.clamp(5, Tier2CallThreshold)

type
  TieredVM* = object
    vm*: WasmVM
    pool*: JitMemPool
    profiler*: PgoProfiler          # PGO data collected during interpreter execution
    # Per-function JIT state
    callCounts*: seq[int]           # call counter per store func index
    jitThresholds*: seq[int]        # adaptive Tier 1 threshold per store func index
    tier2Thresholds*: seq[int]      # adaptive Tier 2 threshold (frequency-weighted)
    jitDisabled*: seq[bool]         # true after a foreground JIT compile fails
    jitCode*: seq[JitCompiledFunc]  # JIT'd code (one per store func, nil if not JIT'd)
    jitPtrs*: seq[JitFuncPtr]       # Function pointers (nil if not JIT'd)
    tier2Code*: seq[JitCode]        # Tier 2 optimized code per store func
    tier2Ptrs*: seq[JitFuncPtr]     # Tier 2 function pointers (nil if not compiled)
    tier2Disabled*: seq[bool]       # true after Tier 2 compile fails for this function
    modules*: seq[WasmModule]       # Keep module refs for JIT compilation
    # Background Tier 2 compilation
    bgWorker*: ptr BgWorker         # nil if background thread not started
    bgThread*: Thread[ptr BgWorker] # the background compilation thread
    bgStarted*: bool                # true once bgThread is running
    tier2Pending*: seq[bool]        # func is queued for background Tier 2
    # Persistent AOT cache
    aotCacheDir*: string            # directory for on-disk JIT cache (empty = disabled)
    pendingCache*: AotCache         # functions compiled this session, pending flush
    moduleHashVal*: uint64          # FNV-1a hash of the primary module bytes

proc initTieredVM*(): TieredVM =
  result.vm = initWasmVM()
  result.pool = initJitMemPool(JitPoolSize)
  result.bgWorker = nil
  result.bgStarted = false
  when defined(wasmGuardPages):
    installGuardPageHandlers()

proc localSlotCount(tvm: TieredVM, storeAddr: int, localTypes: openArray[ValType],
                    preferTier2: bool): int32 =
  if preferTier2 and storeAddr < tvm.tier2Code.len and
     tvm.tier2Code[storeAddr].numLocals > 0:
    tvm.tier2Code[storeAddr].numLocals.int32
  else:
    slotCount(localTypes)

proc buildTableElems(tvm: var TieredVM, modInst: ModuleInst,
                     preferTier2: bool): seq[TableElem] =
  ## Build pre-resolved table elements for call_indirect (table 0 only).
  ## When preferTier2 is true, Tier 2 pointers take precedence over Tier 1.
  if modInst.tableAddrs.len == 0: return
  let tableAddr = modInst.tableAddrs[0]
  let tableInst = tvm.vm.store.tables[tableAddr]
  result = newSeq[TableElem](tableInst.elems.len)
  for i in 0 ..< tableInst.elems.len:
    let elem = tableInst.elems[i]
    if elem.kind == wvkFuncRef and elem.funcRef >= 0:
      let storeAddr = elem.funcRef.int
      if storeAddr < tvm.vm.store.funcs.len:
        let fi = tvm.vm.store.funcs[storeAddr]
        result[i] = TableElem(
          paramCount: fi.funcType.params.len.int32,
          localCount: tvm.localSlotCount(storeAddr, fi.localTypes, preferTier2),
          resultCount: fi.funcType.results.len.int32,
          paramSlotCount: slotCount(fi.funcType.params),
          resultSlotCount: slotCount(fi.funcType.results),
        )
        if preferTier2 and storeAddr < tvm.tier2Ptrs.len and tvm.tier2Ptrs[storeAddr] != nil:
          result[i].jitAddr = cast[pointer](tvm.tier2Ptrs[storeAddr])
        elif storeAddr < tvm.jitPtrs.len and tvm.jitPtrs[storeAddr] != nil:
          result[i].jitAddr = cast[pointer](tvm.jitPtrs[storeAddr])

proc buildFuncElems(tvm: var TieredVM, modInst: ModuleInst,
                    preferTier2: bool): seq[TableElem] =
  ## Build module-indexed function entries for direct calls.
  ## When preferTier2 is true, Tier 2 pointers take precedence over Tier 1.
  result = newSeq[TableElem](modInst.funcAddrs.len)
  for moduleIdx in 0 ..< modInst.funcAddrs.len:
    let storeAddr = modInst.funcAddrs[moduleIdx]
    if storeAddr < 0 or storeAddr >= tvm.vm.store.funcs.len:
      continue
    let fi = tvm.vm.store.funcs[storeAddr]
    result[moduleIdx] = TableElem(
      paramCount: fi.funcType.params.len.int32,
      resultCount: fi.funcType.results.len.int32,
      paramSlotCount: slotCount(fi.funcType.params),
      resultSlotCount: slotCount(fi.funcType.results),
    )
    if fi.isHost:
      result[moduleIdx].localCount = result[moduleIdx].paramSlotCount
    else:
      result[moduleIdx].localCount = tvm.localSlotCount(storeAddr, fi.localTypes, preferTier2)
    if preferTier2 and storeAddr < tvm.tier2Ptrs.len and tvm.tier2Ptrs[storeAddr] != nil:
      result[moduleIdx].jitAddr = cast[pointer](tvm.tier2Ptrs[storeAddr])
    elif storeAddr < tvm.jitPtrs.len and tvm.jitPtrs[storeAddr] != nil:
      result[moduleIdx].jitAddr = cast[pointer](tvm.jitPtrs[storeAddr])

proc ensureBgThread*(tvm: var TieredVM) =
  ## Start the background compilation thread if it hasn't been started yet.
  ## Safe to call multiple times — only starts the thread once.
  if tvm.bgStarted: return
  # Allocate the worker on the shared heap so the background thread can access it
  tvm.bgWorker = cast[ptr BgWorker](allocShared0(sizeof(BgWorker)))
  tvm.bgWorker[].pool = initJitMemPool(BgJitPoolSize)
  tvm.bgWorker[].reqChan.open()
  tvm.bgWorker[].resChan.open()
  createThread(tvm.bgThread, bgWorkerProc, tvm.bgWorker)
  tvm.bgStarted = true

proc destroy*(tvm: var TieredVM) =
  # Stop background thread gracefully before freeing resources
  if tvm.bgStarted and tvm.bgWorker != nil:
    # Send sentinel request to signal shutdown
    tvm.bgWorker[].reqChan.send(BgRequest(funcAddr: -1))
    joinThread(tvm.bgThread)
    tvm.bgWorker[].pool.destroy()
    tvm.bgWorker[].reqChan.close()
    tvm.bgWorker[].resChan.close()
    deallocShared(tvm.bgWorker)
    tvm.bgWorker = nil
    tvm.bgStarted = false
  tvm.pool.destroy()
  # Flush any pending cache entries on shutdown
  if tvm.aotCacheDir.len > 0 and tvm.pendingCache.funcs.len > 0:
    try:
      createDir(tvm.aotCacheDir)
      let p = cachePath(tvm.aotCacheDir, tvm.moduleHashVal)
      tvm.pendingCache.moduleHash = tvm.moduleHashVal
      writeCacheFile(p, tvm.pendingCache)
    except Exception:
      discard  # Non-fatal: just won't be cached this run

proc enableAotCache*(tvm: var TieredVM, cacheDir: string = "") =
  ## Enable persistent on-disk AOT cache.  If *cacheDir* is empty, uses the
  ## platform default (~/.cache/wasm-jit on Linux/macOS).
  tvm.aotCacheDir = if cacheDir.len > 0: cacheDir else: defaultCacheDir()

proc setModuleBytes*(tvm: var TieredVM, moduleBytes: openArray[byte]) =
  ## Compute and store the hash of the primary module for cache key lookup.
  tvm.moduleHashVal = fnv1a64(moduleBytes)
  tvm.pendingCache.moduleHash = tvm.moduleHashVal

proc tryLoadFromAotCache*(tvm: var TieredVM): bool =
  ## Attempt to load previously compiled Tier-2 functions from disk.
  ## Returns true if at least one function was installed from cache.
  ## Must be called after instantiate() and setModuleBytes().
  if tvm.aotCacheDir.len == 0 or tvm.moduleHashVal == 0:
    return false
  let p = cachePath(tvm.aotCacheDir, tvm.moduleHashVal)
  var cache: AotCache
  try:
    cache = readCacheFile(p, tvm.moduleHashVal)
  except Exception:
    return false  # Cache miss or stale — silent fallback

  let dispatchAddr = cast[uint64](tier2CallIndirectDispatch)
  var installed = 0
  for cf in cache.funcs:
    let fa = cf.funcIdx.int
    if fa >= tvm.tier2Ptrs.len: continue
    if tvm.tier2Ptrs[fa] != nil: continue  # already compiled in this session

    # Pre-allocate a fresh CallIndirectCache for each unique call_indirect site
    var siteMap: seq[pointer]  # siteIdx → new CallIndirectCache*
    for r in cf.relocs:
      if r.kind == relocCallCache:
        let si = r.siteIdx.int
        while siteMap.len <= si:
          siteMap.add(nil)
        if siteMap[si] == nil:
          let p2 = allocShared0(sizeof(CallIndirectCache))
          tvm.pool.sideData.add(p2)
          siteMap[si] = p2

    let jc = linkCachedFunc(tvm.pool, cf, dispatchAddr, siteMap)
    if jc.address == nil: continue

    if fa < tvm.tier2Code.len:
      tvm.tier2Code[fa] = jc
    if fa < tvm.tier2Ptrs.len:
      tvm.tier2Ptrs[fa] = cast[JitFuncPtr](jc.address)
    # Mark call counters so we don't re-compile
    if fa < tvm.callCounts.len:
      tvm.callCounts[fa] = tvm.tier2Thresholds[fa]
    inc installed

  result = installed > 0

proc instantiate*(tvm: var TieredVM, module: WasmModule,
                  imports: openArray[(string, string, ExternalVal)]): int =
  result = tvm.vm.instantiate(module, imports)
  tvm.modules.add(module)
  # Extend call counters and JIT code slots for all functions in store
  while tvm.callCounts.len < tvm.vm.store.funcs.len:
    let funcAddr = tvm.callCounts.len
    let funcInst = tvm.vm.store.funcs[funcAddr]

    # Compute adaptive thresholds using the cost model's static bytecode analysis.
    # This is lightweight (no IR lowering) — just walks the instruction stream.
    var threshold = JitCallThreshold
    var tier2Threshold = Tier2CallThreshold
    if not funcInst.isHost and funcInst.code != nil:
      let modIdx = funcInst.moduleIdx
      if modIdx < tvm.modules.len:
        let mod0 = tvm.modules[modIdx]
        let modInst = tvm.vm.store.modules[modIdx]
        let (codeIdx, _) = findCodeIdx(modInst, mod0, funcAddr)
        if codeIdx >= 0:
          let ft = mod0.types[mod0.funcTypeIdxs[codeIdx].int]
          var totalLocals: int16 = ft.params.len.int16
          for ld in mod0.codes[codeIdx].locals:
            totalLocals += ld.count.int16
          let profile = analyzeStatic(
            mod0.codes[codeIdx].code.code, ft.params.len.int16, totalLocals,
            mod0.codes[codeIdx].code.maxStackDepth)
          let (t1, t2) = computeStaticTierThresholds(profile)
          threshold = t1.int
          tier2Threshold = t2.int

    # Pre-allocate PGO profile slots for this function so the interpreter
    # hot loop never needs to grow the profile arrays.  Reset any stale data
    # from a previous instantiation with the same funcAddr.
    if not funcInst.isHost and funcInst.code != nil:
      let codeLen = funcInst.code[].code.len
      if codeLen > 0:
        tvm.profiler.resetFunc(funcAddr)
        tvm.profiler.ensureFunc(funcAddr, codeLen)

    tvm.callCounts.add(0)
    tvm.jitThresholds.add(threshold)
    tvm.tier2Thresholds.add(tier2Threshold)
    tvm.jitDisabled.add(false)
    tvm.jitCode.add(JitCompiledFunc())
    tvm.jitPtrs.add(nil)
    tvm.tier2Code.add(JitCode())
    tvm.tier2Ptrs.add(nil)
    tvm.tier2Disabled.add(false)
    tvm.tier2Pending.add(false)

proc tryTier2Compile(tvm: var TieredVM, funcAddr: int): bool

proc tryJitCompile(tvm: var TieredVM, funcAddr: int): bool =
  ## Try to JIT compile a function. Returns true if successful.
  when defined(riscv64) or defined(riscv32):
    # Tier 1 is currently AArch64-only. On RISC-V, promote directly to the
    # native Tier 2 backend so we never install wrong-ISA code.
    return tvm.tryTier2Compile(funcAddr)
  else:
    let funcInst = tvm.vm.store.funcs[funcAddr]
    if funcInst.isHost:
      return false
    if funcInst.code == nil:
      return false

    # Find the module this function belongs to
    let modIdx = funcInst.moduleIdx
    if modIdx >= tvm.modules.len:
      return false

    let module = tvm.modules[modIdx]
    let modInst = tvm.vm.store.modules[modIdx]

    let (codeIdx, _) = findCodeIdx(modInst, module, funcAddr)
    if codeIdx < 0:
      return false

    try:
      # Build call targets so the JIT can resolve function calls.
      let numImportFuncs = modInst.funcAddrs.len - module.codes.len
      let totalFuncs = numImportFuncs + module.codes.len
      var callTargets = newSeq[CallTarget](totalFuncs)
      var selfModuleIdx = -1

      for i in 0 ..< module.codes.len:
        let storeAddr = modInst.funcAddrs[numImportFuncs + i]
        let fi = tvm.vm.store.funcs[storeAddr]
        let ft = fi.funcType
        let moduleIdx = numImportFuncs + i
        callTargets[moduleIdx] = CallTarget(
          paramCount: ft.params.len,
          localCount: fi.localTypes.len,
          resultCount: ft.results.len,
          globalsCount: modInst.globalAddrs.len,
        )
        if storeAddr < tvm.jitPtrs.len and tvm.jitPtrs[storeAddr] != nil:
          callTargets[moduleIdx].jitAddr = cast[pointer](tvm.jitPtrs[storeAddr])
        if i == codeIdx:
          selfModuleIdx = moduleIdx

      let tableData = tvm.buildTableElems(modInst, preferTier2 = false)

      # Pass globalsOffset so the JIT can access globals from the locals array.
      # Globals are stored after the function's locals in the locals array.
      let globOff = funcInst.localTypes.len * 8
      let compiled = tvm.pool.compileFunction(module, codeIdx,
                                              callTargets, tableData,
                                              globalsOffset = globOff,
                                              selfIdx = selfModuleIdx)
      tvm.jitCode[funcAddr] = compiled
      tvm.jitPtrs[funcAddr] = cast[JitFuncPtr](compiled.code.address)
      return true
    except Exception:
      return false  # Compilation failed, stay in interpreter

proc tryTier2Compile(tvm: var TieredVM, funcAddr: int): bool =
  ## Try to compile a function with Tier 2 optimizations. Returns true if successful.
  let funcInst = tvm.vm.store.funcs[funcAddr]
  if funcInst.isHost:
    return false
  if funcInst.code == nil:
    return false

  let modIdx = funcInst.moduleIdx
  if modIdx >= tvm.modules.len:
    return false

  let module = tvm.modules[modIdx]
  let modInst = tvm.vm.store.modules[modIdx]

  let (codeIdx, selfModuleIdx) = findCodeIdx(modInst, module, funcAddr)
  if codeIdx < 0:
    return false

  # Heap-allocate table elements and register with pool so they live
  # until the pool is destroyed. Uses Tier 2 pointers where available.
  let tableData = tvm.buildTableElems(modInst, preferTier2 = true)
  var tableElemsPtr: ptr UncheckedArray[TableElem] = nil
  var tableLenI32 = 0.int32
  if tableData.len > 0:
    let bytes = tableData.len * sizeof(TableElem)
    let rawPtr = allocShared0(bytes)
    tvm.pool.sideData.add(rawPtr)
    tableElemsPtr = cast[ptr UncheckedArray[TableElem]](rawPtr)
    tableLenI32 = tableData.len.int32
    copyMem(tableElemsPtr, tableData[0].unsafeAddr, bytes)

  let funcData = tvm.buildFuncElems(modInst, preferTier2 = true)
  var funcElemsPtr: ptr UncheckedArray[TableElem] = nil
  var numFuncsI32 = 0.int32
  if funcData.len > 0:
    let bytes = funcData.len * sizeof(TableElem)
    let rawPtr = allocShared0(bytes)
    tvm.pool.sideData.add(rawPtr)
    funcElemsPtr = cast[ptr UncheckedArray[TableElem]](rawPtr)
    numFuncsI32 = funcData.len.int32
    copyMem(funcElemsPtr, funcData[0].unsafeAddr, bytes)

  # Look up PGO data collected during interpreter execution for this funcAddr.
  let pgoDataPtr = tvm.profiler.getFuncData(funcAddr)

  try:
    var relocs: seq[Relocation]
    let relocPtr = if tvm.aotCacheDir.len > 0: addr relocs else: nil
    let t2code =
      when defined(riscv64):
        tvm.pool.compileTier2Rv64(module, selfModuleIdx, selfModuleIdx,
                                  tableElemsPtr, tableLenI32,
                                  funcElemsPtr, numFuncsI32,
                                  pgoData = pgoDataPtr,
                                  target = defaultRv64Target())
      elif defined(riscv32):
        tvm.pool.compileTier2Rv32(module, selfModuleIdx, selfModuleIdx,
                                  tableElemsPtr, tableLenI32,
                                  funcElemsPtr, numFuncsI32,
                                  pgoData = pgoDataPtr,
                                  target = defaultRv32Target())
      elif defined(amd64):
        tvm.pool.compileTier2X64(module, codeIdx, selfModuleIdx,
                                 tableElemsPtr, tableLenI32,
                                 pgoData = pgoDataPtr,
                                 relocSites = relocPtr)
      else:
        tvm.pool.compileTier2(module, codeIdx, selfModuleIdx,
                              tableElemsPtr, tableLenI32,
                              pgoData = pgoDataPtr,
                              relocSites = relocPtr)

    tvm.tier2Code[funcAddr] = t2code
    tvm.tier2Ptrs[funcAddr] = cast[JitFuncPtr](t2code.address)

    # Collect code bytes for persistent cache
    if tvm.aotCacheDir.len > 0 and t2code.address != nil and t2code.size > 0:
      var codeBytes = newSeq[byte](t2code.size)
      copyMem(addr codeBytes[0], t2code.address, t2code.size)
      tvm.pendingCache.funcs.add(CachedFunc(
        funcIdx:   funcAddr.uint32,
        tier:      2'u8,
        numLocals: t2code.numLocals.uint32,
        code:      codeBytes,
        relocs:    relocs))

    return true
  except Exception:
    if funcAddr >= 0 and funcAddr < tvm.tier2Disabled.len:
      tvm.tier2Disabled[funcAddr] = true
    return false  # Tier 2 compilation failed, stay in Tier 1

proc pollBgResults*(tvm: var TieredVM) =
  ## Drain all completed background Tier 2 results and install them.
  ## Call this at the start of invoke() to pick up newly compiled functions
  ## without blocking (tryRecv returns immediately if the channel is empty).
  if not tvm.bgStarted or tvm.bgWorker == nil: return
  while true:
    let (avail, res) = tvm.bgWorker[].resChan.tryRecv()
    if not avail: break
    let fa = res.funcAddr
    if fa < 0 or fa >= tvm.tier2Ptrs.len: continue
    if fa < tvm.tier2Pending.len:
      tvm.tier2Pending[fa] = false
    if res.success and res.address != nil:
      # Install numLocals first so invokeJit sees it before the function pointer
      if fa < tvm.tier2Code.len:
        tvm.tier2Code[fa].address = res.address
        tvm.tier2Code[fa].size = res.size
        tvm.tier2Code[fa].numLocals = res.numLocals
      tvm.tier2Ptrs[fa] = cast[JitFuncPtr](res.address)
      # Save code bytes to pending cache if reloc collection was requested
      if tvm.aotCacheDir.len > 0 and res.codeBytes.len > 0:
        tvm.pendingCache.funcs.add(CachedFunc(
          funcIdx:   fa.uint32,
          tier:      2'u8,
          numLocals: res.numLocals.uint32,
          code:      res.codeBytes,
          relocs:    res.relocSites))
    elif fa < tvm.tier2Disabled.len:
      tvm.tier2Disabled[fa] = true

proc sendBgTier2Request*(tvm: var TieredVM, funcAddr: int) =
  ## Build a background Tier 2 compile request and send it to the worker thread.
  ## Returns immediately; the result will appear in the next pollBgResults().
  if funcAddr < tvm.tier2Disabled.len and tvm.tier2Disabled[funcAddr]:
    return
  let funcInst = tvm.vm.store.funcs[funcAddr]
  if funcInst.isHost or funcInst.code == nil: return

  let modIdx = funcInst.moduleIdx
  if modIdx >= tvm.modules.len: return

  let module = tvm.modules[modIdx]
  let modInst = tvm.vm.store.modules[modIdx]

  let (codeIdx, selfModuleIdx) = findCodeIdx(modInst, module, funcAddr)
  if codeIdx < 0: return

  let tableElems = tvm.buildTableElems(modInst, preferTier2 = true)
  let funcElems = tvm.buildFuncElems(modInst, preferTier2 = true)

  # Snapshot PGO data at request time so the background thread has a stable copy.
  let pgoSnapshot = block:
    let p = tvm.profiler.getFuncData(funcAddr)
    if p != nil: p[] else: FuncPgoData()

  ensureBgThread(tvm)
  if funcAddr < tvm.tier2Pending.len:
    tvm.tier2Pending[funcAddr] = true
  tvm.bgWorker[].reqChan.send(BgRequest(
    module: module,
    funcAddr: funcAddr,
    codeIdx: codeIdx,
    selfModuleIdx: selfModuleIdx,
    tableElems: tableElems,
    funcElems: funcElems,
    pgoData: pgoSnapshot,
    collectRelocs: tvm.aotCacheDir.len > 0,
  ))

proc waitForTier2*(tvm: var TieredVM, funcAddr: int, timeoutIter: int = 100_000) =
  ## Spin-poll until the background Tier 2 compile for funcAddr completes
  ## or timeoutIter iterations elapse.  Use in tests and benchmarks only;
  ## production code should rely on pollBgResults() called from invoke().
  if not tvm.bgStarted or tvm.bgWorker == nil: return
  if funcAddr >= tvm.tier2Ptrs.len: return
  var i = 0
  while i < timeoutIter:
    tvm.pollBgResults()
    if tvm.tier2Ptrs[funcAddr] != nil: return
    if funcAddr < tvm.tier2Pending.len and not tvm.tier2Pending[funcAddr]: return
    inc i

proc invokeJit(tvm: var TieredVM, funcAddr: int,
               args: openArray[WasmValue]): seq[WasmValue] =
  ## Execute a JIT-compiled function (Tier 1 or Tier 2)
  let funcInst = tvm.vm.store.funcs[funcAddr]
  let ft = funcInst.funcType

  # Prefer Tier 2 over Tier 1
  let f = if funcAddr < tvm.tier2Ptrs.len and tvm.tier2Ptrs[funcAddr] != nil:
            tvm.tier2Ptrs[funcAddr]
          else:
            tvm.jitPtrs[funcAddr]

  # Set up locals. Runtime local storage is counted in uint64 slots; v128 uses
  # two slots even though it is one logical Wasm local.
  let origLocalSlots = slotCount(funcInst.localTypes).int
  var irLocals = origLocalSlots
  if funcAddr < tvm.tier2Code.len and tvm.tier2Code[funcAddr].numLocals > irLocals:
    irLocals = tvm.tier2Code[funcAddr].numLocals

  # Count module globals — these are appended after locals in the array.
  # Tier 2's numLocals already includes globals (added by the lowerer).
  # Tier 1 doesn't include them, so we add them if needed.
  let modIdx = funcInst.moduleIdx
  let numGlobals = tvm.vm.store.modules[modIdx].globalAddrs.len

  var globalSlots = 0
  for i in 0 ..< numGlobals:
    let globalAddr = tvm.vm.store.modules[modIdx].globalAddrs[i]
    globalSlots += valueSlotCount(tvm.vm.store.globals[globalAddr].globalType.valType).int

  # Ensure the locals array is large enough to hold both locals and globals.
  let totalLocals = max(irLocals, origLocalSlots + globalSlots)
  var locals = newSeq[uint64](totalLocals)
  var paramSlot = 0
  for i in 0 ..< ft.params.len:
    locals.storeValueSlots(paramSlot, args[i])
    paramSlot += valueSlotCount(ft.params[i]).int
  # Remaining locals are already 0

  # Copy globals into the locals array after the function's original locals.
  # Both Tier 1 and Tier 2 access them after the original local slots.
  var globalSlot = origLocalSlots
  for i in 0 ..< numGlobals:
    let globalAddr = tvm.vm.store.modules[modIdx].globalAddrs[i]
    let globalVal = tvm.vm.store.globals[globalAddr].value
    locals.storeValueSlots(globalSlot, globalVal)
    globalSlot += valueSlotCount(tvm.vm.store.globals[globalAddr].globalType.valType).int

  # Set up value stack
  var vstack = newSeq[uint64](1024)

  # Set up memory pointers
  var memBase: ptr byte = nil
  var memSize: uint64 = 0
  if tvm.vm.store.modules[modIdx].memAddrs.len > 0:
    let memAddr = tvm.vm.store.modules[modIdx].memAddrs[0]
    when defined(wasmGuardPages):
      if tvm.vm.store.mems[memAddr].useGuard:
        memBase = cast[ptr byte](tvm.vm.store.mems[memAddr].guardMem.base)
        memSize = high(uint64)  # guard pages handle the check; disable software bounds
      else:
        let mem = tvm.vm.store.mems[memAddr]
        if mem.data.len > 0:
          memBase = mem.data[0].unsafeAddr
          memSize = mem.data.len.uint64
    else:
      let mem = tvm.vm.store.mems[memAddr]
      if mem.data.len > 0:
        memBase = mem.data[0].unsafeAddr
        memSize = mem.data.len.uint64

  # Call JIT code — wrap with guard page fault recovery when -d:wasmGuardPages
  var resultVsp: ptr uint64 = nil
  when defined(wasmGuardPages):
    wasmGuardedCall do:
      raise newException(WasmTrap, "out of bounds memory access")
    do:
      resultVsp = f(vstack[0].addr, locals[0].addr, memBase, memSize)
  else:
    resultVsp = f(vstack[0].addr, locals[0].addr, memBase, memSize)

  # Write globals back to the store (JIT may have modified them via global.set)
  globalSlot = origLocalSlots
  for i in 0 ..< numGlobals:
    let globalAddr = tvm.vm.store.modules[modIdx].globalAddrs[i]
    let vt = tvm.vm.store.globals[globalAddr].globalType.valType
    tvm.vm.store.globals[globalAddr].value = loadValueSlots(locals, globalSlot, vt)
    globalSlot += valueSlotCount(vt).int

  # Collect results
  let resultCount = (cast[uint](resultVsp) - cast[uint](vstack[0].addr)) div 8
  result = newSeq[WasmValue](ft.results.len)
  var resultSlot = 0
  for i in 0 ..< ft.results.len:
    let needSlots = valueSlotCount(ft.results[i]).int
    if resultSlot + needSlots <= resultCount.int:
      result[i] = loadValueSlots(vstack, resultSlot, ft.results[i])
    else:
      result[i] = defaultValue(ft.results[i])
    resultSlot += needSlots

proc invoke*(tvm: var TieredVM, moduleIdx: int, name: string,
             args: openArray[WasmValue]): seq[WasmValue] =
  ## Invoke a function by name with tiered compilation.
  ## Functions start in interpreter and get promoted to JIT (Tier 1),
  ## then to optimized JIT (Tier 2) after sustained use.
  ##
  ## Tier 2 promotion is non-blocking: the compile request is posted to a
  ## background thread and the function continues at Tier 1 speed until the
  ## result arrives (picked up by pollBgResults on the next call).

  let exp = tvm.vm.getExport(moduleIdx, name)
  if exp.kind != ekFunc:
    raise newException(WasmTrap, "export is not a function: " & name)

  let funcAddr = exp.idx

  # Poll for completed background Tier 2 compilations — non-blocking.
  # This installs newly compiled functions before we decide which tier to use.
  tvm.pollBgResults()

  # Already JIT compiled — track call count for Tier 2 and execute
  if funcAddr < tvm.jitPtrs.len and tvm.jitPtrs[funcAddr] != nil:
    if funcAddr < tvm.callCounts.len and
       funcAddr < tvm.tier2Ptrs.len and tvm.tier2Ptrs[funcAddr] == nil and
       (funcAddr >= tvm.tier2Disabled.len or not tvm.tier2Disabled[funcAddr]):
      # Only queue once — avoid spamming the background thread
      let alreadyPending = funcAddr < tvm.tier2Pending.len and
                           tvm.tier2Pending[funcAddr]
      if not alreadyPending:
        inc tvm.callCounts[funcAddr]
        let t2Threshold = if funcAddr < tvm.tier2Thresholds.len:
                            tvm.tier2Thresholds[funcAddr]
                          else:
                            Tier2CallThreshold
        if tvm.callCounts[funcAddr] >= t2Threshold:
          # Non-blocking: post to background thread
          tvm.sendBgTier2Request(funcAddr)
    return tvm.invokeJit(funcAddr, args)

  # Increment call counter and check for Tier 1 promotion
  if funcAddr < tvm.callCounts.len:
    inc tvm.callCounts[funcAddr]
    if tvm.callCounts[funcAddr] >= tvm.jitThresholds[funcAddr] and
       (funcAddr >= tvm.jitDisabled.len or not tvm.jitDisabled[funcAddr]):
      if tvm.tryJitCompile(funcAddr):
        return tvm.invokeJit(funcAddr, args)
      if funcAddr < tvm.jitDisabled.len:
        tvm.jitDisabled[funcAddr] = true

  # Fall back to interpreter — pass profiler so branch/call_indirect data is collected.
  # Also pass an OsrTrigger so that if the function's inner loops are hot,
  # we immediately compile Tier 1 JIT and queue Tier 2 for the next call.
  var osrTrigger: OsrTrigger
  let interpResult = tvm.vm.execute(funcAddr, args, addr tvm.profiler, addr osrTrigger)

  if osrTrigger.triggered:
    let hotFunc = osrTrigger.funcAddr
    # Synchronously compile Tier 1 so the very next invocation runs in JIT.
    if hotFunc < tvm.jitPtrs.len and tvm.jitPtrs[hotFunc] == nil and
       (hotFunc >= tvm.jitDisabled.len or not tvm.jitDisabled[hotFunc]):
      if not tvm.tryJitCompile(hotFunc) and hotFunc < tvm.jitDisabled.len:
        tvm.jitDisabled[hotFunc] = true
    # Queue Tier 2 in background as well; if the function is called again
    # we want optimized code waiting.
    if hotFunc < tvm.tier2Ptrs.len and tvm.tier2Ptrs[hotFunc] == nil and
       (hotFunc >= tvm.tier2Disabled.len or not tvm.tier2Disabled[hotFunc]):
      let alreadyPending = hotFunc < tvm.tier2Pending.len and tvm.tier2Pending[hotFunc]
      if not alreadyPending:
        tvm.sendBgTier2Request(hotFunc)

  interpResult
