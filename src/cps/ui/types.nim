## CPS UI Types
##
## Core frontend types shared across DSL, runtime, hooks, and reconciler.

import std/[parseutils, strutils, tables]
import ./schema/generated/events

include "schema/generated/event_type.nim"

type
  VNodeKind* = enum
    vkElement, vkText, vkFragment, vkComponent, vkPortal, vkErrorBoundary, vkSuspense, vkContextProvider, vkRouterOutlet

  EventOptions* = object
    capture*: bool
    passive*: bool
    `once`*: bool

  VAttrKind* = enum
    vakAttr, vakProp, vakStyle

  UiEvent* = object
    eventType*: EventType
    targetId*: int32
    currentTargetId*: int32
    value*: string
    key*: string
    checked*: bool
    ctrlKey*: bool
    altKey*: bool
    shiftKey*: bool
    metaKey*: bool
    clientX*: int32
    clientY*: int32
    button*: int32
    defaultPrevented*: bool
    propagationStopped*: bool
    capturePhase*: bool
    extras*: Table[string, string]

  EffectCleanup* = proc() {.closure.}
  EffectProc* = proc(): EffectCleanup {.closure.}

  LazyStatus* = enum
    lzsPending,
    lzsReady,
    lzsError

  LazyHandle* = ref object
    status*: LazyStatus
    render*: proc(): VNode {.closure.}
    error*: string

  LazyPendingError* = object of CatchableError

  VAttr* = object
    kind*: VAttrKind
    name*: string
    value*: string

  VEventHandler* = proc(ev: var UiEvent) {.closure.}

  VEventBinding* = object
    eventType*: EventType
    handler*: VEventHandler
    options*: EventOptions

  VNode* = ref object
    kind*: VNodeKind
    tag*: string
    key*: string
    text*: string
    attrs*: seq[VAttr]
    events*: seq[VEventBinding]
    children*: seq[VNode]
    componentId*: int32
    portalSelector*: string
    componentType*: string
    domId*: int32
    renderFn*: proc(): VNode {.closure.}
    errorFallback*: proc(msg: string): VNode {.closure.}
    errorMessage*: string
    suspenseFallback*: VNode
    contextId*: int32
    contextValue*: ref RootObj

  ComponentProc* = proc(): VNode {.closure.}

proc preventDefault*(ev: var UiEvent) =
  ev.defaultPrevented = true

proc stopPropagation*(ev: var UiEvent) =
  ev.propagationStopped = true

proc eventOptionsMask*(options: EventOptions): int32 =
  var resultMask = 0'i32
  if options.capture:
    resultMask = resultMask or 1
  if options.passive:
    resultMask = resultMask or 2
  if options.`once`:
    resultMask = resultMask or 4
  resultMask

proc eventOptionsFromMask*(mask: int32): EventOptions =
  EventOptions(
    capture: (mask and 1) != 0,
    passive: (mask and 2) != 0,
    `once`: (mask and 4) != 0
  )

converter toVarEventHandler*(handler: proc(ev: UiEvent) {.closure.}): VEventHandler =
  proc wrapped(ev: var UiEvent) =
    handler(ev)
  wrapped

proc eventTypeName*(kind: EventType): string =
  eventDomNameByCode(ord(kind).int32)

proc eventTypeCode*(kind: EventType): int32 =
  ord(kind).int32

proc eventTypeFromCode*(code: int32): EventType =
  if code < 0 or code > ord(high(EventType)).int32:
    return low(EventType)
  EventType(code)

proc eventExtra*(ev: UiEvent, key: string, `default` = ""): string =
  if key in ev.extras:
    return ev.extras[key]
  `default`

proc eventExtraInt*(ev: UiEvent, key: string, `default` = 0): int =
  let raw = eventExtra(ev, key, "")
  if raw.len == 0:
    return `default`
  var parsed = 0
  if parseInt(raw, parsed) == raw.len:
    return parsed
  `default`

proc eventExtraBool*(ev: UiEvent, key: string, `default` = false): bool =
  let raw = eventExtra(ev, key, "").toLowerAscii()
  case raw
  of "1", "true", "yes", "on":
    true
  of "0", "false", "no", "off":
    false
  else:
    `default`
