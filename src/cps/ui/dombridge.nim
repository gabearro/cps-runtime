## CPS UI DOM Bridge
##
## Thin abstraction over host-provided DOM functions for wasm builds.
## Native builds use no-op stubs so unit tests can run without a browser.

import std/tables
import ./types
when not defined(wasm):
  import ./errors

proc ptrAndLen(s: string): tuple[p: pointer, n: int32] =
  if s.len == 0:
    return (nil, 0)
  (cast[pointer](unsafeAddr s[0]), s.len.int32)

when defined(wasm):
  proc nimui_mount_root_raw(rootId: int32, selPtr: pointer, selLen: int32): int32 {.
    importc: "nimui_mount_root", cdecl.}
  proc nimui_unmount_root_raw(rootId: int32) {.
    importc: "nimui_unmount_root", cdecl.}
  proc nimui_create_element_raw(nodeId: int32, tagPtr: pointer, tagLen: int32) {.
    importc: "nimui_create_element", cdecl.}
  proc nimui_create_text_raw(nodeId: int32, txtPtr: pointer, txtLen: int32) {.
    importc: "nimui_create_text", cdecl.}
  proc nimui_append_child_raw(parentId: int32, childId: int32) {.
    importc: "nimui_append_child", cdecl.}
  proc nimui_insert_before_raw(parentId: int32, childId: int32, refChildId: int32) {.
    importc: "nimui_insert_before", cdecl.}
  proc nimui_remove_node_raw(nodeId: int32) {.
    importc: "nimui_remove_node", cdecl.}
  proc nimui_set_text_raw(nodeId: int32, txtPtr: pointer, txtLen: int32) {.
    importc: "nimui_set_text", cdecl.}
  proc nimui_set_attr_raw(
    nodeId: int32,
    namePtr: pointer,
    nameLen: int32,
    valPtr: pointer,
    valLen: int32,
    kindCode: int32
  ) {.importc: "nimui_set_attr", cdecl.}
  proc nimui_remove_attr_raw(nodeId: int32, namePtr: pointer, nameLen: int32, kindCode: int32) {.
    importc: "nimui_remove_attr", cdecl.}
  proc nimui_add_event_listener_raw(nodeId: int32, eventCode: int32, optionsMask: int32) {.
    importc: "nimui_add_event_listener", cdecl.}
  proc nimui_remove_event_listener_raw(nodeId: int32, eventCode: int32, optionsMask: int32) {.
    importc: "nimui_remove_event_listener", cdecl.}
  proc nimui_hydrate_begin_raw(rootId: int32) {.
    importc: "nimui_hydrate_begin", cdecl.}
  proc nimui_hydrate_end_raw(rootId: int32) {.
    importc: "nimui_hydrate_end", cdecl.}
  proc nimui_hydrate_element_raw(
    nodeId: int32,
    parentId: int32,
    tagPtr: pointer,
    tagLen: int32
  ) {.importc: "nimui_hydrate_element", cdecl.}
  proc nimui_hydrate_text_raw(
    nodeId: int32,
    parentId: int32,
    txtPtr: pointer,
    txtLen: int32
  ) {.importc: "nimui_hydrate_text", cdecl.}
  proc nimui_schedule_flush_raw() {.
    importc: "nimui_schedule_flush", cdecl.}
  proc nimui_location_path_len_raw(): int32 {.
    importc: "nimui_location_path_len", cdecl.}
  proc nimui_location_path_copy_raw(dst: pointer, cap: int32): int32 {.
    importc: "nimui_location_path_copy", cdecl.}
  proc nimui_location_origin_len_raw(): int32 {.
    importc: "nimui_location_origin_len", cdecl.}
  proc nimui_location_origin_copy_raw(dst: pointer, cap: int32): int32 {.
    importc: "nimui_location_origin_copy", cdecl.}
  proc nimui_history_push_raw(pathPtr: pointer, pathLen: int32) {.
    importc: "nimui_history_push", cdecl.}
  proc nimui_history_replace_raw(pathPtr: pointer, pathLen: int32) {.
    importc: "nimui_history_replace", cdecl.}
  proc nimui_history_subscribe_raw() {.
    importc: "nimui_history_subscribe", cdecl.}
  proc nimui_net_fetch_raw(
    requestId: int32,
    urlPtr: pointer,
    urlLen: int32,
    methodPtr: pointer,
    methodLen: int32,
    headersPtr: pointer,
    headersLen: int32,
    bodyPtr: pointer,
    bodyLen: int32,
    responseModeCode: int32
  ) {.importc: "nimui_net_fetch", cdecl.}
  proc nimui_net_fetch_abort_raw(requestId: int32): int32 {.
    importc: "nimui_net_fetch_abort", cdecl.}
  proc nimui_net_ws_connect_raw(connId: int32, urlPtr: pointer, urlLen: int32): int32 {.
    importc: "nimui_net_ws_connect", cdecl.}
  proc nimui_net_ws_send_raw(connId: int32, dataPtr: pointer, dataLen: int32): int32 {.
    importc: "nimui_net_ws_send", cdecl.}
  proc nimui_net_ws_close_raw(
    connId: int32,
    code: int32,
    reasonPtr: pointer,
    reasonLen: int32
  ): int32 {.importc: "nimui_net_ws_close", cdecl.}
  proc nimui_net_sse_connect_raw(
    streamId: int32,
    urlPtr: pointer,
    urlLen: int32,
    withCredentials: int32
  ): int32 {.importc: "nimui_net_sse_connect", cdecl.}
  proc nimui_net_sse_close_raw(streamId: int32): int32 {.
    importc: "nimui_net_sse_close", cdecl.}
