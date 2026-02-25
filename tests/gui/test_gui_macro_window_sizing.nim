import std/[os, strutils]
import cps/gui
import cps/gui/macros

guiInline(WindowMacroModule, """
component Root {
  Text("Window Macro")
}

app WindowMacro {
  window {
    title: "Window Macro App"
    width: 980
    height: 720
    minWidth: 820
    minHeight: 560
    showTitleBar: false
    closeAppOnLastWindowClose: true
  }

  state {
    ready: Bool = true
  }
}
""")

let diags = checkWindowMacroModuleGui()
assert not diags.hasErrors

let outRoot = getTempDir() / "cps_gui_macro_window"
if dirExists(outRoot):
  removeDir(outRoot)

let gen = generateWindowMacroModuleGui(outRoot)
assert not gen.diagnostics.hasErrors

let appDir = outRoot / "WindowMacro"
let mainSwift = readFile(appDir / "App" / "Generated" / "GUI.generated.swift")
assert mainSwift.contains("WindowGroup(\"Window Macro App\")")
assert mainSwift.contains(".defaultSize(width: 980.0, height: 720.0)")
assert mainSwift.contains("window.minSize = NSSize(width: 820.0, height: 560.0)")
assert mainSwift.contains("window.titleVisibility = .hidden")
assert mainSwift.contains("window.titlebarAppearsTransparent = true")
assert mainSwift.contains("window.toolbarStyle = .unified")
assert mainSwift.contains("window.toolbar?.showsBaselineSeparator = false")
assert mainSwift.contains("applicationShouldTerminateAfterLastWindowClosed")

echo "PASS: GUI macro window sizing"
