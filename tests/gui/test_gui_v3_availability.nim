import std/os
import cps/gui
import cps/gui/sema

let tmpRoot = getTempDir() / "cps_gui_v3_availability"
if dirExists(tmpRoot):
  removeDir(tmpRoot)
createDir(tmpRoot)

let entry = tmpRoot / "availability.gui"
writeFile(entry, """
component Root {
  Text("Availability")
    .navigationSubtitle("Sub")
    .controlSize(ControlSize.small)
}

app AvailabilityApp {
  state {
    count: Int = 0
  }
}
""")

let parsed = parseGuiProgram(entry)
assert not parsed.diagnostics.hasErrors

let sem = semanticCheck(
  parsed.program,
  GuiSemaOptions(
    backend: gbkSwiftUI,
    targets: @[gtpIOS],
    unsupportedPolicy: gupStrict
  )
)

assert sem.diagnostics.hasErrors
var sawAvailability = false
for d in sem.diagnostics:
  if d.code == "GUI_SEMA_AVAILABILITY":
    sawAvailability = true
    break
assert sawAvailability

echo "PASS: GUI v3 availability checks"
