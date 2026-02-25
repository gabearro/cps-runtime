## CPS UI VDOM Constructors

import std/[tables, parseutils, macros]
import ./types
import ./scheduler

proc componentTypeNameFromNode(n: NimNode): string {.compileTime.} =
  case n.kind
  of nnkIdent, nnkSym:
    $n
  of nnkAccQuoted:
    var combined = ""
    for part in n:
      combined.add componentTypeNameFromNode(part)
    combined
  of nnkDotExpr:
    if n.len > 0:
      componentTypeNameFromNode(n[^1])
    else:
      ""
  of nnkOpenSymChoice, nnkClosedSymChoice:
    if n.len > 0:
      componentTypeNameFromNode(n[0])
    else:
      ""
  of nnkCall, nnkCommand:
    if n.len > 0:
      componentTypeNameFromNode(n[0])
    else:
      ""
  else:
    ""

macro componentOf*(
  renderProc: typed,
  key: typed = ""
): untyped =
  var typeName = componentTypeNameFromNode(renderProc)
  if typeName.len == 0:
    typeName = "anonymous"
  newCall(ident("component"), renderProc, key, newLit(typeName))

proc attr*(name: string, value: string): VAttr =
  VAttr(kind: vakAttr, name: name, value: value)

proc attr*[T](name: string, value: T): VAttr =
  VAttr(kind: vakAttr, name: name, value: $value)

proc prop*(name: string, value: string): VAttr =
  VAttr(kind: vakProp, name: name, value: value)

proc prop*[T](name: string, value: T): VAttr =
  VAttr(kind: vakProp, name: name, value: $value)

proc styleProp*(name: string, value: string): VAttr =
  VAttr(kind: vakStyle, name: name, value: value)

proc styleProp*[T](name: string, value: T): VAttr =
  VAttr(kind: vakStyle, name: name, value: $value)

proc boolProp*(name: string, value: bool): VAttr =
  VAttr(kind: vakProp, name: name, value: if value: "true" else: "false")

proc opts*(capture: bool = false, passive: bool = false, `once`: bool = false): EventOptions =
  EventOptions(capture: capture, passive: passive, `once`: `once`)

proc on*(eventType: EventType, handler: VEventHandler, options: EventOptions): VEventBinding =
  VEventBinding(eventType: eventType, handler: handler, options: options)

proc on*(eventType: EventType, handler: VEventHandler): VEventBinding =
  VEventBinding(eventType: eventType, handler: handler, options: opts())

proc on*(eventType: EventType, handler: proc(ev: UiEvent) {.closure.}): VEventBinding =
  let wrapped: VEventHandler = proc(ev: var UiEvent) =
    handler(ev)
  VEventBinding(eventType: eventType, handler: wrapped, options: opts())

proc on*(eventType: EventType, handler: proc(ev: UiEvent) {.closure.}, options: EventOptions): VEventBinding =
  let wrapped: VEventHandler = proc(ev: var UiEvent) =
    handler(ev)
  VEventBinding(eventType: eventType, handler: wrapped, options: options)

type
  NodeRef* = ref object
    nodeId*: int32
    token*: int32

var
  nextNodeRefToken = 1'i32
  nodeRefRegistry = initTable[int32, NodeRef]()

proc createNodeRef*(): NodeRef =
  result = NodeRef(nodeId: 0, token: nextNodeRefToken)
  nodeRefRegistry[result.token] = result
  inc nextNodeRefToken

proc refProp*(r: NodeRef): VAttr =
  if r == nil:
    return VAttr(kind: vakProp, name: "__nimui_ref", value: "")
  if r.token == 0:
    r.token = nextNodeRefToken
    nodeRefRegistry[r.token] = r
    inc nextNodeRefToken
  VAttr(kind: vakProp, name: "__nimui_ref", value: $r.token)

proc resolveNodeRef*(tokenText: string): NodeRef =
  if tokenText.len == 0:
    return nil
  var token = 0
  let parsed = parseInt(tokenText, token)
  if parsed == tokenText.len:
    let key = token.int32
    if key in nodeRefRegistry:
      return nodeRefRegistry[key]
  nil

proc setRefNodeId*(tokenText: string, nodeId: int32) =
  let r = resolveNodeRef(tokenText)
  if r != nil:
    r.nodeId = nodeId

