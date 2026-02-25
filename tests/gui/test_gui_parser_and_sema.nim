import std/[os, strutils, sequtils]
import cps/gui

let tmpRoot = getTempDir() / "cps_gui_parser_sema"
if dirExists(tmpRoot):
  removeDir(tmpRoot)
createDir(tmpRoot)
createDir(tmpRoot / "partials")

writeFile(tmpRoot / "partials" / "components.gui", """
component Root {
  VStack {
    Text("Hello")
  }
}
""")

writeFile(tmpRoot / "app.gui", """
include "partials/*.gui"

app ParserSmoke {
  window {
    title: "Parser Smoke"
    width: 960
    height: 680
    minWidth: 800
    minHeight: 520
    showTitleBar: true
  }

  tokens {
    color.primary = "#00ffaa"
    spacing.md = 16
  }

  state {
    count: Int = 0
    status: String = "idle"
  }

  action Increment

  reducer {
    on Increment {
      set count = count + 1
      emit timer.once(ms: 100, action: Increment)
    }
  }

  navigation {
    tabs {
      tab home(root: Root, stack: main)
    }

    stack main {
      route detail(component: Root)
    }
  }
}
""")

let parsed = parseGuiProgram(tmpRoot / "app.gui")
assert parsed.program.appName == "ParserSmoke"
assert parsed.program.window.hasWidth
assert parsed.program.window.width == 960
assert parsed.program.window.hasShowTitleBar
assert parsed.program.window.showTitleBar
assert parsed.program.loadedFiles.len == 2
assert parsed.program.components.len == 1
assert parsed.diagnostics.len == 0

let sem = semanticCheck(parsed.program)
assert not sem.diagnostics.hasErrors

writeFile(tmpRoot / "invalid.gui", """
app Invalid {
  state {
    count: Int = 0
  }

  action Tick

  reducer {
    on Tick {
      emit timer.unknown(ms: 50, action: Tick)
    }
  }
}
""")

let invalidParsed = parseGuiProgram(tmpRoot / "invalid.gui")
let invalidSem = semanticCheck(invalidParsed.program)
assert invalidSem.diagnostics.hasErrors
assert invalidSem.diagnostics.anyIt(it.code == "GUI_SEMA_COMMAND")

echo "PASS: GUI parser/sema"