else:
  proc nimui_mount_root_raw(rootId: int32, selPtr: pointer, selLen: int32): int32 = rootId
  proc nimui_unmount_root_raw(rootId: int32) = discard
  proc nimui_create_element_raw(nodeId: int32, tagPtr: pointer, tagLen: int32) = discard
  proc nimui_create_text_raw(nodeId: int32, txtPtr: pointer, txtLen: int32) = discard
  proc nimui_append_child_raw(parentId: int32, childId: int32) = discard
  proc nimui_insert_before_raw(parentId: int32, childId: int32, refChildId: int32) = discard
  proc nimui_remove_node_raw(nodeId: int32) = discard
  proc nimui_set_text_raw(nodeId: int32, txtPtr: pointer, txtLen: int32) = discard
  proc nimui_set_attr_raw(
    nodeId: int32,
    namePtr: pointer,
    nameLen: int32,
    valPtr: pointer,
    valLen: int32,
    kindCode: int32
  ) = discard
  proc nimui_remove_attr_raw(nodeId: int32, namePtr: pointer, nameLen: int32, kindCode: int32) = discard
  proc nimui_add_event_listener_raw(nodeId: int32, eventCode: int32, optionsMask: int32) = discard
  proc nimui_remove_event_listener_raw(nodeId: int32, eventCode: int32, optionsMask: int32) = discard
  proc nimui_hydrate_begin_raw(rootId: int32) = discard
  proc nimui_hydrate_end_raw(rootId: int32) = discard
  proc nimui_hydrate_element_raw(
    nodeId: int32,
    parentId: int32,
    tagPtr: pointer,
    tagLen: int32
  ) = discard
  proc nimui_hydrate_text_raw(
    nodeId: int32,
    parentId: int32,
    txtPtr: pointer,
    txtLen: int32
  ) = discard
  proc nimui_schedule_flush_raw() = discard
  proc nimui_location_path_len_raw(): int32 = 0
  proc nimui_location_path_copy_raw(dst: pointer, cap: int32): int32 = 0
  proc nimui_location_origin_len_raw(): int32 = 0
  proc nimui_location_origin_copy_raw(dst: pointer, cap: int32): int32 = 0
  proc nimui_history_push_raw(pathPtr: pointer, pathLen: int32) = discard
  proc nimui_history_replace_raw(pathPtr: pointer, pathLen: int32) = discard
  proc nimui_history_subscribe_raw() = discard
  proc nimui_net_fetch_raw(
    requestId: int32,
    urlPtr: pointer,
    urlLen: int32,
    methodPtr: pointer,
    methodLen: int32,
    headersPtr: pointer,
    headersLen: int32,
    bodyPtr: pointer,
    bodyLen: int32,
    responseModeCode: int32
  ) = discard
  proc nimui_net_fetch_abort_raw(requestId: int32): int32 = 1
  proc nimui_net_ws_connect_raw(connId: int32, urlPtr: pointer, urlLen: int32): int32 = 1
  proc nimui_net_ws_send_raw(connId: int32, dataPtr: pointer, dataLen: int32): int32 = 1
  proc nimui_net_ws_close_raw(
    connId: int32,
    code: int32,
    reasonPtr: pointer,
    reasonLen: int32
  ): int32 = 1
  proc nimui_net_sse_connect_raw(
    streamId: int32,
    urlPtr: pointer,
    urlLen: int32,
    withCredentials: int32
  ): int32 = 1
  proc nimui_net_sse_close_raw(streamId: int32): int32 = 1

