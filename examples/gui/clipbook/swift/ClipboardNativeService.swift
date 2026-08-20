#if os(macOS)
import AppKit
import Foundation

struct ClipboardSnapshot: Equatable {
    var kind: String
    var text: String
    var filePath: String
    var sourceApp: String
    var changeCount: Int
}

@MainActor
final class ClipboardNativeService {
    static let shared = ClipboardNativeService()

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var ignoredChangeCount: Int?

    func poll() -> ClipboardSnapshot? {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return nil }
        lastChangeCount = current
        if ignoredChangeCount == current {
            ignoredChangeCount = nil
            return nil
        }

        let source = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        if let file = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL, file.isFileURL {
            return ClipboardSnapshot(kind: "File", text: file.absoluteString, filePath: file.path, sourceApp: source, changeCount: current)
        }
        if let image = NSImage(pasteboard: pasteboard) {
            let url = temporaryImageURL(changeCount: current)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: url, options: .atomic)
            }
            return ClipboardSnapshot(kind: "Image", text: url.lastPathComponent, filePath: url.path, sourceApp: source, changeCount: current)
        }
        if let string = pasteboard.string(forType: .string) {
            return ClipboardSnapshot(kind: classify(string), text: string, filePath: "", sourceApp: source, changeCount: current)
        }
        return nil
    }

    func restore(text: String, filePath: String, kind: String = "") {
        pasteboard.clearContents()
        if kind == "Image", !filePath.isEmpty, let image = NSImage(contentsOfFile: filePath) {
            pasteboard.writeObjects([image])
        } else if !filePath.isEmpty {
            pasteboard.writeObjects([URL(fileURLWithPath: filePath) as NSURL])
        } else {
            pasteboard.setString(text, forType: .string)
        }
        ignoredChangeCount = pasteboard.changeCount
    }

    func restoreSelectedItem(from store: GUIStore) {
        let text = store.state.selectedPreviewText.isEmpty ? store.state.selectedTitle : store.state.selectedPreviewText
        restore(text: text, filePath: store.state.selectedPayloadPath, kind: store.state.selectedKind)
    }

    func restoreItem(id: Int, from store: GUIStore) {
        if id == store.state.selectedItemId {
            restoreSelectedItem(from: store)
            return
        }
        guard let item = store.state.history.first(where: { $0.id == id }) else { return }
        let text = item.preview.isEmpty ? item.title : item.preview
        restore(text: text, filePath: "")
    }

    func copyItemAsPlainText(id: Int, from store: GUIStore) {
        let text: String
        if id == store.state.selectedItemId {
            text = plainTextForSelectedItem(from: store)
        } else if let item = store.state.history.first(where: { $0.id == id }) {
            text = item.preview.isEmpty ? item.title : item.preview
        } else {
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ignoredChangeCount = pasteboard.changeCount
    }

    func copySelectedTextAsNewClipIfAvailable(from store: GUIStore) -> Bool {
        guard let selected = selectedTextInKeyWindow()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selected.isEmpty else {
            return false
        }
        let fullText = plainTextForSelectedItem(from: store).trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected != fullText else {
            return false
        }
        pasteboard.clearContents()
        pasteboard.setString(selected, forType: .string)
        ignoredChangeCount = pasteboard.changeCount
        store.state.incomingClipboardKind = classify(selected)
        store.state.incomingClipboardText = selected
        store.state.incomingClipboardPath = ""
        store.state.incomingClipboardSource = "ClipBook"
        store.send(.captureClipboard)
        return true
    }

    func shareItem(id: Int, from store: GUIStore) {
        guard let item = sharingObject(id: id, from: store) else { return }
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let contentView = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [item])
        picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
    }

    func revealItemInFinder(id: Int, from store: GUIStore) {
        let path: String
        if id == store.state.selectedItemId, !store.state.selectedPayloadPath.isEmpty {
            path = store.state.selectedPayloadPath
        } else if !store.state.storagePath.isEmpty {
            path = store.state.storagePath
        } else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func plainTextForSelectedItem(from store: GUIStore) -> String {
        if !store.state.selectedPreviewText.isEmpty { return store.state.selectedPreviewText }
        if !store.state.selectedPayloadPath.isEmpty { return store.state.selectedPayloadPath }
        return store.state.selectedTitle
    }

    private func selectedTextInKeyWindow() -> String? {
        guard let responder = NSApp.keyWindow?.firstResponder else { return nil }
        if let textView = responder as? NSTextView {
            let selected = textView.selectedRanges.compactMap { rangeValue -> String? in
                let range = rangeValue.rangeValue
                guard range.length > 0, range.location + range.length <= (textView.string as NSString).length else { return nil }
                return (textView.string as NSString).substring(with: range)
            }.joined()
            return selected.isEmpty ? nil : selected
        }
        if let fieldEditor = responder as? NSText {
            let range = fieldEditor.selectedRange
            let value = fieldEditor.string
            guard range.length > 0, range.location + range.length <= (value as NSString).length else { return nil }
            return (value as NSString).substring(with: range)
        }
        return nil
    }

    private func sharingObject(id: Int, from store: GUIStore) -> Any? {
        if id == store.state.selectedItemId {
            if store.state.selectedKind == "Image",
               !store.state.selectedPayloadPath.isEmpty,
               let image = NSImage(contentsOfFile: store.state.selectedPayloadPath) {
                return image
            }
            if store.state.selectedKind == "File", !store.state.selectedPayloadPath.isEmpty {
                return URL(fileURLWithPath: store.state.selectedPayloadPath)
            }
            if store.state.selectedKind == "Link",
               let url = URL(string: store.state.selectedPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url
            }
            return plainTextForSelectedItem(from: store)
        }
        guard let item = store.state.history.first(where: { $0.id == id }) else { return nil }
        if item.kind == "Link", let url = URL(string: item.preview.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }
        return item.preview.isEmpty ? item.title : item.preview
    }

    private func classify(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return "Link" }
        if trimmed.hasPrefix("#"), [4, 7, 9].contains(trimmed.count) { return "Color" }
        if trimmed.contains("@"), trimmed.contains("."), !trimmed.contains(" ") { return "Email" }
        return "Text"
    }

    private func temporaryImageURL(changeCount: Int) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CPS ClipBook/Payloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipboard-\(changeCount).png")
    }
}
#endif
