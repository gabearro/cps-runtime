import cps/gui
import cps/gui/macros

# Macro-facing entry point that binds the IRC GUI module.
guiFile(IrcMacroModule, "app.gui")

when isMainModule:
  let diags = checkIrcMacroModuleGui()
  if diags.hasErrors:
    for d in diags:
      echo d.formatDiagnostic()
    quit(1)
  echo "IRC GUI module parsed successfully."