var
  nextRootId = -1'i32
  boundHandlers* = initTable[(int32, EventType, bool), VEventHandler]()
  historySubscribed = false
  hydrationActive = false
  hydrationRootId = 0'i32
when not defined(wasm):
  var testLocationPath = "/"

proc allocRootId*(): int32 =
  result = nextRootId
  dec nextRootId

proc mountRootWithId*(rootId: int32, selector: string): int32 =
  let (p, n) = ptrAndLen(selector)
  nimui_mount_root_raw(rootId, p, n)

proc mountRoot*(selector: string): int32 =
  let rootId = allocRootId()
  discard mountRootWithId(rootId, selector)
  rootId

proc beginHydration*(rootId: int32) =
  hydrationActive = true
  hydrationRootId = rootId
  nimui_hydrate_begin_raw(rootId)

proc endHydration*() =
  if hydrationActive:
    nimui_hydrate_end_raw(hydrationRootId)
  hydrationActive = false
  hydrationRootId = 0

proc isHydrationActive*(): bool =
  hydrationActive

proc unmountRoot*(rootId: int32) =
  nimui_unmount_root_raw(rootId)

proc scheduleHostFlush*() =
  nimui_schedule_flush_raw()

proc locationPath*(): string =
  when defined(wasm):
    let n = nimui_location_path_len_raw()
    if n <= 0:
      return ""
    var buf = newString(n + 1)
    let copied = nimui_location_path_copy_raw(addr buf[0], n + 1)
    if copied <= 0:
      return ""
    result = newString(copied)
    copyMem(addr result[0], addr buf[0], copied)
  else:
    testLocationPath

proc locationOrigin*(): string =
  when defined(wasm):
    let n = nimui_location_origin_len_raw()
    if n <= 0:
      return ""
    var buf = newString(n + 1)
    let copied = nimui_location_origin_copy_raw(addr buf[0], n + 1)
    if copied <= 0:
      return ""
    result = newString(copied)
    copyMem(addr result[0], addr buf[0], copied)
  else:
    "http://localhost"

proc pushHistory*(path: string, replace = false) =
  when defined(wasm):
    let (p, n) = ptrAndLen(path)
    if replace:
      nimui_history_replace_raw(p, n)
    else:
      nimui_history_push_raw(p, n)
  else:
    if path.len == 0:
      testLocationPath = "/"
    elif path[0] == '/':
      testLocationPath = path
    else:
      testLocationPath = "/" & path

proc subscribeHistory*() =
  if historySubscribed:
    return
  historySubscribed = true
  nimui_history_subscribe_raw()

proc netFetchRequest*(
  requestId: int32,
  url: string,
  httpMethod: string,
  headersBlob: string,
  body: string,
  responseModeCode: int32 = 0
) =
  let (up, un) = ptrAndLen(url)
  let (mp, mn) = ptrAndLen(httpMethod)
  let (hp, hn) = ptrAndLen(headersBlob)
  let (bp, bn) = ptrAndLen(body)
  nimui_net_fetch_raw(requestId, up, un, mp, mn, hp, hn, bp, bn, responseModeCode)

proc netFetchAbort*(requestId: int32): bool =
  nimui_net_fetch_abort_raw(requestId) != 0

proc netWsConnect*(connId: int32, url: string): bool =
  let (up, un) = ptrAndLen(url)
  nimui_net_ws_connect_raw(connId, up, un) != 0

proc netWsSend*(connId: int32, data: string): bool =
  let (dp, dn) = ptrAndLen(data)
  nimui_net_ws_send_raw(connId, dp, dn) != 0

proc netWsClose*(connId: int32, code: int32 = 1000, reason: string = ""): bool =
  let (rp, rn) = ptrAndLen(reason)
  nimui_net_ws_close_raw(connId, code, rp, rn) != 0

proc netSseConnect*(streamId: int32, url: string, withCredentials = false): bool =
  let (up, un) = ptrAndLen(url)
  nimui_net_sse_connect_raw(streamId, up, un, if withCredentials: 1 else: 0) != 0

proc netSseClose*(streamId: int32): bool =
  nimui_net_sse_close_raw(streamId) != 0

