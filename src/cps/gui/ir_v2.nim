## GUI canonical IR v2.
##
## v2 currently aliases GuiIrProgram while formalizing parity helpers used by
## .gui and Nim-macro frontends.

import std/strutils
import ./types
import ./ast
import ./ir

export ir

type
  GuiIrV2Program* = GuiIrProgram

proc buildIrV2*(semProgram: GuiSemanticProgram): GuiIrV2Program =
  buildIr(semProgram)

proc canonicalActionShape(action: GuiActionDecl): string =
  var params: seq[string] = @[]
  for param in action.params:
    params.add param.name & ":" & param.typ
  action.name & "(" & params.join(",") & ")@" & actionOwnerText(action.owner)

proc canonicalIrSignature*(program: GuiIrV2Program): string =
  var lines: seq[string] = @[]
  lines.add "app=" & program.appName
  lines.add "bridge=" & program.bridge.nimEntry
  if program.window.hasTitle:
    lines.add "window.title=" & program.window.title
  if program.window.hasWidth:
    lines.add "window.width=" & $program.window.width
  if program.window.hasHeight:
    lines.add "window.height=" & $program.window.height
  if program.window.hasMinWidth:
    lines.add "window.minWidth=" & $program.window.minWidth
  if program.window.hasMinHeight:
    lines.add "window.minHeight=" & $program.window.minHeight
  if program.window.hasMaxWidth:
    lines.add "window.maxWidth=" & $program.window.maxWidth
  if program.window.hasMaxHeight:
    lines.add "window.maxHeight=" & $program.window.maxHeight
  if program.window.hasClosePolicy:
    lines.add "window.closeOnLast=" & $program.window.closeAppOnLastWindowClose
  if program.window.hasShowTitleBar:
    lines.add "window.showTitleBar=" & $program.window.showTitleBar

  for action in program.actions:
    lines.add "action=" & canonicalActionShape(action)

  for component in program.components:
    lines.add "component=" & component.name

  lines.join("\n")

proc irParityDiagnostics*(
  leftName: string,
  leftProgram: GuiIrV2Program,
  rightName: string,
  rightProgram: GuiIrV2Program
): seq[GuiDiagnostic] =
  let leftSig = canonicalIrSignature(leftProgram)
  let rightSig = canonicalIrSignature(rightProgram)
  if leftSig != rightSig:
    result.add mkDiagnostic(
      "",
      1,
      1,
      gsError,
      "IR parity mismatch between " & leftName & " and " & rightName,
      "GUI_IR_PARITY"
    )
