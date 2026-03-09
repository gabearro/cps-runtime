import SwiftUI
import UniformTypeIdentifiers

/// A ViewModifier that adds drag-and-drop support for .torrent files.
/// When a .torrent file is dropped on the view, it dispatches DropTorrentFile(path:).
struct TorrentDropModifier: ViewModifier {
    @ObservedObject var store: GUIStore

    func body(content: Content) -> some View {
        content
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                        guard let data = data as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                        let path = url.path
                        let ext = url.pathExtension.lowercased()

                        if ext == "torrent" {
                            DispatchQueue.main.async {
                                store.send(.dropTorrentFile(path: path))
                            }
                        } else if path.hasPrefix("magnet:") {
                            // Handle magnet links dropped as text
                            DispatchQueue.main.async {
                                store.send(.dropTorrentFile(path: path))
                            }
                        }
                    }
                }
                return true
            }
    }
}
