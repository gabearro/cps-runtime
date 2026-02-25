## CPS UI Reconciler
##
## Produces DOM patch operations from old/new VDOM trees and applies them
## through the DOM bridge.

import std/[tables, sets]
import ./types
import ./dombridge
import ./vdom

type
  PatchKind* = enum
    pkInsert,
    pkRemove,
    pkMove,
    pkReplaceNode,
    pkReplaceText,
    pkSetAttr,
    pkRemoveAttr,
    pkBindEvent,
    pkUnbindEvent,
    pkMountPortal,
    pkUnmountPortal

  Patch* = object
    kind*: PatchKind
    parentId*: int32
    nodeId*: int32
    oldNodeId*: int32
    rootId*: int32
    refId*: int32
    index*: int
    fromIndex*: int
    toIndex*: int
    attrKind*: VAttrKind
    attrName*: string
    attrValue*: string
    eventBinding*: VEventBinding
    node*: VNode
    oldNode*: VNode
    selector*: string

var nextDomId = 1'i32

proc resetReconcilerIds*() =
  nextDomId = 1

proc allocDomId(): int32 =
  result = nextDomId
  inc nextDomId

proc isTransparent(node: VNode): bool =
  if node == nil:
    return false
  node.kind in {vkFragment, vkComponent, vkErrorBoundary, vkSuspense, vkContextProvider}

proc firstDomId(node: VNode): int32 =
  if node == nil:
    return 0
  case node.kind
  of vkPortal, vkRouterOutlet:
    return 0
  of vkFragment, vkComponent, vkErrorBoundary, vkSuspense, vkContextProvider:
    for child in node.children:
      let id = firstDomId(child)
      if id > 0:
        return id
    return 0
  else:
    if node.domId > 0:
      return node.domId
    for child in node.children:
      let id = firstDomId(child)
      if id > 0:
        return id
    return 0

proc assignNodeIds(node: VNode) =
  if node == nil:
    return

  case node.kind
  of vkElement, vkText:
    if node.domId <= 0:
      node.domId = allocDomId()
  else:
    discard

  for child in node.children:
    assignNodeIds(child)

proc sameHandler(a, b: VEventHandler): bool =
  a == b

proc componentIdentityMatches(oldNode, newNode: VNode): bool =
  if oldNode.componentType.len > 0 or newNode.componentType.len > 0:
    oldNode.componentType == newNode.componentType
  else:
    oldNode.renderFn == newNode.renderFn

proc sameIdentity(oldNode, newNode: VNode): bool =
  if oldNode == nil or newNode == nil:
    return false
  if oldNode.kind != newNode.kind:
    return false

  case oldNode.kind
  of vkElement:
    oldNode.tag == newNode.tag and oldNode.key == newNode.key
  of vkText:
    oldNode.key == newNode.key
  of vkFragment:
    oldNode.key == newNode.key
  of vkPortal:
    oldNode.portalSelector == newNode.portalSelector and oldNode.key == newNode.key
  of vkComponent:
    componentIdentityMatches(oldNode, newNode) and oldNode.key == newNode.key
  of vkErrorBoundary:
    oldNode.key == newNode.key
  of vkSuspense:
    oldNode.key == newNode.key
  of vkContextProvider:
    oldNode.contextId == newNode.contextId and oldNode.key == newNode.key
  of vkRouterOutlet:
    true

proc attrKey(a: VAttr): string =
  $ord(a.kind) & ":" & a.name

proc attrTable(attrs: seq[VAttr]): Table[string, VAttr] =
  result = initTable[string, VAttr]()
  for a in attrs:
    result[attrKey(a)] = a

proc eventBindingKey(binding: VEventBinding): string =
  $eventTypeCode(binding.eventType) & ":" & $eventOptionsMask(binding.options)

proc eventTable(events: seq[VEventBinding]): Table[string, VEventBinding] =
  result = initTable[string, VEventBinding]()
  for binding in events:
    result[eventBindingKey(binding)] = binding

