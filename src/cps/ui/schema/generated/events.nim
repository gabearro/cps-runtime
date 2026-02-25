## Generated UI event metadata. Do not edit manually.

const domEventNamesByCode* = [
  "abort",
  "animationcancel",
  "animationend",
  "animationiteration",
  "animationstart",
  "auxclick",
  "beforeinput",
  "beforematch",
  "beforetoggle",
  "blur",
  "cancel",
  "canplay",
  "canplaythrough",
  "change",
  "click",
  "close",
  "compositionend",
  "compositionstart",
  "compositionupdate",
  "contextmenu",
  "copy",
  "cut",
  "dblclick",
  "drag",
  "dragend",
  "dragenter",
  "dragleave",
  "dragover",
  "dragstart",
  "drop",
  "durationchange",
  "emptied",
  "ended",
  "error",
  "focus",
  "focusin",
  "focusout",
  "formdata",
  "fullscreenchange",
  "fullscreenerror",
  "gotpointercapture",
  "hashchange",
  "input",
  "invalid",
  "keydown",
  "keypress",
  "keyup",
  "load",
  "loadeddata",
  "loadedmetadata",
  "loadstart",
  "lostpointercapture",
  "mousedown",
  "mouseenter",
  "mouseleave",
  "mousemove",
  "mouseout",
  "mouseover",
  "mouseup",
  "pagehide",
  "pageshow",
  "paste",
  "pause",
  "play",
  "playing",
  "pointercancel",
  "pointerdown",
  "pointerenter",
  "pointerleave",
  "pointermove",
  "pointerout",
  "pointerover",
  "pointerup",
  "popstate",
  "progress",
  "ratechange",
  "reset",
  "resize",
  "scroll",
  "scrollend",
  "securitypolicyviolation",
  "seeked",
  "seeking",
  "select",
  "selectionchange",
  "selectstart",
  "slotchange",
  "stalled",
  "submit",
  "suspend",
  "timeupdate",
  "toggle",
  "touchcancel",
  "touchend",
  "touchmove",
  "touchstart",
  "transitioncancel",
  "transitionend",
  "transitionrun",
  "transitionstart",
  "visibilitychange",
  "volumechange",
  "waiting",
  "wheel",
]

const dslEventNames* = [
  "onAbort",
  "onAnimationCancel",
  "onAnimationEnd",
  "onAnimationIteration",
  "onAnimationStart",
  "onAuxClick",
  "onBeforeInput",
  "onBeforeMatch",
  "onBeforeToggle",
  "onBlur",
  "onCancel",
  "onCanPlay",
  "onCanPlayThrough",
  "onChange",
  "onClick",
  "onClose",
  "onCompositionEnd",
  "onCompositionStart",
  "onCompositionUpdate",
  "onContextMenu",
  "onCopy",
  "onCut",
  "onDblClick",
  "onDoubleClick",
  "onDrag",
  "onDragEnd",
  "onDragEnter",
  "onDragLeave",
  "onDragOver",
  "onDragStart",
  "onDrop",
  "onDurationChange",
  "onEmptied",
  "onEnded",
  "onError",
  "onFocus",
  "onFocusIn",
  "onFocusOut",
  "onFormData",
  "onFullScreenChange",
  "onFullScreenError",
  "onGotPointerCapture",
  "onHashChange",
  "onInput",
  "onInvalid",
  "onKeyDown",
  "onKeyPress",
  "onKeyUp",
  "onLoad",
  "onLoadedData",
  "onLoadedMetadata",
  "onLoadStart",
  "onLostPointerCapture",
  "onMouseDown",
  "onMouseEnter",
  "onMouseLeave",
  "onMouseMove",
  "onMouseOut",
  "onMouseOver",
  "onMouseUp",
  "onPageHide",
  "onPageShow",
  "onPaste",
  "onPause",
  "onPlay",
  "onPlaying",
  "onPointerCancel",
  "onPointerDown",
  "onPointerEnter",
  "onPointerLeave",
  "onPointerMove",
  "onPointerOut",
  "onPointerOver",
  "onPointerUp",
  "onPopState",
  "onProgress",
  "onRateChange",
  "onReset",
  "onResize",
  "onScroll",
  "onScrollEnd",
  "onSecurityPolicyViolation",
  "onSeeked",
  "onSeeking",
  "onSelect",
  "onSelectionChange",
  "onSelectStart",
  "onSlotChange",
  "onStalled",
  "onSubmit",
  "onSuspend",
  "onTimeUpdate",
  "onToggle",
  "onTouchCancel",
  "onTouchEnd",
  "onTouchMove",
  "onTouchStart",
  "onTransitionCancel",
  "onTransitionEnd",
  "onTransitionRun",
  "onTransitionStart",
  "onVisibilityChange",
  "onVolumeChange",
  "onWaiting",
  "onWheel",
]

