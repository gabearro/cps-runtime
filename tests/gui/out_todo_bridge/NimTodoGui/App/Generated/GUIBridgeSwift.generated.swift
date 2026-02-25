import Foundation
import Darwin

let GUIBridgeAbiVersion: UInt32 = 2

struct GUIBridgeDispatchResult {
  var status: Int32
  var statePatch: Data
  var effects: Data
  var emittedActions: Data
  var diagnostics: Data

  static var empty: GUIBridgeDispatchResult {
    GUIBridgeDispatchResult(status: 0, statePatch: Data(), effects: Data(), emittedActions: Data(), diagnostics: Data())
  }
}

private struct GUIBridgeBuffer {
  var data: UnsafeMutablePointer<UInt8>?
  var len: UInt32
}

private struct GUIBridgeDispatchOutput {
  var statePatch: GUIBridgeBuffer
  var effects: GUIBridgeBuffer
  var emittedActions: GUIBridgeBuffer
  var diagnostics: GUIBridgeBuffer

  static var empty: GUIBridgeDispatchOutput {
    GUIBridgeDispatchOutput(statePatch: GUIBridgeBuffer(data: nil, len: 0), effects: GUIBridgeBuffer(data: nil, len: 0), emittedActions: GUIBridgeBuffer(data: nil, len: 0), diagnostics: GUIBridgeBuffer(data: nil, len: 0))
  }
}

private struct GUIBridgeFunctionTable {
  var abiVersion: UInt32
  var alloc: (@convention(c) (Int) -> UnsafeMutableRawPointer?)?
  var free: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
  var dispatch: (@convention(c) (UnsafePointer<UInt8>?, UInt32, UnsafeMutableRawPointer?) -> Int32)?
}

private typealias GUIBridgeGetTableFn = @convention(c) () -> UnsafeRawPointer?

final class GUIBridgeRuntime {
  private var dylib: UnsafeMutableRawPointer?
  private var table: GUIBridgeFunctionTable?
  private var loadedPath: String = ""
  private var lastLoadTime: Date = .distantPast

  func load(path: String) -> Bool {
    if loadedPath == path, table != nil { return true }
    unload()

    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
      return false
    }
    guard let sym = dlsym(handle, "gui_bridge_get_table") else {
      dlclose(handle)
      return false
    }

    let getter = unsafeBitCast(sym, to: GUIBridgeGetTableFn.self)
    guard let rawTable = getter() else {
      dlclose(handle)
      return false
    }
    let ptr = rawTable.assumingMemoryBound(to: GUIBridgeFunctionTable.self)
    let t = ptr.pointee
    guard t.abiVersion == GUIBridgeAbiVersion else {
      dlclose(handle)
      return false
    }

    dylib = handle
    table = t
    loadedPath = path
    lastLoadTime = Date()
    return true
  }

  func unload() {
    table = nil
    loadedPath = ""
    if let handle = dylib {
      dlclose(handle)
    }
    dylib = nil
  }

  func dispatch(payload: Data) -> GUIBridgeDispatchResult {
    guard var t = table, let dispatchFn = t.dispatch else {
      return .empty
    }

    var out = GUIBridgeDispatchOutput.empty
    let status: Int32 = payload.withUnsafeBytes { bytes in
      withUnsafeMutablePointer(to: &out) { outPtr in
        dispatchFn(bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(payload.count), UnsafeMutableRawPointer(outPtr))
      }
    }

    func bufferToData(_ buffer: GUIBridgeBuffer) -> Data {
      guard let ptr = buffer.data, buffer.len > 0 else { return Data() }
      let data = Data(bytes: ptr, count: Int(buffer.len))
      if let freeFn = t.free {
        freeFn(UnsafeMutableRawPointer(ptr))
      }
      return data
    }

    return GUIBridgeDispatchResult(status: status, statePatch: bufferToData(out.statePatch), effects: bufferToData(out.effects), emittedActions: bufferToData(out.emittedActions), diagnostics: bufferToData(out.diagnostics))
  }

  func maybeReload(path: String) {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: path),
          let mtime = attrs[.modificationDate] as? Date else {
      return
    }
    if mtime > lastLoadTime {
      _ = load(path: path)
    }
  }
}

let guiBridgeActionNames: [String] = [
  "CreateTask",
  "ClearDraftTitle",
  "SetDraftBacklog",
  "SetDraftInProgress",
  "SetDraftBlocked",
  "SetDraftPriorityLow",
  "SetDraftPriorityMedium",
  "SetDraftPriorityHigh",
  "SetDraftPriorityUrgent",
  "ApplySearch",
  "ClearSearch",
  "SetFilterAll",
  "SetFilterOpen",
  "SetFilterDone",
  "SetFilterBlocked",
  "SetSortNewest",
  "SetSortDueSoonest",
  "SetSortPriority",
  "SelectTask",
  "RenameActiveTask",
  "SetActiveDueDate",
  "ClearActiveDueDate",
  "SetActiveStatusBacklog",
  "SetActiveStatusInProgress",
  "SetActiveStatusBlocked",
  "SetActiveStatusDone",
  "CompleteActiveTask",
  "ReopenActiveTask",
  "RemoveActiveTask",
  "ClearCompleted",
  "LoadDemoData",
  "ResetTodos",
  "PersistPreferences",
  "MoveActiveTaskUp",
  "MoveActiveTaskDown"
]
