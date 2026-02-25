import std/os
import cps/gui

let tmpRoot = getTempDir() / "cps_gui_keychain"
if dirExists(tmpRoot):
  removeDir(tmpRoot)
createDir(tmpRoot)

writeFile(tmpRoot / "ok.gui", """
app KeychainOk {
  state {
    token: String = ""
  }

  action Save
  action Done
  action Fail

  reducer {
    on Save {
      emit persist.defaults(key: "token", value: token)
      emit persist.file(key: "token", value: token)
      emit keychain.add(
        service: "dev.cps.gui",
        account: "session",
        value: token,
        attrs: { "kSecAttrSynchronizable": true }
      )
      emit keychain.query(service: "dev.cps.gui", account: "session", onSuccess: Done, onError: Fail)
    }
  }
}
""")

writeFile(tmpRoot / "bad.gui", """
app KeychainBad {
  state {
    token: String = ""
  }

  action Save

  reducer {
    on Save {
      emit keychain.add(
        service: "dev.cps.gui",
        account: "session",
        value: token,
        attrs: { "notAKeychainAttr": true }
      )
    }
  }
}
""")

let okParsed = parseGuiProgram(tmpRoot / "ok.gui")
let okSem = semanticCheck(okParsed.program)
assert not (okParsed.diagnostics & okSem.diagnostics).hasErrors

let badParsed = parseGuiProgram(tmpRoot / "bad.gui")
let badSem = semanticCheck(badParsed.program)
let badDiags = badParsed.diagnostics & badSem.diagnostics
assert badDiags.hasErrors
var sawKeychainAttrError = false
for d in badDiags:
  if d.code == "GUI_SEMA_KEYCHAIN_ATTR":
    sawKeychainAttrError = true
    break
assert sawKeychainAttrError

echo "PASS: GUI keychain/persistence sema"