proc setTestLocationPath*(path: string) =
  when not defined(wasm):
    if path.len == 0:
      testLocationPath = "/"
    elif path[0] == '/':
      testLocationPath = path
    else:
      testLocationPath = "/" & path

proc resetTestHistoryState*() =
  when not defined(wasm):
    testLocationPath = "/"
    historySubscribed = false

proc createElementNode*(nodeId: int32, tag: string) =
  let (p, n) = ptrAndLen(tag)
  nimui_create_element_raw(nodeId, p, n)

proc createTextNode*(nodeId: int32, txt: string) =
  let (p, n) = ptrAndLen(txt)
  nimui_create_text_raw(nodeId, p, n)

proc hydrateElementNode*(nodeId, parentId: int32, tag: string) =
  let (p, n) = ptrAndLen(tag)
  nimui_hydrate_element_raw(nodeId, parentId, p, n)

proc hydrateTextNode*(nodeId, parentId: int32, txt: string) =
  let (p, n) = ptrAndLen(txt)
  nimui_hydrate_text_raw(nodeId, parentId, p, n)

proc appendChild*(parentId, childId: int32) =
  nimui_append_child_raw(parentId, childId)

proc insertBefore*(parentId, childId, refChildId: int32) =
  nimui_insert_before_raw(parentId, childId, refChildId)

proc removeNode*(nodeId: int32) =
  nimui_remove_node_raw(nodeId)

proc setNodeText*(nodeId: int32, txt: string) =
  let (p, n) = ptrAndLen(txt)
  nimui_set_text_raw(nodeId, p, n)

proc setNodeAttr*(nodeId: int32, name: string, value: string, kind: VAttrKind = vakAttr) =
  let (np, nn) = ptrAndLen(name)
  let (vp, vn) = ptrAndLen(value)
  nimui_set_attr_raw(nodeId, np, nn, vp, vn, ord(kind).int32)

proc removeNodeAttr*(nodeId: int32, name: string, kind: VAttrKind = vakAttr) =
  let (p, n) = ptrAndLen(name)
  nimui_remove_attr_raw(nodeId, p, n, ord(kind).int32)

proc addNodeEventListener*(nodeId: int32, eventType: EventType, options: EventOptions = EventOptions()) =
  nimui_add_event_listener_raw(nodeId, eventTypeCode(eventType), eventOptionsMask(options))

proc removeNodeEventListener*(nodeId: int32, eventType: EventType, options: EventOptions = EventOptions()) =
  nimui_remove_event_listener_raw(nodeId, eventTypeCode(eventType), eventOptionsMask(options))

proc bindEvent*(nodeId: int32, binding: VEventBinding) =
  let key = (nodeId, binding.eventType, binding.options.capture)
  boundHandlers[key] = binding.handler
  addNodeEventListener(nodeId, binding.eventType, binding.options)

proc unbindEvent*(nodeId: int32, binding: VEventBinding) =
  let key = (nodeId, binding.eventType, binding.options.capture)
  if key in boundHandlers:
    boundHandlers.del(key)
  removeNodeEventListener(nodeId, binding.eventType, binding.options)

proc removeHandlersForNode*(nodeId: int32) =
  var toDelete: seq[(int32, EventType, bool)] = @[]
  for key in boundHandlers.keys:
    if key[0] == nodeId:
      toDelete.add key
  for key in toDelete:
    removeNodeEventListener(
      key[0],
      key[1],
      EventOptions(capture: key[2], passive: false, `once`: false)
    )
    boundHandlers.del(key)

proc clearBoundEvents*() =
  var keys: seq[(int32, EventType, bool)] = @[]
  for key in boundHandlers.keys:
    keys.add key
  for key in keys:
    removeNodeEventListener(
      key[0],
      key[1],
      EventOptions(capture: key[2], passive: false, `once`: false)
    )
  boundHandlers.clear()

proc boundEventCount*(): int =
  boundHandlers.len

proc dispatchBoundEvent*(ev: var UiEvent): int32 =
  let key = (ev.currentTargetId, ev.eventType, ev.capturePhase)
  if key notin boundHandlers:
    return 0
  let handler = boundHandlers[key]
  if handler == nil:
    return 0

  when defined(wasm):
    handler(ev)
  else:
    try:
      handler(ev)
    except Exception as e:
      reportUiError("event:" & eventTypeName(ev.eventType), e)

  var flags = 0'i32
  if ev.defaultPrevented:
    flags = flags or 1
  if ev.propagationStopped:
    flags = flags or 2
  flags
