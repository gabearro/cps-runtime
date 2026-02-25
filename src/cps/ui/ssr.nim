## CPS UI SSR
##
## Server-side renderer for cps/ui trees.

import std/[tables, strutils]
import ./types
import ./hooks

type
  SsrOptions* = object
    includeDoctype*: bool

  SsrChunkHandler* = proc(chunk: string) {.closure.}
  SsrDoneHandler* = proc() {.closure.}

proc copyContextValues(src: Table[int32, ref RootObj]): Table[int32, ref RootObj] =
  result = initTable[int32, ref RootObj]()
  for k, v in src:
    result[k] = v

proc escapeHtml(value: string): string =
  result = newStringOfCap(value.len)
  for c in value:
    case c
    of '&':
      result.add("&amp;")
    of '<':
      result.add("&lt;")
    of '>':
      result.add("&gt;")
    of '"':
      result.add("&quot;")
    of '\'':
      result.add("&#39;")
    else:
      result.add(c)

proc boolFromText(raw: string): bool =
  let value = raw.toLowerAscii().strip()
  not (value.len == 0 or value in ["0", "false", "off", "no"])

proc isVoidElement(tag: string): bool =
  case tag.toLowerAscii()
  of "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr":
    true
  else:
    false

proc renderAttrs(attrs: seq[VAttr]): string =
  var styleParts: seq[string] = @[]

  for attr in attrs:
    if attr.kind == vakProp and attr.name == "__nimui_ref":
      continue

    if attr.kind == vakStyle:
      styleParts.add(attr.name & ":" & attr.value)
      continue

    if attr.kind == vakProp and attr.name in ["checked", "selected", "disabled"]:
      if boolFromText(attr.value):
        result.add(" " & attr.name)
      continue

    result.add(" " & attr.name & "=\"" & escapeHtml(attr.value) & "\"")

  if styleParts.len > 0:
    result.add(" style=\"" & escapeHtml(styleParts.join(";")) & "\"")

proc renderNode(
  node: VNode,
  contexts: Table[int32, ref RootObj],
  nextComponentId: var int32,
  boundaryKey: string = ""
): string =
  if node == nil:
    return ""

  case node.kind
  of vkText:
    return escapeHtml(node.text)

  of vkElement:
    let tag = if node.tag.len > 0: node.tag else: "div"
    result.add("<" & tag)
    result.add(renderAttrs(node.attrs))
    if isVoidElement(tag):
      result.add(">")
      return
    result.add(">")
    for child in node.children:
      result.add(renderNode(child, contexts, nextComponentId, boundaryKey))
    result.add("</" & tag & ">")

  of vkFragment, vkPortal:
    for child in node.children:
      result.add(renderNode(child, contexts, nextComponentId, boundaryKey))

  of vkContextProvider:
    var nextContexts = copyContextValues(contexts)
    if node.contextId != 0 and node.contextValue != nil:
      nextContexts[node.contextId] = node.contextValue
    for child in node.children:
      result.add(renderNode(child, nextContexts, nextComponentId, boundaryKey))

  of vkComponent:
    if node.renderFn == nil:
      return ""
    inc nextComponentId
    let inst = newComponentInstance(nextComponentId, label = "ssr:" & node.componentType)
    inst.contextValues = copyContextValues(contexts)
    inst.boundaryKey = boundaryKey

    beginComponentRender(inst)
    var rendered: VNode
    try:
      rendered = node.renderFn()
    finally:
      endComponentRender(inst)

    result.add(renderNode(rendered, contexts, nextComponentId, boundaryKey))

  of vkErrorBoundary:
    let nextBoundaryKey = "ssr-boundary:" & $nextComponentId & ":" & node.key
    try:
      if node.children.len > 0:
        result.add(renderNode(node.children[0], contexts, nextComponentId, nextBoundaryKey))
    except CatchableError as e:
      if node.errorFallback != nil:
        result.add(renderNode(node.errorFallback(e.msg), contexts, nextComponentId, boundaryKey))
      else:
        result.add(escapeHtml("UI boundary error: " & e.msg))

  of vkSuspense:
    try:
      if node.children.len > 0:
        result.add(renderNode(node.children[0], contexts, nextComponentId, boundaryKey))
    except LazyPendingError:
      result.add(renderNode(node.suspenseFallback, contexts, nextComponentId, boundaryKey))

  of vkRouterOutlet:
    return ""

proc renderToString*(root: ComponentProc, opts: SsrOptions = SsrOptions()): string =
  if root == nil:
    return ""

  let prevMode = renderMode()
  setRenderMode(rmServer)
  defer:
    setRenderMode(prevMode)

  var componentId = 0'i32
  let contexts = initTable[int32, ref RootObj]()

  let rootInstance = newComponentInstance(0, key = "ssr-root", label = "ssr-root")
  beginComponentRender(rootInstance)
  var rootNode: VNode
  try:
    rootNode = root()
  finally:
    endComponentRender(rootInstance)

  let body = renderNode(rootNode, contexts, componentId, "")
  if opts.includeDoctype:
    return "<!doctype html>" & body
  body

proc renderToStream*(
  root: ComponentProc,
  onChunk: SsrChunkHandler,
  onDone: SsrDoneHandler = nil,
  opts: SsrOptions = SsrOptions()
) =
  if root == nil:
    if onDone != nil:
      onDone()
    return

  let html = renderToString(root, opts)
  if onChunk != nil:
    const chunkSize = 4096
    var idx = 0
    while idx < html.len:
      let stop = min(idx + chunkSize, html.len)
      onChunk(html[idx ..< stop])
      idx = stop
  if onDone != nil:
    onDone()
