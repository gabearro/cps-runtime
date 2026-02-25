## CPS UI Networking
##
## Browser networking bridge for wasm UI apps:
## - HTTP fetch requests
## - WebSocket client connections
## - Server-Sent Events (SSE) streams

import std/[tables, base64]
when defined(wasm):
  type JsonNode* = ref object
else:
  import std/json
import ./dombridge
when not defined(wasm):
  import ./errors

type
  FetchResponseMode* = enum
    frmText,
    frmJson,
    frmBytes

  FetchHandle* = object
    id*: int32

  FetchResponse* = object
    status*: int
    statusText*: string
    body*: string
    json*: JsonNode
    bytes*: seq[byte]
    ok*: bool
    headers*: Table[string, string]

  FetchRequestOptions* = object
    responseMode*: FetchResponseMode

  FetchSuccessHandler* = proc(resp: FetchResponse) {.closure.}
  FetchErrorHandler* = proc(message: string) {.closure.}

  WebSocketOpenHandler* = proc() {.closure.}
  WebSocketMessageHandler* = proc(data: string) {.closure.}
  WebSocketCloseHandler* = proc(code: int, reason: string, wasClean: bool) {.closure.}
  WebSocketErrorHandler* = proc(message: string) {.closure.}

  SseOpenHandler* = proc() {.closure.}
  SseMessageHandler* = proc(eventName: string, data: string, lastEventId: string) {.closure.}
  SseErrorHandler* = proc(message: string) {.closure.}

  FetchPending = object
    onSuccess: FetchSuccessHandler
    onError: FetchErrorHandler
    responseMode: FetchResponseMode

  WebSocketPending = object
    onOpen: WebSocketOpenHandler
    onMessage: WebSocketMessageHandler
    onClose: WebSocketCloseHandler
    onError: WebSocketErrorHandler

  SsePending = object
    onOpen: SseOpenHandler
    onMessage: SseMessageHandler
    onError: SseErrorHandler

var
  nextNetId = 0'i32
  pendingFetch = initTable[int32, FetchPending]()
  pendingWebSockets = initTable[int32, WebSocketPending]()
  pendingSseStreams = initTable[int32, SsePending]()

proc runUserCallback(phase: string, cb: proc()) =
  if cb == nil:
    return
  when defined(wasm):
    cb()
  else:
    try:
      cb()
    except Exception as e:
      reportUiError(phase, e)

proc allocNetId(): int32 =
  inc nextNetId
  nextNetId

proc stringFromPtr(data: pointer, len: int32): string =
  if data == nil or len <= 0:
    return ""
  result = newString(len)
  copyMem(addr result[0], data, len)

proc encodePairsBlob(pairs: openArray[(string, string)]): string =
  for (key, value) in pairs:
    if key.len == 0:
      continue
    result.add(key)
    result.add('\0')
    result.add(value)
    result.add('\0')

proc decodePairsBlob(blob: string): Table[string, string] =
  result = initTable[string, string]()
  var i = 0
  while i < blob.len:
    let keyStart = i
    while i < blob.len and blob[i] != '\0':
      inc i
    if i >= blob.len:
      break
    let key = blob[keyStart ..< i]
    inc i

    let valueStart = i
    while i < blob.len and blob[i] != '\0':
      inc i
    let value =
      if valueStart < i:
        blob[valueStart ..< i]
      else:
        ""
    if key.len > 0:
      result[key] = value
    if i < blob.len:
      inc i

proc defaultFetchOptions*(): FetchRequestOptions =
  FetchRequestOptions(responseMode: frmText)

proc responseModeCode(mode: FetchResponseMode): int32 =
  case mode
  of frmText:
    0
  of frmJson:
    1
  of frmBytes:
    2

proc bytesFromBinaryString(binary: string): seq[byte] =
  result = newSeq[byte](binary.len)
  for i in 0 ..< binary.len:
    result[i] = byte(ord(binary[i]))

proc fetch*(
  url: string,
  onSuccess: FetchSuccessHandler,
  onError: FetchErrorHandler = nil,
  httpMethod = "GET",
  body = "",
  headers: seq[(string, string)] = @[],
  options: FetchRequestOptions = defaultFetchOptions()
): FetchHandle =
  let requestId = allocNetId()
  pendingFetch[requestId] = FetchPending(
    onSuccess: onSuccess,
    onError: onError,
    responseMode: options.responseMode
  )
  netFetchRequest(
    requestId,
    url,
    httpMethod,
    encodePairsBlob(headers),
    body,
    responseModeCode(options.responseMode)
  )
  FetchHandle(id: requestId)

