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

    // MARK: - Tabs

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

    /// Keep at most a handful of live web views; colder tabs keep their history state and reload when shown.
    /// Background tabs kept live, scaled to the device: ~3 per GB of RAM (36 on a 12 GB iPad), never fewer than 6.
    nonisolated static let liveTabLimit = max(6, Int(ProcessInfo.processInfo.physicalMemory / 1_000_000_000) * 3)
    private var memoryObserver: NSObjectProtocol?

    private func trimMemory(keeping limit: Int = BrowserStore.liveTabLimit) {
        let live = tabs.filter { $0.hasWebView && $0.id != activeId }.sorted { $0.lastAccess > $1.lastAccess }
        for t in live.dropFirst(limit) where !(t.webView.map(BackgroundMedia.shared.isPlaying) ?? false) { t.discard() }
    }

    /// Drop every live web view (except ones playing media) so it is rebuilt with the current configuration,
    /// keeping history and scroll state. Used when a setting that only applies at web view creation changes.
    func recycleWebViews() {
        for t in tabs where t.hasWebView && !(t.webView.map(BackgroundMedia.shared.isPlaying) ?? false) { t.discard() }
        objectWillChange.send()
    }

    /// Only a real memory warning from iOS sheds tabs, and then just the least recently used half.
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

    // MARK: - Persistence

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

// MARK: - Extension runtime bridge

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
        // Welcome pages extensions open on first install go behind the start page.
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

// MARK: - Search

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, startpage, brave
    var id: String { rawValue }
    var name: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .startpage: return "Startpage"
        case .brave: return "Brave Search"
        }
    }
    static var current: SearchEngine {
        get { SearchEngine(rawValue: UserDefaults.standard.string(forKey: "search.engine") ?? "") ?? .google }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "search.engine") }
    }
    func url(for q: String) -> URL? {
        var c: URLComponents
        switch self {
        case .google: c = URLComponents(string: "https://www.google.com/search")!
        case .duckduckgo: c = URLComponents(string: "https://duckduckgo.com/")!
        case .bing: c = URLComponents(string: "https://www.bing.com/search")!
        case .startpage: c = URLComponents(string: "https://www.startpage.com/do/search")!
        case .brave: c = URLComponents(string: "https://search.brave.com/search")!
        }
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        return c.url
    }
}

// MARK: - History

@MainActor
final class BrowserHistory: ObservableObject {
    static let shared = BrowserHistory()
    struct Entry: Codable, Identifiable, Hashable { var url: String; var title: String; var date: Date; var visits: Int; var id: String { url } }
    @Published private(set) var entries: [Entry] = []
    private var saveScheduled = false
    private static var fileURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("history.json") }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
    }

    func record(_ u: URL, title: String) {
        let s = u.absoluteString
        if let i = entries.firstIndex(where: { $0.url == s }) {
            var e = entries.remove(at: i)
            e.date = Date(); e.visits += 1
            if !title.isEmpty { e.title = title }
            entries.insert(e, at: 0)
        } else {
            entries.insert(Entry(url: s, title: title, date: Date(), visits: 1), at: 0)
        }
        if entries.count > 3_000 { entries.removeLast(entries.count - 3_000) }
        save()
    }

    func suggestions(for q: String, limit: Int = 6) -> [Entry] {
        let q = q.lowercased()
        guard !q.isEmpty else { return [] }
        return Array(entries.lazy.filter { $0.url.lowercased().contains(q) || $0.title.lowercased().contains(q) }
            .sorted { ($0.visits, $0.date) > ($1.visits, $1.date) }.prefix(limit))
    }

    func remove(_ e: Entry) { entries.removeAll { $0.url == e.url }; save() }
    func clear() { entries.removeAll(); save() }

    private func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let d = try? JSONEncoder().encode(self.entries) { try? d.write(to: Self.fileURL, options: .atomic) }
        }
    }
}

// MARK: - Downloads

final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    private var destinations: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = (suggestedFilename as NSString).deletingPathExtension, ext = (suggestedFilename as NSString).pathExtension
            dest = dir.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        destinations[ObjectIdentifier(download)] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let dest = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        Task { @MainActor in Toasts.shared.show("downloaded \(dest.lastPathComponent) — in Files › WinBrowse") }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations[ObjectIdentifier(download)] = nil
        Task { @MainActor in Toasts.shared.show("download failed") }
    }
}

@MainActor
final class Toasts: ObservableObject {
    static let shared = Toasts()
    @Published var message: String?
    func show(_ s: String) {
        withAnimation(.easeOut(duration: 0.2)) { message = s }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if message == s { withAnimation(.easeOut(duration: 0.2)) { message = nil } }
        }
    }
}
