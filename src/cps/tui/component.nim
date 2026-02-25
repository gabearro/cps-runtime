## CPS TUI - Component Model
##
## A component is a function that returns a Widget, with persistent state
## stored in a ComponentState object. Components survive across render frames
## — their state is keyed by a string ID and stored in a ComponentRegistry.
##
## Example:
##   proc counter(state: ComponentState, ctx: ReactiveContext): Widget =
##     let count = state.useSignal(ctx, 0, 0)
##     vbox(
##       text("Count: " & $count.val),
##       text("[+]").withOnClick(proc(mx, my: int) = count.set(count.val + 1)),
##     )

import ./widget
import ./reactive
import std/tables

type
  EffectCleanup* = proc()

  EffectEntry = object
    deps: uint64
    cleanup: EffectCleanup

  ComponentState* = ref object
    ## Persistent state for a single component instance.
    id*: string
    signals: seq[RootRef]      ## Persistent state slots
    effects: seq[EffectEntry]
    mounted*: bool

  ComponentProc* = proc(state: ComponentState, ctx: ReactiveContext): Widget

  ComponentRegistry* = ref object
    ## Tracks component instances by ID across render frames.
    instances: Table[string, ComponentState]
    activeIds: seq[string]     ## IDs seen in current frame (for cleanup)

# ============================================================
# ComponentState
# ============================================================

proc newComponentState*(id: string): ComponentState =
  ComponentState(id: id, signals: @[], effects: @[], mounted: false)

proc useSignal*[T](cs: ComponentState, ctx: ReactiveContext,
                   idx: int, initial: T): Signal[T] =
  ## Get or create a persistent Signal[T] at slot `idx`.
  ## On first call, creates a new signal with `initial`.
  ## On subsequent calls, returns the existing signal.
  while cs.signals.len <= idx:
    cs.signals.add(nil)
  if cs.signals[idx] == nil:
    cs.signals[idx] = newSignal[T](ctx, initial)
  cast[Signal[T]](cs.signals[idx])

proc useEffect*(cs: ComponentState, idx: int,
                deps: uint64, effect: proc(): EffectCleanup) =
  ## Run `effect` when `deps` changes. `effect` returns an optional cleanup proc.
  ## The cleanup runs before the next effect call or on unmount.
  while cs.effects.len <= idx:
    cs.effects.add(EffectEntry(deps: 0, cleanup: nil))
  if not cs.mounted or cs.effects[idx].deps != deps:
    # Deps changed — run cleanup of previous effect, then run new one
    if cs.effects[idx].cleanup != nil:
      cs.effects[idx].cleanup()
    cs.effects[idx].cleanup = effect()
    cs.effects[idx].deps = deps

proc cleanup*(cs: ComponentState) =
  ## Run all effect cleanups (called on unmount).
  for i in 0 ..< cs.effects.len:
    if cs.effects[i].cleanup != nil:
      cs.effects[i].cleanup()
      cs.effects[i].cleanup = nil

# ============================================================
# ComponentRegistry
# ============================================================

proc newComponentRegistry*(): ComponentRegistry =
  ComponentRegistry(instances: initTable[string, ComponentState]())

proc get*(cr: ComponentRegistry, id: string): ComponentState =
  ## Get or create a component state for the given ID.
  if id notin cr.instances:
    cr.instances[id] = newComponentState(id)
  cr.activeIds.add(id)
  cr.instances[id]

proc beginFrame*(cr: ComponentRegistry) =
  ## Call at the start of each render frame.
  cr.activeIds.setLen(0)

proc endFrame*(cr: ComponentRegistry) =
  ## Call at the end of each render frame. Cleans up unmounted components.
  var toRemove: seq[string] = @[]
  for id in cr.instances.keys:
    var found = false
    for activeId in cr.activeIds:
      if activeId == id:
        found = true
        break
    if not found:
      cr.instances[id].cleanup()
      toRemove.add(id)
  for id in toRemove:
    cr.instances.del(id)

  # Mark all active components as mounted
  for id in cr.activeIds:
    cr.instances[id].mounted = true

proc renderComponent*(cr: ComponentRegistry, ctx: ReactiveContext,
                      id: string, comp: ComponentProc): Widget =
  ## Render a component, managing its lifecycle state.
  let state = cr.get(id)
  comp(state, ctx)
