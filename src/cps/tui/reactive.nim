## CPS TUI - Reactive State
##
## Provides reactive state primitives for TUI applications.
## When state changes, the UI automatically re-renders.
## Inspired by React hooks / SolidJS signals.

type
  StateCallback* = proc()

  ReactiveContext* = ref object
    ## Holds reactive state and manages re-render triggering.
    dirtyFlag*: bool
    afterUpdate*: StateCallback   ## Called after any state change (triggers re-render)

  Signal*[T] = ref object
    ## A reactive signal that triggers re-render on change.
    value: T
    ctx: ReactiveContext

  Computed*[T] = ref object
    ## A derived value that recomputes when dependencies change.
    compute: proc(): T
    cached: T
    dirty: bool
    ctx: ReactiveContext

# ============================================================
# ReactiveContext
# ============================================================

proc newReactiveContext*(): ReactiveContext =
  ReactiveContext(dirtyFlag: false)

proc markDirty*(ctx: ReactiveContext) =
  ctx.dirtyFlag = true
  if ctx.afterUpdate != nil:
    ctx.afterUpdate()

proc isDirty*(ctx: ReactiveContext): bool =
  ctx.dirtyFlag

proc clearDirty*(ctx: ReactiveContext) =
  ctx.dirtyFlag = false

# ============================================================
# Signal[T]
# ============================================================

proc newSignal*[T](ctx: ReactiveContext, initial: T): Signal[T] =
  Signal[T](value: initial, ctx: ctx)

proc get*[T](s: Signal[T]): T =
  s.value

proc set*[T](s: Signal[T], val: T) =
  if s.value != val:
    s.value = val
    s.ctx.markDirty()

proc update*[T](s: Signal[T], fn: proc(old: T): T) =
  let newVal = fn(s.value)
  s.set(newVal)

proc modify*[T](s: Signal[T], fn: proc(val: var T)) =
  ## Mutate in-place and mark dirty. Use for seqs, tables, etc.
  fn(s.value)
  s.ctx.markDirty()

# Template for cleaner syntax: `signal.val` instead of `signal.get()`
template val*[T](s: Signal[T]): T = s.get()

# ============================================================
# Computed[T]
# ============================================================

proc newComputed*[T](ctx: ReactiveContext, compute: proc(): T): Computed[T] =
  Computed[T](compute: compute, dirty: true, ctx: ctx)

proc get*[T](c: Computed[T]): T =
  if c.dirty:
    c.cached = c.compute()
    c.dirty = false
  c.cached

proc invalidate*[T](c: Computed[T]) =
  c.dirty = true

template val*[T](c: Computed[T]): T = c.get()

# ============================================================
# List-specific helpers
# ============================================================

proc append*[T](s: Signal[seq[T]], item: T) =
  s.value.add(item)
  s.ctx.markDirty()

proc prepend*[T](s: Signal[seq[T]], item: T) =
  s.value.insert(item, 0)
  s.ctx.markDirty()

proc removeAt*[T](s: Signal[seq[T]], idx: int) =
  if idx >= 0 and idx < s.value.len:
    s.value.delete(idx)
    s.ctx.markDirty()

proc len*[T](s: Signal[seq[T]]): int =
  s.value.len

proc `[]`*[T](s: Signal[seq[T]], idx: int): T =
  s.value[idx]
