## Nim macro surface for GUI v2.

import std/[os, strutils, tables]
import std/macros
import ./types
import ./parser
import ./sema
import ./ir_v2
import ../gui

proc sanitizeIdent(text: string): string {.compileTime.} =
  var normalized = newStringOfCap(text.len)
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

proc resolveBaseDir(filename: string): string {.compileTime.} =
  if filename.len > 0: filename.parentDir()
  else: getCurrentDir()

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

proc writeInlineDslFile(sanitizedName: string, body: NimNode, siteFile: string): string {.compileTime.} =
  let dsl = inlineDslFromBody(body)
  let cacheDir = normalizedPath(resolveBaseDir(siteFile) / ".guiinline")
  createDir(cacheDir)
  result = cacheDir / (sanitizedName & ".generated.gui")
  let content = dsl.strip() & "\n"
  # Skip write if content unchanged to avoid timestamp churn
  var existing = ""
  try: existing = readFile(result)
  except: discard
  if existing != content:
    writeFile(result, content)

proc formatDiagnostics(phase: string, path: string, diags: seq[GuiDiagnostic]): string {.compileTime.} =
  result = "gui macro " & phase & " failed for " & path & ":"
  for d in diags:
    if d.isError:
      result.add "\n  " & d.message

proc emitModuleBindings(moduleBase: string, moduleName: string, guiPath: string): NimNode {.compileTime.} =
  let parsed = parseGuiProgram(guiPath)
  if parsed.diagnostics.hasErrors:
    error(formatDiagnostics("parse", guiPath, parsed.diagnostics))

  let sem = semanticCheck(parsed.program)
  if sem.diagnostics.hasErrors:
    error(formatDiagnostics("semantic check", guiPath, sem.diagnostics))

  let irProgram = buildIrV2(sem)

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
  let moduleBase = sanitizeIdent(modName)
  var resolved = path
  if not resolved.isAbsolute:
    resolved = normalizedPath(resolveBaseDir(moduleName.lineInfoObj.filename) / resolved)
  emitModuleBindings(moduleBase, modName, resolved)

proc inlineGuiImpl(moduleName, body: NimNode): NimNode {.compileTime.} =
  let modName = moduleName.repr
  let moduleBase = sanitizeIdent(modName)
  let outPath = writeInlineDslFile(moduleBase, body, moduleName.lineInfoObj.filename)
  emitModuleBindings(moduleBase, modName, outPath)

macro guiBlock*(moduleName: untyped, body: untyped): untyped =
  inlineGuiImpl(moduleName, body)

macro guiBuild*(moduleName: untyped, body: untyped): untyped =
  inlineGuiImpl(moduleName, body)

macro guiInline*(moduleName: untyped, body: untyped): untyped =
  inlineGuiImpl(moduleName, body)

macro guiBridge*(moduleName: untyped, body: untyped): untyped =
  let modName = sanitizeIdent(moduleName.repr)
  let handlerTy = ident(modName & "BridgeHandler")
  let tableName = ident(modName & "BridgeHandlerTable")
  let registerProc = ident("register" & modName & "BridgeHandler")
  let dispatchProc = ident("dispatch" & modName & "BridgeAction")
  let initTableSym = bindSym"initTable"
  let getOrDefaultSym = bindSym"getOrDefault"
  let scaffoldConst = ident(modName & "BridgeScaffold")

  let bodyText = newLit(body.repr)

  result = quote do:
    type `handlerTy`* = proc(payload: seq[byte]): seq[byte] {.closure.}
    var `tableName`* = `initTableSym`[string, `handlerTy`]()

    proc `registerProc`*(actionName: string, handler: `handlerTy`) =
      `tableName`[actionName] = handler

    proc `dispatchProc`*(actionName: string, payload: seq[byte]): seq[byte] =
      let handler = `getOrDefaultSym`(`tableName`, actionName)
      if not handler.isNil:
        return handler(payload)
      @[]

    const `scaffoldConst`* = `bodyText`
