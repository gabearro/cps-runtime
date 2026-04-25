## Bridge artifact codegen for Swift/header side.

import std/strutils
import ./ir

const
  guiBridgeAbiVersion* = 5'u32

proc swiftEscape(value: string): string =
  value
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")
    .replace("\n", "\\n")
    .replace("\r", "\\r")
    .replace("\t", "\\t")

proc upperSnake(value: string): string =
  var text = ""
  var prevUnderscore = false
  for c in value:
    let mapped =
      if c.isAlphaNumeric:
        if c.isUpperAscii: c else: c.toUpperAscii
      else:
        '_'
    if mapped == '_':
      if prevUnderscore:
        continue
      prevUnderscore = true
    else:
      prevUnderscore = false
    text.add mapped
  if text.len == 0:
    return "UNKNOWN"
  text

proc emitBridgeHeader*(irProgram: GuiIrProgram): string =
  var lines: seq[string] = @[]

  lines.add "#ifndef GUI_BRIDGE_GENERATED_H"
  lines.add "#define GUI_BRIDGE_GENERATED_H"
  lines.add ""
  lines.add "#include <stdint.h>"
  lines.add "#include <stddef.h>"
  lines.add ""
  lines.add "#ifdef __cplusplus"
  lines.add "extern \"C\" {"
  lines.add "#endif"
  lines.add ""
  lines.add "enum { GUI_BRIDGE_ABI_VERSION = " & $guiBridgeAbiVersion & "u };"
  lines.add ""

  lines.add "typedef enum GUIBridgeActionTag {"
  if irProgram.actions.len == 0:
    lines.add "  GUI_BRIDGE_ACTION_NONE = 0"
  else:
    for i, action in irProgram.actions:
      let comma = if i + 1 < irProgram.actions.len: "," else: ""
      lines.add "  GUI_BRIDGE_ACTION_" & upperSnake(action.name) & " = " & $i & comma
  lines.add "} GUIBridgeActionTag;"
  lines.add ""

  lines.add "typedef struct GUIBridgeBuffer {"
  lines.add "  uint8_t* data;"
  lines.add "  uint32_t len;"
  lines.add "} GUIBridgeBuffer;"
  lines.add ""
  lines.add "typedef struct GUIBridgeDispatchOutput {"
  lines.add "  GUIBridgeBuffer statePatch;"
  lines.add "  GUIBridgeBuffer effects;"
  lines.add "  GUIBridgeBuffer emittedActions;"
  lines.add "  GUIBridgeBuffer diagnostics;"
  lines.add "} GUIBridgeDispatchOutput;"
  lines.add ""
  lines.add "typedef void* (*GUIBridgeAllocFn)(size_t size);"
  lines.add "typedef void (*GUIBridgeFreeFn)(void* ptr);"
  lines.add "typedef int32_t (*GUIBridgeDispatchFn)(const uint8_t* payload, uint32_t payloadLen, GUIBridgeDispatchOutput* out);"
  lines.add "typedef int32_t (*GUIBridgeGetNotifyFdFn)(void);"
  lines.add "typedef int32_t (*GUIBridgeWaitShutdownFn)(int32_t timeoutMs);"
  lines.add ""
  lines.add "typedef struct GUIBridgeFunctionTable {"
  lines.add "  uint32_t abiVersion;"
  lines.add "  GUIBridgeAllocFn alloc;"
  lines.add "  GUIBridgeFreeFn free;"
  lines.add "  GUIBridgeDispatchFn dispatch;"
  lines.add "  GUIBridgeGetNotifyFdFn getNotifyFd;"
  lines.add "  GUIBridgeWaitShutdownFn waitShutdown;"
  lines.add "} GUIBridgeFunctionTable;"
  lines.add ""
  lines.add "const GUIBridgeFunctionTable* gui_bridge_get_table(void);"
  lines.add ""
  lines.add "#ifdef __cplusplus"
  lines.add "}"
  lines.add "#endif"
  lines.add ""
  lines.add "#endif"

  lines.join("\n") & "\n"

