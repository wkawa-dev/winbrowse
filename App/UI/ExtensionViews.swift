import SwiftUI
import WebKit

struct ExtensionsView: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @State private var tick = 0

    var body: some View {
        MetroPage(title: "extensions") {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Button { router.push(.ublock) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            UBOIcon(size: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("uBlock Origin").font(MetroFont.title(24)).foregroundStyle(theme.fg)
                                Text("filter lists \(ContentBlocker.shared.version) · \(ContentBlocker.shared.status)")
                                    .font(MetroFont.caption).foregroundStyle(theme.subtle)
                                Text("network filtering, cosmetic filtering and scriptlets from uBO's own filter compiler")
                                    .font(.system(size: 14)).foregroundStyle(theme.subtle)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(theme.subtle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.tilt)

                    ForEach(ExtensionHost.shared.extensions) { e in
                        ExtensionCard(ext: e, onChange: { tick += 1 })
                    }
                    Text("toggling an extension reloads open tabs.").font(MetroFont.caption).foregroundStyle(theme.subtle)
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 18)
                .id(tick)
            }
        }
    }
}

private struct ExtensionCard: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    let ext: WebExtension
    let onChange: () -> Void
    @State private var on: Bool

    init(ext: WebExtension, onChange: @escaping () -> Void) {
        self.ext = ext
        self.onChange = onChange
        _on = State(initialValue: ExtensionHost.shared.isEnabled(ext.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                ExtensionIcon(ext: ext, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ext.name).font(MetroFont.title(24)).foregroundStyle(theme.fg)
                    Text("version \(ext.version)").font(MetroFont.caption).foregroundStyle(theme.subtle)
                    Text(ext.summary).font(.system(size: 14)).foregroundStyle(theme.subtle).lineLimit(3)
                }
            }
            MetroToggle(title: "enabled", isOn: $on)
                .onChange(of: on) { _, v in
                    ExtensionHost.shared.setEnabled(ext.id, v)
                    WebViewFactory.shared.rebuildScripts()
                    for t in store.tabs { t.webView?.reload() }
                    onChange()
                }
            HStack(spacing: 10) {
                if let p = ext.popup { MetroButton(title: "open", filled: true) { store.extPresent(ext: ext, page: p) } }
                if let o = ext.options { MetroButton(title: "options") { store.extPresent(ext: ext, page: o) } }
            }
            .disabled(!on).opacity(on ? 1 : 0.4)
        }
    }
}

/// uBO's popup + dashboard rolled into one: per-site power switch, filter lists.
struct UBlockView: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @ObservedObject var blocker = ContentBlocker.shared
    @State private var pending: Set<String> = []
    @State private var dirty = false

    var body: some View {
        MetroPage(title: "uBlock Origin", subtitle: "filter lists \(blocker.version)") {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let host = store.active?.url?.host {
                        let off = blocker.isSiteDisabled(host)
                        Button {
                            blocker.setSite(host, disabled: !off)
                            if let t = store.active { t.rebuildWebView(loading: t.url) }
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "power").font(.system(size: 38, weight: .light))
                                    .foregroundStyle(off ? theme.subtle : .white)
                                    .frame(width: 76, height: 76).background(off ? theme.chrome : theme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(host).font(MetroFont.title(22)).foregroundStyle(theme.fg).lineLimit(1)
                                    Text(off ? "uBlock Origin is off for this site — tap to turn on" : "filtering this site — tap to turn off")
                                        .font(MetroFont.caption).foregroundStyle(theme.subtle)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.tilt)
                    }

                    MetroGroup(title: "status") {
                        MetroToggle(title: "uBlock Origin", detail: blocker.status, isOn: $blocker.enabled)
                            .onChange(of: blocker.enabled) { _, _ in dirty = true }
                        if blocker.compiling { MetroDots() }
                    }

                    let groups = ["default", "ads", "privacy", "annoyances", "regions"]
                    ForEach(groups, id: \.self) { g in
                        let sets = blocker.rulesets.filter { $0.group == g }
                        if !sets.isEmpty {
                            MetroGroup(title: g == "default" ? "built-in" : g) {
                                ForEach(sets) { r in
                                    MetroToggle(title: r.name, detail: "\(r.networkRules.formatted()) network · \(r.cosmetic.formatted()) cosmetic",
                                                isOn: Binding(get: { pending.contains(r.id) }, set: { v in
                                                    if v { pending.insert(r.id) } else { pending.remove(r.id) }
                                                    dirty = true
                                                }))
                                }
                            }
                        }
                    }

                    if !disabledSites.isEmpty {
                        MetroGroup(title: "trusted sites") {
                            ForEach(disabledSites, id: \.self) { s in
                                HStack {
                                    Text(s).font(.system(size: 17)).foregroundStyle(theme.fg)
                                    Spacer()
                                    Button("remove") { blocker.setSite(s, disabled: false) }.foregroundStyle(theme.accent)
                                }
                            }
                        }
                    }
                    Text("uBlock Origin © Raymond Hill, GPLv3. Filter lists compiled by uBO Lite for WebKit: network rules run as WebKit content blockers, cosmetic filters and scriptlets are injected into every frame.")
                        .font(MetroFont.caption).foregroundStyle(theme.subtle)
                    Color.clear.frame(height: 60)
                }
                .padding(.horizontal, 18)
            }
            if dirty {
                HStack { MetroButton(title: blocker.compiling ? "applying…" : "apply changes", filled: true, busy: blocker.compiling) { apply() } }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(theme.chrome.ignoresSafeArea(edges: .bottom))
            }
        }
        .onAppear { pending = blocker.enabledIds }
    }

    private var disabledSites: [String] { blocker.disabledSites.sorted() }

    private func apply() {
        blocker.enabledIds = pending
        Task {
            await AppBoot.reloadBlocking()
            dirty = false
            for t in store.tabs { t.webView?.reload() }
        }
    }
}

/// Presents an extension page (popup / options) like a Windows Phone full-screen panel.
struct ExtensionPageView: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    let req: BrowserStore.ExtensionPageRequest

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ExtensionIcon(ext: req.ext, size: 22)
                Text(req.ext.name.uppercased()).font(MetroFont.appTitle).foregroundStyle(theme.fg)
                Spacer()
                if let o = req.ext.options, o != req.page {
                    Button("options") { store.presentedExtensionPage = .init(ext: req.ext, page: o, tabId: req.tabId) }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
                }
                Button { store.presentedExtensionPage = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.fg)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            ExtensionPageWebView(req: req)
        }
        .background(theme.chrome.ignoresSafeArea())
    }
}

private struct ExtensionPageWebView: UIViewRepresentable {
    let req: BrowserStore.ExtensionPageRequest
    func makeUIView(context: Context) -> WKWebView {
        let w = ExtensionHost.shared.makePageWebView(ext: req.ext, path: req.page, tabId: req.tabId)
        w.navigationDelegate = context.coordinator
        w.uiDelegate = context.coordinator
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { ExtensionHost.shared.releasePage(uiView) }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = action.request.url {
                Task { @MainActor in
                    BrowserStore.shared.presentedExtensionPage = nil
                    BrowserStore.shared.newTab(url: u)
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Links out of an extension page open in a browser tab.
            if let u = action.request.url, u.scheme == "http" || u.scheme == "https", action.targetFrame?.isMainFrame != false {
                Task { @MainActor in
                    BrowserStore.shared.presentedExtensionPage = nil
                    BrowserStore.shared.newTab(url: u)
                }
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }
}
