## Live SSR SPA app shell
## Demonstrates SSR + hydration for interactive client UI.
##
## Build:
##   bash scripts/build_ui_wasm.sh examples/ui/live_ssr_spa_app.nim examples/ui/live_ssr_spa_app.wasm
##   nim c --mm:arc -d:release -o:examples/ui/live_ssr_spa_server examples/ui/live_ssr_spa_server.nim

import cps/ui

proc ClientControlsCard(): VNode =
  let (clicks, setClicks) = useState(0)
  let (hydrated, setHydrated) = useState(false)

  useEffect(
    proc(): EffectCleanup =
      setHydrated(true)
      proc() = discard,
    deps(1)
  )

  ui:
    section(className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm", attr("data-testid", "client-controls")):
      p(className="text-xs font-bold uppercase tracking-[0.14em] text-slate-500"):
        text("Hydrated SPA controls")
      p(className="mt-2 text-sm text-slate-700"):
        text("Hydration status: " & (if hydrated: "hydrated" else: "server-rendered"))
      `div`(className="mt-3 flex items-center gap-3"):
        button(
          className="rounded-lg bg-slate-900 px-3 py-1.5 text-sm font-semibold text-white",
          attr("data-testid", "client-increment"),
          onClick=proc(ev: var UiEvent) =
            setClicks(clicks + 1)
        ):
          text("Increment")
        span(className="font-mono text-sm", attr("data-testid", "client-clicks")):
          text($clicks)

proc liveSsrSpaRoot*(): VNode =
  ui:
    `div`(className="space-y-4", attr("data-testid", "live-ssr-spa-root")):
      section(className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"):
        p(className="text-xs font-bold uppercase tracking-[0.14em] text-slate-500"):
          text("Live SSR SPA")
        h1(className="mt-1 text-2xl font-black tracking-tight text-slate-900", attr("data-testid", "app-title")):
          text("Server-Driven Runtime Re-Render Demo")
        p(className="mt-2 text-sm text-slate-600"):
          text("The app shell is SSR + hydrated once. A separate server component is re-rendered at runtime.")
      ClientControlsCard()

setRootComponent(liveSsrSpaRoot)
