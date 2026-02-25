import cps/gui
import cps/gui/macros

# Macro-facing entry point that binds the same .gui module.
guiFile(TodoMacroModule, "app.gui")

when isMainModule:
  let diags = checkTodoMacroModuleGui()
  if diags.hasErrors:
    for d in diags:
      echo d.formatDiagnostic()
    quit(1)
  echo "Todo macro module parsed successfully."
