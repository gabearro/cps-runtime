import std/strutils
import cps/ui

proc firstText(node: VNode): string =
  if node == nil:
    return ""
  if node.kind == vkText:
    return node.text
  for child in node.children:
    let value = firstText(child)
    if value.len > 0:
      return value
  ""

block testSuspenseLazyLifecycle:
  let lazyHandle = newLazyHandle()
  let LazyPage = lazyComponent(proc(): LazyHandle = lazyHandle)

  proc app(): VNode =
    suspense(
      fallback = text("loading"),
      child = component(LazyPage, typeName = "LazyPage")
    )

  mount("#app", app)
  assert firstText(currentTree()) == "loading"

  resolveLazy(lazyHandle, proc(): VNode = text("ready"))
  var spins = 0
  while isFlushPending() and spins < 6:
    inc spins
    runPendingFlush()

  assert firstText(currentTree()) == "ready"
  unmount()

block testRenderToString:
  let html = renderToString(
    proc(): VNode =
      element("div", attrs = @[attr("id", "root")], children = @[text("hello")]),
    SsrOptions(includeDoctype: true)
  )

  assert html.startsWith("<!doctype html>")
  assert html.contains("<div id=\"root\">hello</div>")

block testRenderToStream:
  var chunks: seq[string] = @[]
  var done = false

  let onChunk: SsrChunkHandler =
    proc(chunk: string) =
      chunks.add chunk

  let onDone: SsrDoneHandler =
    proc() =
      done = true

  renderToStream(
    proc(): VNode =
      element("main", attrs = @[attr("id", "streamed")], children = @[text("stream-hello")]),
    onChunk = onChunk,
    onDone = onDone,
    opts = SsrOptions(includeDoctype: true)
  )

  let streamed = chunks.join("")
  assert done
  assert streamed.startsWith("<!doctype html>")
  assert streamed.contains("<main id=\"streamed\">stream-hello</main>")

block testHydrationErrorExports:
  clearLastUiHydrationError()
  setLastUiHydrationError("hydrate mismatch")

  assert nimui_last_hydration_error_len() == "hydrate mismatch".len.int32

  var buf = newString(64)
  let copied = nimui_copy_last_hydration_error(addr buf[0], buf.len.int32)
  assert copied == "hydrate mismatch".len.int32
  assert buf[0 ..< copied.int] == "hydrate mismatch"

block testHydrateEntryPoint:
  hydrate("#app", proc(): VNode =
    element("div", children = @[text("hydrated")])
  )
  assert firstText(currentTree()) == "hydrated"
  unmount()

echo "PASS: suspense/lazy + ssr + hydrate APIs are operational"
