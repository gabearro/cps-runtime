import std/os
import cps/gui

let tmpRoot = getTempDir() / "cps_gui_v3_parser_ops"
if dirExists(tmpRoot):
  removeDir(tmpRoot)
createDir(tmpRoot)

let entryFile = tmpRoot / "ops_types.gui"
writeFile(entryFile, """
component Root {
  Text("v3")
}

app OpsTypes {
  state {
    lhs: Int = 1
    rhs: Int = 2
    flag: Bool = false
    title: String? = null
    fallbackTitle: String = "fallback"
    tags: [String] = []
    metadata: [String:Int]? = null
    tupleValue: (Int, String)? = null
    maybeResult: Result<Int, String>? = null
    maybeSet: Set<Int>? = null
    rangeState: Range = 1 ... 3
  }

  action Tick owner swift

  reducer {
    on Tick {
      set flag = !(lhs == rhs) || ((lhs < rhs) && (lhs <= rhs) && (rhs >= lhs) && (lhs != rhs))
      set lhs = lhs < rhs ? lhs : rhs
      set title = title ?? fallbackTitle
      set rangeState = lhs ..< rhs
    }
  }
}
""")

let parsed = parseGuiProgram(entryFile)
let sem = semanticCheck(parsed.program)
let diags = parsed.diagnostics & sem.diagnostics
assert not diags.hasErrors

echo "PASS: GUI v3 parser ops/types"