proc eventDomNameByCode*(code: int32): string =
  if code < 0 or code >= domEventNamesByCode.len.int32:
    return domEventNamesByCode[0]
  domEventNamesByCode[code]

proc dslEventLookup*(name: string, eventId: var string, capture: var bool): bool {.compileTime.} =
  case name
  of "onAbort":
    eventId = "etAbort"
    capture = false
    true
  of "onAbortCapture":
    eventId = "etAbort"
    capture = true
    true
  of "onAnimationCancel":
    eventId = "etAnimationCancel"
    capture = false
    true
  of "onAnimationCancelCapture":
    eventId = "etAnimationCancel"
    capture = true
    true
  of "onAnimationEnd":
    eventId = "etAnimationEnd"
    capture = false
    true
  of "onAnimationEndCapture":
    eventId = "etAnimationEnd"
    capture = true
    true
  of "onAnimationIteration":
    eventId = "etAnimationIteration"
    capture = false
    true
  of "onAnimationIterationCapture":
    eventId = "etAnimationIteration"
    capture = true
    true
  of "onAnimationStart":
    eventId = "etAnimationStart"
    capture = false
    true
  of "onAnimationStartCapture":
    eventId = "etAnimationStart"
    capture = true
    true
  of "onAuxClick":
    eventId = "etAuxClick"
    capture = false
    true
  of "onAuxClickCapture":
    eventId = "etAuxClick"
    capture = true
    true
  of "onBeforeInput":
    eventId = "etBeforeInput"
    capture = false
    true
  of "onBeforeInputCapture":
    eventId = "etBeforeInput"
    capture = true
    true
  of "onBeforeMatch":
    eventId = "etBeforeMatch"
    capture = false
    true
  of "onBeforeMatchCapture":
    eventId = "etBeforeMatch"
    capture = true
    true
  of "onBeforeToggle":
    eventId = "etBeforeToggle"
    capture = false
    true
  of "onBeforeToggleCapture":
    eventId = "etBeforeToggle"
    capture = true
    true
  of "onBlur":
    eventId = "etBlur"
    capture = false
    true
  of "onBlurCapture":
    eventId = "etBlur"
    capture = true
    true
  of "onCancel":
    eventId = "etCancel"
    capture = false
    true
  of "onCancelCapture":
    eventId = "etCancel"
    capture = true
    true
  of "onCanPlay":
    eventId = "etCanPlay"
    capture = false
    true
  of "onCanPlayCapture":
    eventId = "etCanPlay"
    capture = true
    true
  of "onCanPlayThrough":
    eventId = "etCanPlayThrough"
    capture = false
    true
  of "onCanPlayThroughCapture":
    eventId = "etCanPlayThrough"
    capture = true
    true
  of "onChange":
    eventId = "etChange"
    capture = false
    true
  of "onChangeCapture":
    eventId = "etChange"
    capture = true
    true
  of "onClick":
    eventId = "etClick"
    capture = false
    true
  of "onClickCapture":
    eventId = "etClick"
    capture = true
    true
  of "onClose":
    eventId = "etClose"
    capture = false
    true
  of "onCloseCapture":
    eventId = "etClose"
    capture = true
    true
  of "onCompositionEnd":
    eventId = "etCompositionEnd"
    capture = false
    true
  of "onCompositionEndCapture":
    eventId = "etCompositionEnd"
    capture = true
    true
  of "onCompositionStart":
    eventId = "etCompositionStart"
    capture = false
    true
  of "onCompositionStartCapture":
    eventId = "etCompositionStart"
    capture = true
    true
  of "onCompositionUpdate":
    eventId = "etCompositionUpdate"
    capture = false
    true
  of "onCompositionUpdateCapture":
    eventId = "etCompositionUpdate"
    capture = true
    true
  of "onContextMenu":
    eventId = "etContextMenu"
    capture = false
    true
  of "onContextMenuCapture":
    eventId = "etContextMenu"
    capture = true
    true
  of "onCopy":
    eventId = "etCopy"
    capture = false
    true
  of "onCopyCapture":
    eventId = "etCopy"
    capture = true
    true
  of "onCut":
    eventId = "etCut"
    capture = false
    true
  of "onCutCapture":
    eventId = "etCut"
    capture = true
    true
  of "onDblClick":
    eventId = "etDblClick"
    capture = false
    true
  of "onDblClickCapture":
    eventId = "etDblClick"
    capture = true
    true
  of "onDoubleClick":
    eventId = "etDblClick"
    capture = false
    true
  of "onDoubleClickCapture":
    eventId = "etDblClick"
    capture = true
    true
  of "onDrag":
    eventId = "etDrag"
    capture = false
    true
  of "onDragCapture":
    eventId = "etDrag"
    capture = true
    true
  of "onDragEnd":
    eventId = "etDragEnd"
    capture = false
    true
  of "onDragEndCapture":
    eventId = "etDragEnd"
    capture = true
    true
  of "onDragEnter":
    eventId = "etDragEnter"
    capture = false
    true
  of "onDragEnterCapture":
    eventId = "etDragEnter"
    capture = true
    true
  of "onDragLeave":
    eventId = "etDragLeave"
    capture = false
    true
  of "onDragLeaveCapture":
    eventId = "etDragLeave"
    capture = true
    true
  of "onDragOver":
    eventId = "etDragOver"
    capture = false
    true
  of "onDragOverCapture":
    eventId = "etDragOver"
    capture = true
    true
  of "onDragStart":
    eventId = "etDragStart"
    capture = false
    true
  of "onDragStartCapture":
    eventId = "etDragStart"
    capture = true
    true
  of "onDrop":
    eventId = "etDrop"
    capture = false
    true
  of "onDropCapture":
    eventId = "etDrop"
    capture = true
    true
  of "onDurationChange":
    eventId = "etDurationChange"
    capture = false
    true
  of "onDurationChangeCapture":
    eventId = "etDurationChange"
    capture = true
    true
  of "onEmptied":
    eventId = "etEmptied"
    capture = false
    true
  of "onEmptiedCapture":
    eventId = "etEmptied"
    capture = true
    true
  of "onEnded":
    eventId = "etEnded"
    capture = false
    true
  of "onEndedCapture":
    eventId = "etEnded"
    capture = true
    true
  of "onError":
    eventId = "etError"
    capture = false
    true
  of "onErrorCapture":
    eventId = "etError"
    capture = true
    true
  of "onFocus":
    eventId = "etFocus"
    capture = false
    true
  of "onFocusCapture":
    eventId = "etFocus"
    capture = true
    true
  of "onFocusIn":
    eventId = "etFocusIn"
    capture = false
    true
  of "onFocusInCapture":
    eventId = "etFocusIn"
    capture = true
    true
  of "onFocusOut":
    eventId = "etFocusOut"
    capture = false
    true
  of "onFocusOutCapture":
    eventId = "etFocusOut"
    capture = true
    true
  of "onFormData":
    eventId = "etFormData"
    capture = false
    true
  of "onFormDataCapture":
    eventId = "etFormData"
    capture = true
    true
  of "onFullScreenChange":
    eventId = "etFullScreenChange"
    capture = false
    true
  of "onFullScreenChangeCapture":
    eventId = "etFullScreenChange"
    capture = true
    true
  of "onFullScreenError":
    eventId = "etFullScreenError"
    capture = false
    true
  of "onFullScreenErrorCapture":
    eventId = "etFullScreenError"
    capture = true
    true
  of "onGotPointerCapture":
    eventId = "etGotPointerCapture"
    capture = false
    true
  of "onGotPointerCaptureCapture":
    eventId = "etGotPointerCapture"
    capture = true
    true
  of "onHashChange":
    eventId = "etHashChange"
    capture = false
    true
  of "onHashChangeCapture":
    eventId = "etHashChange"
    capture = true
    true
  of "onInput":
    eventId = "etInput"
    capture = false
    true
  of "onInputCapture":
    eventId = "etInput"
    capture = true
    true
  of "onInvalid":
    eventId = "etInvalid"
    capture = false
    true
  of "onInvalidCapture":
    eventId = "etInvalid"
    capture = true
    true
  of "onKeyDown":
    eventId = "etKeyDown"
    capture = false
    true
  of "onKeyDownCapture":
    eventId = "etKeyDown"
    capture = true
    true
  of "onKeyPress":
    eventId = "etKeyPress"
    capture = false
    true
  of "onKeyPressCapture":
    eventId = "etKeyPress"
    capture = true
    true
  of "onKeyUp":
    eventId = "etKeyUp"
    capture = false
    true
  of "onKeyUpCapture":
    eventId = "etKeyUp"
    capture = true
    true
  of "onLoad":
    eventId = "etLoad"
    capture = false
    true
  of "onLoadCapture":
    eventId = "etLoad"
    capture = true
    true
  of "onLoadedData":
    eventId = "etLoadedData"
    capture = false
    true
  of "onLoadedDataCapture":
    eventId = "etLoadedData"
    capture = true
    true
  of "onLoadedMetadata":
    eventId = "etLoadedMetadata"
    capture = false
    true
  of "onLoadedMetadataCapture":
    eventId = "etLoadedMetadata"
    capture = true
    true
  of "onLoadStart":
    eventId = "etLoadStart"
    capture = false
    true
  of "onLoadStartCapture":
    eventId = "etLoadStart"
    capture = true
    true
  of "onLostPointerCapture":
    eventId = "etLostPointerCapture"
    capture = false
    true
  of "onLostPointerCaptureCapture":
    eventId = "etLostPointerCapture"
    capture = true
    true
  of "onMouseDown":
    eventId = "etMouseDown"
    capture = false
    true
  of "onMouseDownCapture":
    eventId = "etMouseDown"
    capture = true
    true
  of "onMouseEnter":
    eventId = "etMouseEnter"
    capture = false
    true
  of "onMouseEnterCapture":
    eventId = "etMouseEnter"
    capture = true
    true
  of "onMouseLeave":
    eventId = "etMouseLeave"
    capture = false
    true
  of "onMouseLeaveCapture":
    eventId = "etMouseLeave"
    capture = true
    true
  of "onMouseMove":
    eventId = "etMouseMove"
    capture = false
    true
  of "onMouseMoveCapture":
    eventId = "etMouseMove"
    capture = true
    true
  of "onMouseOut":
    eventId = "etMouseOut"
    capture = false
    true
  of "onMouseOutCapture":
    eventId = "etMouseOut"
    capture = true
    true
  of "onMouseOver":
    eventId = "etMouseOver"
    capture = false
    true
  of "onMouseOverCapture":
    eventId = "etMouseOver"
    capture = true
    true
  of "onMouseUp":
    eventId = "etMouseUp"
    capture = false
    true
  of "onMouseUpCapture":
    eventId = "etMouseUp"
    capture = true
    true
  of "onPageHide":
    eventId = "etPageHide"
    capture = false
    true
  of "onPageHideCapture":
    eventId = "etPageHide"
    capture = true
    true
  of "onPageShow":
    eventId = "etPageShow"
    capture = false
    true
  of "onPageShowCapture":
    eventId = "etPageShow"
    capture = true
    true
  of "onPaste":
    eventId = "etPaste"
    capture = false
    true
  of "onPasteCapture":
    eventId = "etPaste"
    capture = true
    true
  of "onPause":
    eventId = "etPause"
    capture = false
    true
  of "onPauseCapture":
    eventId = "etPause"
    capture = true
    true
  of "onPlay":
    eventId = "etPlay"
    capture = false
    true
  of "onPlayCapture":
    eventId = "etPlay"
    capture = true
    true
  of "onPlaying":
    eventId = "etPlaying"
    capture = false
    true
  of "onPlayingCapture":
    eventId = "etPlaying"
    capture = true
    true
  of "onPointerCancel":
    eventId = "etPointerCancel"
    capture = false
    true
  of "onPointerCancelCapture":
    eventId = "etPointerCancel"
    capture = true
    true
  of "onPointerDown":
    eventId = "etPointerDown"
    capture = false
    true
  of "onPointerDownCapture":
    eventId = "etPointerDown"
    capture = true
    true
  of "onPointerEnter":
    eventId = "etPointerEnter"
    capture = false
    true
  of "onPointerEnterCapture":
    eventId = "etPointerEnter"
    capture = true
    true
  of "onPointerLeave":
    eventId = "etPointerLeave"
    capture = false
    true
  of "onPointerLeaveCapture":
    eventId = "etPointerLeave"
    capture = true
    true
  of "onPointerMove":
    eventId = "etPointerMove"
    capture = false
    true
  of "onPointerMoveCapture":
    eventId = "etPointerMove"
    capture = true
    true
  of "onPointerOut":
    eventId = "etPointerOut"
    capture = false
    true
  of "onPointerOutCapture":
    eventId = "etPointerOut"
    capture = true
    true
  of "onPointerOver":
    eventId = "etPointerOver"
    capture = false
    true
  of "onPointerOverCapture":
    eventId = "etPointerOver"
    capture = true
    true
  of "onPointerUp":
    eventId = "etPointerUp"
    capture = false
    true
  of "onPointerUpCapture":
    eventId = "etPointerUp"
    capture = true
    true
  of "onPopState":
    eventId = "etPopState"
    capture = false
    true
  of "onPopStateCapture":
    eventId = "etPopState"
    capture = true
    true
  of "onProgress":
    eventId = "etProgress"
    capture = false
    true
  of "onProgressCapture":
    eventId = "etProgress"
    capture = true
    true
  of "onRateChange":
    eventId = "etRateChange"
    capture = false
    true
  of "onRateChangeCapture":
    eventId = "etRateChange"
    capture = true
    true
  of "onReset":
    eventId = "etReset"
    capture = false
    true
  of "onResetCapture":
    eventId = "etReset"
    capture = true
    true
  of "onResize":
    eventId = "etResize"
    capture = false
    true
  of "onResizeCapture":
    eventId = "etResize"
    capture = true
    true
  of "onScroll":
    eventId = "etScroll"
    capture = false
    true
  of "onScrollCapture":
    eventId = "etScroll"
    capture = true
    true
  of "onScrollEnd":
    eventId = "etScrollEnd"
    capture = false
    true
  of "onScrollEndCapture":
    eventId = "etScrollEnd"
    capture = true
    true
  of "onSecurityPolicyViolation":
    eventId = "etSecurityPolicyViolation"
    capture = false
    true
  of "onSecurityPolicyViolationCapture":
    eventId = "etSecurityPolicyViolation"
    capture = true
    true
  of "onSeeked":
    eventId = "etSeeked"
    capture = false
    true
  of "onSeekedCapture":
    eventId = "etSeeked"
    capture = true
    true
  of "onSeeking":
    eventId = "etSeeking"
    capture = false
    true
  of "onSeekingCapture":
    eventId = "etSeeking"
    capture = true
    true
  of "onSelect":
    eventId = "etSelect"
    capture = false
    true
  of "onSelectCapture":
    eventId = "etSelect"
    capture = true
    true
  of "onSelectionChange":
    eventId = "etSelectionChange"
    capture = false
    true
  of "onSelectionChangeCapture":
    eventId = "etSelectionChange"
    capture = true
    true
  of "onSelectStart":
    eventId = "etSelectStart"
    capture = false
    true
  of "onSelectStartCapture":
    eventId = "etSelectStart"
    capture = true
    true
  of "onSlotChange":
    eventId = "etSlotChange"
    capture = false
    true
  of "onSlotChangeCapture":
    eventId = "etSlotChange"
    capture = true
    true
  of "onStalled":
    eventId = "etStalled"
    capture = false
    true
  of "onStalledCapture":
    eventId = "etStalled"
    capture = true
    true
  of "onSubmit":
    eventId = "etSubmit"
    capture = false
    true
  of "onSubmitCapture":
    eventId = "etSubmit"
    capture = true
    true
  of "onSuspend":
    eventId = "etSuspend"
    capture = false
    true
  of "onSuspendCapture":
    eventId = "etSuspend"
    capture = true
    true
  of "onTimeUpdate":
    eventId = "etTimeUpdate"
    capture = false
    true
  of "onTimeUpdateCapture":
    eventId = "etTimeUpdate"
    capture = true
    true
  of "onToggle":
    eventId = "etToggle"
    capture = false
    true
  of "onToggleCapture":
    eventId = "etToggle"
    capture = true
    true
  of "onTouchCancel":
    eventId = "etTouchCancel"
    capture = false
    true
  of "onTouchCancelCapture":
    eventId = "etTouchCancel"
    capture = true
    true
  of "onTouchEnd":
    eventId = "etTouchEnd"
    capture = false
    true
  of "onTouchEndCapture":
    eventId = "etTouchEnd"
    capture = true
    true
  of "onTouchMove":
    eventId = "etTouchMove"
    capture = false
    true
  of "onTouchMoveCapture":
    eventId = "etTouchMove"
    capture = true
    true
  of "onTouchStart":
    eventId = "etTouchStart"
    capture = false
    true
  of "onTouchStartCapture":
    eventId = "etTouchStart"
    capture = true
    true
  of "onTransitionCancel":
    eventId = "etTransitionCancel"
    capture = false
    true
  of "onTransitionCancelCapture":
    eventId = "etTransitionCancel"
    capture = true
    true
  of "onTransitionEnd":
    eventId = "etTransitionEnd"
    capture = false
    true
  of "onTransitionEndCapture":
    eventId = "etTransitionEnd"
    capture = true
    true
  of "onTransitionRun":
    eventId = "etTransitionRun"
    capture = false
    true
  of "onTransitionRunCapture":
    eventId = "etTransitionRun"
    capture = true
    true
  of "onTransitionStart":
    eventId = "etTransitionStart"
    capture = false
    true
  of "onTransitionStartCapture":
    eventId = "etTransitionStart"
    capture = true
    true
  of "onVisibilityChange":
    eventId = "etVisibilityChange"
    capture = false
    true
  of "onVisibilityChangeCapture":
    eventId = "etVisibilityChange"
    capture = true
    true
  of "onVolumeChange":
    eventId = "etVolumeChange"
    capture = false
    true
  of "onVolumeChangeCapture":
    eventId = "etVolumeChange"
    capture = true
    true
  of "onWaiting":
    eventId = "etWaiting"
    capture = false
    true
  of "onWaitingCapture":
    eventId = "etWaiting"
    capture = true
    true
  of "onWheel":
    eventId = "etWheel"
    capture = false
    true
  of "onWheelCapture":
    eventId = "etWheel"
    capture = true
    true
  else:
    false

