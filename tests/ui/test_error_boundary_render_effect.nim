import std/strutils
import cps/ui

var
  setRenderCrash: proc(next: bool) {.closure.}
  setEffectCrash: proc(next: bool) {.closure.}

proc firstText(node: VNode): string =
  if node == nil:
    return ""
  if node.kind == vkText:
    return node.text
  for child in node.children:
    let t = firstText(child)
    if t.len > 0:
      return t
  ""

proc renderExploder(crash: bool): VNode =
  if crash:
    raise newException(ValueError, "render-boom")
  element("span", children = @[text("render-ok")])

proc renderBoundaryApp(): VNode =
  let (crash, setCrash) = useState(true)
  setRenderCrash = setCrash
  errorBoundary(
    component(
      proc(): VNode = renderExploder(crash),
      key = "render-child",
      typeName = "RenderExploder"
    ),
    proc(msg: string): VNode =
      element("span", children = @[text("fallback:" & msg)]),
    key = "render-boundary"
  )

proc effectExploder(crash: bool): VNode =
  useEffect(
    proc(): EffectCleanup =
      if crash:
        raise newException(ValueError, "effect-boom")
      proc() = discard,
    depsHash(crash)
  )
  element("span", children = @[text(if crash: "effect-crash" else: "effect-ok")])

proc effectBoundaryApp(): VNode =
  let (crash, setCrash) = useState(true)
  setEffectCrash = setCrash
  errorBoundary(
    component(
      proc(): VNode = effectExploder(crash),
      key = "effect-child",
      typeName = "EffectExploder"
    ),
    proc(msg: string): VNode =
      element("span", children = @[text("fallback:" & msg)]),
    key = "effect-boundary"
  )

block testRenderErrorBoundary:
  mount("#app", renderBoundaryApp)
  assert firstText(currentTree()).contains("fallback:render-boom")

  setRenderCrash(false)
  runPendingFlush()
  assert firstText(currentTree()) == "render-ok"

  unmount()

block testEffectErrorBoundary:
  mount("#app", effectBoundaryApp)

  assert isFlushPending()
  runPendingFlush()
  assert firstText(currentTree()).contains("fallback:effect-boom")

  setEffectCrash(false)
  runPendingFlush()
  assert firstText(currentTree()) == "effect-ok"

  unmount()

echo "PASS: error boundaries catch render/effect errors and recover on rerender"
