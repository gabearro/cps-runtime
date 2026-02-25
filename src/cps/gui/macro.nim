## Nim macro surface for GUI v2.

import std/[os, strutils, tables]
import std/macros
import ./types
import ./parser
import ./sema
import ./ir_v2
import ../gui

proc sanitizeIdent(text: string): string {.compileTime.} =
  var normalized = ""
  for c in text:
    if c.isAlphaNumeric or c == '_':
      normalized.add c
    else:
      normalized.add '_'
  if normalized.len == 0:
    return "GuiModule"
  if normalized[0].isDigit:
    normalized = "G_" & normalized
  normalized

proc inlineDslFromBody(body: NimNode): string {.compileTime.} =
  case body.kind
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    body.strVal
  of nnkStmtList:
    if body.len == 1 and body[0].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      body[0].strVal
    else:
      body.repr
  else:
    body.repr

proc writeInlineDslFile(moduleName: string, body: NimNode, siteFile: string): string {.compileTime.} =
  let dsl = inlineDslFromBody(body)
  let baseDir =
    if siteFile.len > 0:
      siteFile.parentDir()
    else:
      getCurrentDir()
  let cacheDir = normalizedPath(baseDir / ".guiinline")
  createDir(cacheDir)
  result = cacheDir / (sanitizeIdent(moduleName) & ".generated.gui")
  writeFile(result, dsl.strip() & "\n")

proc emitModuleBindings(moduleName: string, guiPath: string): NimNode {.compileTime.} =
  let parsed = parseGuiProgram(guiPath)
  if parsed.diagnostics.hasErrors:
    error("gui macro parse failed for " & guiPath & ": " & parsed.diagnostics[0].message)

  let sem = semanticCheck(parsed.program)
  if sem.diagnostics.hasErrors:
    error("gui macro semantic check failed for " & guiPath & ": " & sem.diagnostics[0].message)

  let irProgram = buildIrV2(sem)

  let moduleBase = sanitizeIdent(moduleName)
  let actionEnumName = ident(moduleBase & "GuiAction")
  let checkProcName = ident("check" & moduleBase & "Gui")
  let generateProcName = ident("generate" & moduleBase & "Gui")
  let bridgeRegProcName = ident("register" & moduleBase & "BridgeHandlers")
  let sigProcName = ident(moduleBase & "GuiIrSignature")
  let pathConstName = ident(moduleBase & "GuiPath")
  let moduleConstName = ident(moduleBase & "GuiModule")

  var enumTy = newNimNode(nnkEnumTy)
  enumTy.add newEmptyNode()
  if irProgram.actions.len == 0:
    enumTy.add ident("gaNone")
  else:
    for action in irProgram.actions:
      enumTy.add ident("ga" & sanitizeIdent(action.name))

  let actionEnumDef = newTree(
    nnkTypeSection,
    newTree(
      nnkTypeDef,
      postfix(actionEnumName, "*"),
      newEmptyNode(),
      enumTy
    )
  )

  let pathLit = newLit(guiPath)
  let moduleLit = newLit(moduleName)
  let irSig = newLit(canonicalIrSignature(irProgram))
  let guiDiagTy = bindSym"GuiDiagnostic"
  let guiGenResTy = bindSym"GuiGenerateResult"
  let checkGuiProjectSym = bindSym"checkGuiProject"
  let generateGuiProjectSym = bindSym"generateGuiProject"
  let defaultGenerateOptionsSym = bindSym"defaultGenerateOptions"

  result = newStmtList()
  result.add quote do:
    const `pathConstName`* = `pathLit`
    const `moduleConstName`* = `moduleLit`
  result.add actionEnumDef
  result.add quote do:
    proc `checkProcName`*(): seq[`guiDiagTy`] =
      `checkGuiProjectSym`(`pathLit`)

    proc `generateProcName`*(outDir = "out"): `guiGenResTy` =
      `generateGuiProjectSym`(`pathLit`, outDir, `defaultGenerateOptionsSym`())

    proc `sigProcName`*(): string =
      `irSig`

    proc `bridgeRegProcName`*() =
      discard

macro guiFile*(moduleName: untyped, path: static[string]): untyped =
  let modName = moduleName.repr
  var resolved = path
  let site = moduleName.lineInfoObj
  if not resolved.isAbsolute:
    let baseDir =
      if site.filename.len > 0:
        site.filename.parentDir()
      else:
        getCurrentDir()
    resolved = normalizedPath(baseDir / resolved)
  emitModuleBindings(modName, resolved)

macro guiBlock*(moduleName: untyped, body: untyped): untyped =
  let modName = moduleName.repr
  let site = moduleName.lineInfoObj
  let outPath = writeInlineDslFile(modName, body, site.filename)
  emitModuleBindings(modName, outPath)

macro guiBuild*(moduleName: untyped, body: untyped): untyped =
  let modName = moduleName.repr
  let site = moduleName.lineInfoObj
  let outPath = writeInlineDslFile(modName, body, site.filename)
  emitModuleBindings(modName, outPath)

macro guiInline*(moduleName: untyped, body: untyped): untyped =
  result = quote do:
    guiBlock(`moduleName`, `body`)

macro guiBridge*(moduleName: untyped, body: untyped): untyped =
  let modName = sanitizeIdent(moduleName.repr)
  let handlerTy = ident(modName & "BridgeHandler")
  let tableName = ident(modName & "BridgeHandlerTable")
  let registerProc = ident("register" & modName & "BridgeHandler")
  let dispatchProc = ident("dispatch" & modName & "BridgeAction")
  let initTableSym = bindSym"initTable"
  let scaffoldConst = ident(modName & "BridgeScaffold")

  let bodyText = newLit(body.repr)

  result = quote do:
    type `handlerTy`* = proc(payload: seq[byte]): seq[byte] {.closure.}
    var `tableName`* = `initTableSym`[string, `handlerTy`]()

    proc `registerProc`*(actionName: string, handler: `handlerTy`) =
      `tableName`[actionName] = handler

    proc `dispatchProc`*(actionName: string, payload: seq[byte]): seq[byte] =
      if actionName in `tableName`:
        return `tableName`[actionName](payload)
      @[]

    const `scaffoldConst`* = `bodyText`
