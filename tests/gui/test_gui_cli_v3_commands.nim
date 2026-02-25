import std/os
import cps/gui/cli

let tmpRoot = getTempDir() / "cps_gui_cli_v3"
if dirExists(tmpRoot):
  removeDir(tmpRoot)
createDir(tmpRoot)

let leftGui = tmpRoot / "left.gui"
let rightGui = tmpRoot / "right.gui"
let otherGui = tmpRoot / "other.gui"
let nimFromFile = tmpRoot / "module_file.nim"
let nimFromInline = tmpRoot / "module_inline.nim"

let shared = """
component Root {
  Text("Parity")
}

app CliParity {
  state {
    count: Int = 0
  }
}
"""

writeFile(leftGui, shared)
writeFile(rightGui, shared)
writeFile(otherGui, """
component Root {
  Text("Other")
}

app CliParityOther {
  state {
    count: Int = 0
  }
}
""")

writeFile(nimFromFile, "import cps/gui/macros\nguiFile(ParityModuleFile, \"" & leftGui & "\")\n")
writeFile(
  nimFromInline,
  "import cps/gui/macros\n" &
  "guiBlock(ParityModuleInline, \"\"\"\n" &
  "component Root {\n" &
  "  Text(\"Parity\")\n" &
  "}\n\n" &
  "app CliParity {\n" &
  "  state {\n" &
  "    count: Int = 0\n" &
  "  }\n" &
  "}\n" &
  "\"\"\")\n"
)

assert runGuiCli(@["coverage"]) == 0
assert runGuiCli(@["parity", leftGui, rightGui]) == 0
assert runGuiCli(@["parity", leftGui, otherGui]) == 1
assert runGuiCli(@["parity", nimFromFile, leftGui]) == 0
assert runGuiCli(@["parity", nimFromInline, leftGui]) == 0

echo "PASS: GUI CLI v3 commands"
