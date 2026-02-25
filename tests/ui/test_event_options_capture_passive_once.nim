import cps/ui

proc oldView(): VNode =
  element(
    "button",
    events = @[
      on(
        etClick,
        proc(ev: var UiEvent) = discard,
        opts(capture = true, passive = true, once = true)
      )
    ],
    children = @[text("old")]
  )

proc newView(): VNode =
  element(
    "button",
    events = @[
      on(etClick, proc(ev: var UiEvent) = discard)
    ],
    children = @[text("new")]
  )

block testEventOptionsAffectListenerIdentity:
  resetReconcilerIds()

  var oldTree = oldView()
  discard diffTrees(nil, oldTree, -1)

  var nextTree = newView()
  let patches = diffTrees(oldTree, nextTree, -1)

  var sawUnbind = false
  var sawBind = false

  for patch in patches:
    case patch.kind
    of pkUnbindEvent:
      sawUnbind = true
      assert patch.eventBinding.eventType == etClick
      assert patch.eventBinding.options.capture
      assert patch.eventBinding.options.passive
      assert patch.eventBinding.options.`once`
    of pkBindEvent:
      sawBind = true
      assert patch.eventBinding.eventType == etClick
      assert patch.eventBinding.options.capture == false
      assert patch.eventBinding.options.passive == false
      assert patch.eventBinding.options.`once` == false
    else:
      discard

  assert sawUnbind
  assert sawBind

echo "PASS: event options are part of listener identity and diffing"
