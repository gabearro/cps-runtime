import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct TodoTask: Codable {
  var id: Int
  var title: String
  var statusText: String
  var priorityText: String
  var dueDateText: String
  var done: Bool
  var blocked: Bool
  var active: Bool
  var overdue: Bool
}

struct GUIState: Codable {
  var todoCount: Int = 0
  var openCount: Int = 0
  var doneCount: Int = 0
  var blockedCount: Int = 0
  var newTaskTitle: String = ""
  var draftDueDate: String = ""
  var searchQuery: String = ""
  var draftStatusBacklog: Bool = true
  var draftStatusInProgress: Bool = false
  var draftStatusBlocked: Bool = false
  var draftPriorityLow: Bool = false
  var draftPriorityMedium: Bool = true
  var draftPriorityHigh: Bool = false
  var draftPriorityUrgent: Bool = false
  var filterAll: Bool = true
  var filterOpen: Bool = false
  var filterDone: Bool = false
  var filterBlocked: Bool = false
  var sortNewest: Bool = true
  var sortDueSoonest: Bool = false
  var sortPriority: Bool = false
  var tasks: [TodoTask] = []
  var selectedTaskId: Int = (0 - 1)
  var selectedTaskTitle: String = "No task selected"
  var editTaskTitle: String = ""
  var editTaskDueDate: String = ""
  var compactMode: Bool = false
  var status: String = "Ready"
}

enum GUIAction: Equatable {
  case createTask
  case clearDraftTitle
  case setDraftBacklog
  case setDraftInProgress
  case setDraftBlocked
  case setDraftPriorityLow
  case setDraftPriorityMedium
  case setDraftPriorityHigh
  case setDraftPriorityUrgent
  case applySearch
  case clearSearch
  case setFilterAll
  case setFilterOpen
  case setFilterDone
  case setFilterBlocked
  case setSortNewest
  case setSortDueSoonest
  case setSortPriority
  case selectTask(taskId: Int)
  case renameActiveTask
  case setActiveDueDate
  case clearActiveDueDate
  case setActiveStatusBacklog
  case setActiveStatusInProgress
  case setActiveStatusBlocked
  case setActiveStatusDone
  case completeActiveTask
  case reopenActiveTask
  case removeActiveTask
  case clearCompleted
  case loadDemoData
  case resetTodos
  case persistPreferences
  case moveActiveTaskUp
  case moveActiveTaskDown
}

enum GUIActionOwner {
  case swift
  case nim
  case both
}

func guiActionOwner(_ action: GUIAction) -> GUIActionOwner {
  switch action {
  case .createTask: return .nim
  case .clearDraftTitle: return .nim
  case .setDraftBacklog: return .nim
  case .setDraftInProgress: return .nim
  case .setDraftBlocked: return .nim
  case .setDraftPriorityLow: return .nim
  case .setDraftPriorityMedium: return .nim
  case .setDraftPriorityHigh: return .nim
  case .setDraftPriorityUrgent: return .nim
  case .applySearch: return .nim
  case .clearSearch: return .nim
  case .setFilterAll: return .nim
  case .setFilterOpen: return .nim
  case .setFilterDone: return .nim
  case .setFilterBlocked: return .nim
  case .setSortNewest: return .nim
  case .setSortDueSoonest: return .nim
  case .setSortPriority: return .nim
  case .selectTask: return .both
  case .renameActiveTask: return .nim
  case .setActiveDueDate: return .nim
  case .clearActiveDueDate: return .nim
  case .setActiveStatusBacklog: return .nim
  case .setActiveStatusInProgress: return .nim
  case .setActiveStatusBlocked: return .nim
  case .setActiveStatusDone: return .nim
  case .completeActiveTask: return .nim
  case .reopenActiveTask: return .nim
  case .removeActiveTask: return .nim
  case .clearCompleted: return .nim
  case .loadDemoData: return .nim
  case .resetTodos: return .nim
  case .persistPreferences: return .nim
  case .moveActiveTaskUp: return .nim
  case .moveActiveTaskDown: return .nim
  }
}

