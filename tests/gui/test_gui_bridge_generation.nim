import std/[os, strutils]
import cps/gui

let tmpRoot = getTempDir() / "cps_gui_bridge_generation"
if dirExists(tmpRoot):
  removeDir(tmpRoot)
createDir(tmpRoot)

let entryFile = tmpRoot / "app.gui"
let bridgeEntry = tmpRoot / "bridge.nim"

writeFile(entryFile, """
component Root {
  Text("Bridge Harness")
}

app BridgeHarness {
  state {
    count: Int = 0
  }

  action SwiftInc owner swift
  action NimInc owner nim
  action Hybrid owner both

  reducer {
    on SwiftInc {
      set count = count + 1
    }
    on NimInc {
      set count = count + 2
    }
    on Hybrid {
      set count = count + 3
    }
  }

  bridge {
    nimEntry: "bridge.nim"
  }
}
""")

writeFile(bridgeEntry, """
proc bridgePlaceholder*() =
  discard
""")

let outDir = tmpRoot / "out"
let gen = generateGuiProject(entryFile, outDir, defaultGenerateOptions())
assert not gen.diagnostics.hasErrors
assert gen.bridgeEnabled
assert normalizedPath(gen.bridgeEntry) == normalizedPath(bridgeEntry)

let appRoot = outDir / "BridgeHarness"
let mainSwiftPath = appRoot / "App" / "Generated" / "GUI.generated.swift"
let runtimeSwiftPath = appRoot / "App" / "Generated" / "GUIRuntime.generated.swift"
let bridgeHeaderPath = appRoot / "Bridge" / "Generated" / "GUIBridge.generated.h"
let bridgeSwiftPath = appRoot / "Bridge" / "Generated" / "GUIBridgeSwift.generated.swift"
let bridgeNimPath = appRoot / "Bridge" / "Generated" / "GUIBridgeNim.generated.nim"
let bridgeScriptPath = appRoot / "Bridge" / "Nim" / "build_bridge.sh"
let bridgeImplPath = appRoot / "Bridge" / "Nim" / "bridge_impl.nim"

assert fileExists(mainSwiftPath)
assert fileExists(runtimeSwiftPath)
assert fileExists(bridgeHeaderPath)
assert fileExists(bridgeSwiftPath)
assert fileExists(bridgeNimPath)
assert fileExists(bridgeScriptPath)
assert fileExists(bridgeImplPath)

let mainSwift = readFile(mainSwiftPath)
assert mainSwift.contains("case .swiftInc: return .swift")
assert mainSwift.contains("case .nimInc: return .nim")
assert mainSwift.contains("case .hybrid: return .both")
assert mainSwift.contains("name: \"bridge.dispatch\"")
assert not mainSwift.contains("state.count = (state.count + 2)")

let customMarker = "# custom bridge impl marker"
writeFile(bridgeImplPath, customMarker & "\n")

let regen = generateGuiProject(entryFile, outDir, defaultGenerateOptions())
assert not regen.diagnostics.hasErrors
assert readFile(bridgeImplPath).contains(customMarker)

echo "PASS: GUI bridge generation"
