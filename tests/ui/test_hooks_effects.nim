import cps/ui

var
  logs: seq[string] = @[]
  setFlagProc: proc(next: bool) {.closure.}

proc app(): VNode =
  let (flag, setFlag) = useState(false)
  setFlagProc = setFlag

  useEffect(
    proc(): EffectCleanup =
      logs.add("create:" & $flag)
      proc() =
        logs.add("cleanup:" & $flag),
    depsHash(flag)
  )

  element("span", children = @[text(if flag: "1" else: "0")])

block testUseEffectOrdering:
  mount("#app", app)
  assert logs == @["create:false"]

  setFlagProc(true)
  runPendingFlush()
  assert logs == @["create:false", "cleanup:false", "create:true"]

  unmount()
  assert logs == @["create:false", "cleanup:false", "create:true", "cleanup:true"]

echo "PASS: useEffect cleanup/create ordering is deterministic"
