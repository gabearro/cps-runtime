import SwiftUI
import AppKit

/// A button that opens an NSOpenPanel for selecting .torrent files.
/// When a file is selected, dispatches the TorrentFileSelected action with the path.
struct TorrentFilePickerButton: View {
    @ObservedObject var store: GUIStore
    let selectedPath: String

    var body: some View {
        Button(action: openPanel) {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 12))
                Text(selectedPath.isEmpty ? "Choose File..." : "Change File...")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.039, green: 0.518, blue: 1.0))
            )
        }
        .buttonStyle(.borderless)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Select Torrent File"
        panel.allowedContentTypes = [
            .init(filenameExtension: "torrent") ?? .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            store.send(.torrentFileSelected(path: url.path))
        }
    }
}

/// Extract the last path component from a file path string.
func lastPathComponent(_ path: String) -> String {
    return (path as NSString).lastPathComponent
}
