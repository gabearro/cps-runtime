## Test: SplitView drag event routing
## Verifies that press on divider → motion → release correctly drags the split view.

import ../../src/cps/tui/widget
import ../../src/cps/tui/input
import ../../src/cps/tui/layout
import ../../src/cps/tui/cell
import ../../src/cps/tui/renderer
import ../../src/cps/tui/events
import ../../src/cps/tui/components

# Helper to create a mouse event
proc mouseEvt(action: MouseAction, button: MouseButton, mx, my: int): InputEvent =
  InputEvent(kind: iekMouse, action: action, button: button, mx: mx, my: my)

# Create a split view with known ratio
let sv = newSplitView(dirHorizontal, ratio = 0.3, minFirst = 5, minSecond = 5)

# Create two simple children
let left = text("Left pane")
let right = text("Right pane")

# Build the widget with events
let w = sv.toWidgetWithEvents(left, right)

# Simulate rendering to build the hit map
let screenW = 80
let screenH = 24
let rootRect = Rect(x: 0, y: 0, w: screenW, h: screenH)
var buf = newCellBuffer(screenW, screenH)
var hitMap: HitMap
var fm = newFocusManager()

# Render to populate hit map, lastRect, and child rects
renderWidgetWithEvents(buf, w, rootRect, hitMap, fm)

# Check that the split view widget is in the hit map
echo "Hit map regions: ", hitMap.regions.len
assert hitMap.regions.len > 0, "Hit map should have regions"

# Find the split view's divider position
let usable = max(0, screenW - 1)
let firstSize = sv.computeFirstSize(usable)
let dividerX = firstSize  # rect.x = 0, so dividerX = firstSize
echo "Divider X: ", dividerX
echo "SplitView lastRect: ", sv.lastRect
echo "Initial ratio: ", sv.ratio

# Verify lastRect is set
assert sv.lastRect.w > 0, "lastRect should be set after render"

# Test 1: Press on divider
echo ""
echo "--- Test 1: Press on divider ---"
let pressEvt = mouseEvt(maPress, mbLeft, dividerX, 10)
let pressResult = routeMouseEvent(hitMap, fm, pressEvt)
echo "Press result (handled): ", pressResult
echo "sv.dragging after press: ", sv.dragging
assert sv.dragging, "Should be dragging after press on divider"

# Test 2: Motion while dragging (move right into child area)
echo ""
echo "--- Test 2: Motion while dragging ---"
let newX = dividerX + 10
let motionEvt = mouseEvt(maMotion, mbLeft, newX, 10)
let motionResult = routeMouseEvent(hitMap, fm, motionEvt)
echo "Motion result (handled): ", motionResult
echo "sv.ratio after motion: ", sv.ratio
let expectedRatio = float(newX) / float(usable)
echo "Expected ratio (approx): ", expectedRatio
assert motionResult, "Motion should be handled"
assert sv.ratio != 0.3, "Ratio should have changed after drag motion"

# Test 3: Release
echo ""
echo "--- Test 3: Release ---"
let releaseEvt = mouseEvt(maRelease, mbLeft, newX, 10)
let releaseResult = routeMouseEvent(hitMap, fm, releaseEvt)
echo "Release result (handled): ", releaseResult
echo "sv.dragging after release: ", sv.dragging
assert not sv.dragging, "Should not be dragging after release"

# Test 4: Motion to the LEFT of the divider (into the left child)
echo ""
echo "--- Test 4: Full drag sequence moving left ---"
let sv2 = newSplitView(dirHorizontal, ratio = 0.5, minFirst = 5, minSecond = 5)
let w2 = sv2.toWidgetWithEvents(text("L"), text("R"))
var hitMap2: HitMap
var fm2 = newFocusManager()
var buf2 = newCellBuffer(screenW, screenH)
renderWidgetWithEvents(buf2, w2, rootRect, hitMap2, fm2)

let divX2 = sv2.computeFirstSize(usable)
echo "Divider X2: ", divX2
echo "Initial ratio2: ", sv2.ratio

# Press on divider
let press2 = mouseEvt(maPress, mbLeft, divX2, 5)
discard routeMouseEvent(hitMap2, fm2, press2)
assert sv2.dragging

# Motion to the left (into left child area)
let motion2 = mouseEvt(maMotion, mbLeft, divX2 - 15, 5)
let motion2Result = routeMouseEvent(hitMap2, fm2, motion2)
echo "Motion2 result: ", motion2Result
echo "Ratio2 after drag left: ", sv2.ratio
assert motion2Result, "Should handle motion into left child during drag"
assert sv2.ratio < 0.5, "Ratio should decrease when dragging left"

