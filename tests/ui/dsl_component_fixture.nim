import cps/ui

proc FixturePanel*(child: VNode): VNode =
  element(
    "section",
    attrs = @[attr("data-component", "fixture-panel")],
    children = if child == nil: @[] else: @[child]
  )
