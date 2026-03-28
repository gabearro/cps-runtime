## Profile-guided optimization (PGO) data collection and query API.
##
## Profile data is collected by the interpreter during its pre-JIT execution
## phase.  The Tier 2 optimizing compiler then queries this data to make
## better decisions:
##
##   * Branch probabilities   → irBrIf scheduling priority (likely-taken first)
##   * call_indirect targets  → inline-cache seeding, hot-callee identification
##
## Design constraints:
##   - Zero overhead when profiler is nil (default WasmVM has nil profiler).
##   - uint16 saturation as the natural "enough data" stop for counters.
##   - No atomic ops needed — the interpreter is single-threaded.
##   - Pre-allocated profile arrays (indexed by instruction PC) avoid hot-path
##     allocation; only bounds-checked, never grown, in the recording fast path.

const
  PgoMaxCallTargets* = 4       ## max tracked callees per call_indirect site
  PgoBranchLikelyThresh*   = 192'u8  ## branchProb ≥ this → "likely taken"
  PgoBranchUnlikelyThresh* = 64'u8   ## branchProb ≤ this → "likely not-taken"

type
  PgoBranchProfile* = object
    taken*:    uint16  ## saturating count of taken-branch executions
    notTaken*: uint16  ## saturating count of fall-through executions

  PgoCallTarget* = object
    funcIdx*: int32   ## store funcAddr of callee (-1 = empty slot)
    count*:   uint16  ## saturating call count

  PgoCallIndirectProfile* = object
    targets*:    array[PgoMaxCallTargets, PgoCallTarget]
    totalCount*: uint32  ## total indirect calls through this site

  FuncPgoData* = object
    ## Per-function profile data, indexed by instruction PC within the function
    ## body.  branchProfiles[pc] is valid only for PCs that are opBrIf;
    ## callIndirectProfiles[pc] only for opCallIndirect.
    branchProfiles*:       seq[PgoBranchProfile]
    callIndirectProfiles*: seq[PgoCallIndirectProfile]

  PgoProfiler* = object
    ## Global profiler: per-funcAddr PGO data.
    funcData*: seq[FuncPgoData]

# ---------------------------------------------------------------------------
# Profiler lifecycle
# ---------------------------------------------------------------------------

proc ensureFunc*(p: var PgoProfiler, funcAddr: int, codeLen: int) =
  ## Pre-allocate profile slots for `funcAddr` to avoid hot-path allocation.
  ## `codeLen` is the number of instructions in the function body.
  while p.funcData.len <= funcAddr:
    p.funcData.add(FuncPgoData())
  let data = addr p.funcData[funcAddr]
  if data.branchProfiles.len < codeLen:
    data.branchProfiles.setLen(codeLen)
  if data.callIndirectProfiles.len < codeLen:
    data.callIndirectProfiles.setLen(codeLen)

proc resetFunc*(p: var PgoProfiler, funcAddr: int) =
  ## Reset PGO data for a function (call when re-instantiating modules).
  if funcAddr < p.funcData.len:
    p.funcData[funcAddr] = FuncPgoData()

# ---------------------------------------------------------------------------
# Recording (called from interpreter hot loop — keep inlined and minimal)
# ---------------------------------------------------------------------------

proc recordBranch*(p: var PgoProfiler, funcAddr: int, pc: int,
                   taken: bool) {.inline.} =
  ## Record a conditional branch outcome at (funcAddr, pc).
  ## Silently ignored if no profile data has been pre-allocated for this slot.
  if funcAddr >= p.funcData.len: return
  let data = addr p.funcData[funcAddr]
  if pc >= data.branchProfiles.len: return
  if taken:
    if data.branchProfiles[pc].taken < 0xFFFF'u16:
      inc data.branchProfiles[pc].taken
  else:
    if data.branchProfiles[pc].notTaken < 0xFFFF'u16:
      inc data.branchProfiles[pc].notTaken

proc recordCallIndirect*(p: var PgoProfiler, funcAddr: int, pc: int,
                         callee: int32) {.inline.} =
  ## Record a successful call_indirect dispatch to `callee` at (funcAddr, pc).
  if funcAddr >= p.funcData.len: return
  let data = addr p.funcData[funcAddr]
  if pc >= data.callIndirectProfiles.len: return
  let prof = addr data.callIndirectProfiles[pc]
  if prof.totalCount < 0xFFFF_FFFF'u32:
    inc prof.totalCount
  # Update frequency table for this specific callee.
  for i in 0 ..< PgoMaxCallTargets:
    if prof.targets[i].funcIdx == callee:
      if prof.targets[i].count < 0xFFFF'u16:
        inc prof.targets[i].count
      return
    if prof.targets[i].funcIdx < 0:  # empty slot → claim it
      prof.targets[i].funcIdx = callee
      prof.targets[i].count = 1
      return
  # All slots full — evict the minimum-count entry.
  var minIdx = 0
  for i in 1 ..< PgoMaxCallTargets:
    if prof.targets[i].count < prof.targets[minIdx].count:
      minIdx = i
  prof.targets[minIdx].funcIdx = callee
  prof.targets[minIdx].count = 1

# ---------------------------------------------------------------------------
# Query API (used by the Tier 2 compiler)
# ---------------------------------------------------------------------------

proc getFuncData*(p: var PgoProfiler, funcAddr: int): ptr FuncPgoData =
  ## Return a pointer to the PGO data for `funcAddr`, or nil if none.
  if funcAddr >= p.funcData.len: return nil
  addr p.funcData[funcAddr]

proc branchTakenProb*(prof: PgoBranchProfile): uint8 =
  ## Return taken-probability as uint8 in [0, 255].
  ## 128 = 50% (returned when no profile data is available).
  let t = prof.taken.uint32
  let n = prof.notTaken.uint32
  let total = t + n
  if total == 0: return 128
  result = uint8((t * 255) div total)

proc hotCalleeOf*(prof: ptr PgoCallIndirectProfile): int32 =
  ## Return the most-frequent callee funcAddr, or -1 if no data.
  if prof == nil: return -1
  var bestIdx = -1
  var bestCount = 0'u16
  for i in 0 ..< PgoMaxCallTargets:
    if prof.targets[i].funcIdx >= 0 and prof.targets[i].count > bestCount:
      bestCount = prof.targets[i].count
      bestIdx = i
  if bestIdx >= 0: prof.targets[bestIdx].funcIdx else: -1

proc isMegamorphic*(prof: ptr PgoCallIndirectProfile): bool =
  ## True when this call site dispatches to many different callees,
  ## making it unlikely to benefit from speculative inlining.
  ## Heuristic: all 4 slots used AND the dominant callee covers < 80%.
  if prof == nil: return false
  var numTargets = 0
  for i in 0 ..< PgoMaxCallTargets:
    if prof.targets[i].funcIdx >= 0 and prof.targets[i].count > 0:
      inc numTargets
  if numTargets < PgoMaxCallTargets: return false
  let total = prof.totalCount
  if total == 0: return false
  var maxCount = 0'u16
  for i in 0 ..< PgoMaxCallTargets:
    if prof.targets[i].count > maxCount:
      maxCount = prof.targets[i].count
  # top callee < 80% of total → megamorphic
  result = (maxCount.uint32 * 5) < (total * 4)
