## CPS UI Runtime

import std/[tables, sets, algorithm, json]
when not defined(wasm):
  import std/[monotimes, times]
import ./types
import ./dombridge
import ./scheduler
import ./hooks
import ./reconciler
import ./errors
import ./vdom
import ./net

type
  UiRuntimeState = object
    mounted: bool
    fatal: bool
    hydrating: bool
    rootSelector: string
    rootDomId: int32
    rootProc: ComponentProc
    rootInstance: ComponentInstance
    tree: VNode
    instances: OrderedTable[string, ComponentInstance]
    nextComponentId: int32
    isFlushing: bool
    boundaryErrors: Table[string, string]
    renderCounts: Table[string, int]

var
  uiRt: UiRuntimeState
  registeredRoot: ComponentProc

when defined(wasm):
  var nimInitialized = false
  proc NimMain() {.importc.}

proc ensureNimInitialized() =
  when defined(wasm):
    if not nimInitialized:
      NimMain()
      nimInitialized = true

proc stringFromPtr(data: pointer, len: int32): string =
  if data == nil or len <= 0:
    return ""
  result = newString(len)
  copyMem(addr result[0], data, len)

proc extrasFromPtr(data: pointer, len: int32): Table[string, string] =
  result = initTable[string, string]()
  if data == nil or len <= 0:
    return

  let raw = stringFromPtr(data, len)
  var i = 0
  while i < raw.len:
    let keyStart = i
    while i < raw.len and raw[i] != '\0':
      inc i
    if i >= raw.len:
      break
    let key = raw[keyStart ..< i]
    inc i

    let valueStart = i
    while i < raw.len and raw[i] != '\0':
      inc i
    let value =
      if valueStart < i:
        raw[valueStart ..< i]
      else:
        ""
    if key.len > 0:
      result[key] = value
    if i < raw.len:
      inc i

proc currentTree*(): VNode =
  uiRt.tree

proc setRootComponent*(root: ComponentProc) =
  registeredRoot = root

proc flush*(lane: UpdateLane = ulSync)
proc unmount*()

proc nextComponentId(): int32 =
  inc uiRt.nextComponentId
  uiRt.nextComponentId

proc childSegment(node: VNode, idx: int): string =
  if node != nil and node.key.len > 0:
    "k:" & node.key
  else:
    "i:" & $idx

proc componentTypeToken(node: VNode): string =
  if node == nil:
    return "nil"
  if node.componentType.len > 0:
    return node.componentType
  if node.tag.len > 0:
    return node.tag
  "anonymous"

proc componentInstanceKey(node: VNode, path: string): string =
  let token = componentTypeToken(node)
  token & "|key=" & node.key & "|path=" & path

proc boundaryInstanceKey(path: string, key: string): string =
  "boundary|path=" & path & "|key=" & key

proc cloneContextValues(src: Table[int32, ref RootObj]): Table[int32, ref RootObj] =
  result = initTable[int32, ref RootObj]()
  for k, v in src:
    result[k] = v

proc incRenderCount(label: string) =
  if label.len == 0:
    return
  uiRt.renderCounts[label] = uiRt.renderCounts.getOrDefault(label, 0) + 1

proc applyPendingStateQueues(flushLane: UpdateLane) =
  applyPendingStateUpdates(uiRt.rootInstance, flushLane)
  for inst in uiRt.instances.values:
    applyPendingStateUpdates(inst, flushLane)

proc hasPendingStateQueue(): tuple[pending: bool, lane: UpdateLane] =
  var seen = false
  var best = ulIdle

  if hasPendingStateUpdates(uiRt.rootInstance):
    seen = true
    best = nextPendingStateLane(uiRt.rootInstance)

  for inst in uiRt.instances.values:
    if not hasPendingStateUpdates(inst):
      continue
    let lane = nextPendingStateLane(inst)
    if not seen or (ord(lane) < ord(best)):
      best = lane
      seen = true

  (seen, best)

