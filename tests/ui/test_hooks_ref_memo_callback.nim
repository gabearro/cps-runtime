import cps/ui

type
  IntMapper = proc(v: int): int {.closure.}

var
  setCountProc: proc(next: int) {.closure.}
  setOtherProc: proc(next: int) {.closure.}
  memoRuns = 0
  renderCount = 0
  lastMemo = ""
  lastCallbackValue = 0
  lastRefCurrent = 0

proc app(): VNode =
  inc renderCount
  let (count, setCount) = useState(0)
  let (other, setOther) = useState(0)
  setCountProc = setCount
  setOtherProc = setOther

  let r = useRef(0)
  r.current = r.current + 1

  let memoValue = useMemo(
    proc(): string =
      inc memoRuns
      "memo:" & $count,
    depsHash(count)
  )

  let mapper = useCallback(
    IntMapper(proc(v: int): int = v + count),
    depsHash(count)
  )

  lastMemo = memoValue
  lastCallbackValue = mapper(10)
  lastRefCurrent = r.current

  element("div", children = @[text(lastMemo & "|" & $other)])

block testHooksRefMemoCallback:
  mount("#app", app)
  assert renderCount == 1
  assert memoRuns == 1
  assert lastMemo == "memo:0"
  assert lastCallbackValue == 10
  assert lastRefCurrent == 1

  setOtherProc(1)
  runPendingFlush()

  assert renderCount == 2
  assert memoRuns == 1
  assert lastMemo == "memo:0"
  assert lastCallbackValue == 10
  assert lastRefCurrent == 2

  setCountProc(3)
  runPendingFlush()

  assert renderCount == 3
  assert memoRuns == 2
  assert lastMemo == "memo:3"
  assert lastCallbackValue == 13
  assert lastRefCurrent == 3

  unmount()

echo "PASS: useRef/useMemo/useCallback maintain deterministic dependency behavior"
