import std/os
import cps/gui
import cps/gui/macros
import cps/gui/ir_v2

const thisDir = currentSourcePath().parentDir()
const fixturePath = thisDir / "fixtures" / "macro_file.gui"

guiInline(InlineParityModule, """
component Root {
  Text("Macro Fixture")
}

app MacroFixture {
  state {
    count: Int = 0
  }

  action Increment owner swift
  action Refresh owner nim
  action Sync owner both

  reducer {
    on Increment {
      set count = count + 1
    }

    on Refresh {
      set count = count + 2
    }

    on Sync {
      set count = count + 3
    }
  }

  bridge {
    nimEntry: "bridge.nim"
  }
}
""")

let parsed = parseGuiProgram(fixturePath)
let sem = semanticCheck(parsed.program)
let allDiags = parsed.diagnostics & sem.diagnostics
assert not allDiags.hasErrors

let expectedSig = canonicalIrSignature(buildIrV2(sem))
assert InlineParityModuleGuiIrSignature() == expectedSig
assert checkInlineParityModuleGui().len == 0

var actionValue: InlineParityModuleGuiAction = gaIncrement
assert ord(actionValue) == 0

echo "PASS: GUI macro guiInline parity"