proc resolveNode(
  node: VNode,
  path: string,
  activeKeys: var HashSet[string],
  renderOrder: var seq[string],
  contexts: Table[int32, ref RootObj],
  activeBoundary: string
): VNode

proc resolveChildren(
  node: VNode,
  path: string,
  activeKeys: var HashSet[string],
  renderOrder: var seq[string],
  contexts: Table[int32, ref RootObj],
  activeBoundary: string
) =
  var resolvedChildren: seq[VNode] = @[]
  for i, child in node.children:
    let resolved = resolveNode(
      child,
      path & "/" & childSegment(child, i),
      activeKeys,
      renderOrder,
      contexts,
      activeBoundary
    )
    if resolved != nil:
      resolvedChildren.add resolved
  node.children = resolvedChildren

proc fallbackForBoundary(node: VNode, errMsg: string): VNode =
  if node != nil and node.errorFallback != nil:
    return node.errorFallback(errMsg)
  text("UI boundary error: " & errMsg)

proc resolveNode(
  node: VNode,
  path: string,
  activeKeys: var HashSet[string],
  renderOrder: var seq[string],
  contexts: Table[int32, ref RootObj],
  activeBoundary: string
): VNode =
  if node == nil:
    return nil

  case node.kind
  of vkComponent:
    if node.renderFn == nil:
      return nil

    let instKey = componentInstanceKey(node, path)
    var inst = uiRt.instances.getOrDefault(instKey)
    if inst == nil:
      inst = newComponentInstance(
        id = nextComponentId(),
        key = instKey,
        label = componentTypeToken(node) & "@" & path
      )
      uiRt.instances[instKey] = inst
    else:
      inst.active = true

    inst.contextValues = cloneContextValues(contexts)
    inst.boundaryKey = activeBoundary
    incRenderCount(inst.label)

    activeKeys.incl(instKey)
    renderOrder.add(instKey)

    beginComponentRender(inst)
    var rendered: VNode
    try:
      when defined(wasm):
        rendered = node.renderFn()
      else:
        try:
          rendered = node.renderFn()
        except LazyPendingError:
          raise
        except Exception as e:
          if activeBoundary.len > 0:
            uiRt.boundaryErrors[activeBoundary] = e.msg
            rendered = nil
          else:
            uiRt.fatal = true
            reportUiError("component-render", e)
            rendered = nil
    finally:
      endComponentRender(inst)

    resolveNode(rendered, path & "/render", activeKeys, renderOrder, contexts, activeBoundary)

  of vkSuspense:
    var primary: VNode = nil
    var pending = false
    if node.children.len > 0:
      try:
        primary = resolveNode(
          node.children[0],
          path & "/suspense-child",
          activeKeys,
          renderOrder,
          contexts,
          activeBoundary
        )
      except LazyPendingError:
        pending = true

    if pending:
      let fallbackNode =
        if node.suspenseFallback != nil:
          node.suspenseFallback
        else:
          text("")
      return resolveNode(
        fallbackNode,
        path & "/suspense-fallback",
        activeKeys,
        renderOrder,
        contexts,
        activeBoundary
      )

    primary

  of vkErrorBoundary:
    let bKey = boundaryInstanceKey(path, node.key)
    if bKey in uiRt.boundaryErrors:
      let msg = uiRt.boundaryErrors[bKey]
      uiRt.boundaryErrors.del(bKey)
      let fallback = fallbackForBoundary(node, msg)
      return resolveNode(fallback, path & "/fallback", activeKeys, renderOrder, contexts, activeBoundary)

    var child: VNode = nil
    if node.children.len > 0:
      child = resolveNode(
        node.children[0],
        path & "/child",
        activeKeys,
        renderOrder,
        contexts,
        bKey
      )

    if bKey in uiRt.boundaryErrors:
      let msg = uiRt.boundaryErrors[bKey]
      uiRt.boundaryErrors.del(bKey)
      let fallback = fallbackForBoundary(node, msg)
      return resolveNode(fallback, path & "/fallback", activeKeys, renderOrder, contexts, activeBoundary)
    child

  of vkContextProvider:
    var nextContexts = cloneContextValues(contexts)
    if node.contextId != 0 and node.contextValue != nil:
      nextContexts[node.contextId] = node.contextValue
    resolveChildren(node, path, activeKeys, renderOrder, nextContexts, activeBoundary)
    if node.children.len == 0:
      nil
    elif node.children.len == 1:
      node.children[0]
    else:
      fragmentFromSeq(node.children)

  of vkRouterOutlet:
    nil

  of vkElement, vkFragment, vkPortal:
    resolveChildren(node, path, activeKeys, renderOrder, contexts, activeBoundary)
    node

  of vkText:
    node

