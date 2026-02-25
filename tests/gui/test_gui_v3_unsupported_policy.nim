import std/os
import cps/gui
import cps/gui/sema

let tmpRoot = getTempDir() / "cps_gui_v3_policy"
if dirExists(tmpRoot):
  removeDir(tmpRoot)
createDir(tmpRoot)

let entryFile = tmpRoot / "policy.gui"
writeFile(entryFile, """
component Root {
  Text("Policy")
    .customGlassShadow(radius: 8)
}

app PolicyApp {
  state {
    count: Int = 0
  }
}
""")

let parsed = parseGuiProgram(entryFile)
assert not parsed.diagnostics.hasErrors

let strictRes = semanticCheck(
  parsed.program,
  GuiSemaOptions(
    backend: gbkSwiftUI,
    targets: @[gtpMacOS],
    unsupportedPolicy: gupStrict
  )
)
assert strictRes.diagnostics.hasErrors

let warnRes = semanticCheck(
  parsed.program,
  GuiSemaOptions(
    backend: gbkSwiftUI,
    targets: @[gtpMacOS],
    unsupportedPolicy: gupWarnPassthrough
  )
)
assert not warnRes.diagnostics.hasErrors
assert warnRes.diagnostics.len > 0

echo "PASS: GUI v3 unsupported policy"
