import Foundation
import SwiftUI

struct Todo: Codable {
  var id: Int = 0
  var title: String = ""
  var done: Bool = false
}

struct GUIState: Codable {
  var count: Int = 0
  var query: String = ""
  var networkStatus: String = "idle"
  var lastEvent: String = "none"
  var remindersEnabled: Bool = true
}

let guiBridgePollActionTag: UInt32? = nil
let guiBridgeValueTypeBool: UInt8 = 1
let guiBridgeValueTypeInt64: UInt8 = 2
let guiBridgeValueTypeDouble: UInt8 = 3
let guiBridgeValueTypeString: UInt8 = 4
let guiBridgeValueTypeJSON: UInt8 = 5

struct GUIBridgeFieldValue {
  var fieldId: UInt16
  var valueType: UInt8
  var payload: Data
}

private func guiBridgeEncodeInt64(_ value: Int64) -> Data {
  var le = value.littleEndian
  return withUnsafeBytes(of: &le) { Data($0) }
}

private func guiBridgeDecodeInt64(_ payload: Data) -> Int64? {
  guard payload.count == 8 else { return nil }
  var value: Int64 = 0
  _ = withUnsafeMutableBytes(of: &value) { payload.copyBytes(to: $0) }
  return Int64(littleEndian: value)
}

private func guiBridgeEncodeDouble(_ value: Double) -> Data {
  var bits = value.bitPattern.littleEndian
  return withUnsafeBytes(of: &bits) { Data($0) }
}

private func guiBridgeDecodeDouble(_ payload: Data) -> Double? {
  guard payload.count == 8 else { return nil }
  var bits: UInt64 = 0
  _ = withUnsafeMutableBytes(of: &bits) { payload.copyBytes(to: $0) }
  return Double(bitPattern: UInt64(littleEndian: bits))
}

private func guiBridgeDecodeBool(_ payload: Data) -> Bool? {
  guard payload.count == 1 else { return nil }
  return payload[0] != 0
}

private func guiBridgeEncodeString(_ value: String) -> Data {
  value.data(using: .utf8) ?? Data()
}

private func guiBridgeDecodeString(_ payload: Data) -> String? {
  String(data: payload, encoding: .utf8)
}

func guiBridgeEncodeRequestFields(actionTag: UInt32, state: GUIState?) -> [GUIBridgeFieldValue] {
  guard let state else { return [] }
  if let pollTag = guiBridgePollActionTag, actionTag == pollTag {
    return []
  }
  var out: [GUIBridgeFieldValue] = []
  return out
}

func guiBridgeApplyPatchField(state: inout GUIState, fieldId: UInt16, valueType: UInt8, payload: Data) -> Bool {
  switch fieldId {
  case 1:
    if valueType == guiBridgeValueTypeInt64, let decoded = guiBridgeDecodeInt64(payload) {
      state.count = Int(decoded)
      return true
    }
    if valueType == guiBridgeValueTypeJSON, let decoded = try? JSONDecoder().decode(Int.self, from: payload) {
      state.count = decoded
      return true
    }
    return false
  case 2:
    if valueType == guiBridgeValueTypeString, let decoded = guiBridgeDecodeString(payload) {
      state.query = decoded
      return true
    }
    if valueType == guiBridgeValueTypeJSON, let decoded = try? JSONDecoder().decode(String.self, from: payload) {
      state.query = decoded
      return true
    }
    return false
  case 3:
    if valueType == guiBridgeValueTypeString, let decoded = guiBridgeDecodeString(payload) {
      state.networkStatus = decoded
      return true
    }
    if valueType == guiBridgeValueTypeJSON, let decoded = try? JSONDecoder().decode(String.self, from: payload) {
      state.networkStatus = decoded
      return true
    }
    return false
  case 4:
    if valueType == guiBridgeValueTypeString, let decoded = guiBridgeDecodeString(payload) {
      state.lastEvent = decoded
      return true
    }
    if valueType == guiBridgeValueTypeJSON, let decoded = try? JSONDecoder().decode(String.self, from: payload) {
      state.lastEvent = decoded
      return true
    }
    return false
  case 5:
    if valueType == guiBridgeValueTypeBool, let decoded = guiBridgeDecodeBool(payload) {
      state.remindersEnabled = decoded
      return true
    }
    if valueType == guiBridgeValueTypeJSON, let decoded = try? JSONDecoder().decode(Bool.self, from: payload) {
      state.remindersEnabled = decoded
      return true
    }
    return false
  default:
    return false
  }
}

enum GUIAction: Equatable {
  case increment
  case tick
  case setQuery(value: String)
  case netSuccess
  case netError
  case streamEvent
  case wsMessage
  case chunkSeen
  case persisted
  case keychainOk
  case keychainErr
}