proc keyFor(node: VNode, idx: int): string =
  if node != nil and node.key.len > 0:
    "k:" & node.key
  else:
    "i:" & $idx

proc ensureNoDuplicateKeys(children: seq[VNode], label: string) =
  var seen = initHashSet[string]()
  for child in children:
    if child == nil or child.key.len == 0:
      continue
    if child.key in seen:
      raise newException(ValueError, "UI reconciler error: duplicate key '" & child.key & "' in " & label)
    seen.incl(child.key)

proc ensureAllChildrenKeyed(children: seq[VNode], label: string) =
  for i, child in children:
    if child == nil:
      continue
    if child.key.len == 0:
      raise newException(
        ValueError,
        "UI reconciler error: mixed keyed/unkeyed siblings in " & label &
        "; missing key at index " & $i
      )

proc lisPositions(values: seq[int]): HashSet[int] =
  if values.len == 0:
    return
  var tails: seq[int] = @[]
  var prev = newSeq[int](values.len)
  for i in 0 ..< prev.len:
    prev[i] = -1

  for i, v in values:
    if v < 0:
      continue
    var lo = 0
    var hi = tails.len
    while lo < hi:
      let mid = (lo + hi) shr 1
      if values[tails[mid]] < v:
        lo = mid + 1
      else:
        hi = mid
    if lo > 0:
      prev[i] = tails[lo - 1]
    if lo == tails.len:
      tails.add i
    else:
      tails[lo] = i

  if tails.len == 0:
    return

  var k = tails[^1]
  while k >= 0:
    result.incl(k)
    k = prev[k]

proc clearRefsDeep(node: VNode) =
  if node == nil:
    return
  if node.kind == vkElement:
    for a in node.attrs:
      if a.kind == vakProp and a.name == "__nimui_ref":
        setRefNodeId(a.value, 0)
  for child in node.children:
    clearRefsDeep(child)

proc removeHandlersDeep(node: VNode) =
  if node == nil:
    return
  clearRefsDeep(node)
  if node.domId > 0:
    removeHandlersForNode(node.domId)
  for child in node.children:
    removeHandlersDeep(child)

proc materializeNode(node: VNode, parentId: int32, refId: int32 = 0)

proc mountChildren(children: seq[VNode], parentId: int32, refId: int32 = 0) =
  if refId == 0:
    for child in children:
      materializeNode(child, parentId, 0)
  else:
    var anchor = refId
    for i in countdown(children.len - 1, 0):
      let child = children[i]
      materializeNode(child, parentId, anchor)
      let id = firstDomId(child)
      if id > 0:
        anchor = id

proc materializeNode(node: VNode, parentId: int32, refId: int32 = 0) =
  if node == nil:
    return

  case node.kind
  of vkFragment, vkErrorBoundary, vkSuspense, vkContextProvider:
    mountChildren(node.children, parentId, refId)

  of vkRouterOutlet:
    discard

  of vkPortal:
    var targetId = node.componentId
    if targetId == 0:
      targetId = mountRoot(node.portalSelector)
      node.componentId = targetId
    mountChildren(node.children, targetId, 0)

  of vkComponent:
    if node.renderFn != nil and node.children.len == 0:
      let rendered = node.renderFn()
      if rendered != nil:
        node.children = @[rendered]
    mountChildren(node.children, parentId, refId)

  of vkText:
    if isHydrationActive():
      hydrateTextNode(node.domId, parentId, node.text)
      setNodeText(node.domId, node.text)
    else:
      createTextNode(node.domId, node.text)
      if refId > 0:
        insertBefore(parentId, node.domId, refId)
      else:
        appendChild(parentId, node.domId)

  of vkElement:
    if isHydrationActive():
      hydrateElementNode(node.domId, parentId, node.tag)
    else:
      createElementNode(node.domId, node.tag)
    for a in node.attrs:
      if a.kind == vakProp and a.name == "__nimui_ref":
        setRefNodeId(a.value, node.domId)
      else:
        setNodeAttr(node.domId, a.name, a.value, a.kind)
    if not isHydrationActive():
      if refId > 0:
        insertBefore(parentId, node.domId, refId)
      else:
        appendChild(parentId, node.domId)
    for binding in node.events:
      bindEvent(node.domId, binding)
    mountChildren(node.children, node.domId, 0)