converter fetchHandleToInt32*(handle: FetchHandle): int32 =
  handle.id

proc abortFetch*(handle: FetchHandle): bool

proc cancelFetch*(requestId: int32) =
  let handle = FetchHandle(id: requestId)
  discard abortFetch(handle)

proc abortFetch*(handle: FetchHandle): bool =
  if handle.id notin pendingFetch:
    return false
  pendingFetch.del(handle.id)
  netFetchAbort(handle.id)

proc abortFetch*(requestId: int32): bool =
  abortFetch(FetchHandle(id: requestId))

proc wsConnect*(
  url: string,
  onOpen: WebSocketOpenHandler = nil,
  onMessage: WebSocketMessageHandler = nil,
  onClose: WebSocketCloseHandler = nil,
  onError: WebSocketErrorHandler = nil
): int32 =
  let connectionId = allocNetId()
  pendingWebSockets[connectionId] = WebSocketPending(
    onOpen: onOpen,
    onMessage: onMessage,
    onClose: onClose,
    onError: onError
  )
  if not netWsConnect(connectionId, url):
    let pending = pendingWebSockets.getOrDefault(connectionId)
    pendingWebSockets.del(connectionId)
    runUserCallback("net-ws-connect", proc() =
      if pending.onError != nil:
        pending.onError("failed to initialize WebSocket connection")
    )
  connectionId

proc wsSend*(connectionId: int32, data: string): bool =
  if connectionId notin pendingWebSockets:
    return false
  netWsSend(connectionId, data)

proc wsClose*(connectionId: int32, code = 1000, reason = ""): bool =
  if connectionId notin pendingWebSockets:
    return false
  netWsClose(connectionId, code.int32, reason)

proc sseConnect*(
  url: string,
  onMessage: SseMessageHandler,
  onError: SseErrorHandler = nil,
  onOpen: SseOpenHandler = nil,
  withCredentials = false
): int32 =
  let streamId = allocNetId()
  pendingSseStreams[streamId] = SsePending(
    onOpen: onOpen,
    onMessage: onMessage,
    onError: onError
  )
  if not netSseConnect(streamId, url, withCredentials):
    let pending = pendingSseStreams.getOrDefault(streamId)
    pendingSseStreams.del(streamId)
    runUserCallback("net-sse-connect", proc() =
      if pending.onError != nil:
        pending.onError("failed to initialize EventSource stream")
    )
  streamId

proc sseClose*(streamId: int32): bool =
  if streamId notin pendingSseStreams:
    return false
  pendingSseStreams.del(streamId)
  netSseClose(streamId)

proc resetUiNetState*() =
  var wsIds: seq[int32] = @[]
  for id in pendingWebSockets.keys:
    wsIds.add(id)
  for id in wsIds:
    discard netWsClose(id, 1000)

  var sseIds: seq[int32] = @[]
  for id in pendingSseStreams.keys:
    sseIds.add(id)
  for id in sseIds:
    discard netSseClose(id)

  pendingFetch.clear()
  pendingWebSockets.clear()
  pendingSseStreams.clear()

proc nimui_net_fetch_resolve*(
  requestId: int32,
  status: int32,
  ok: int32,
  statusTextPtr: pointer,
  statusTextLen: int32,
  bodyPtr: pointer,
  bodyLen: int32,
  headersPtr: pointer,
  headersLen: int32
) {.exportc.} =
  if requestId notin pendingFetch:
    return
  let pending = pendingFetch[requestId]
  pendingFetch.del(requestId)

  let rawBody = stringFromPtr(bodyPtr, bodyLen)
  var response = FetchResponse(
    status: status.int,
    statusText: stringFromPtr(statusTextPtr, statusTextLen),
    body: "",
    json: nil,
    bytes: @[],
    ok: ok != 0,
    headers: decodePairsBlob(stringFromPtr(headersPtr, headersLen))
  )

  case pending.responseMode
  of frmText:
    response.body = rawBody
    response.bytes = bytesFromBinaryString(rawBody)
  of frmJson:
    response.body = rawBody
    response.bytes = bytesFromBinaryString(rawBody)
    when defined(wasm):
      response.json = nil
    else:
      if rawBody.len == 0:
        response.json = newJNull()
      else:
        try:
          response.json = parseJson(rawBody)
        except CatchableError as e:
          runUserCallback("net-fetch-json-parse", proc() =
            if pending.onError != nil:
              pending.onError("invalid JSON response: " & e.msg)
          )
          return
  of frmBytes:
    var decoded = ""
    if rawBody.len > 0:
      try:
        decoded = decode(rawBody)
      except CatchableError as e:
        runUserCallback("net-fetch-bytes-decode", proc() =
          if pending.onError != nil:
            pending.onError("invalid base64 bytes response: " & e.msg)
        )
        return
    response.body = decoded
    response.bytes = bytesFromBinaryString(decoded)

  runUserCallback("net-fetch-success", proc() =
    if pending.onSuccess != nil:
      pending.onSuccess(response)
  )

