import std/[os, sequtils]
import cps/gui

let tmpRoot = getTempDir() / "cps_gui_modifier_validation"
if dirExists(tmpRoot):
  removeDir(tmpRoot)
createDir(tmpRoot)

let validPath = tmpRoot / "valid.gui"
writeFile(validPath, """
component Root {
  VStack {
    Text("Hello")
      .foregroundColor(token.color.accent)
      .padding(12)
      .frame(maxWidth: Double.infinity, alignment: Alignment.leading)
      .opacity(0.9)
  }
}

app ModifierValid {
  tokens {
    color.accent = "#1177cc"
  }

  state {
    ok: Bool = true
  }
}
""")

let validParsed = parseGuiProgram(validPath)
let validSem = semanticCheck(validParsed.program)
assert not (validParsed.diagnostics & validSem.diagnostics).hasErrors

let invalidPath = tmpRoot / "invalid.gui"
writeFile(invalidPath, """
component Root {
  Text("Broken")
    .frame(foo: 1)
    .disabled("no")
    .padding(top: 4, top: 8)
}

app ModifierInvalid {
  state {
    ok: Bool = true
  }
}
""")

let invalidParsed = parseGuiProgram(invalidPath)
let invalidSem = semanticCheck(invalidParsed.program)
let diags = invalidParsed.diagnostics & invalidSem.diagnostics
assert diags.hasErrors
assert diags.anyIt(it.code == "GUI_SEMA_MODIFIER_ARG")
assert diags.anyIt(it.code == "GUI_SEMA_MODIFIER_ARG_TYPE")
assert diags.anyIt(it.code == "GUI_SEMA_MODIFIER_ARG_DUP")

echo "PASS: GUI modifier validation"