proc isKnownDslEventName*(name: string): bool {.compileTime.} =
  var eventId = ""
  var capture = false
  dslEventLookup(name, eventId, capture)

proc eventIdFromName*(name: string): int32 =
  case name
  of "etAbort": 0.int32
  of "etAnimationCancel": 1.int32
  of "etAnimationEnd": 2.int32
  of "etAnimationIteration": 3.int32
  of "etAnimationStart": 4.int32
  of "etAuxClick": 5.int32
  of "etBeforeInput": 6.int32
  of "etBeforeMatch": 7.int32
  of "etBeforeToggle": 8.int32
  of "etBlur": 9.int32
  of "etCancel": 10.int32
  of "etCanPlay": 11.int32
  of "etCanPlayThrough": 12.int32
  of "etChange": 13.int32
  of "etClick": 14.int32
  of "etClose": 15.int32
  of "etCompositionEnd": 16.int32
  of "etCompositionStart": 17.int32
  of "etCompositionUpdate": 18.int32
  of "etContextMenu": 19.int32
  of "etCopy": 20.int32
  of "etCut": 21.int32
  of "etDblClick": 22.int32
  of "etDrag": 23.int32
  of "etDragEnd": 24.int32
  of "etDragEnter": 25.int32
  of "etDragLeave": 26.int32
  of "etDragOver": 27.int32
  of "etDragStart": 28.int32
  of "etDrop": 29.int32
  of "etDurationChange": 30.int32
  of "etEmptied": 31.int32
  of "etEnded": 32.int32
  of "etError": 33.int32
  of "etFocus": 34.int32
  of "etFocusIn": 35.int32
  of "etFocusOut": 36.int32
  of "etFormData": 37.int32
  of "etFullScreenChange": 38.int32
  of "etFullScreenError": 39.int32
  of "etGotPointerCapture": 40.int32
  of "etHashChange": 41.int32
  of "etInput": 42.int32
  of "etInvalid": 43.int32
  of "etKeyDown": 44.int32
  of "etKeyPress": 45.int32
  of "etKeyUp": 46.int32
  of "etLoad": 47.int32
  of "etLoadedData": 48.int32
  of "etLoadedMetadata": 49.int32
  of "etLoadStart": 50.int32
  of "etLostPointerCapture": 51.int32
  of "etMouseDown": 52.int32
  of "etMouseEnter": 53.int32
  of "etMouseLeave": 54.int32
  of "etMouseMove": 55.int32
  of "etMouseOut": 56.int32
  of "etMouseOver": 57.int32
  of "etMouseUp": 58.int32
  of "etPageHide": 59.int32
  of "etPageShow": 60.int32
  of "etPaste": 61.int32
  of "etPause": 62.int32
  of "etPlay": 63.int32
  of "etPlaying": 64.int32
  of "etPointerCancel": 65.int32
  of "etPointerDown": 66.int32
  of "etPointerEnter": 67.int32
  of "etPointerLeave": 68.int32
  of "etPointerMove": 69.int32
  of "etPointerOut": 70.int32
  of "etPointerOver": 71.int32
  of "etPointerUp": 72.int32
  of "etPopState": 73.int32
  of "etProgress": 74.int32
  of "etRateChange": 75.int32
  of "etReset": 76.int32
  of "etResize": 77.int32
  of "etScroll": 78.int32
  of "etScrollEnd": 79.int32
  of "etSecurityPolicyViolation": 80.int32
  of "etSeeked": 81.int32
  of "etSeeking": 82.int32
  of "etSelect": 83.int32
  of "etSelectionChange": 84.int32
  of "etSelectStart": 85.int32
  of "etSlotChange": 86.int32
  of "etStalled": 87.int32
  of "etSubmit": 88.int32
  of "etSuspend": 89.int32
  of "etTimeUpdate": 90.int32
  of "etToggle": 91.int32
  of "etTouchCancel": 92.int32
  of "etTouchEnd": 93.int32
  of "etTouchMove": 94.int32
  of "etTouchStart": 95.int32
  of "etTransitionCancel": 96.int32
  of "etTransitionEnd": 97.int32
  of "etTransitionRun": 98.int32
  of "etTransitionStart": 99.int32
  of "etVisibilityChange": 100.int32
  of "etVolumeChange": 101.int32
  of "etWaiting": 102.int32
  of "etWheel": 103.int32
  else: 0'i32