proc applyPatches*(patches: openArray[Patch]) =
  for patch in patches:
    case patch.kind
    of pkInsert:
      materializeNode(patch.node, patch.parentId, patch.refId)

    of pkRemove:
      removeHandlersDeep(patch.node)
      if patch.nodeId > 0:
        removeNode(patch.nodeId)

    of pkMove:
      if patch.nodeId > 0:
        if patch.refId > 0:
          insertBefore(patch.parentId, patch.nodeId, patch.refId)
        else:
          appendChild(patch.parentId, patch.nodeId)

    of pkReplaceNode:
      if patch.node != nil:
        assignNodeIds(patch.node)
        materializeNode(patch.node, patch.parentId, patch.oldNodeId)
      if patch.oldNode != nil:
        removeHandlersDeep(patch.oldNode)
      if patch.oldNodeId > 0:
        removeNode(patch.oldNodeId)

    of pkReplaceText:
      setNodeText(patch.nodeId, patch.attrValue)

    of pkSetAttr:
      if patch.attrKind == vakProp and patch.attrName == "__nimui_ref":
        setRefNodeId(patch.attrValue, patch.nodeId)
      else:
        setNodeAttr(patch.nodeId, patch.attrName, patch.attrValue, patch.attrKind)

    of pkRemoveAttr:
      if patch.attrKind == vakProp and patch.attrName == "__nimui_ref":
        setRefNodeId(patch.attrValue, 0)
      else:
        removeNodeAttr(patch.nodeId, patch.attrName, patch.attrKind)

    of pkBindEvent:
      if patch.eventBinding.handler != nil:
        bindEvent(patch.nodeId, patch.eventBinding)

    of pkUnbindEvent:
      unbindEvent(patch.nodeId, patch.eventBinding)

    of pkMountPortal:
      if patch.node != nil:
        let rootId =
          if patch.rootId != 0: patch.rootId
          else: mountRoot(patch.selector)
        patch.node.componentId = rootId
        mountChildren(patch.node.children, rootId, 0)

    of pkUnmountPortal:
      if patch.rootId != 0:
        unmountRoot(patch.rootId)

proc diffNode(oldNode, newNode: VNode, parentId: int32, patches: var seq[Patch])

proc queuePortalMount(node: VNode, patches: var seq[Patch]) =
  if node == nil:
    return
  patches.add Patch(
    kind: pkMountPortal,
    node: node,
    selector: node.portalSelector,
    rootId: node.componentId
  )

proc queueInsert(newChild: VNode, parentId: int32, refId: int32, patches: var seq[Patch]) =
  if newChild == nil:
    return
  assignNodeIds(newChild)
  if newChild.kind == vkPortal:
    queuePortalMount(newChild, patches)
  elif isTransparent(newChild) or newChild.kind == vkRouterOutlet:
    for child in newChild.children:
      queueInsert(child, parentId, refId, patches)
  else:
    patches.add Patch(
      kind: pkInsert,
      parentId: parentId,
      nodeId: newChild.domId,
      node: newChild,
      refId: refId
    )

proc queueRemove(oldChild: VNode, parentId: int32, patches: var seq[Patch]) =
  if oldChild == nil:
    return

  case oldChild.kind
  of vkFragment, vkErrorBoundary, vkSuspense, vkContextProvider:
    for child in oldChild.children:
      diffNode(child, nil, parentId, patches)

  of vkRouterOutlet:
    discard

  of vkPortal:
    let targetId = oldChild.componentId
    for child in oldChild.children:
      diffNode(child, nil, targetId, patches)
    patches.add Patch(kind: pkUnmountPortal, rootId: targetId, node: oldChild)

  else:
    patches.add Patch(kind: pkRemove, parentId: parentId, nodeId: oldChild.domId, node: oldChild)