proc emitBridgeSwiftWrapper*(irProgram: GuiIrProgram): string =
  var lines: seq[string] = @[]

  lines.add "import Foundation"
  lines.add "import Darwin"
  lines.add ""
  lines.add "let GUIBridgeAbiVersion: UInt32 = " & $guiBridgeAbiVersion
  lines.add ""
  lines.add "struct GUIBridgeDispatchResult {"
  lines.add "  var status: Int32"
  lines.add "  var statePatch: Data"
  lines.add "  var effects: Data"
  lines.add "  var emittedActions: Data"
  lines.add "  var diagnostics: Data"
  lines.add ""
  lines.add "  static var empty: GUIBridgeDispatchResult {"
  lines.add "    GUIBridgeDispatchResult(status: 0, statePatch: Data(), effects: Data(), emittedActions: Data(), diagnostics: Data())"
  lines.add "  }"
  lines.add "}"
  lines.add ""
  lines.add "private struct GUIBridgeBuffer {"
  lines.add "  var data: UnsafeMutablePointer<UInt8>?"
  lines.add "  var len: UInt32"
  lines.add "}"
  lines.add ""
  lines.add "private struct GUIBridgeDispatchOutput {"
  lines.add "  var statePatch: GUIBridgeBuffer"
  lines.add "  var effects: GUIBridgeBuffer"
  lines.add "  var emittedActions: GUIBridgeBuffer"
  lines.add "  var diagnostics: GUIBridgeBuffer"
  lines.add ""
  lines.add "  static var empty: GUIBridgeDispatchOutput {"
  lines.add "    GUIBridgeDispatchOutput(statePatch: GUIBridgeBuffer(data: nil, len: 0), effects: GUIBridgeBuffer(data: nil, len: 0), emittedActions: GUIBridgeBuffer(data: nil, len: 0), diagnostics: GUIBridgeBuffer(data: nil, len: 0))"
  lines.add "  }"
  lines.add "}"
  lines.add ""
  lines.add "private struct GUIBridgeFunctionTable {"
  lines.add "  var abiVersion: UInt32"
  lines.add "  var alloc: (@convention(c) (Int) -> UnsafeMutableRawPointer?)?"
  lines.add "  var free: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?"
  lines.add "  var dispatch: (@convention(c) (UnsafePointer<UInt8>?, UInt32, UnsafeMutableRawPointer?) -> Int32)?"
  lines.add "  var getNotifyFd: (@convention(c) () -> Int32)?"
  lines.add "  var waitShutdown: (@convention(c) (Int32) -> Int32)?"
  lines.add "}"
  lines.add ""
  lines.add "private typealias GUIBridgeGetTableFn = @convention(c) () -> UnsafeRawPointer?"
  lines.add ""
  lines.add "final class GUIBridgeRuntime {"
  lines.add "  private var dylib: UnsafeMutableRawPointer?"
  lines.add "  private var table: GUIBridgeFunctionTable?"
  lines.add "  private var loadedPath: String = \"\""
  lines.add "  private var lastLoadTime: Date = .distantPast"
  lines.add ""
  lines.add "  func load(path: String) -> Bool {"
  lines.add "    if loadedPath == path, table != nil { return true }"
  lines.add "    unload()"
  lines.add ""
  lines.add "    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {"
  lines.add "      return false"
  lines.add "    }"
  lines.add "    guard let sym = dlsym(handle, \"gui_bridge_get_table\") else {"
  lines.add "      dlclose(handle)"
  lines.add "      return false"
  lines.add "    }"
  lines.add ""
  lines.add "    let getter = unsafeBitCast(sym, to: GUIBridgeGetTableFn.self)"
  lines.add "    guard let rawTable = getter() else {"
  lines.add "      dlclose(handle)"
  lines.add "      return false"
  lines.add "    }"
  lines.add "    let ptr = rawTable.assumingMemoryBound(to: GUIBridgeFunctionTable.self)"
  lines.add "    let t = ptr.pointee"
  lines.add "    guard t.abiVersion == GUIBridgeAbiVersion else {"
  lines.add "      dlclose(handle)"
  lines.add "      return false"
  lines.add "    }"
  lines.add ""
  lines.add "    dylib = handle"
  lines.add "    table = t"
  lines.add "    loadedPath = path"
  lines.add "    lastLoadTime = Date()"
  lines.add "    return true"
  lines.add "  }"
  lines.add ""
  lines.add "  func unload() {"
  lines.add "    table = nil"
  lines.add "    loadedPath = \"\""
  lines.add "    if let handle = dylib {"
  lines.add "      dlclose(handle)"
  lines.add "    }"
  lines.add "    dylib = nil"
  lines.add "  }"
  lines.add ""
  lines.add "  func dispatch(payload: Data) -> GUIBridgeDispatchResult {"
  lines.add "    guard let t = table, let dispatchFn = t.dispatch else {"
  lines.add "      return .empty"
  lines.add "    }"
  lines.add ""
  lines.add "    var out = GUIBridgeDispatchOutput.empty"
  lines.add "    let status: Int32 = payload.withUnsafeBytes { bytes in"
  lines.add "      withUnsafeMutablePointer(to: &out) { outPtr in"
  lines.add "        dispatchFn(bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(payload.count), UnsafeMutableRawPointer(outPtr))"
  lines.add "      }"
  lines.add "    }"
  lines.add ""
  lines.add "    func bufferToData(_ buffer: GUIBridgeBuffer) -> Data {"
  lines.add "      guard let ptr = buffer.data, buffer.len > 0 else { return Data() }"
  lines.add "      let data = Data(bytes: ptr, count: Int(buffer.len))"
  lines.add "      if let freeFn = t.free {"
  lines.add "        freeFn(UnsafeMutableRawPointer(ptr))"
  lines.add "      }"
  lines.add "      return data"
  lines.add "    }"
  lines.add ""
  lines.add "    return GUIBridgeDispatchResult(status: status, statePatch: bufferToData(out.statePatch), effects: bufferToData(out.effects), emittedActions: bufferToData(out.emittedActions), diagnostics: bufferToData(out.diagnostics))"
  lines.add "  }"
  lines.add ""
  lines.add "  func getNotifyFd() -> Int32 {"
  lines.add "    guard let t = table, let fn = t.getNotifyFd else { return -1 }"
  lines.add "    return fn()"
  lines.add "  }"
  lines.add ""
  lines.add "  func waitShutdown(timeoutMs: Int32) -> Bool {"
  lines.add "    guard let t = table, let fn = t.waitShutdown else { return false }"
  lines.add "    return fn(timeoutMs) != 0"
  lines.add "  }"
  lines.add ""
  lines.add "  func maybeReload(path: String) {"
  lines.add "    let fm = FileManager.default"
  lines.add "    guard let attrs = try? fm.attributesOfItem(atPath: path),"
  lines.add "          let mtime = attrs[.modificationDate] as? Date else {"
  lines.add "      return"
  lines.add "    }"
  lines.add "    if mtime > lastLoadTime {"
  lines.add "      _ = load(path: path)"
  lines.add "    }"
  lines.add "  }"
  lines.add "}"
  lines.add ""
  lines.add "let guiBridgeActionNames: [String] = ["
  for i, action in irProgram.actions:
    let suffix = if i + 1 < irProgram.actions.len: "," else: ""
    lines.add "  \"" & swiftEscape(action.name) & "\"" & suffix
  lines.add "]"

  lines.join("\n") & "\n"
