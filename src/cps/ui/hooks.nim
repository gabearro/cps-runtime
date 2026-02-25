## CPS UI Hooks

import std/[hashes, macros, tables]
import ./types
import ./scheduler
when not defined(wasm):
  import ./errors

type
  HookSlotKind* = enum
    hskState, hskEffect, hskLayoutEffect, hskInsertionEffect, hskMemo

  HookEffect* = object
    deps*: seq[uint64]
    create*: EffectProc
    cleanup*: EffectCleanup
    pending*: bool
    cleanupBeforeRun*: bool

  HookSlot* = ref object
    kind*: HookSlotKind
    stateBox*: ref RootObj
    effect*: HookEffect
    memoDeps*: seq[uint64]

  QueuedStateUpdate* = object
    lane*: UpdateLane
    apply*: proc() {.closure.}

  ComponentInstance* = ref object
    id*: int32
    key*: string
    label*: string
    hooks*: seq[HookSlot]
    cursor*: int
    expectedHooks*: int
    mounted*: bool
    isRendering*: bool
    active*: bool
    contextValues*: Table[int32, ref RootObj]
    boundaryKey*: string
    pendingStateUpdates*: seq[QueuedStateUpdate]

  StateBox[T] = ref object of RootObj
    value: T

  RefCell*[T] = ref object of RootObj
    current*: T

  ReducerBox[S, A] = ref object of RootObj
    state: S
    reducer: proc(state: S, action: A): S {.closure.}

  Context*[T] = ref object
    id*: int32
    defaultValue*: T

  ContextValueBox[T] = ref object of RootObj
    value: T

  HookErrorReporter* = proc(inst: ComponentInstance, phase: string, message: string) {.closure.}

  RenderMode* = enum
    rmClient,
    rmServer

var
  currentInstance*: ComponentInstance
  nextContextId = 1'i32
  hookErrorReporter: HookErrorReporter
  currentRenderMode = rmClient

proc setHookErrorReporter*(reporter: HookErrorReporter) =
  hookErrorReporter = reporter

proc setRenderMode*(mode: RenderMode) =
  currentRenderMode = mode

proc renderMode*(): RenderMode =
  currentRenderMode

proc hookFailure(msg: string, inst: ComponentInstance): ref ValueError =
  let compId = if inst != nil: inst.id else: -1
  let label =
    if inst != nil and inst.label.len > 0:
      " key=" & inst.label
    else:
      ""
  newException(ValueError, "UI hook error (component=" & $compId & label & "): " & msg)

proc reportHookError(inst: ComponentInstance, phase: string, message: string) {.used.} =
  if hookErrorReporter != nil:
    hookErrorReporter(inst, phase, message)
  when not defined(wasm):
    reportUiError(phase & ":" & inst.label & ": " & message)

proc newComponentInstance*(id: int32, key: string = "", label: string = ""): ComponentInstance =
  ComponentInstance(
    id: id,
    key: key,
    label: label,
    hooks: @[],
    cursor: 0,
    expectedHooks: 0,
    mounted: false,
    isRendering: false,
    active: true,
    contextValues: initTable[int32, ref RootObj](),
    boundaryKey: "",
    pendingStateUpdates: @[]
  )

proc beginComponentRender*(inst: ComponentInstance) =
  if inst == nil:
    raise newException(ValueError, "UI runtime error: beginComponentRender(nil)")
  inst.cursor = 0
  inst.isRendering = true
  currentInstance = inst

proc endComponentRender*(inst: ComponentInstance) =
  if inst == nil:
    currentInstance = nil
    return
  if inst.mounted:
    if inst.cursor != inst.expectedHooks:
      inst.isRendering = false
      currentInstance = nil
      raise hookFailure(
        "hook count mismatch; expected " & $inst.expectedHooks & ", got " & $inst.cursor,
        inst
      )
  else:
    inst.expectedHooks = inst.cursor
    inst.mounted = true
  inst.isRendering = false
  currentInstance = nil