func guiActionTag(_ action: GUIAction) -> UInt32 {
  switch action {
  case .createTask: return 0
  case .clearDraftTitle: return 1
  case .setDraftBacklog: return 2
  case .setDraftInProgress: return 3
  case .setDraftBlocked: return 4
  case .setDraftPriorityLow: return 5
  case .setDraftPriorityMedium: return 6
  case .setDraftPriorityHigh: return 7
  case .setDraftPriorityUrgent: return 8
  case .applySearch: return 9
  case .clearSearch: return 10
  case .setFilterAll: return 11
  case .setFilterOpen: return 12
  case .setFilterDone: return 13
  case .setFilterBlocked: return 14
  case .setSortNewest: return 15
  case .setSortDueSoonest: return 16
  case .setSortPriority: return 17
  case .selectTask: return 18
  case .renameActiveTask: return 19
  case .setActiveDueDate: return 20
  case .clearActiveDueDate: return 21
  case .setActiveStatusBacklog: return 22
  case .setActiveStatusInProgress: return 23
  case .setActiveStatusBlocked: return 24
  case .setActiveStatusDone: return 25
  case .completeActiveTask: return 26
  case .reopenActiveTask: return 27
  case .removeActiveTask: return 28
  case .clearCompleted: return 29
  case .loadDemoData: return 30
  case .resetTodos: return 31
  case .persistPreferences: return 32
  case .moveActiveTaskUp: return 33
  case .moveActiveTaskDown: return 34
  }
}

