import std/[tables, json, base64]
import cps/ui

proc ptrAndLen(s: string): tuple[p: pointer, n: int32] =
  if s.len == 0:
    return (nil, 0'i32)
  (cast[pointer](unsafeAddr s[0]), s.len.int32)

block testFetchCallbacks:
  var fetchStatus = ""
  var fetchBody = ""
  var fetchHeader = ""
  var fetchError = ""

  let okRequest = fetch(
    "/api/ping",
    onSuccess = proc(resp: FetchResponse) =
      fetchStatus = $resp.status & ":" & $resp.ok
      fetchBody = resp.body
      fetchHeader = resp.headers.getOrDefault("content-type", ""),
    onError = proc(message: string) =
      fetchError = message,
    httpMethod = "POST",
    body = "hello",
    headers = @[
      ("content-type", "text/plain"),
      ("x-test", "1")
    ]
  )

  var statusText = "Created"
  var responseBody = "pong"
  var responseHeaders = "content-type\0text/plain\0x-id\0" & "123\0"
  let statusBuf = ptrAndLen(statusText)
  let bodyBuf = ptrAndLen(responseBody)
  let headersBuf = ptrAndLen(responseHeaders)
  nimui_net_fetch_resolve(
    okRequest,
    201,
    1,
    statusBuf.p,
    statusBuf.n,
    bodyBuf.p,
    bodyBuf.n,
    headersBuf.p,
    headersBuf.n
  )

  assert fetchStatus == "201:true"
  assert fetchBody == "pong"
  assert fetchHeader == "text/plain"
  assert fetchError.len == 0

  let badRequest = fetch(
    "/api/ping",
    onSuccess = proc(resp: FetchResponse) = discard,
    onError = proc(message: string) =
      fetchError = message
  )
  var err = "network-down"
  let errBuf = ptrAndLen(err)
  nimui_net_fetch_reject(badRequest, errBuf.p, errBuf.n)
  assert fetchError == "network-down"

block testFetchAbortHandle:
  var onSuccessCalled = false
  var onErrorCalled = false

  let handle = fetch(
    "/api/slow",
    onSuccess = proc(resp: FetchResponse) =
      onSuccessCalled = true,
    onError = proc(message: string) =
      onErrorCalled = true
  )
  assert handle.id > 0
  assert abortFetch(handle)

  var err = "aborted"
  let errBuf = ptrAndLen(err)
  nimui_net_fetch_reject(handle.id, errBuf.p, errBuf.n)

  assert not onSuccessCalled
  assert not onErrorCalled

block testFetchResponseModesJsonAndBytes:
  var jsonMode = ""
  var jsonError = ""
  var bytesMode = ""
  var bytesError = ""

  let jsonRequest = fetch(
    "/api/json",
    onSuccess = proc(resp: FetchResponse) =
      let mode =
        if resp.json != nil and resp.json.kind == JObject and "mode" in resp.json:
          resp.json["mode"].getStr("")
        else:
          ""
      jsonMode = mode & ":" & $resp.ok,
    onError = proc(message: string) =
      jsonError = message,
    options = FetchRequestOptions(responseMode: frmJson)
  )

  var statusText = "OK"
  var jsonBody = """{"mode":"json"}"""
  let statusBuf = ptrAndLen(statusText)
  let jsonBuf = ptrAndLen(jsonBody)
  nimui_net_fetch_resolve(
    jsonRequest,
    200,
    1,
    statusBuf.p,
    statusBuf.n,
    jsonBuf.p,
    jsonBuf.n,
    nil,
    0
  )

  assert jsonMode == "json:true"
  assert jsonError.len == 0

  let bytesRequest = fetch(
    "/api/bytes",
    onSuccess = proc(resp: FetchResponse) =
      bytesMode = $resp.bytes.len & ":" & resp.body,
    onError = proc(message: string) =
      bytesError = message,
    options = FetchRequestOptions(responseMode: frmBytes)
  )

  var bytesBody = encode("abc")
  let bytesBuf = ptrAndLen(bytesBody)
  nimui_net_fetch_resolve(
    bytesRequest,
    200,
    1,
    statusBuf.p,
    statusBuf.n,
    bytesBuf.p,
    bytesBuf.n,
    nil,
    0
  )

  assert bytesMode == "3:abc"
  assert bytesError.len == 0

block testWebSocketCallbacksAndLifecycle:
  var opened = false
  var lastMessage = ""
  var lastError = ""
  var closeState = ""

  let wsId = wsConnect(
    "ws://127.0.0.1:8080/ws",
    onOpen = proc() = opened = true,
    onMessage = proc(data: string) = lastMessage = data,
    onClose = proc(code: int, reason: string, wasClean: bool) =
      closeState = $code & ":" & reason & ":" & $wasClean,
    onError = proc(message: string) = lastError = message
  )
  assert wsId > 0
  assert wsSend(wsId, "ping")

  nimui_net_ws_open(wsId)
  assert opened

  var wsData = "pong"
  let dataBuf = ptrAndLen(wsData)
  nimui_net_ws_message(wsId, dataBuf.p, dataBuf.n)
  assert lastMessage == "pong"

  var wsErr = "timeout"
  let errBuf = ptrAndLen(wsErr)
  nimui_net_ws_error(wsId, errBuf.p, errBuf.n)
  assert lastError == "timeout"

  var reason = "done"
  let reasonBuf = ptrAndLen(reason)
  nimui_net_ws_closed(wsId, 1000, 1, reasonBuf.p, reasonBuf.n)
  assert closeState == "1000:done:true"
  assert wsSend(wsId, "late") == false
  assert wsClose(wsId) == false

block testSseCallbacksAndLifecycle:
  var opened = false
  var lastEvent = ""
  var lastError = ""

  let streamId = sseConnect(
    "/events",
    onMessage = proc(eventName: string, data: string, lastEventId: string) =
      lastEvent = eventName & ":" & data & ":" & lastEventId,
    onError = proc(message: string) =
      lastError = message,
    onOpen = proc() =
      opened = true
  )
  assert streamId > 0

  nimui_net_sse_open(streamId)
  assert opened

  var eventName = "message"
  var eventData = "hello"
  var lastId = "42"
  let eventNameBuf = ptrAndLen(eventName)
  let eventDataBuf = ptrAndLen(eventData)
  let lastIdBuf = ptrAndLen(lastId)
  nimui_net_sse_message(
    streamId,
    eventNameBuf.p,
    eventNameBuf.n,
    eventDataBuf.p,
    eventDataBuf.n,
    lastIdBuf.p,
    lastIdBuf.n
  )
  assert lastEvent == "message:hello:42"

  var sseErr = "retrying"
  let sseErrBuf = ptrAndLen(sseErr)
  nimui_net_sse_error(streamId, sseErrBuf.p, sseErrBuf.n)
  assert lastError == "retrying"

  assert sseClose(streamId)
  nimui_net_sse_message(
    streamId,
    eventNameBuf.p,
    eventNameBuf.n,
    eventDataBuf.p,
    eventDataBuf.n,
    lastIdBuf.p,
    lastIdBuf.n
  )
  assert lastEvent == "message:hello:42"

block testResetStateClearsPendingConnections:
  let wsId = wsConnect("ws://127.0.0.1:8080/ws")
  let sseId = sseConnect("/events", onMessage = proc(eventName: string, data: string, lastEventId: string) = discard)

  resetUiNetState()

  assert wsSend(wsId, "x") == false
  assert wsClose(wsId) == false
  assert sseClose(sseId) == false

echo "PASS: ui net fetch/ws/sse callbacks and lifecycle behavior"
