## WAST spec test suite runner
## Loads and runs all .wast files in tests/wasm/spec/

import std/[os, strutils, strformat]
import wast_runner

const SpecDir = currentSourcePath.parentDir / "spec"

proc runFile(path: string): tuple[passed, failed: int] =
  let name = path.extractFilename()
  let (passed, failed) = runWastFile(path, verbose = false)
  let total = passed + failed
  if failed == 0:
    echo fmt"PASS {name}: {passed}/{total} assertions passed"
  else:
    echo fmt"FAIL {name}: {passed}/{total} passed, {failed} FAILED"
    # Re-run with verbose for details
    discard runWastFile(path, verbose = true)
  return (passed, failed)

proc main() =
  var totalPassed = 0
  var totalFailed = 0

  let files = [
    SpecDir / "i32.wast",
    SpecDir / "i64.wast",
    SpecDir / "memory.wast",
    SpecDir / "block.wast",
    SpecDir / "loop.wast",
    SpecDir / "br.wast",
    SpecDir / "br_if.wast",
    SpecDir / "call.wast",
  ]

  for f in files:
    if fileExists(f):
      let (p, fa) = runFile(f)
      totalPassed += p
      totalFailed += fa
    else:
      echo "SKIP (not found): " & f

  echo ""
  echo "=== WAST Suite Summary ==="
  echo fmt"Total: {totalPassed + totalFailed} assertions, {totalPassed} passed, {totalFailed} failed"
  if totalFailed > 0:
    quit(1)

main()
