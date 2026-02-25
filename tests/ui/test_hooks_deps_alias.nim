import cps/ui

var
  setCountProc: proc(next: int) {.closure.}
  memoRuns = 0

proc app(): VNode =
  let (count, setCount) = useState(0)
  setCountProc = setCount

  discard useMemo(
    proc(): int =
      inc memoRuns
      count,
    deps(count)
  )

  element("span", children = @[text($count)])

block testDepsAliasProducesSameHashes:
  let a = deps(1, "x", true)
  let b = depsHash(1, "x", true)
  assert a == b

block testDepsAliasWorksInHooks:
  memoRuns = 0
  mount("#app", app)
  assert memoRuns == 1

  setCountProc(1)
  runPendingFlush()
  assert memoRuns == 2

  # Rerender with unchanged dependency should not recompute memo value.
  setCountProc(1)
  runPendingFlush()
  assert memoRuns == 2

  unmount()

echo "PASS: deps alias matches depsHash and preserves memo dependency semantics"
