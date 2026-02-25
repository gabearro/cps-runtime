## CPS UI Error Handling
##
## Centralized runtime error reporting so event/effect/render failures can be
## surfaced without crashing the entire UI loop.

type
  UiErrorHandler* = proc(phase: string, message: string) {.closure.}

var
  uiErrorHandler: UiErrorHandler
  lastUiError*: string
  lastUiRuntimeEvent*: string
  lastUiHydrationError*: string

proc setUiErrorHandler*(handler: UiErrorHandler) =
  uiErrorHandler = handler

proc clearUiErrorHandler*() =
  uiErrorHandler = nil

proc clearLastUiError*() =
  lastUiError = ""

proc clearLastUiRuntimeEvent*() =
  lastUiRuntimeEvent = ""

proc clearLastUiHydrationError*() =
  lastUiHydrationError = ""

proc setLastUiRuntimeEvent*(payload: string) =
  lastUiRuntimeEvent = payload

proc setLastUiHydrationError*(payload: string) =
  lastUiHydrationError = payload

proc reportUiError*(phase: string, exc: ref Exception) =
  let message =
    if exc != nil and exc.msg.len > 0:
      exc.msg
    else:
      "unknown error"
  lastUiError = phase & ": " & message

  if uiErrorHandler != nil:
    uiErrorHandler(phase, message)
  else:
    when not defined(wasm):
      try:
        echo "CPS UI error [" & phase & "]: " & message
      except Exception:
        discard

proc reportUiError*(phase: string) =
  when defined(wasm):
    reportUiError(phase, nil)
  else:
    reportUiError(phase, getCurrentException())

proc nimui_last_error_len*(): int32 {.exportc, used.} =
  lastUiError.len.int32

proc nimui_copy_last_error*(dst: pointer, cap: int32): int32 {.exportc, used.} =
  if dst == nil or cap <= 0 or lastUiError.len == 0:
    return 0
  let n = min(lastUiError.len, cap.int - 1)
  copyMem(dst, unsafeAddr lastUiError[0], n)
  cast[ptr UncheckedArray[char]](dst)[n] = '\0'
  n.int32

proc nimui_clear_last_error*() {.exportc, used.} =
  clearLastUiError()

proc ui_last_runtime_event_len*(): int32 =
  lastUiRuntimeEvent.len.int32

proc ui_copy_last_runtime_event*(dst: pointer, cap: int32): int32 =
  if dst == nil or cap <= 0 or lastUiRuntimeEvent.len == 0:
    return 0
  let n = min(lastUiRuntimeEvent.len, cap.int - 1)
  copyMem(dst, unsafeAddr lastUiRuntimeEvent[0], n)
  cast[ptr UncheckedArray[char]](dst)[n] = '\0'
  n.int32

proc ui_last_hydration_error_len*(): int32 =
  lastUiHydrationError.len.int32

proc ui_copy_last_hydration_error*(dst: pointer, cap: int32): int32 =
  if dst == nil or cap <= 0 or lastUiHydrationError.len == 0:
    return 0
  let n = min(lastUiHydrationError.len, cap.int - 1)
  copyMem(dst, unsafeAddr lastUiHydrationError[0], n)
  cast[ptr UncheckedArray[char]](dst)[n] = '\0'
  n.int32

proc ui_set_last_hydration_error*(msgPtr: pointer, msgLen: int32) =
  if msgPtr == nil or msgLen <= 0:
    lastUiHydrationError = ""
    return
  var msg = newString(msgLen)
  copyMem(addr msg[0], msgPtr, msgLen)
  lastUiHydrationError = msg