proc diffAttrsAndEvents(oldNode, newNode: VNode, patches: var seq[Patch]) =
  let oldAttrs = attrTable(oldNode.attrs)
  let newAttrs = attrTable(newNode.attrs)

  for _, newAttr in newAttrs:
    let key = attrKey(newAttr)
    if key notin oldAttrs or oldAttrs[key].value != newAttr.value:
      patches.add Patch(
        kind: pkSetAttr,
        nodeId: newNode.domId,
        attrKind: newAttr.kind,
        attrName: newAttr.name,
        attrValue: newAttr.value
      )
  for _, oldAttr in oldAttrs:
    let key = attrKey(oldAttr)
    if key notin newAttrs:
      patches.add Patch(
        kind: pkRemoveAttr,
        nodeId: newNode.domId,
        attrKind: oldAttr.kind,
        attrName: oldAttr.name,
        attrValue: oldAttr.value
      )

  let oldEvents = eventTable(oldNode.events)
  let newEvents = eventTable(newNode.events)

  for eventKey in oldEvents.keys:
    if eventKey notin newEvents:
      patches.add Patch(
        kind: pkUnbindEvent,
        nodeId: newNode.domId,
        eventBinding: oldEvents[eventKey]
      )
    elif not sameHandler(oldEvents[eventKey].handler, newEvents[eventKey].handler):
      patches.add Patch(
        kind: pkUnbindEvent,
        nodeId: newNode.domId,
        eventBinding: oldEvents[eventKey]
      )
      patches.add Patch(
        kind: pkBindEvent,
        nodeId: newNode.domId,
        eventBinding: newEvents[eventKey]
      )

  for eventKey in newEvents.keys:
    if eventKey notin oldEvents:
      patches.add Patch(
        kind: pkBindEvent,
        nodeId: newNode.domId,
        eventBinding: newEvents[eventKey]
      )

proc diffChildren(oldChildren, newChildren: seq[VNode], parentId: int32, patches: var seq[Patch]) =
  let oldLen = oldChildren.len
  let newLen = newChildren.len

  var keyedMode = false
  for child in oldChildren:
    if child != nil and child.key.len > 0:
      keyedMode = true
      break
  if not keyedMode:
    for child in newChildren:
      if child != nil and child.key.len > 0:
        keyedMode = true
        break

  if not keyedMode:
    let m = min(oldLen, newLen)
    for i in 0 ..< m:
      diffNode(oldChildren[i], newChildren[i], parentId, patches)

    for i in countdown(oldLen - 1, m):
      queueRemove(oldChildren[i], parentId, patches)

    var anchor = 0'i32
    for i in countdown(newLen - 1, m):
      let newChild = newChildren[i]
      queueInsert(newChild, parentId, anchor, patches)
      let id = firstDomId(newChild)
      if id > 0:
        anchor = id
    return

  ensureAllChildrenKeyed(oldChildren, "old children")
  ensureAllChildrenKeyed(newChildren, "new children")
  ensureNoDuplicateKeys(oldChildren, "old children")
  ensureNoDuplicateKeys(newChildren, "new children")

  var oldKeyToIndex = initTable[string, int]()
  for i, oldChild in oldChildren:
    oldKeyToIndex[keyFor(oldChild, i)] = i

  var newToOld = newSeq[int](newLen)
  for i in 0 ..< newToOld.len:
    newToOld[i] = -1
  var oldMatched = newSeq[bool](oldLen)

  for i, newChild in newChildren:
    let key = keyFor(newChild, i)
    if key in oldKeyToIndex:
      let oldIdx = oldKeyToIndex[key]
      newToOld[i] = oldIdx
      oldMatched[oldIdx] = true
      diffNode(oldChildren[oldIdx], newChild, parentId, patches)
    else:
      assignNodeIds(newChild)

  for i in countdown(oldLen - 1, 0):
    if not oldMatched[i]:
      queueRemove(oldChildren[i], parentId, patches)

  let lis = lisPositions(newToOld)

  var anchor = 0'i32
  for i in countdown(newLen - 1, 0):
    let newChild = newChildren[i]
    if newChild == nil:
      continue

    let oldIdx = newToOld[i]
    let childDomId = firstDomId(newChild)

    if oldIdx < 0:
      queueInsert(newChild, parentId, anchor, patches)
    elif i notin lis and childDomId > 0:
      patches.add Patch(
        kind: pkMove,
        parentId: parentId,
        nodeId: childDomId,
        fromIndex: oldIdx,
        toIndex: i,
        refId: anchor
      )

    if childDomId > 0:
      anchor = childDomId

