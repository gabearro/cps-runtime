import SwiftUI

/// A chat message list that auto-scrolls to the bottom when new messages arrive,
/// but preserves scroll position when the user has scrolled up to read history.
struct ChatMessageList: View {
    @ObservedObject var store: GUIStore
    var isDark: Bool

    @State private var isNearBottom: Bool = true

    var body: some View {
        let visibleMessages = store.state.messages
        let visibleMessageIds = visibleMessages.map(\.id)
        let searchIsActive = store.state.searchActive
            && !store.state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let selectedMessageId: Int? = {
            guard searchIsActive,
                  store.state.searchCurrentIndex >= 0,
                  store.state.searchCurrentIndex < visibleMessages.count else {
                return nil
            }
            return visibleMessages[store.state.searchCurrentIndex].id
        }()

        ScrollViewReader { proxy in
            List {
                ForEach(visibleMessages, id: \.id) { msg in
                    let isSelectedSearchMatch = selectedMessageId == msg.id

                    Component_MessageRow(store: store, message: msg, isDark: isDark, nickColorOverrides: store.state.nickColors)
                        .background(
                            isSelectedSearchMatch
                                ? Color.accentColor.opacity(isDark ? 0.24 : 0.14)
                                : Color.clear
                        )
                        .id(msg.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
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
            .onChange(of: visibleMessages.count) { oldCount, newCount in
                if isNearBottom && newCount > oldCount {
                    // Small delay lets SwiftUI finish inserting the row
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("_bottom_anchor_", anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: visibleMessageIds) { _, _ in
                if searchIsActive,
                   store.state.searchCurrentIndex >= 0,
                   store.state.searchCurrentIndex < visibleMessages.count {
                    let targetId = visibleMessages[store.state.searchCurrentIndex].id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(targetId, anchor: .center)
                        }
                    }
                } else if isNearBottom {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("_bottom_anchor_", anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: store.state.searchCurrentIndex) { _, newIndex in
                guard searchIsActive, newIndex >= 0, newIndex < visibleMessages.count else {
                    return
                }

                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(visibleMessages[newIndex].id, anchor: .center)
                }
            }
            .onAppear {
                // Scroll to bottom on first appear
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo("_bottom_anchor_", anchor: .bottom)
                }
            }
        }
    }
}
