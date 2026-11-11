import Combine
import UIKit
import WebKit

@MainActor
final class Tab: NSObject, ObservableObject, Identifiable {
    enum Life {
        case cold(URL?)
        case suspended(Data, URL?)
        case live(WKWebView)
        case terminated(WKWebView)
    }

    let id: Int
    @Published var url: URL?
    @Published var title: String = ""
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var thumbnail: UIImage?
    @Published var blockedURL: URL?
    @Published var desktop = false
    @Published private(set) var protections: Protections = .all
    @Published private(set) var life: Life
    var lastAccess = Date()
    var bypassHost: String?
    private var bag: Set<AnyCancellable> = []
    weak var store: BrowserStore?

    init(id: Int, url: URL?, store: BrowserStore, savedState: Data? = nil) {
        self.id = id
        self.url = url
        self.store = store
        life = savedState.map { .suspended($0, url) } ?? .cold(url)
    }

    var webView: WKWebView? {
        switch life {
        case .live(let w), .terminated(let w): return w
        case .cold, .suspended: return nil
        }
    }

    var hasWebView: Bool { webView != nil }

    var savedState: Data? {
        switch life {
        case .live(let w), .terminated(let w): return w.interactionState as? Data
        case .suspended(let d, _): return d
        case .cold: return nil
        }
    }

    private var isVisible: Bool {
        store?.activeId == id && UIApplication.shared.applicationState == .active
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if url?.scheme == "winext", let e = url?.host.flatMap({ ExtensionHost.shared.ext($0) }) { return e.name }
        if let h = url?.host { return h }
        return url == nil ? "new tab" : (url?.absoluteString ?? "")
    }

    func wanted(for target: URL?) -> Protections {
        SiteSettings.shared.protections(for: target?.host, bypass: bypassHost)
    }

    func reviveIfNeeded() {
        guard case .terminated(let w) = life else { return }
        life = .live(w)
        if w.url != nil { w.reload() } else if let u = url { w.load(URLRequest(url: u)) }
    }

    @discardableResult
    func ensureWebView() -> WKWebView {
        let target: URL?, state: Data?
        switch life {
        case .live(let w), .terminated(let w): return w
        case .cold(let u): target = u; state = nil
        case .suspended(let d, let u): target = u; state = d
        }
        let f = WebViewFactory.shared
        protections = wanted(for: target)
        let w = f.makeWebView(configuration: f.configuration(protections, desktop: desktop))
        attach(w)
        if let state { w.interactionState = state } else if let target { w.load(URLRequest(url: target)) }
        return w
    }

    func adopt(configuration: WKWebViewConfiguration) -> WKWebView {
        protections = WebViewFactory.shared.protections(of: configuration.userContentController) ?? wanted(for: url)
        let w = WebViewFactory.shared.makeWebView(configuration: configuration)
        attach(w)
        return w
    }

    private func attach(_ w: WKWebView) {
        life = .live(w)
        w.navigationDelegate = self
        w.uiDelegate = self
        w.customUserAgent = desktop ? WebViewFactory.desktopUA : nil
        bag.removeAll()
        w.publisher(for: \.title).receive(on: RunLoop.main).sink { [weak self] t in
            guard let self, let t, !t.isEmpty else { return }
            self.title = t; self.notifyHost(["title": t])
        }.store(in: &bag)
        w.publisher(for: \.url).receive(on: RunLoop.main).sink { [weak self] u in
            guard let self, let u else { return }
            if u.scheme == "about" && self.url != nil { return }
            if self.url != u { self.url = u; self.notifyHost(["url": u.absoluteString]); self.store?.persistSoon() }
        }.store(in: &bag)
        w.publisher(for: \.estimatedProgress).receive(on: RunLoop.main).sink { [weak self] p in self?.progress = p }.store(in: &bag)
        w.publisher(for: \.isLoading).receive(on: RunLoop.main).sink { [weak self] l in
            guard let self else { return }
            self.isLoading = l
            self.notifyHost(["status": l ? "loading" : "complete"])
        }.store(in: &bag)
        w.publisher(for: \.canGoBack).receive(on: RunLoop.main).sink { [weak self] v in self?.canGoBack = v }.store(in: &bag)
        w.publisher(for: \.canGoForward).receive(on: RunLoop.main).sink { [weak self] v in self?.canGoForward = v }.store(in: &bag)
    }