enum GUIActionOwner {
  case swift
  case nim
  case both
}

func guiActionOwner(_ action: GUIAction) -> GUIActionOwner {
  switch action {
  case .increment: return .swift
  case .tick: return .swift
  case .setQuery: return .swift
  case .netSuccess: return .swift
  case .netError: return .swift
  case .streamEvent: return .swift
  case .wsMessage: return .swift
  case .chunkSeen: return .swift
  case .persisted: return .swift
  case .keychainOk: return .swift
  case .keychainErr: return .swift
  }
}

func guiActionTag(_ action: GUIAction) -> UInt32 {
  switch action {
  case .increment: return 0
  case .tick: return 1
  case .setQuery: return 2
  case .netSuccess: return 3
  case .netError: return 4
  case .streamEvent: return 5
  case .wsMessage: return 6
  case .chunkSeen: return 7
  case .persisted: return 8
  case .keychainOk: return 9
  case .keychainErr: return 10
  }
}

func guiActionFromTag(_ tag: UInt32) -> GUIAction? {
  switch tag {
  case 0: return .increment
  case 1: return .tick
  case 2: return nil
  case 3: return .netSuccess
  case 4: return .netError
  case 5: return .streamEvent
  case 6: return .wsMessage
  case 7: return .chunkSeen
  case 8: return .persisted
  case 9: return .keychainOk
  case 10: return .keychainErr
  default: return nil
  }
}

func guiActionOwnerText(_ owner: GUIActionOwner) -> String {
  switch owner {
  case .swift: return "swift"
  case .nim: return "nim"
  case .both: return "both"
  }
}

enum GUITokens {
  static let color_primary: Color = guiColor("#2dd4bf")
  static let color_surface: Color = guiColor("#0f172a")
  static let spacing_sm: Double = 8.0
  static let spacing_md: Double = 16.0
  static let spacing_lg: Double = 24.0
}

@MainActor
func guiReduce(state: inout GUIState, action: GUIAction) -> [GUIEffectCommand] {
  var effects: [GUIEffectCommand] = []

  switch action {
  case .increment:
    state.count = (state.count + 1)
    effects.append(GUIEffectCommand(name: "timer.once", args: ["ms": .int(250), "action": .action(.tick)]))
    effects.append(GUIEffectCommand(name: "timer.debounce", args: ["id": .string("search"), "ms": .int(400), "action": .action(.persisted)]))
    effects.append(GUIEffectCommand(name: "persist.defaults", args: ["key": .string("count"), "value": GUIAnyValue.from(state.count)]))
  case .tick:
    state.networkStatus = "tick"
    effects.append(GUIEffectCommand(name: "timer.interval", args: ["id": .string("heartbeat"), "ms": .int(5000), "action": .action(.tick)]))
  case let .setQuery(value):
    state.query = value
    effects.append(GUIEffectCommand(name: "persist.file", args: ["key": .string("query"), "value": GUIAnyValue.from(value)]))
    effects.append(GUIEffectCommand(name: "http.request", args: ["method": .string("GET"), "url": .string("https://example.com"), "onSuccess": .action(.netSuccess), "onError": .action(.netError)]))
  case .netSuccess:
    state.networkStatus = "ok"
    effects.append(GUIEffectCommand(name: "stream.sse", args: ["url": .string("https://example.com/events"), "onEvent": .action(.streamEvent), "onError": .action(.netError)]))
    effects.append(GUIEffectCommand(name: "stream.ws", args: ["url": .string("wss://echo.websocket.events"), "onMessage": .action(.wsMessage), "onError": .action(.netError), "onClose": .action(.netError)]))
    effects.append(GUIEffectCommand(name: "stream.httpChunked", args: ["url": .string("https://example.com/chunks"), "onChunk": .action(.chunkSeen), "onError": .action(.netError)]))
  case .netError:
    state.networkStatus = "error"
  case .streamEvent:
    state.lastEvent = "sse"
  case .wsMessage:
    state.lastEvent = "ws"
  case .chunkSeen:
    state.lastEvent = "chunk"
  case .persisted:
    effects.append(GUIEffectCommand(name: "keychain.add", args: ["service": .string("dev.cps.gui"), "account": .string("session"), "value": GUIAnyValue.from(state.query), "attrs": .object(["kSecAttrSynchronizable": .bool(true), "kSecAttrLabel": .string("Momentum Session")])]))
    effects.append(GUIEffectCommand(name: "keychain.query", args: ["service": .string("dev.cps.gui"), "account": .string("session"), "onSuccess": .action(.keychainOk), "onError": .action(.keychainErr)]))
    effects.append(GUIEffectCommand(name: "keychain.update", args: ["service": .string("dev.cps.gui"), "account": .string("session"), "value": GUIAnyValue.from(state.query)]))
    effects.append(GUIEffectCommand(name: "keychain.delete", args: ["service": .string("dev.cps.gui"), "account": .string("obsolete")]))
  case .keychainOk:
    state.lastEvent = "keychain-ok"
  case .keychainErr:
    state.lastEvent = "keychain-error"
  default:
    break
  }

  return effects
}

