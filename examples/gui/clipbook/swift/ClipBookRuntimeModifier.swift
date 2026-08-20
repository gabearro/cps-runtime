#if os(macOS)
import AppKit
import SwiftUI

@MainActor
private final class ClipBookWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = ClipBookWindowDelegate()

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
private final class ClipBookApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ClipboardWindowController.shared.showClipBookWindow()
        return false
    }
}

@MainActor
private final class ClipBookRuntime {
    static let shared = ClipBookRuntime()
    let shortcutMonitor = KeyboardShortcutMonitor()
    let appDelegate = ClipBookApplicationDelegate()
    var resignObserver: NSObjectProtocol?
}

struct ClipBookRuntimeModifier: ViewModifier {
    @ObservedObject var store: GUIStore
    @State private var timer: Timer?

    func body(content: Content) -> some View {
        content
            .onAppear {
                installWindowBehavior()
                applyAppearance()
                ClipBookRuntime.shared.shortcutMonitor.start(store: store)
                installAutoHideBehavior()
                startClipboardPolling()
            }
            .onChange(of: store.state.appearanceMode) { _ in
                applyAppearance()
            }
            .onChange(of: store.state.restoreClipboardItemId) { itemId in
                guard itemId >= 0 else { return }
                ClipboardNativeService.shared.restoreItem(id: itemId, from: store)
            }
            .onChange(of: store.state.revealInFinderItemId) { itemId in
                guard itemId >= 0 else { return }
                ClipboardNativeService.shared.revealItemInFinder(id: itemId, from: store)
            }
            .onChange(of: store.state.copyAsItemId) { itemId in
                guard itemId >= 0 else { return }
                ClipboardNativeService.shared.copyItemAsPlainText(id: itemId, from: store)
            }
            .onChange(of: store.state.shareItemId) { itemId in
                guard itemId >= 0 else { return }
                ClipboardNativeService.shared.shareItem(id: itemId, from: store)
            }
            .onReceive(store.$state) { state in
                if state.restoreClipboardItemId >= 0 {
                    ClipboardNativeService.shared.restoreItem(id: state.restoreClipboardItemId, from: store)
                }
                if state.revealInFinderItemId >= 0 {
                    ClipboardNativeService.shared.revealItemInFinder(id: state.revealInFinderItemId, from: store)
                }
                if state.copyAsItemId >= 0 {
                    ClipboardNativeService.shared.copyItemAsPlainText(id: state.copyAsItemId, from: store)
                }
                if state.shareItemId >= 0 {
                    ClipboardNativeService.shared.shareItem(id: state.shareItemId, from: store)
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }

    private func installWindowBehavior() {
        NSApp.setActivationPolicy(.regular)
        NSApp.delegate = ClipBookRuntime.shared.appDelegate
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.delegate = ClipBookWindowDelegate.shared
                ClipboardWindowController.shared.register(window: window)
            }
        }
    }

    private func applyAppearance() {
        switch store.state.appearanceMode {
        case "Light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "Dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    private func installAutoHideBehavior() {
        guard ClipBookRuntime.shared.resignObserver == nil else { return }
        ClipBookRuntime.shared.resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ClipboardWindowController.shared.hideClipBookWindow()
            }
        }
    }

    private func startClipboardPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
            Task { @MainActor in
                guard !store.state.pausedCapture else { return }
                guard let snapshot = ClipboardNativeService.shared.poll() else { return }
                guard snapshot.sourceApp != "ClipBook" else { return }
                if snapshot.kind == "Image" && !store.state.captureImages { return }
                if snapshot.kind == "File" && !store.state.captureFiles { return }
                if !store.state.captureSensitiveApps {
                    let source = snapshot.sourceApp.lowercased()
                    if source.contains("password") || source.contains("keychain") || source.contains("1password") {
                        return
                    }
                }
                store.state.incomingClipboardKind = snapshot.kind
                store.state.incomingClipboardText = snapshot.text
                store.state.incomingClipboardPath = snapshot.filePath
                store.state.incomingClipboardSource = snapshot.sourceApp
                store.send(.captureClipboard)
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
}
#endif
