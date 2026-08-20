#if os(macOS)
import AppKit
import Foundation
import Carbon.HIToolbox

@MainActor
final class KeyboardShortcutMonitor {
    private var monitor: Any?
    private weak var store: GUIStore?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var lastToggleTime: TimeInterval = 0
    private static weak var activeMonitor: KeyboardShortcutMonitor?

    func start(store: GUIStore) {
        self.store = store
        Self.activeMonitor = self
        registerGlobalHotKey()
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
    }

    func reloadBindings(from json: String) {
        _ = json
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), let store else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if flags == .command, let slot = Int(chars), (1...9).contains(slot) {
            store.send(.pasteSlot(slot: slot))
            return nil
        }
        if flags == [.command, .shift], chars == "v" {
            toggleClipBookWindow()
            return nil
        }
        if flags == .command, chars == "c", store.state.selectedItemId >= 0 {
            if ClipboardNativeService.shared.copySelectedTextAsNewClipIfAvailable(from: store) {
                return nil
            }
            ClipboardNativeService.shared.restoreItem(id: store.state.selectedItemId, from: store)
            store.send(.copyItem(itemId: store.state.selectedItemId))
            return nil
        }
        if flags == [.command, .shift], chars == "c" {
            if ClipboardNativeService.shared.copySelectedTextAsNewClipIfAvailable(from: store) {
                return nil
            }
            ClipboardNativeService.shared.restoreItem(id: store.state.selectedItemId, from: store)
            store.send(.copyItem(itemId: store.state.selectedItemId))
            return nil
        }
        if flags == [.command, .shift], chars == "o" {
            store.send(.copyOcrText)
            return nil
        }
        return event
    }

    private func registerGlobalHotKey() {
        guard hotKeyRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr, hotKeyID.signature == KeyboardShortcutMonitor.hotKeySignature {
                DispatchQueue.main.async {
                    KeyboardShortcutMonitor.activeMonitor?.toggleClipBookWindow()
                }
                return noErr
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        guard status == noErr else { return }
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private static let hotKeySignature: OSType = 0x434C5042 // CLPB

    func toggleClipBookWindow() {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastToggleTime > 0.25 else { return }
        lastToggleTime = now
        ClipboardWindowController.shared.toggleClipBookWindow()
    }

    func showClipBookWindow() {
        ClipboardWindowController.shared.showClipBookWindow()
    }

    func hideClipBookWindow() {
        ClipboardWindowController.shared.hideClipBookWindow()
    }
}

typealias ClipboardHotkeys = KeyboardShortcutMonitor
#endif