func guiActionFromTag(_ tag: UInt32) -> GUIAction? {
  switch tag {
  case 0: return .createTask
  case 1: return .clearDraftTitle
  case 2: return .setDraftBacklog
  case 3: return .setDraftInProgress
  case 4: return .setDraftBlocked
  case 5: return .setDraftPriorityLow
  case 6: return .setDraftPriorityMedium
  case 7: return .setDraftPriorityHigh
  case 8: return .setDraftPriorityUrgent
  case 9: return .applySearch
  case 10: return .clearSearch
  case 11: return .setFilterAll
  case 12: return .setFilterOpen
  case 13: return .setFilterDone
  case 14: return .setFilterBlocked
  case 15: return .setSortNewest
  case 16: return .setSortDueSoonest
  case 17: return .setSortPriority
  case 18: return nil
  case 19: return .renameActiveTask
  case 20: return .setActiveDueDate
  case 21: return .clearActiveDueDate
  case 22: return .setActiveStatusBacklog
  case 23: return .setActiveStatusInProgress
  case 24: return .setActiveStatusBlocked
  case 25: return .setActiveStatusDone
  case 26: return .completeActiveTask
  case 27: return .reopenActiveTask
  case 28: return .removeActiveTask
  case 29: return .clearCompleted
  case 30: return .loadDemoData
  case 31: return .resetTodos
  case 32: return .persistPreferences
  case 33: return .moveActiveTaskUp
  case 34: return .moveActiveTaskDown
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
  static let color_panelRaised: Color = guiColor("#ffffff")
  static let color_rowBackground: Color = guiColor("#ffffff")
  static let color_rowActive: Color = guiColor("#e8f0ff")
  static let color_badge: Color = guiColor("#edf1f7")
  static let color_accent: Color = guiColor("#2563eb")
  static let color_info: Color = guiColor("#0f766e")
  static let color_success: Color = guiColor("#15803d")
  static let color_warning: Color = guiColor("#b45309")
  static let color_muted: Color = guiColor("#94a3b8")
  static let color_textPrimary: Color = guiColor("#0f172a")
  static let color_textMuted: Color = guiColor("#475569")
  static let color_textSubtle: Color = guiColor("#64748b")
  static let spacing_xs: Double = 6.0
  static let spacing_sm: Double = 10.0
  static let spacing_md: Double = 16.0
  static let spacing_lg: Double = 22.0
}

@MainActor
func guiReduce(state: inout GUIState, action: GUIAction) -> [GUIEffectCommand] {
  var effects: [GUIEffectCommand] = []

  switch action {
  case let .selectTask(taskId):
    state.selectedTaskId = taskId
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

  func shutdown() {
    runtime.shutdown()
  }
}

struct Component_SidebarMetric: View {
  @ObservedObject var store: GUIStore
  var title: String
  var value: String
  var subtitle: String
  var tint: Color

  var body: some View {
    VStack(alignment: HorizontalAlignment.leading, spacing: GUITokens.spacing_xs) {
      Text(title)
      .font(Font.system(size: 11, weight: Font.Weight.semibold, design: Font.Design.default))
      .foregroundColor(GUITokens.color_textMuted)
      Text(value)
      .font(Font.system(size: 22, weight: Font.Weight.bold, design: Font.Design.default))
      .foregroundColor(tint)
      Text(subtitle)
      .font(Font.system(size: 11, weight: Font.Weight.medium, design: Font.Design.default))
      .foregroundColor(GUITokens.color_textSubtle)
      .lineLimit(1)
    }
    .frame(maxWidth: Double.infinity, alignment: Alignment.leading)
    .padding(GUITokens.spacing_sm)
    .background(GUITokens.color_panelRaised)
    .cornerRadius(GUITokens.spacing_sm)
  }
}

struct Component_TodoRow: View {
  @ObservedObject var store: GUIStore
  var task: TodoTask

  var body: some View {
    HStack(spacing: GUITokens.spacing_sm) {
      Image(systemName: ((task.done) ? ("checkmark.circle.fill") : (((task.blocked) ? ("exclamationmark.triangle.fill") : (((task.overdue) ? ("clock.badge.exclamationmark") : ("circle")))))))
      .font(Font.system(size: 15, weight: Font.Weight.semibold, design: Font.Design.default))
      .foregroundColor(((task.done) ? (GUITokens.color_success) : (((task.blocked) ? (GUITokens.color_warning) : (((task.overdue) ? (GUITokens.color_warning) : (GUITokens.color_accent)))))))
      VStack(alignment: HorizontalAlignment.leading, spacing: 4) {
        HStack(spacing: GUITokens.spacing_xs) {
          Text(task.title)
          .font(Font.system(size: 14, weight: Font.Weight.semibold, design: Font.Design.default))
          .foregroundColor(GUITokens.color_textPrimary)
          .lineLimit(1)
          Text((String(describing: "#") + String(describing: task.id)))
          .font(Font.system(size: 11, weight: Font.Weight.semibold, design: Font.Design.default))
          .foregroundColor(GUITokens.color_textSubtle)
        }
        HStack(spacing: GUITokens.spacing_xs) {
          Text(task.statusText)
          .font(Font.system(size: 11, weight: Font.Weight.medium, design: Font.Design.default))
          .foregroundColor(GUITokens.color_textMuted)
          .padding(6)
          .background(GUITokens.color_badge)
          .cornerRadius(6)
          Text(task.priorityText)
          .font(Font.system(size: 11, weight: Font.Weight.medium, design: Font.Design.default))
          .foregroundColor(GUITokens.color_textMuted)
          .padding(6)
          .background(GUITokens.color_badge)
          .cornerRadius(6)
          Text(task.dueDateText)
          .font(Font.system(size: 11, weight: Font.Weight.medium, design: Font.Design.default))
          .foregroundColor(((task.overdue) ? (GUITokens.color_warning) : (GUITokens.color_textSubtle)))
        }
      }
      Spacer()
      Text(((task.active) ? ("SELECTED") : (((task.done) ? ("DONE") : ("OPEN")))))
      .font(Font.system(size: 10, weight: Font.Weight.bold, design: Font.Design.default))
      .foregroundColor(((task.active) ? (Color.white) : (GUITokens.color_textSubtle)))
      .padding(7)
      .background(((task.active) ? (GUITokens.color_accent) : (GUITokens.color_badge)))
      .cornerRadius(7)
    }
    .padding(GUITokens.spacing_xs)
    .background(((task.active) ? (GUITokens.color_rowActive) : (GUITokens.color_rowBackground)))
    .cornerRadius(GUITokens.spacing_sm)
  }
}

struct Component_TodoDashboard: View {
  @ObservedObject var store: GUIStore

  var body: some View {
    NavigationSplitView {
      Component_TodoSidebar(store: store)
    } detail: {
      Component_TodoDetail(store: store)
    }
    .navigationSplitViewStyle(BalancedNavigationSplitViewStyle())
  }
}

struct Component_TodoSidebar: View {
  @ObservedObject var store: GUIStore

  var body: some View {
    List() {
      Section("Overview") {
        HStack(spacing: GUITokens.spacing_sm) {
          Component_SidebarMetric(store: store, title: "Total", value: (String(describing: "") + String(describing: store.state.todoCount)), subtitle: "All tasks", tint: GUITokens.color_accent)
          Component_SidebarMetric(store: store, title: "Open", value: (String(describing: "") + String(describing: store.state.openCount)), subtitle: "Needs attention", tint: GUITokens.color_info)
        }
        HStack(spacing: GUITokens.spacing_sm) {
          Component_SidebarMetric(store: store, title: "Done", value: (String(describing: "") + String(describing: store.state.doneCount)), subtitle: "Completed", tint: GUITokens.color_success)
          Component_SidebarMetric(store: store, title: "Blocked", value: (String(describing: "") + String(describing: store.state.blockedCount)), subtitle: "Need unblock", tint: GUITokens.color_warning)
        }
      }
      Section("Create Task") {
        TextField("What needs to be done?", text: $store.state.newTaskTitle)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        TextField("Due date (YYYY-MM-DD, optional)", text: $store.state.draftDueDate)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Status")
        .font(Font.system(size: 11, weight: Font.Weight.semibold, design: Font.Design.default))
        .foregroundColor(GUITokens.color_textSubtle)
        HStack(spacing: GUITokens.spacing_xs) {
          Button("Backlog") { store.send(.setDraftBacklog) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.draftStatusBacklog) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
          Button("In Progress") { store.send(.setDraftInProgress) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.draftStatusInProgress) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
          Button("Blocked") { store.send(.setDraftBlocked) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.draftStatusBlocked) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
        }
        Text("Priority")
        .font(Font.system(size: 11, weight: Font.Weight.semibold, design: Font.Design.default))
        .foregroundColor(GUITokens.color_textSubtle)
        HStack(spacing: GUITokens.spacing_xs) {
          Button("Low") { store.send(.setDraftPriorityLow) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.draftPriorityLow) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
          Button("Medium") { store.send(.setDraftPriorityMedium) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.draftPriorityMedium) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
          Button("High") { store.send(.setDraftPriorityHigh) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.draftPriorityHigh) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
          Button("Urgent") { store.send(.setDraftPriorityUrgent) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.draftPriorityUrgent) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
        }
        HStack(spacing: GUITokens.spacing_xs) {
          Button("Create") { store.send(.createTask) }
          .buttonStyle(BorderedProminentButtonStyle())
          Button("Clear") { store.send(.clearDraftTitle) }
          .buttonStyle(BorderedButtonStyle())
        }
      }
      Section("Filter") {
        HStack(spacing: GUITokens.spacing_xs) {
          Button("All") { store.send(.setFilterAll) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.filterAll) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
          Button("Open") { store.send(.setFilterOpen) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.filterOpen) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
          Button("Done") { store.send(.setFilterDone) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.filterDone) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
          Button("Blocked") { store.send(.setFilterBlocked) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.filterBlocked) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
        }
      }
      Section("Sort") {
        HStack(spacing: GUITokens.spacing_xs) {
          Button("Newest") { store.send(.setSortNewest) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.sortNewest) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
          Button("Due Soonest") { store.send(.setSortDueSoonest) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.sortDueSoonest) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
          Button("Priority") { store.send(.setSortPriority) }
          .buttonStyle(BorderedButtonStyle())
          .tint(((store.state.sortPriority) ? (GUITokens.color_accent) : (GUITokens.color_muted)))
        }
      }
      Section("Workspace") {
        HStack(spacing: GUITokens.spacing_xs) {
          Button("Load Demo Data") { store.send(.loadDemoData) }
          .buttonStyle(BorderedButtonStyle())
          Button("Clear Completed") { store.send(.clearCompleted) }
          .buttonStyle(BorderedButtonStyle())
        }
        HStack(spacing: GUITokens.spacing_xs) {
          Button("Reset Board") { store.send(.resetTodos) }
          .buttonStyle(BorderedButtonStyle())
          Toggle("Compact rows", isOn: $store.state.compactMode)
          .toggleStyle(SwitchToggleStyle())
          .onTapGesture { store.send(.persistPreferences) }
        }
        Text(store.state.status)
        .font(Font.system(size: 12, weight: Font.Weight.medium, design: Font.Design.default))
        .foregroundColor(GUITokens.color_textMuted)
        .lineLimit(2)
      }
    }
    .listStyle(SidebarListStyle())
    .navigationTitle("Nim Tasks")
  }
}

struct Component_TodoDetail: View {
  @ObservedObject var store: GUIStore

  var body: some View {
    VStack(alignment: HorizontalAlignment.leading, spacing: GUITokens.spacing_md) {
      VStack(alignment: HorizontalAlignment.leading, spacing: GUITokens.spacing_sm) {
        Text("Selected task")
        .font(Font.system(size: 12, weight: Font.Weight.semibold, design: Font.Design.default))
        .foregroundColor(GUITokens.color_textSubtle)
        Text(store.state.selectedTaskTitle)
        .font(Font.system(size: 26, weight: Font.Weight.bold, design: Font.Design.default))
        .foregroundColor(GUITokens.color_textPrimary)
        HStack(spacing: GUITokens.spacing_xs) {
          TextField("Rename selected task", text: $store.state.editTaskTitle)
          .textFieldStyle(RoundedBorderTextFieldStyle())
          Button("Rename") { store.send(.renameActiveTask) }
          .buttonStyle(BorderedButtonStyle())
        }
        HStack(spacing: GUITokens.spacing_xs) {
          TextField("Selected due date (YYYY-MM-DD)", text: $store.state.editTaskDueDate)
          .textFieldStyle(RoundedBorderTextFieldStyle())
          Button("Set Due") { store.send(.setActiveDueDate) }
          .buttonStyle(BorderedButtonStyle())
          Button("Clear Due") { store.send(.clearActiveDueDate) }
          .buttonStyle(BorderedButtonStyle())
        }
        HStack(spacing: GUITokens.spacing_xs) {
          Button("Backlog") { store.send(.setActiveStatusBacklog) }
          .buttonStyle(BorderedButtonStyle())
          Button("In Progress") { store.send(.setActiveStatusInProgress) }
          .buttonStyle(BorderedButtonStyle())
          Button("Blocked") { store.send(.setActiveStatusBlocked) }
          .buttonStyle(BorderedButtonStyle())
          Button("Done") { store.send(.setActiveStatusDone) }
          .buttonStyle(BorderedButtonStyle())
        }
        HStack(spacing: GUITokens.spacing_xs) {
          Button("Complete") { store.send(.completeActiveTask) }
          .buttonStyle(BorderedProminentButtonStyle())
          Button("Reopen") { store.send(.reopenActiveTask) }
          .buttonStyle(BorderedButtonStyle())
          Button("Remove") { store.send(.removeActiveTask) }
          .buttonStyle(BorderedButtonStyle())
          Button("Move Up") { store.send(.moveActiveTaskUp) }
          .buttonStyle(BorderedButtonStyle())
          Button("Move Down") { store.send(.moveActiveTaskDown) }
          .buttonStyle(BorderedButtonStyle())
        }
      }
      .padding(GUITokens.spacing_md)
      .background(GUITokens.color_panelRaised)
      .cornerRadius(GUITokens.spacing_sm)
      List() {
        ForEach(Array(store.state.tasks.indices), id: \.self) { rowIndex in
          let task = store.state.tasks[rowIndex]
          Component_TodoRow(store: store, task: task)
          .listRowSeparator(Visibility.hidden)
          .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
          .onTapGesture { store.send(.selectTask(taskId: task.id)) }
        }
      }
      .searchable(text: $store.state.searchQuery)
      .listStyle(InsetListStyle())
      .frame(maxWidth: Double.infinity, maxHeight: Double.infinity)
    }
    .frame(maxWidth: Double.infinity, maxHeight: Double.infinity, alignment: Alignment.topLeading)
    .padding(GUITokens.spacing_md)
    .navigationTitle("Tasks")
    .toolbar {
      ToolbarItemGroup(placement: ToolbarItemPlacement.automatic) {
        Button("Apply Search") { store.send(.applySearch) }
        .buttonStyle(BorderedProminentButtonStyle())
        Button("Clear Search") { store.send(.clearSearch) }
        .buttonStyle(BorderedButtonStyle())
      }
    }
  }
}

struct GUIRootView: View {
  @ObservedObject var store: GUIStore

  var body: some View {
    Component_TodoDashboard(store: store)
  }
}

#if os(macOS)
@MainActor
final class GUILifecycleDelegate: NSObject, NSApplicationDelegate {
  static var onTerminate: (() -> Void)?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationWillTerminate(_ notification: Notification) {
    GUILifecycleDelegate.onTerminate?()
  }
}
#endif

@main
struct NimTodoGui: App {
  @StateObject private var store = GUIStore()
#if os(macOS)
  @NSApplicationDelegateAdaptor(GUILifecycleDelegate.self) private var guiLifecycleDelegate
#endif

  var body: some Scene {
    WindowGroup("Nim Tasks") {
      GUIRootView(store: store)
        .onAppear {
#if os(macOS)
          GUILifecycleDelegate.onTerminate = { store.shutdown() }
#endif
#if os(macOS)
          if let window = NSApplication.shared.windows.first {
            window.title = "Nim Tasks"
            window.setContentSize(NSSize(width: 1180.0, height: 760.0))
            window.minSize = NSSize(width: 1020.0, height: 680.0)
            window.maxSize = NSSize(width: 1680.0, height: 1200.0)
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.styleMask = window.styleMask.subtracting(.fullSizeContentView)
          }
#endif
        }
        .onDisappear {
          store.shutdown()
        }
    }
    .defaultSize(width: 1180.0, height: 760.0)
  }
}