proc collectRemovedInstances(activeKeys: HashSet[string]): seq[ComponentInstance] =
  var staleKeys: seq[string] = @[]
  for key in uiRt.instances.keys:
    if key notin activeKeys:
      staleKeys.add key

  staleKeys.sort()

  for key in staleKeys:
    if key in uiRt.instances:
      result.add uiRt.instances[key]
      uiRt.instances.del(key)

proc runLayoutCleanupPhase(renderOrder: seq[string]) =
  runPendingLayoutEffectCleanups(uiRt.rootInstance)
  for key in renderOrder:
    if key in uiRt.instances:
      runPendingLayoutEffectCleanups(uiRt.instances[key])

proc runInsertionCleanupPhase(renderOrder: seq[string]) =
  runPendingInsertionEffectCleanups(uiRt.rootInstance)
  for key in renderOrder:
    if key in uiRt.instances:
      runPendingInsertionEffectCleanups(uiRt.instances[key])

proc runEffectCleanupPhase(renderOrder: seq[string]) =
  runPendingEffectCleanups(uiRt.rootInstance)
  for key in renderOrder:
    if key in uiRt.instances:
      runPendingEffectCleanups(uiRt.instances[key])

proc runRemovedCleanupPhase(removed: seq[ComponentInstance]) =
  for inst in removed:
    cleanupEffects(inst)

proc runLayoutCreatePhase(renderOrder: seq[string]) =
  runPendingLayoutEffectCreates(uiRt.rootInstance)
  for key in renderOrder:
    if key in uiRt.instances:
      runPendingLayoutEffectCreates(uiRt.instances[key])

proc runInsertionCreatePhase(renderOrder: seq[string]) =
  runPendingInsertionEffectCreates(uiRt.rootInstance)
  for key in renderOrder:
    if key in uiRt.instances:
      runPendingInsertionEffectCreates(uiRt.instances[key])

proc runEffectCreatePhase(renderOrder: seq[string]) =
  runPendingEffectCreates(uiRt.rootInstance)
  for key in renderOrder:
    if key in uiRt.instances:
      runPendingEffectCreates(uiRt.instances[key])

proc mountInternal(selector: string, root: ComponentProc, hydrateMode: bool) =
  if root == nil:
    raise newException(ValueError, "mount requires a non-nil root component")

  unmount()

  uiRt = UiRuntimeState()
  uiRt.mounted = true
  uiRt.fatal = false
  uiRt.hydrating = hydrateMode
  uiRt.rootSelector = selector
  uiRt.rootProc = root
  uiRt.instances = initOrderedTable[string, ComponentInstance]()
  uiRt.nextComponentId = 0
  uiRt.rootInstance = newComponentInstance(id = 0, key = "root", label = "root")
  uiRt.boundaryErrors = initTable[string, string]()
  uiRt.renderCounts = initTable[string, int]()
  setRenderMode(rmClient)
  clearLastUiError()
  clearLastUiRuntimeEvent()
  clearLastUiHydrationError()

  setHookErrorReporter(proc(inst: ComponentInstance, phase: string, message: string) =
    if inst != nil and inst.boundaryKey.len > 0:
      uiRt.boundaryErrors[inst.boundaryKey] = message
      requestFlush()
    else:
      uiRt.fatal = true
      lastUiError = phase & ": " & message
  )

  let rootId = allocRootId()
  discard mountRootWithId(rootId, selector)
  uiRt.rootDomId = rootId
  if hydrateMode:
    beginHydration(rootId)

  setFlushCallback(proc(lane: UpdateLane) =
    if uiRt.fatal:
      return
    flush(lane)
  )
  flush(ulSync)

