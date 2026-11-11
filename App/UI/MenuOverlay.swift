import SwiftUI
import WebKit

struct MenuOverlay: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @ObservedObject var tab: Tab
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var shown = false

    private var wide: Bool { hsc == .regular }

    var body: some View {
        panel
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: wide ? .topTrailing : .bottom)
            .transition(.metroPeel(wide ? .top : .bottom))
            .onAppear {
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
        if tab.url?.scheme?.hasPrefix("http") == true {
            out.append(("report broken site", "send a report without personal data", { close(); BreakageReporter.present(for: tab) }))
        }
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