proc nimui_net_fetch_reject*(
  requestId: int32,
  errorPtr: pointer,
  errorLen: int32
) {.exportc.} =
  if requestId notin pendingFetch:
    return
  let pending = pendingFetch[requestId]
  pendingFetch.del(requestId)
  let message = stringFromPtr(errorPtr, errorLen)

  runUserCallback("net-fetch-error", proc() =
    if pending.onError != nil:
      pending.onError(message)
  )

proc nimui_net_ws_open*(connectionId: int32) {.exportc.} =
  if connectionId notin pendingWebSockets:
    return
  let pending = pendingWebSockets[connectionId]
  runUserCallback("net-ws-open", proc() =
    if pending.onOpen != nil:
      pending.onOpen()
  )

proc nimui_net_ws_message*(
  connectionId: int32,
  dataPtr: pointer,
  dataLen: int32
) {.exportc.} =
  if connectionId notin pendingWebSockets:
    return
  let pending = pendingWebSockets[connectionId]
  let data = stringFromPtr(dataPtr, dataLen)
  runUserCallback("net-ws-message", proc() =
    if pending.onMessage != nil:
      pending.onMessage(data)
  )

proc nimui_net_ws_error*(
  connectionId: int32,
  errorPtr: pointer,
  errorLen: int32
) {.exportc.} =
  if connectionId notin pendingWebSockets:
    return
  let pending = pendingWebSockets[connectionId]
  let message = stringFromPtr(errorPtr, errorLen)
  runUserCallback("net-ws-error", proc() =
    if pending.onError != nil:
      pending.onError(message)
  )

proc nimui_net_ws_closed*(
  connectionId: int32,
  code: int32,
  wasClean: int32,
  reasonPtr: pointer,
  reasonLen: int32
) {.exportc.} =
  if connectionId notin pendingWebSockets:
    return
  let pending = pendingWebSockets[connectionId]
  pendingWebSockets.del(connectionId)

  let reason = stringFromPtr(reasonPtr, reasonLen)
  runUserCallback("net-ws-close", proc() =
    if pending.onClose != nil:
      pending.onClose(code.int, reason, wasClean != 0)
  )

proc nimui_net_sse_open*(streamId: int32) {.exportc.} =
  if streamId notin pendingSseStreams:
    return
  let pending = pendingSseStreams[streamId]
  runUserCallback("net-sse-open", proc() =
    if pending.onOpen != nil:
      pending.onOpen()
  )

proc nimui_net_sse_message*(
  streamId: int32,
  eventNamePtr: pointer,
  eventNameLen: int32,
  dataPtr: pointer,
  dataLen: int32,
  lastEventIdPtr: pointer,
  lastEventIdLen: int32
) {.exportc.} =
  if streamId notin pendingSseStreams:
    return
  let pending = pendingSseStreams[streamId]
  let eventName = stringFromPtr(eventNamePtr, eventNameLen)
  let data = stringFromPtr(dataPtr, dataLen)
  let lastEventId = stringFromPtr(lastEventIdPtr, lastEventIdLen)

  runUserCallback("net-sse-message", proc() =
    if pending.onMessage != nil:
      pending.onMessage(eventName, data, lastEventId)
  )

proc nimui_net_sse_error*(
  streamId: int32,
  errorPtr: pointer,
  errorLen: int32
) {.exportc.} =
  if streamId notin pendingSseStreams:
    return
  let pending = pendingSseStreams[streamId]
  let message = stringFromPtr(errorPtr, errorLen)
  runUserCallback("net-sse-error", proc() =
    if pending.onError != nil:
      pending.onError(message)
  )

proc nimui_net_sse_closed*(streamId: int32) {.exportc.} =
  if streamId in pendingSseStreams:
    pendingSseStreams.del(streamId)