proc ensureCanCreateHook(inst: ComponentInstance, idx: int) =
  if inst.mounted and idx >= inst.expectedHooks:
    raise hookFailure(
      "hook order mismatch; attempted to create new hook at index " & $idx &
      " after initial render",
      inst
    )

proc ensureHookContext(): ComponentInstance =
  if currentInstance == nil:
    raise newException(ValueError, "UI hook error: hooks can only be used during component render")
  currentInstance

proc depsEqual(a, b: seq[uint64]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc laneRank(lane: UpdateLane): int =
  case lane
  of ulSync:
    0
  of ulTransition:
    1
  of ulIdle:
    2

proc shouldApplyUpdate(updateLane, flushLane: UpdateLane): bool =
  if flushLane == ulSync:
    return true
  laneRank(updateLane) <= laneRank(flushLane)

proc queueStateUpdate(inst: ComponentInstance, lane: UpdateLane, apply: proc() {.closure.}) =
  if inst == nil or apply == nil:
    return
  inst.pendingStateUpdates.add QueuedStateUpdate(lane: lane, apply: apply)

proc useState*[T](initial: T): tuple[value: T, set: proc(next: T) {.closure.}] =
  let inst = ensureHookContext()
  let idx = inst.cursor
  inst.cursor = idx + 1

  if idx == inst.hooks.len:
    ensureCanCreateHook(inst, idx)
    inst.hooks.add HookSlot(kind: hskState, stateBox: StateBox[T](value: initial))
  elif idx > inst.hooks.len:
    raise hookFailure("internal hook cursor gap at index " & $idx, inst)

  let slot = inst.hooks[idx]
  if slot.kind != hskState:
    raise hookFailure("hook kind mismatch at index " & $idx, inst)
  if not (slot.stateBox of StateBox[T]):
    raise hookFailure("state type mismatch at index " & $idx, inst)

  let box = StateBox[T](slot.stateBox)

  proc setter(next: T) =
    if not inst.active:
      return
    if currentInstance != nil:
      raise hookFailure("setState is not allowed during render", inst)
    let lane = currentUpdateLane()
    queueStateUpdate(inst, lane, proc() =
      box.value = next
    )
    requestFlush(lane)

  (box.value, setter)

proc useStateFn*[T](
  initial: T
): tuple[value: T, set: proc(updater: proc(prev: T): T {.closure.}) {.closure.}] =
  let inst = ensureHookContext()
  let idx = inst.cursor
  inst.cursor = idx + 1

  if idx == inst.hooks.len:
    ensureCanCreateHook(inst, idx)
    inst.hooks.add HookSlot(kind: hskState, stateBox: StateBox[T](value: initial))
  elif idx > inst.hooks.len:
    raise hookFailure("internal hook cursor gap at index " & $idx, inst)

  let slot = inst.hooks[idx]
  if slot.kind != hskState:
    raise hookFailure("hook kind mismatch at index " & $idx, inst)
  if not (slot.stateBox of StateBox[T]):
    raise hookFailure("state type mismatch at index " & $idx, inst)

  let box = StateBox[T](slot.stateBox)

  proc setter(updater: proc(prev: T): T {.closure.}) =
    if not inst.active:
      return
    if currentInstance != nil:
      raise hookFailure("setState is not allowed during render", inst)
    let lane = currentUpdateLane()
    queueStateUpdate(inst, lane, proc() =
      box.value = updater(box.value)
    )
    requestFlush(lane)

  (box.value, setter)

proc useRef*[T](initial: T): RefCell[T] =
  let inst = ensureHookContext()
  let idx = inst.cursor
  inst.cursor = idx + 1

  if idx == inst.hooks.len:
    ensureCanCreateHook(inst, idx)
    inst.hooks.add HookSlot(kind: hskState, stateBox: RefCell[T](current: initial))
  elif idx > inst.hooks.len:
    raise hookFailure("internal hook cursor gap at index " & $idx, inst)

  let slot = inst.hooks[idx]
  if slot.kind != hskState:
    raise hookFailure("hook kind mismatch at index " & $idx, inst)
  if not (slot.stateBox of RefCell[T]):
    raise hookFailure("ref type mismatch at index " & $idx, inst)

  RefCell[T](slot.stateBox)

proc useMemo*[T](factory: proc(): T {.closure.}, deps: openArray[uint64]): T =
  let inst = ensureHookContext()
  let idx = inst.cursor
  inst.cursor = idx + 1
  let depsSeq = @deps

  if idx == inst.hooks.len:
    ensureCanCreateHook(inst, idx)
    let value = factory()
    inst.hooks.add HookSlot(
      kind: hskMemo,
      stateBox: StateBox[T](value: value),
      memoDeps: depsSeq
    )
  elif idx > inst.hooks.len:
    raise hookFailure("internal hook cursor gap at index " & $idx, inst)

  let slot = inst.hooks[idx]
  if slot.kind != hskMemo:
    raise hookFailure("hook kind mismatch at index " & $idx, inst)
  if not (slot.stateBox of StateBox[T]):
    raise hookFailure("memo type mismatch at index " & $idx, inst)

  if not depsEqual(slot.memoDeps, depsSeq):
    let box = StateBox[T](slot.stateBox)
    box.value = factory()
    slot.memoDeps = depsSeq

  StateBox[T](slot.stateBox).value

proc useCallback*[T](fn: T, deps: openArray[uint64]): T =
  useMemo(proc(): T = fn, deps)

proc useReducer*[S, A](
  reducer: proc(state: S, action: A): S {.closure.},
  initial: S
): tuple[state: S, dispatch: proc(action: A) {.closure.}] =
  let inst = ensureHookContext()
  let idx = inst.cursor
  inst.cursor = idx + 1

  if idx == inst.hooks.len:
    ensureCanCreateHook(inst, idx)
    inst.hooks.add HookSlot(
      kind: hskState,
      stateBox: ReducerBox[S, A](state: initial, reducer: reducer)
    )
  elif idx > inst.hooks.len:
    raise hookFailure("internal hook cursor gap at index " & $idx, inst)

  let slot = inst.hooks[idx]
  if slot.kind != hskState:
    raise hookFailure("hook kind mismatch at index " & $idx, inst)
  if not (slot.stateBox of ReducerBox[S, A]):
    raise hookFailure("reducer type mismatch at index " & $idx, inst)

  let box = ReducerBox[S, A](slot.stateBox)
  box.reducer = reducer

  proc dispatch(action: A) =
    if not inst.active:
      return
    if currentInstance != nil:
      raise hookFailure("dispatch is not allowed during render", inst)
    let lane = currentUpdateLane()
    queueStateUpdate(inst, lane, proc() =
      box.state = box.reducer(box.state, action)
    )
    requestFlush(lane)

  (box.state, dispatch)

proc registerEffect(kind: HookSlotKind, effect: EffectProc, deps: openArray[uint64]) =
  let inst = ensureHookContext()
  let idx = inst.cursor
  inst.cursor = idx + 1
  let depsSeq = @deps

  if idx == inst.hooks.len:
    ensureCanCreateHook(inst, idx)
    inst.hooks.add HookSlot(
      kind: kind,
      effect: HookEffect(
        deps: depsSeq,
        create: effect,
        cleanup: nil,
        pending: true,
        cleanupBeforeRun: false
      )
    )
    return
  elif idx > inst.hooks.len:
    raise hookFailure("internal hook cursor gap at index " & $idx, inst)

  let slot = inst.hooks[idx]
  if slot.kind != kind:
    raise hookFailure("hook kind mismatch at index " & $idx, inst)

  if not depsEqual(slot.effect.deps, depsSeq):
    slot.effect.deps = depsSeq
    slot.effect.create = effect
    slot.effect.pending = true
    slot.effect.cleanupBeforeRun = slot.effect.cleanup != nil
  else:
    slot.effect.create = effect

proc useEffect*(effect: EffectProc, deps: openArray[uint64]) =
  registerEffect(hskEffect, effect, deps)

proc useLayoutEffect*(effect: EffectProc, deps: openArray[uint64]) =
  registerEffect(hskLayoutEffect, effect, deps)

proc useInsertionEffect*(effect: EffectProc, deps: openArray[uint64]) =
  registerEffect(hskInsertionEffect, effect, deps)

proc runPendingEffectCleanupsByKind(inst: ComponentInstance, kind: HookSlotKind) =
  if inst == nil or not inst.active:
    return
  for slot in inst.hooks.mitems:
    if slot.kind != kind:
      continue
    if not slot.effect.pending:
      continue
    if slot.effect.cleanupBeforeRun and slot.effect.cleanup != nil:
      when defined(wasm):
        slot.effect.cleanup()
      else:
        try:
          slot.effect.cleanup()
        except Exception as e:
          reportHookError(inst, "effect-cleanup", e.msg)
      slot.effect.cleanup = nil

proc runPendingEffectCreatesByKind(inst: ComponentInstance, kind: HookSlotKind) =
  if inst == nil or not inst.active:
    return
  for slot in inst.hooks.mitems:
    if slot.kind != kind:
      continue
    if not slot.effect.pending:
      continue
    if slot.effect.create != nil:
      when defined(wasm):
        slot.effect.cleanup = slot.effect.create()
      else:
        try:
          slot.effect.cleanup = slot.effect.create()
        except Exception as e:
          slot.effect.cleanup = nil
          reportHookError(inst, "effect-create", e.msg)
    else:
      slot.effect.cleanup = nil
    slot.effect.pending = false
    slot.effect.cleanupBeforeRun = false

proc runPendingEffectCleanups*(inst: ComponentInstance) =
  runPendingEffectCleanupsByKind(inst, hskEffect)

proc runPendingEffectCreates*(inst: ComponentInstance) =
  runPendingEffectCreatesByKind(inst, hskEffect)

proc runPendingLayoutEffectCleanups*(inst: ComponentInstance) =
  runPendingEffectCleanupsByKind(inst, hskLayoutEffect)

proc runPendingLayoutEffectCreates*(inst: ComponentInstance) =
  runPendingEffectCreatesByKind(inst, hskLayoutEffect)

proc runPendingInsertionEffectCleanups*(inst: ComponentInstance) =
  runPendingEffectCleanupsByKind(inst, hskInsertionEffect)

proc runPendingInsertionEffectCreates*(inst: ComponentInstance) =
  runPendingEffectCreatesByKind(inst, hskInsertionEffect)

proc applyPendingStateUpdates*(inst: ComponentInstance, flushLane: UpdateLane) =
  if inst == nil or not inst.active:
    return
  if inst.pendingStateUpdates.len == 0:
    return

  var remaining: seq[QueuedStateUpdate] = @[]
  for queued in inst.pendingStateUpdates:
    if queued.apply == nil:
      continue
    if shouldApplyUpdate(queued.lane, flushLane):
      when defined(wasm):
        queued.apply()
      else:
        try:
          queued.apply()
        except Exception as e:
          reportHookError(inst, "state-update", e.msg)
    else:
      remaining.add queued
  inst.pendingStateUpdates = remaining

proc hasPendingStateUpdates*(inst: ComponentInstance): bool =
  inst != nil and inst.pendingStateUpdates.len > 0

proc nextPendingStateLane*(inst: ComponentInstance): UpdateLane =
  if inst == nil or inst.pendingStateUpdates.len == 0:
    return ulSync
  var best = ulIdle
  var seen = false
  for queued in inst.pendingStateUpdates:
    if not seen or laneRank(queued.lane) < laneRank(best):
      best = queued.lane
      seen = true
  best

proc cleanupEffects*(inst: ComponentInstance) =
  if inst == nil:
    return
  for slot in inst.hooks.mitems:
    if slot.kind in {hskEffect, hskLayoutEffect, hskInsertionEffect} and slot.effect.cleanup != nil:
      when defined(wasm):
        slot.effect.cleanup()
      else:
        try:
          slot.effect.cleanup()
        except Exception as e:
          reportHookError(inst, "effect-unmount-cleanup", e.msg)
      slot.effect.cleanup = nil
      slot.effect.pending = false
      slot.effect.cleanupBeforeRun = false
  inst.pendingStateUpdates.setLen(0)
  inst.active = false

proc createContext*[T](defaultValue: T): Context[T] =
  result = Context[T](id: nextContextId, defaultValue: defaultValue)
  inc nextContextId

proc contextValueBox*[T](value: T): ref RootObj =
  ContextValueBox[T](value: value)

proc provider*[T](ctx: Context[T], value: T, child: VNode, key: string = ""): VNode =
  var kids: seq[VNode] = @[]
  if child != nil:
    kids.add child
  VNode(
    kind: vkContextProvider,
    key: key,
    contextId: ctx.id,
    contextValue: contextValueBox(value),
    attrs: @[],
    events: @[],
    children: kids
  )

proc useContext*[T](ctx: Context[T]): T =
  let inst = ensureHookContext()
  if ctx == nil:
    raise hookFailure("useContext called with nil context", inst)
  if ctx.id in inst.contextValues:
    let raw = inst.contextValues[ctx.id]
    if raw of ContextValueBox[T]:
      return ContextValueBox[T](raw).value
    raise hookFailure("context type mismatch for id " & $ctx.id, inst)
  ctx.defaultValue

proc useTransition*(): tuple[
  isPending: bool,
  start: proc(work: proc() {.closure.}) {.closure.}
] =
  let pending = hasPendingTransitions()
  let startProc = proc(work: proc() {.closure.}) =
    scheduler.startTransition(work)
  (pending, startProc)

proc useDeferredValue*[T](value: T): T =
  let (deferred, setDeferred) = useState(value)
  useEffect(
    proc(): EffectCleanup =
      scheduler.startTransition(proc() =
        setDeferred(value)
      )
      nil
    ,
    @[hash(value).uint64]
  )
  deferred

proc useId*(): string =
  let inst = ensureHookContext()
  let idx = inst.cursor
  let (idValue, _) = useState("uid-" & $inst.id & "-" & $idx)
  idValue

proc useImperativeHandle*[T](
  targetRef: RefCell[T],
  factory: proc(): T {.closure.},
  deps: openArray[uint64]
) =
  useLayoutEffect(
    proc(): EffectCleanup =
      if targetRef != nil and factory != nil:
        targetRef.current = factory()
      nil
    ,
    deps
  )

proc useSyncExternalStore*[T](
  subscribe: proc(cb: proc() {.closure.}): proc() {.closure.},
  getSnapshot: proc(): T,
  getServerSnapshot: proc(): T = nil
): T =
  let (_, bumpVersion) = useStateFn(0'i32)
  let subscribeSig = hash(subscribe).uint64
  let snapshotSig = hash(getSnapshot).uint64
  let serverSnapshotSig = hash(getServerSnapshot).uint64

  useLayoutEffect(
    proc(): EffectCleanup =
      if subscribe == nil:
        return nil

      proc onStoreChange() =
        bumpVersion(proc(prev: int32): int32 = prev + 1)

      let unsubscribe = subscribe(onStoreChange)
      proc() =
        if unsubscribe != nil:
          unsubscribe()
    ,
    @[subscribeSig, snapshotSig, serverSnapshotSig]
  )

  if renderMode() == rmServer:
    if getServerSnapshot != nil:
      return getServerSnapshot()
    if getSnapshot != nil:
      return getSnapshot()
    return default(T)

  if getSnapshot != nil:
    return getSnapshot()
  if getServerSnapshot != nil:
    return getServerSnapshot()
  default(T)

proc useDebugValue*[T](value: T) =
  discard value

macro deps*(args: varargs[typed]): untyped =
  result = newNimNode(nnkBracket)
  for arg in args:
    result.add quote do:
      hash(`arg`).uint64

macro depsHash*(args: varargs[typed]): untyped =
  result = newNimNode(nnkBracket)
  for arg in args:
    result.add quote do:
      hash(`arg`).uint64
