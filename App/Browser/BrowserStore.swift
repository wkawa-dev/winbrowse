import Combine
import SwiftUI
import WebKit

@MainActor
final class BrowserStore: ObservableObject {
    static let shared = BrowserStore()

    @Published private(set) var tabs: [Tab] = []
    @Published var activeId: Int?
    @Published var presentedExtensionPage: ExtensionPageRequest?
    private var nextId = 1
    private let launchedAt = Date()
    private var persistScheduled = false

    struct ExtensionPageRequest: Identifiable {
        let id = UUID()
        let ext: WebExtension
        let page: String
        let tabId: Int
    }

    var active: Tab? { tabs.first { $0.id == activeId } }

    private static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tabs.json")
    }

    @discardableResult
    func newTab(url: URL?, activate: Bool = true, opener: Tab? = nil) -> Tab {
        let t = Tab(id: nextId, url: url, store: self)
        nextId += 1
        if let opener, let i = tabs.firstIndex(where: { $0 === opener }) { tabs.insert(t, at: i + 1) } else { tabs.append(t) }
        if activate { select(t) }
        persistSoon()
        return t
    }

    func select(_ t: Tab) {
        active?.snapshot()
        activeId = t.id
        t.lastAccess = Date()
        ExtensionHost.shared.tabActivated(t.id)
        t.reviveIfNeeded()
        trimMemory()
    }

    func close(_ t: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === t }) else { return }
        if let w = t.webView { ExtensionHost.shared.tabNavigated(w); PageErrors.shared.forget(w); w.removeFromSuperview() }
        tabs.remove(at: i)
        ExtensionHost.shared.tabRemoved(t.id)
        if activeId == t.id {
            if tabs.isEmpty { newTab(url: nil) } else { select(tabs[min(i, tabs.count - 1)]) }
        }
        persistSoon()
    }

    func closeAll() {
        for t in tabs { t.webView?.removeFromSuperview(); ExtensionHost.shared.tabRemoved(t.id) }
        tabs.removeAll()
        newTab(url: nil)
    }

    nonisolated static let liveTabLimit = max(6, Int(ProcessInfo.processInfo.physicalMemory / 1_000_000_000) * 3)
    private var memoryObserver: NSObjectProtocol?

    private func trimMemory(keeping limit: Int = BrowserStore.liveTabLimit) {
        let live = tabs.filter { $0.hasWebView && $0.id != activeId }.sorted { $0.lastAccess > $1.lastAccess }
        for t in live.dropFirst(limit) where !(t.webView.map(BackgroundMedia.shared.isPlaying) ?? false) { t.discard() }
    }

    func recycleWebViews() {
        for t in tabs where t.hasWebView && !(t.webView.map(BackgroundMedia.shared.isPlaying) ?? false) { t.discard() }
        objectWillChange.send()
    }

    func observeMemoryWarnings() {
        guard memoryObserver == nil else { return }
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let live = self.tabs.filter { $0.hasWebView && $0.id != self.activeId }.count
                self.trimMemory(keeping: live / 2)
            }
        }
    }

    func open(_ input: String, in tab: Tab? = nil) {
        guard let u = Self.url(from: input) else { return }
        let t = tab ?? active ?? newTab(url: nil)
        t.load(u)
        persistSoon()
    }

    static func url(from raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("winext://") || s.hasPrefix("about:") { return URL(string: s) }
        if let u = URL(string: s), let sch = u.scheme?.lowercased(), ["http", "https"].contains(sch), u.host != nil { return u }
        let looksLikeHost = !s.contains(" ") && (s.contains(".") || s.hasPrefix("localhost")) && !s.hasSuffix(".")
        if looksLikeHost, let u = URL(string: "https://" + s), u.host?.contains(".") == true || u.host == "localhost" { return u }
        return SearchEngine.current.url(for: s)
    }

    struct Saved: Codable { var tabs: [SavedTab]; var active: Int? }
    struct SavedTab: Codable { var url: String?; var title: String; var state: Data?; var desktop: Bool? }

    func restore() {
        guard tabs.isEmpty else { return }
        if let d = try? Data(contentsOf: Self.stateURL), let s = try? JSONDecoder().decode(Saved.self, from: d), !s.tabs.isEmpty {
            for st in s.tabs {
                let t = Tab(id: nextId, url: st.url.flatMap(URL.init(string:)), store: self, savedState: st.state)
                nextId += 1
                t.title = st.title
                t.desktop = st.desktop ?? false
                tabs.append(t)
            }
            let idx = min(max(s.active ?? 0, 0), tabs.count - 1)
            activeId = tabs[idx].id
        } else {
            newTab(url: nil)
        }
    }

    func persistSoon() {
        guard !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.persistNow() }
    }

    func persistNow() {
        persistScheduled = false
        let saved = Saved(tabs: tabs.map { t in
            SavedTab(url: t.url?.absoluteString, title: t.title,
                     state: t.savedState, desktop: t.desktop)
        }, active: tabs.firstIndex { $0.id == activeId })
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: Self.stateURL, options: .atomic) }
    }
}

extension BrowserStore: ExtensionTabProvider {
    var extTabs: [ExtTabInfo] {
        tabs.enumerated().map { i, t in
            ExtTabInfo(id: t.id, index: i, url: t.url?.absoluteString ?? "about:blank", title: t.title, active: t.id == activeId,
                       loading: t.isLoading, audible: t.webView.map(BackgroundMedia.shared.isPlaying) ?? false)
        }
    }
    func extWebView(tabId: Int) -> WKWebView? { tabs.first { $0.id == tabId }?.webView }
    func extTabId(for webView: WKWebView) -> Int? { tabs.first { $0.webView === webView }?.id }
    func extCreateTab(url: URL, active: Bool) -> Int {
        let quiet = Date().timeIntervalSince(launchedAt) < 15
        return newTab(url: url, activate: active && !quiet).id
    }
    func extUpdateTab(tabId: Int, url: URL?, active: Bool?) {
        guard let t = tabs.first(where: { $0.id == tabId }) else { return }
        if let url { t.load(url) }
        if active == true { select(t) }
    }
    func extRemoveTab(tabId: Int) { if let t = tabs.first(where: { $0.id == tabId }) { close(t) } }
    func extReloadTab(tabId: Int) { tabs.first { $0.id == tabId }?.webView?.reload() }
    func extPresent(ext: WebExtension, page: String) {
        presentedExtensionPage = ExtensionPageRequest(ext: ext, page: page, tabId: activeId ?? -1)
    }
}
