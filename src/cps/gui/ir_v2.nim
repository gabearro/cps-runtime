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
  var params: seq[string]
  for param in action.params:
    params.add param.name & ":" & param.typ
  action.name & "(" & params.join(",") & ")@" & actionOwnerText(action.owner)

template addWindowField(result: var string; win: GuiWindowDecl;
                        has: untyped; key, val: string) =
  if win.has:
    result.add key & "=" & val & "\n"

proc canonicalIrSignature*(program: GuiIrV2Program): string =
  result.add "app=" & program.appName & "\n"
  result.add "bridge=" & program.bridge.nimEntry & "\n"

  let w = program.window
  addWindowField(result, w, hasTitle, "window.title", w.title)
  addWindowField(result, w, hasWidth, "window.width", $w.width)
  addWindowField(result, w, hasHeight, "window.height", $w.height)
  addWindowField(result, w, hasMinWidth, "window.minWidth", $w.minWidth)
  addWindowField(result, w, hasMinHeight, "window.minHeight", $w.minHeight)
  addWindowField(result, w, hasMaxWidth, "window.maxWidth", $w.maxWidth)
  addWindowField(result, w, hasMaxHeight, "window.maxHeight", $w.maxHeight)
  addWindowField(result, w, hasClosePolicy, "window.closeOnLast",
                 $w.closeAppOnLastWindowClose)
  addWindowField(result, w, hasShowTitleBar, "window.showTitleBar",
                 $w.showTitleBar)
  addWindowField(result, w, hasSuppressDefaultMenus,
                 "window.suppressDefaultMenus", $w.suppressDefaultMenus)

  for action in program.actions:
    result.add "action=" & canonicalActionShape(action) & "\n"
  for component in program.components:
    result.add "component=" & component.name & "\n"

  if result.len > 0 and result[^1] == '\n':
    result.setLen(result.len - 1)

proc irParityDiagnostics*(
  leftName: string,
  leftProgram: GuiIrV2Program,
  rightName: string,
  rightProgram: GuiIrV2Program
): seq[GuiDiagnostic] =
  let leftSig = canonicalIrSignature(leftProgram)
  let rightSig = canonicalIrSignature(rightProgram)
  if leftSig == rightSig:
    return

  let leftLines = leftSig.split('\n')
  let rightLines = rightSig.split('\n')
  let maxLen = max(leftLines.len, rightLines.len)
  var diffs: seq[string]
  for i in 0 ..< maxLen:
    let l = if i < leftLines.len: leftLines[i] else: "(missing)"
    let r = if i < rightLines.len: rightLines[i] else: "(missing)"
    if l != r:
      diffs.add leftName & ": " & l & "  |  " & rightName & ": " & r

  result.add mkDiagnostic(
    "",
    1,
    1,
    gsError,
    "IR parity mismatch between " & leftName & " and " & rightName &
      ":\n" & diffs.join("\n"),
    "GUI_IR_PARITY"
  )
