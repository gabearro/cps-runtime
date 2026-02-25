import std/[os, sequtils]
import cps/gui

let tmpRoot = getTempDir() / "cps_gui_v2_owner_bridge"
if dirExists(tmpRoot):
  removeDir(tmpRoot)
createDir(tmpRoot)

writeFile(tmpRoot / "ok.gui", """
app OwnerBridgeOk {
  state {
    count: Int = 0
  }

  action SwiftOnly owner swift
  action NimOnly owner nim
  action Hybrid owner both

  reducer {
    on SwiftOnly {
      set count = count + 1
    }
    on NimOnly {
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

let okParsed = parseGuiProgram(tmpRoot / "ok.gui")
assert okParsed.diagnostics.len == 0
assert okParsed.program.actions.len == 3
assert okParsed.program.actions[0].owner == gaoSwift
assert okParsed.program.actions[1].owner == gaoNim
assert okParsed.program.actions[2].owner == gaoBoth
assert okParsed.program.bridge.nimEntry == "bridge.nim"

let okSem = semanticCheck(okParsed.program)
assert not (okParsed.diagnostics & okSem.diagnostics).hasErrors

writeFile(tmpRoot / "warn.gui", """
app OwnerBridgeWarn {
  state {
    count: Int = 0
  }

  action NimOnly owner nim

  reducer {
    on NimOnly {
      set count = count + 1
    }
  }
}
""")

let warnParsed = parseGuiProgram(tmpRoot / "warn.gui")
let warnSem = semanticCheck(warnParsed.program)
let warnDiags = warnParsed.diagnostics & warnSem.diagnostics
assert not warnDiags.hasErrors
assert warnDiags.anyIt(it.code == "GUI_SEMA_BRIDGE_MISSING" and it.severity == gsWarning)

writeFile(tmpRoot / "bad.gui", """
app OwnerBridgeBad {
  state {
    count: Int = 0
  }

  action NimOnly owner nim

  reducer {
    on NimOnly {
      set count = count + 1
    }
  }

  bridge {
    nimEntry: "bridge.txt"
  }
}
""")

let badParsed = parseGuiProgram(tmpRoot / "bad.gui")
let badSem = semanticCheck(badParsed.program)
let badDiags = badParsed.diagnostics & badSem.diagnostics
assert badDiags.hasErrors
assert badDiags.anyIt(it.code == "GUI_SEMA_BRIDGE_ENTRY")

echo "PASS: GUI v2 owner/bridge sema"
