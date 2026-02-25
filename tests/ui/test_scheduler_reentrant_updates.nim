import cps/ui

var
  renderCount = 0

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

proc app(): VNode =
  let (count, setCount) = useState(0)
  inc renderCount

  useEffect(
    proc(): EffectCleanup =
      if count == 0:
        setCount(1)
      proc() = discard,
    depsHash(count)
  )

  element("span", children = @[text($count)])

block testReentrantScheduling:
  mount("#app", app)
  assert renderCount == 1
  assert firstText(currentTree()) == "0"

  # Effect scheduled an update during commit; it should flush on next tick only.
  assert isFlushPending()
  runPendingFlush()

  assert renderCount == 2
  assert firstText(currentTree()) == "1"

  unmount()

echo "PASS: reentrant updates are queued for a follow-up flush"
