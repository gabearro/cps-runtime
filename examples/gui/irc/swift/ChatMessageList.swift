import SwiftUI

/// A chat message list that auto-scrolls to the bottom when new messages arrive,
/// but preserves scroll position when the user has scrolled up to read history.
struct ChatMessageList: View {
    @ObservedObject var store: GUIStore
    var isDark: Bool

    @State private var isNearBottom: Bool = true
    @State private var trackedMessageCount: Int = 0

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(0..<store.state.messages.count, id: \.self) { idx in
                    let msg = store.state.messages[idx]
                    Component_MessageRow(store: store, message: msg, isDark: isDark, nickColorOverrides: store.state.nickColors)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .id(msg.id)
                }

                // Invisible bottom anchor
                Color.clear
                    .frame(height: 0)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .id("_bottom_anchor_")
                    .onAppear {
                        isNearBottom = true
                    }
                    .onDisappear {
                        isNearBottom = false
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.state.messages.count) { oldCount, newCount in
                if isNearBottom && newCount > oldCount {
                    // Small delay lets SwiftUI finish inserting the row
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("_bottom_anchor_", anchor: .bottom)
                        }
                    }
                }
                trackedMessageCount = newCount
            }
            .onAppear {
                trackedMessageCount = store.state.messages.count
                // Scroll to bottom on first appear
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo("_bottom_anchor_", anchor: .bottom)
                }
            }
        }
    }
}