proc text*(s: string): VNode =
  VNode(
    kind: vkText,
    text: s,
    attrs: @[],
    events: @[],
    children: @[]
  )

proc element*(tag: string,
              attrs: openArray[VAttr] = [],
              events: openArray[VEventBinding] = [],
              children: openArray[VNode] = [],
              key: string = ""): VNode =
  var filtered: seq[VNode] = @[]
  for ch in children:
    if ch != nil:
      filtered.add ch
  VNode(
    kind: vkElement,
    tag: tag,
    key: key,
    attrs: @attrs,
    events: @events,
    children: filtered
  )

proc fragment*(children: varargs[VNode]): VNode =
  var filtered: seq[VNode] = @[]
  for ch in children:
    if ch != nil:
      filtered.add ch
  VNode(
    kind: vkFragment,
    attrs: @[],
    events: @[],
    children: filtered
  )

proc fragmentFromSeq*(children: seq[VNode]): VNode =
  var filtered: seq[VNode] = @[]
  for ch in children:
    if ch != nil:
      filtered.add ch
  VNode(
    kind: vkFragment,
    attrs: @[],
    events: @[],
    children: filtered
  )

proc portal*(selector: string, child: VNode): VNode =
  var kids: seq[VNode] = @[]
  if child != nil:
    kids.add child
  VNode(
    kind: vkPortal,
    portalSelector: selector,
    attrs: @[],
    events: @[],
    children: kids
  )

proc component*(render: ComponentProc, key: string = "", typeName: string = ""): VNode =
  VNode(
    kind: vkComponent,
    key: key,
    componentType: typeName,
    attrs: @[],
    events: @[],
    children: @[],
    renderFn: render
  )

proc customTag*(
  name: string,
  attrs: openArray[VAttr] = [],
  events: openArray[VEventBinding] = [],
  children: openArray[VNode] = [],
  key: string = ""
): VNode =
  if name.len == 0 or '-' notin name:
    raise newException(ValueError, "customTag requires a custom-element name containing '-'")
  element(name, attrs = attrs, events = events, children = children, key = key)

proc errorBoundary*(
  child: VNode,
  fallback: proc(msg: string): VNode {.closure.},
  key: string = ""
): VNode =
  var kids: seq[VNode] = @[]
  if child != nil:
    kids.add child
  VNode(
    kind: vkErrorBoundary,
    key: key,
    attrs: @[],
    events: @[],
    children: kids,
    errorFallback: fallback
  )

proc suspense*(
  fallback: VNode,
  child: VNode,
  key: string = ""
): VNode =
  var kids: seq[VNode] = @[]
  if child != nil:
    kids.add child
  VNode(
    kind: vkSuspense,
    key: key,
    attrs: @[],
    events: @[],
    children: kids,
    suspenseFallback: fallback
  )

proc newLazyHandle*(
  render: proc(): VNode {.closure.} = nil
): LazyHandle =
  LazyHandle(
    status: (if render == nil: lzsPending else: lzsReady),
    render: render,
    error: ""
  )

proc resolveLazy*(handle: LazyHandle, render: proc(): VNode {.closure.}) =
  if handle == nil:
    return
  handle.render = render
  handle.error = ""
  handle.status = lzsReady
  requestFlush(ulTransition)

proc rejectLazy*(handle: LazyHandle, message: string) =
  if handle == nil:
    return
  handle.error = message
  handle.status = lzsError
  requestFlush(ulTransition)

proc lazyComponent*(loader: proc(): LazyHandle {.closure.}): ComponentProc =
  var handle: LazyHandle = nil
  proc renderLazy(): VNode =
    if handle == nil and loader != nil:
      handle = loader()
    if handle == nil:
      raise newException(ValueError, "lazyComponent loader returned nil handle")
    case handle.status
    of lzsReady:
      if handle.render != nil:
        return handle.render()
      return nil
    of lzsError:
      raise newException(ValueError, if handle.error.len > 0: handle.error else: "lazy component rejected")
    of lzsPending:
      raise newException(LazyPendingError, "lazy component pending")

  renderLazy

proc routerOutletNode*(): VNode =
  VNode(
    kind: vkRouterOutlet,
    attrs: @[],
    events: @[],
    children: @[]
  )