proc mount*(selector: string, root: ComponentProc) =
  mountInternal(selector, root, hydrateMode = false)

proc hydrate*(selector: string, root: ComponentProc) =
  mountInternal(selector, root, hydrateMode = true)

proc flush*(lane: UpdateLane = ulSync) =
  if not uiRt.mounted or uiRt.rootProc == nil:
    return
  if uiRt.fatal:
    return
  setRenderMode(rmClient)

  if uiRt.isFlushing:
    requestFlush(lane)
    return

  when not defined(wasm):
    let flushStartedAt = getMonoTime()
  uiRt.renderCounts.clear()

  uiRt.isFlushing = true
  defer:
    uiRt.isFlushing = false

  template flushCore() =
    applyPendingStateQueues(lane)

    beginComponentRender(uiRt.rootInstance)
    var renderedRoot: VNode
    try:
      renderedRoot = uiRt.rootProc()
    finally:
      endComponentRender(uiRt.rootInstance)

    var activeKeys = initHashSet[string]()
    var renderOrder: seq[string] = @[]
    let baseContexts = initTable[int32, ref RootObj]()
    let newTree = resolveNode(renderedRoot, "root", activeKeys, renderOrder, baseContexts, "")
    let removedInstances = collectRemovedInstances(activeKeys)

    let patches = diffTrees(uiRt.tree, newTree, uiRt.rootDomId)
    applyPatches(patches)

    runInsertionCleanupPhase(renderOrder)
    runLayoutCleanupPhase(renderOrder)
    runEffectCleanupPhase(renderOrder)
    runRemovedCleanupPhase(removedInstances)
    runInsertionCreatePhase(renderOrder)
    runLayoutCreatePhase(renderOrder)
    runEffectCreatePhase(renderOrder)

    uiRt.tree = newTree
    if uiRt.hydrating:
      endHydration()
      uiRt.hydrating = false

  when defined(wasm):
    flushCore()
  else:
    try:
      flushCore()
    except ValueError as e:
      reportUiError("flush", e)
      raise
    except Exception as e:
      uiRt.fatal = true
      reportUiError("flush", e)

  notifyFlushCompleted(lane)

  let pendingState = hasPendingStateQueue()
  if pendingState.pending:
    requestFlush(pendingState.lane)

  let durationMs =
    when defined(wasm):
      0'i64
    else:
      inMilliseconds(getMonoTime() - flushStartedAt)
  var countsNode = newJObject()
  for label, count in uiRt.renderCounts:
    countsNode[label] = %count
  let payload = %*{
    "type": "commit",
    "lane": $lane,
    "durationMs": durationMs,
    "renderCounts": countsNode,
    "hydrationError": lastUiHydrationError
  }
  setLastUiRuntimeEvent($payload)

proc unmount*() =
  if not uiRt.mounted:
    resetUiNetState()
    return

  if uiRt.tree != nil:
    let patches = diffTrees(uiRt.tree, nil, uiRt.rootDomId)
    applyPatches(patches)
    uiRt.tree = nil

  cleanupEffects(uiRt.rootInstance)
  for inst in uiRt.instances.values:
    cleanupEffects(inst)
  uiRt.instances.clear()

  clearBoundEvents()
  resetUiNetState()
  clearLastUiHydrationError()
  if uiRt.hydrating:
    endHydration()
  unmountRoot(uiRt.rootDomId)
  clearScheduledFlush()
  setFlushCallback(nil)
  setHookErrorReporter(nil)

  uiRt = UiRuntimeState()

proc start*(selector: string = "#app") =
  if registeredRoot == nil:
    raise newException(ValueError, "no root component registered; call setRootComponent first")
  mount(selector, registeredRoot)

proc startHydrate*(selector: string = "#app") =
  if registeredRoot == nil:
    raise newException(ValueError, "no root component registered; call setRootComponent first")
  hydrate(selector, registeredRoot)