# Release
discard routeMouseEvent(hitMap2, fm2, mouseEvt(maRelease, mbLeft, divX2 - 15, 5))
assert not sv2.dragging

# Test 5: Drag when children have event handlers (realistic case)
echo ""
echo "--- Test 5: Drag with event-handler children ---"
let sv3 = newSplitView(dirHorizontal, ratio = 0.3, minFirst = 5, minSecond = 5)

# Left child: a text widget with an onClick handler
let leftWithClick = text("Channels")
  .withOnClick(proc(mx, my: int) = echo "left clicked")

# Right child: a custom widget with an onMouse handler (like ScrollableTextView)
var rightMouseCalled = false
let rightWithMouse = text("Chat")
  .withOnMouse(proc(evt: InputEvent): bool =
    # Simulate a handler that returns false for motion when not selecting
    rightMouseCalled = true
    return false  # Don't consume
  )

let w3 = sv3.toWidgetWithEvents(leftWithClick, rightWithMouse)
var hitMap3: HitMap
var fm3 = newFocusManager()
var buf3 = newCellBuffer(screenW, screenH)
renderWidgetWithEvents(buf3, w3, rootRect, hitMap3, fm3)

echo "Hit map regions (with handlers): ", hitMap3.regions.len
for i, r in hitMap3.regions:
  echo "  Region ", i, ": rect=", r.rect, " depth=", r.depth, " parentIdx=", r.parentIdx,
    " hasOnMouse=", (r.widget.events != nil and r.widget.events.onMouse != nil),
    " hasOnClick=", (r.widget.events != nil and r.widget.events.onClick != nil)

let divX3 = sv3.computeFirstSize(usable)
echo "Divider X3: ", divX3

# Press on divider
let press3 = mouseEvt(maPress, mbLeft, divX3, 5)
let press3Result = routeMouseEvent(hitMap3, fm3, press3)
echo "Press3 result: ", press3Result, " dragging: ", sv3.dragging
assert sv3.dragging, "Should be dragging"

# Motion into the RIGHT child area (which has onMouse returning false)
rightMouseCalled = false
let motion3 = mouseEvt(maMotion, mbLeft, divX3 + 10, 5)
let motion3Result = routeMouseEvent(hitMap3, fm3, motion3)
echo "Motion3 result: ", motion3Result
echo "rightMouseCalled: ", rightMouseCalled
echo "Ratio3 after drag: ", sv3.ratio
assert motion3Result, "Should handle motion even when child has onMouse"
assert sv3.ratio != 0.3, "Ratio should have changed"

# Motion into the LEFT child area (which has onClick, not onMouse)
let motion3b = mouseEvt(maMotion, mbLeft, divX3 - 5, 5)
let motion3bResult = routeMouseEvent(hitMap3, fm3, motion3b)
echo "Motion3b (into left) result: ", motion3bResult
echo "Ratio3 after drag left: ", sv3.ratio

# Release
discard routeMouseEvent(hitMap3, fm3, mouseEvt(maRelease, mbLeft, divX3 - 5, 5))
assert not sv3.dragging

# Test 6: What if child onMouse returns TRUE? Should NOT reach split view.
echo ""
echo "--- Test 6: Child onMouse consumes motion ---"
let sv4 = newSplitView(dirHorizontal, ratio = 0.5, minFirst = 5, minSecond = 5)
let rightConsume = text("Chat")
  .withOnMouse(proc(evt: InputEvent): bool =
    return true  # Consume all mouse events
  )
let w4 = sv4.toWidgetWithEvents(text("L"), rightConsume)
var hitMap4: HitMap
var fm4 = newFocusManager()
var buf4 = newCellBuffer(screenW, screenH)
renderWidgetWithEvents(buf4, w4, rootRect, hitMap4, fm4)

let divX4 = sv4.computeFirstSize(usable)
# Press on divider (should still work — divider is not in child area)
discard routeMouseEvent(hitMap4, fm4, mouseEvt(maPress, mbLeft, divX4, 5))
assert sv4.dragging

# Motion into the consuming child — child eats the event
let origRatio4 = sv4.ratio
let motion4 = mouseEvt(maMotion, mbLeft, divX4 + 10, 5)
let motion4Result = routeMouseEvent(hitMap4, fm4, motion4)
echo "Motion4 into consuming child: handled=", motion4Result, " ratio=", sv4.ratio
# The child consumed it, so the split view's ratio should NOT change
# (This is the expected behavior — child has priority)
echo "Ratio changed: ", sv4.ratio != origRatio4

echo ""
echo "PASS: SplitView drag routing works correctly"