    private func notifyHost(_ change: [String: Any]) {
        guard let store else { return }
        if let info = store.extTabs.first(where: { $0.id == id }) { ExtensionHost.shared.tabUpdated(info, change: change) }
    }

    func rebuildWebView(loading u: URL?) {
        let old = webView
        old?.stopLoading()
        if let old { ExtensionHost.shared.tabNavigated(old) }
        life = .cold(u ?? url)
        ensureWebView()
        old?.removeFromSuperview()
        store?.objectWillChange.send()
    }

    func load(_ u: URL) {
        blockedURL = nil
        url = u
        guard let w = webView else { life = .cold(u); ensureWebView(); return }
        if wanted(for: u) != protections { rebuildWebView(loading: u); return }
        w.load(URLRequest(url: u))
    }

    func snapshot() {
        guard let w = webView, w.window != nil, w.bounds.width > 0 else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 360
        w.takeSnapshot(with: cfg) { [weak self] img, _ in if let img { self?.thumbnail = img } }
    }

    func discard() {
        guard let w = webView else { return }
        let state = w.interactionState as? Data
        ExtensionHost.shared.tabNavigated(w)
        w.removeFromSuperview()
        life = state.map { .suspended($0, url) } ?? .cold(url)
    }
}

extension Tab: WKNavigationDelegate {
    private static let externalSchemes: Set = ["tel", "mailto", "sms", "facetime", "facetime-audio", "maps", "itms-apps", "itms-appss"]
    private static let browserSchemes: Set = ["http", "https", "about", "blob", "data", "winext", "javascript", "file"]
    private static let frameLoadBlockedByContentRuleList = 104

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let u = action.request.url else { return decisionHandler(.cancel, preferences) }
        let scheme = u.scheme?.lowercased() ?? ""
        if Self.externalSchemes.contains(scheme) {
            UIApplication.shared.open(u)
            return decisionHandler(.cancel, preferences)
        }
        guard Self.browserSchemes.contains(scheme) else { return decisionHandler(.cancel, preferences) }
        if action.targetFrame?.isMainFrame == true, scheme == "http" || scheme == "https",
           action.navigationType != .backForward, wanted(for: u) != protections {
            decisionHandler(.cancel, preferences)
            DispatchQueue.main.async { self.rebuildWebView(loading: u) }
            return
        }
        preferences.preferredContentMode = WebViewFactory.contentMode(for: u.host, desktop: desktop)
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.isForMainFrame && !response.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        blockedURL = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        ExtensionHost.shared.tabNavigated(webView)
        if let h = SitePolicy.normalize(webView.url?.host), h != SitePolicy.normalize(bypassHost) { bypassHost = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url, u.scheme?.hasPrefix("http") == true { BrowserHistory.shared.record(u, title: webView.title ?? "") }
        store?.persistSoon()
        if store?.activeId == id { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.snapshot() } }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        guard e.domain == "WebKitErrorDomain", e.code == Self.frameLoadBlockedByContentRuleList else { return }
        blockedURL = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? URL(string: e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? "")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard case .live(let w) = life, w === webView else { return }
        life = .terminated(w)
        if isVisible { reviveIfNeeded() }
    }
}

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let store else { return nil }
        let t = store.newTab(url: nil, activate: true, opener: self)
        t.url = action.request.url
        return t.adopt(configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        store?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        Dialogs.alert(title: frame.securityOrigin.host, message: message) { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        Dialogs.confirm(title: frame.securityOrigin.host, message: message, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        Dialogs.prompt(title: frame.securityOrigin.host, message: prompt, text: defaultText ?? "", completion: completionHandler)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}