proc refresh*() =
  if not uiRt.mounted or uiRt.rootProc == nil:
    return
  let selector = uiRt.rootSelector
  let root = uiRt.rootProc
  mount(selector, root)

proc runPendingFlush*() =
  runScheduledFlush()

proc nimui_start*(selectorPtr: pointer, selectorLen: int32) {.exportc.} =
  ensureNimInitialized()
  clearLastUiError()
  var selector = "#app"
  if selectorPtr != nil and selectorLen > 0:
    selector = stringFromPtr(selectorPtr, selectorLen)
  try:
    start(selector)
  except Exception as e:
    uiRt.fatal = true
    reportUiError("nimui_start", e)

proc nimui_hydrate*(selectorPtr: pointer, selectorLen: int32) {.exportc.} =
  ensureNimInitialized()
  clearLastUiError()
  var selector = "#app"
  if selectorPtr != nil and selectorLen > 0:
    selector = stringFromPtr(selectorPtr, selectorLen)
  try:
    startHydrate(selector)
  except Exception as e:
    uiRt.fatal = true
    reportUiError("nimui_hydrate", e)

proc nimui_flush*() {.exportc.} =
  clearLastUiError()
  try:
    if isFlushPending():
      runScheduledFlush()
    else:
      flush()
  except Exception as e:
    uiRt.fatal = true
    reportUiError("nimui_flush", e)

proc nimui_unmount*() {.exportc.} =
  unmount()

proc nimui_refresh*() {.exportc.} =
  refresh()

proc nimui_dispatch_event*(
  eventCode: int32,
  targetId: int32,
  currentTargetId: int32,
  valuePtr: pointer, valueLen: int32,
  keyPtr: pointer, keyLen: int32,
  checked: int32,
  ctrlKey: int32,
  altKey: int32,
  shiftKey: int32,
  metaKey: int32,
  clientX: int32,
  clientY: int32,
  button: int32,
  capturePhase: int32 = 0,
  extrasPtr: pointer = nil,
  extrasLen: int32 = 0
): int32 {.exportc.} =
  if uiRt.fatal or not uiRt.mounted:
    return 0
  var ev = UiEvent(
    eventType: eventTypeFromCode(eventCode),
    targetId: targetId,
    currentTargetId: currentTargetId,
    value: stringFromPtr(valuePtr, valueLen),
    key: stringFromPtr(keyPtr, keyLen),
    checked: checked != 0,
    ctrlKey: ctrlKey != 0,
    altKey: altKey != 0,
    shiftKey: shiftKey != 0,
    metaKey: metaKey != 0,
    clientX: clientX,
    clientY: clientY,
    button: button,
    defaultPrevented: false,
    propagationStopped: false,
    capturePhase: capturePhase != 0,
    extras: extrasFromPtr(extrasPtr, extrasLen)
  )
  dispatchBoundEvent(ev)

proc nimui_last_runtime_event_len*(): int32 {.exportc, used.} =
  ui_last_runtime_event_len()

proc nimui_copy_last_runtime_event*(dst: pointer, cap: int32): int32 {.exportc, used.} =
  ui_copy_last_runtime_event(dst, cap)

proc nimui_last_hydration_error_len*(): int32 {.exportc, used.} =
  ui_last_hydration_error_len()

proc nimui_copy_last_hydration_error*(dst: pointer, cap: int32): int32 {.exportc, used.} =
  ui_copy_last_hydration_error(dst, cap)

proc nimui_set_last_hydration_error*(msgPtr: pointer, msgLen: int32) {.exportc, used.} =
  ui_set_last_hydration_error(msgPtr, msgLen)

proc nimui_route_changed*() {.exportc.} =
  if uiRt.mounted and not uiRt.fatal:
    requestFlush()

proc nimui_alloc*(size: int32): pointer {.exportc.} =
  if size <= 0:
    return nil
  alloc(size)

proc nimui_dealloc*(p: pointer) {.exportc.} =
  if p != nil:
    dealloc(p)
