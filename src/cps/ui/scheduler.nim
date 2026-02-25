## CPS UI Scheduler
##
## Coalesces multiple state updates into one render flush.

when defined(wasm):
  import ./dombridge

type
  UpdateLane* = enum
    ulSync,
    ulTransition,
    ulIdle

  FlushCallback* = proc(lane: UpdateLane) {.closure.}

var
  flushPending = false
  pendingLane = ulSync
  currentLane = ulSync
  pendingTransitionBatches = 0
  flushCallback: FlushCallback

proc laneRank(lane: UpdateLane): int =
  case lane
  of ulSync:
    0
  of ulTransition:
    1
  of ulIdle:
    2

proc pickHigherPriority(a, b: UpdateLane): UpdateLane =
  if laneRank(a) <= laneRank(b):
    a
  else:
    b

proc setFlushCallback*(cb: FlushCallback) =
  flushCallback = cb

proc isFlushPending*(): bool =
  flushPending

proc scheduledLane*(): UpdateLane =
  pendingLane

proc currentUpdateLane*(): UpdateLane =
  currentLane

proc hasPendingTransitions*(): bool =
  pendingTransitionBatches > 0

proc clearScheduledFlush*() =
  flushPending = false
  pendingLane = ulSync

proc requestFlush*(lane: UpdateLane) =
  if flushPending:
    pendingLane = pickHigherPriority(pendingLane, lane)
    return
  flushPending = true
  pendingLane = lane
  when defined(wasm):
    scheduleHostFlush()

proc requestFlush*() =
  requestFlush(currentLane)

proc startTransition*(work: proc() {.closure.}) =
  let prevLane = currentLane
  currentLane = ulTransition
  inc pendingTransitionBatches
  try:
    if work != nil:
      work()
  finally:
    currentLane = prevLane
  requestFlush(ulTransition)

proc notifyFlushCompleted*(lane: UpdateLane) =
  if pendingTransitionBatches <= 0:
    return
  if lane in {ulSync, ulTransition}:
    # A transition flush can coalesce multiple startTransition calls.
    # Clear the entire batch set in one commit so pending state cannot stick.
    pendingTransitionBatches = 0
    requestFlush(ulSync)

proc runScheduledFlush*() =
  if not flushPending:
    return
  let lane = pendingLane
  flushPending = false
  pendingLane = ulSync
  if flushCallback != nil:
    flushCallback(lane)
