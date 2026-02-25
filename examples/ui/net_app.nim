## UI networking sample app (fetch + WebSocket + SSE).
## Build:
##   scripts/build_ui_wasm.sh examples/ui/net_app.nim examples/ui/net_app.wasm

import std/strutils
import cps/ui

proc wsUrlForCurrentOrigin(path: string): string =
  let origin = locationOrigin()
  if origin.len == 0:
    return "ws://127.0.0.1:8080" & path
  if origin.startsWith("https://"):
    return "wss://" & origin["https://".len .. ^1] & path
  if origin.startsWith("http://"):
    return "ws://" & origin["http://".len .. ^1] & path
  origin & path

proc app(): VNode =
  let (fetchState, setFetchState) = useState("pending")
  let (fetchJsonState, setFetchJsonState) = useState("pending")
  let (fetchBytesState, setFetchBytesState) = useState("pending")
  let (wsState, setWsState) = useState("pending")
  let (sseState, setSseState) = useState("pending")
  let wsRef = useRef(0'i32)
  let sseRef = useRef(0'i32)

  useEffect(
    proc(): EffectCleanup =
      setFetchState("loading")
      discard fetch(
        "/api/net/fetch",
        onSuccess = proc(resp: FetchResponse) =
          setFetchState($resp.status & ":" & resp.body),
        onError = proc(message: string) =
          setFetchState("error:" & message),
        httpMethod = "POST",
        body = "ping",
        headers = @[("content-type", "text/plain")]
      )
      discard fetch(
        "/api/net/json",
        onSuccess = proc(resp: FetchResponse) =
          let modeOk =
            resp.body.contains("\"mode\":\"json\"") and
            resp.body.contains("\"ok\":true")
          setFetchJsonState("json:" & $modeOk),
        onError = proc(message: string) =
          setFetchJsonState("error:" & message),
        options = FetchRequestOptions(responseMode: frmJson)
      )
      discard fetch(
        "/api/net/bytes",
        onSuccess = proc(resp: FetchResponse) =
          setFetchBytesState($resp.bytes.len & ":" & resp.body),
        onError = proc(message: string) =
          setFetchBytesState("error:" & message),
        options = FetchRequestOptions(responseMode: frmBytes)
      )

      var wsId = 0'i32
      wsId = wsConnect(
        wsUrlForCurrentOrigin("/ws/net"),
        onOpen = (proc() =
          setWsState("open")
          discard wsSend(wsId, "hello")
        ),
        onMessage = (proc(data: string) =
          setWsState(data)
        ),
        onError = (proc(message: string) =
          setWsState("error:" & message)
        )
      )
      wsRef.current = wsId

      sseRef.current = sseConnect(
        "/events/net",
        onMessage = (proc(eventName: string, data: string, lastEventId: string) =
          setSseState(eventName & ":" & data & ":" & lastEventId)
          if sseRef.current != 0:
            discard sseClose(sseRef.current)
        ),
        onError = (proc(message: string) =
          setSseState("error:" & message)
        ),
        onOpen = (proc() =
          setSseState("open")
        )
      )

      proc() =
        if wsRef.current != 0:
          discard wsClose(wsRef.current)
        if sseRef.current != 0:
          discard sseClose(sseRef.current)
    ,
    deps(1)
  )

  ui:
    `div`(className="net-app", attr("data-testid", "net-app")):
      h1: text("Network test")
      p(attr("data-testid", "fetch-state")): text(fetchState)
      p(attr("data-testid", "fetch-json-state")): text(fetchJsonState)
      p(attr("data-testid", "fetch-bytes-state")): text(fetchBytesState)
      p(attr("data-testid", "ws-state")): text(wsState)
      p(attr("data-testid", "sse-state")): text(sseState)

setRootComponent(app)