@MainActor
final class GUIStore: ObservableObject {
  @Published var state: GUIState
  private lazy var runtime = GUIRuntime(store: self)

  init(initial: GUIState = GUIState()) {
    self.state = initial
  }

  func send(_ action: GUIAction) {
    var next = state
    let owner = guiActionOwner(action)
    var effects: [GUIEffectCommand] = []
    if owner != .nim {
      effects.append(contentsOf: guiReduce(state: &next, action: action))
    }
    if owner != .swift {
      effects.append(GUIEffectCommand(name: "bridge.dispatch", args: [
        "action": .action(action),
        "actionTag": .int(Int(guiActionTag(action))),
        "owner": .string(guiActionOwnerText(owner))
      ]))
    }
    state = next
    runtime.enqueue(effects)
  }

  func shutdown(completion: @escaping () -> Void) {
    runtime.shutdown()
    completion()
  }
}

struct Component_Dashboard: View {
  @ObservedObject var store: GUIStore

  var body: some View {
    VStack(spacing: GUITokens.spacing_md) {
      Text("Momentum GUI")
      .foregroundColor(GUITokens.color_primary)
      Text((String(describing: "Count: ") + String(describing: store.state.count)))
      Text((String(describing: "Query: ") + String(describing: store.state.query)))
      Text((String(describing: "Network: ") + String(describing: store.state.networkStatus)))
      Text((String(describing: "Last Event: ") + String(describing: store.state.lastEvent)))
      HStack(spacing: GUITokens.spacing_sm) {
        Button("Increment") { store.send(.increment) }
        Button("Mark OK") { store.send(.netSuccess) }
        Button("Mark Error") { store.send(.netError) }
      }
      NavigationLink("Open detail", value: "detail")
      .padding(GUITokens.spacing_sm)
    }
    .padding(GUITokens.spacing_lg)
  }
}

#Preview {
  Component_Dashboard(store: GUIStore())
}

struct Component_Detail: View {
  @ObservedObject var store: GUIStore

  var body: some View {
    VStack(spacing: GUITokens.spacing_md) {
      Text("Detail Screen")
      Text((String(describing: "Count is ") + String(describing: store.state.count)))
      Button("Tick now") { store.send(.tick) }
    }
    .padding(GUITokens.spacing_lg)
  }
}

#Preview {
  Component_Detail(store: GUIStore())
}

struct Component_Settings: View {
  @ObservedObject var store: GUIStore

  var body: some View {
    VStack(spacing: GUITokens.spacing_md) {
      Text("Settings")
      Text((String(describing: "Reminders: ") + String(describing: store.state.remindersEnabled)))
      Button("Persist") { store.send(.persisted) }
    }
    .padding(GUITokens.spacing_lg)
  }
}

#Preview {
  Component_Settings(store: GUIStore())
}

struct Component_ActivityFeed: View {
  @ObservedObject var store: GUIStore

  var body: some View {
    VStack(spacing: GUITokens.spacing_sm) {
      Text("Activity")
      Text(store.state.lastEvent)
    }
  }
}

#Preview {
  Component_ActivityFeed(store: GUIStore())
}

struct GUIRootView: View {
  @ObservedObject var store: GUIStore
  @State private var path_dashboard: [String] = []
  @State private var path_settings: [String] = []

  var body: some View {
    TabView {
      NavigationStack(path: $path_dashboard) {
        Component_Dashboard(store: store)
        .navigationDestination(for: String.self) { route in
          switch route {
          case "detail":
            Component_Detail(store: store)
          default:
            EmptyView()
          }
        }
      }
      .tabItem {
        Text("dashboard")
      }
      NavigationStack(path: $path_settings) {
        Component_Settings(store: store)
        .navigationDestination(for: String.self) { route in
          switch route {
          case "detail":
            Component_Detail(store: store)
          default:
            EmptyView()
          }
        }
      }
      .tabItem {
        Text("settings")
      }
    }
  }
}

@main
struct MomentumGui: App {
  @StateObject private var store = GUIStore()

  var body: some Scene {
    WindowGroup {
      GUIRootView(store: store)
        .onDisappear {
        }
    }
  }
}