proc diffNode(oldNode, newNode: VNode, parentId: int32, patches: var seq[Patch]) =
  if oldNode == nil and newNode == nil:
    return

  if oldNode == nil and newNode != nil:
    if newNode.kind in {vkFragment, vkErrorBoundary, vkSuspense, vkContextProvider}:
      for child in newNode.children:
        diffNode(nil, child, parentId, patches)
      return
    if newNode.kind == vkPortal:
      assignNodeIds(newNode)
      queuePortalMount(newNode, patches)
      return
    if newNode.kind == vkRouterOutlet:
      return
    assignNodeIds(newNode)
    patches.add Patch(kind: pkInsert, parentId: parentId, nodeId: newNode.domId, node: newNode)
    return

  if oldNode != nil and newNode == nil:
    queueRemove(oldNode, parentId, patches)
    return

  if not sameIdentity(oldNode, newNode):
    if oldNode.kind notin {vkFragment, vkPortal, vkErrorBoundary, vkSuspense, vkContextProvider, vkRouterOutlet} and
       newNode.kind notin {vkFragment, vkPortal, vkErrorBoundary, vkSuspense, vkContextProvider, vkRouterOutlet}:
      assignNodeIds(newNode)
      patches.add Patch(
        kind: pkReplaceNode,
        parentId: parentId,
        oldNodeId: oldNode.domId,
        node: newNode,
        oldNode: oldNode
      )
      return

    queueRemove(oldNode, parentId, patches)

    if newNode.kind in {vkFragment, vkErrorBoundary, vkSuspense, vkContextProvider}:
      for child in newNode.children:
        diffNode(nil, child, parentId, patches)
    elif newNode.kind == vkPortal:
      assignNodeIds(newNode)
      queuePortalMount(newNode, patches)
    elif newNode.kind != vkRouterOutlet:
      assignNodeIds(newNode)
      patches.add Patch(kind: pkInsert, parentId: parentId, nodeId: newNode.domId, node: newNode)
    return

  # Same node identity: patch in place.
  newNode.domId = oldNode.domId
  newNode.componentId = oldNode.componentId

  case newNode.kind
  of vkText:
    if oldNode.text != newNode.text:
      patches.add Patch(
        kind: pkReplaceText,
        nodeId: newNode.domId,
        attrValue: newNode.text
      )

  of vkElement:
    diffAttrsAndEvents(oldNode, newNode, patches)
    diffChildren(oldNode.children, newNode.children, newNode.domId, patches)

  of vkFragment, vkErrorBoundary, vkSuspense, vkContextProvider:
    diffChildren(oldNode.children, newNode.children, parentId, patches)

  of vkPortal:
    let targetId = oldNode.componentId
    newNode.componentId = targetId
    if targetId == 0:
      queuePortalMount(newNode, patches)
    else:
      diffChildren(oldNode.children, newNode.children, targetId, patches)

  of vkComponent:
    if newNode.renderFn != nil and newNode.children.len == 0:
      let rendered = newNode.renderFn()
      if rendered != nil:
        newNode.children = @[rendered]
    diffChildren(oldNode.children, newNode.children, parentId, patches)

  of vkRouterOutlet:
    discard

proc diffTrees*(oldTree, newTree: VNode, parentId: int32): seq[Patch] =
  result = @[]
  diffNode(oldTree, newTree, parentId, result)
