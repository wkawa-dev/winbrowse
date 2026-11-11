import SwiftUI
import WebKit

/// The "…" menu: the Windows Phone app bar expanded, round buttons on top, lowercase items below.
///
/// This is the panel only — the dimming scrim behind it lives in `RootView`, so the two can
/// move on their own: the scrim fades, the panel peels open off the edge of the screen.
struct MenuOverlay: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @ObservedObject var tab: Tab
    @ObservedObject var pins = Pins.shared
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var shown = false

    private var wide: Bool { hsc == .regular }

    var body: some View {
        panel
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: wide ? .topTrailing : .bottom)
            .transition(.metroPeel(wide ? .top : .bottom))
            .onAppear {
                // The items follow the panel in, one after another, the way the phone's menu fills.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { withAnimation { shown = true } }
            }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 18) {
                    RoundIcon(system: "arrow.left", label: "back", showLabel: true) { close(); tab.webView?.goBack() }
                        .opacity(tab.canGoBack ? 1 : 0.35)
                    RoundIcon(system: "arrow.right", label: "forward", showLabel: true) { close(); tab.webView?.goForward() }
                        .opacity(tab.canGoForward ? 1 : 0.35)
                    RoundIcon(system: "square.and.arrow.up", label: "share", showLabel: true) { close(); share() }
                    RoundIcon(system: pins.isPinned(tab.url) ? "pin.slash" : "pin", label: pins.isPinned(tab.url) ? "unpin" : "pin", showLabel: true) {
                        if let u = tab.url { pins.toggle(u, title: tab.displayTitle) }
                        close()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14).padding(.bottom, 8)
            .rise(shown, delay: 0.03)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        MetroMenuItem(title: item.title, detail: item.detail) { item.action() }
                            .rise(shown, delay: 0.06 + Double(i) * 0.028)
                    }
                }
                .padding(.bottom, 10)
            }
            .frame(maxHeight: wide ? 660 : 460)
            .fixedSize(horizontal: false, vertical: true)
        }
        // The items clear the home indicator; the panel itself still runs to the edge of the screen.
        .safeAreaPadding(wide ? .top : .bottom)
        .frame(maxWidth: wide ? 380 : .infinity)
        .background(
            Chamfer(corner: wide ? .bottomTrailing : .topTrailing, size: 30)
                .fill(theme.chrome)
                .ignoresSafeArea(edges: wide ? [] : .bottom)
        )
    }

    private var items: [(title: String, detail: String?, action: () -> Void)] {
        var out: [(String, String?, () -> Void)] = []
        out.append(("new tab", nil, { close(); store.newTab(url: nil) }))
        for e in ExtensionHost.shared.enabledExtensions {
            if let p = e.popup ?? e.options {
                out.append((e.name, "extension", { close(); store.extPresent(ext: e, page: p) }))
            }
        }
        out.append(("uBlock Origin", uboDetail, { close(); router.push(.ublock) }))
        out.append(("find on page", nil, { close(); find() }))
        out.append((tab.desktop ? "mobile site" : "desktop site", nil, {
            close()
            tab.desktop.toggle()
            tab.rebuildWebView(loading: tab.url)
        }))
        out.append(("extensions", nil, { close(); router.push(.extensions) }))
        out.append(("history", nil, { close(); router.push(.history) }))
        out.append(("settings", nil, { close(); router.push(.settings) }))
        return out
    }

    private var uboDetail: String {
        let host = tab.url?.host ?? ""
        return tab.protections.isDisjoint(with: .blocking) ? "off for \(host)" : "on · \(ContentBlocker.shared.status)"
    }

    private func close() { router.closeMenu() }

    private func share() {
        guard let u = tab.url, let top = Dialogs.top else { return }
        let vc = UIActivityViewController(activityItems: [u], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.maxX - 40, y: 60, width: 1, height: 1)
        top.present(vc, animated: true)
    }

    private func find() {
        guard let w = tab.webView else { return }
        if #available(iOS 16.0, *) { w.findInteraction?.presentFindNavigator(showingReplace: false) }
    }
}

/// Windows 10 Mobile Edge tab switcher: a grid of page thumbnails.
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
