import SwiftUI
import WebKit

struct TabsView: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @Environment(\.horizontalSizeClass) private var hsc

    var body: some View {
        MetroPage(title: "tabs", subtitle: "\(store.tabs.count) open") {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: hsc == .regular ? 4 : 2), spacing: 14) {
                    ForEach(store.tabs) { t in TabCard(tab: t, active: t.id == store.activeId) }
                }
                .padding(.horizontal, 14).padding(.bottom, 20)
            }
            HStack(spacing: 44) {
                Spacer()
                RoundIcon(system: "plus", label: "new tab", showLabel: true) { store.newTab(url: nil); router.pop() }
                RoundIcon(system: "xmark", label: "close all", showLabel: true) { store.closeAll(); router.pop() }
                Spacer()
            }
            .padding(.vertical, 8)
            .background(theme.chrome.ignoresSafeArea(edges: .bottom))
        }
    }
}

private struct TabCard: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @ObservedObject var tab: Tab
    let active: Bool
    @State private var dragX: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(tab.displayTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(active ? .white : theme.fg).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .onTapGesture(perform: open)
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(active ? .white : theme.fg)
                    .frame(width: 40, height: 30).contentShape(Rectangle())
                    .onTapGesture { withAnimation { store.close(tab) } }
                    .accessibilityAddTraits(.isButton).accessibilityLabel("close tab")
            }
            .padding(.leading, 8)
            .background(active ? theme.accent : theme.chromeHi)
            ZStack {
                theme.chrome
                if let img = tab.thumbnail {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else if tab.url == nil {
                    Text("start").font(MetroFont.header(30)).foregroundStyle(theme.subtle)
                } else {
                    Text(tab.url?.host ?? "").font(.system(size: 14)).foregroundStyle(theme.subtle)
                }
            }
            .frame(height: 190)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
        .overlay(Rectangle().strokeBorder(active ? theme.accent : Color.clear, lineWidth: 2))
        .offset(x: dragX)
        .opacity(1 - Double(abs(dragX)) / 300)
        .simultaneousGesture(DragGesture(minimumDistance: 20).onChanged { v in
            if abs(v.translation.width) > abs(v.translation.height) { dragX = v.translation.width }
        }.onEnded { v in
            if abs(v.translation.width) > 110 { withAnimation { store.close(tab) } } else { withAnimation { dragX = 0 } }
        })
    }

    private func open() { store.select(tab); router.pop() }
}
