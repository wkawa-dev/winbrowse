import Combine
import UIKit
import WebKit

@MainActor
final class Tab: NSObject, ObservableObject, Identifiable {
    let id: Int
    @Published var url: URL?
    @Published var title: String = ""
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var thumbnail: UIImage?
    @Published var blockedURL: URL?          // main-frame load stopped by uBO (strict blocking)
    @Published var desktop = false
    @Published var filteredContent = true
    @Published var hasWebView = false
    var lastAccess = Date()
    var restoreState: Data?
    var pendingURL: URL?
    /// One-shot bypass for "proceed" on the strict-block page.
    var bypassHost: String?
    private var contentTerminated = false

    private var isVisible: Bool {
        store?.activeId == id && UIApplication.shared.applicationState == .active
    }

    /// Reload a tab whose web content process was terminated (called when it is shown / the app returns).
    func reviveIfNeeded() {
        guard contentTerminated, let w = webView else { return }
        contentTerminated = false
        if w.url != nil { w.reload() } else if let u = url { w.load(URLRequest(url: u)) }
    }

    private(set) var webView: WKWebView?
    private var bag: Set<AnyCancellable> = []
    weak var store: BrowserStore?

    init(id: Int, url: URL?, store: BrowserStore) {
        self.id = id
        self.url = url
        self.pendingURL = url
        self.store = store
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if url?.scheme == "winext", let e = url?.host.flatMap({ ExtensionHost.shared.ext($0) }) { return e.name }
        if let h = url?.host { return h }
        return url == nil ? "new tab" : (url?.absoluteString ?? "")
    }

    /// Creates the web view on first use (tabs restored at launch stay cold until shown).
    @discardableResult
    func ensureWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let webView { return webView }
        let f = WebViewFactory.shared
        let filtered = !(ContentBlocker.shared.isSiteDisabled(url?.host))
        filteredContent = filtered
        let w = f.makeWebView(configuration: configuration ?? f.configuration(filteredContent: filtered, desktop: desktop))
        attach(w)
        if configuration == nil {
            if let s = restoreState {
                w.interactionState = s
                restoreState = nil
            } else if let u = pendingURL {
                w.load(URLRequest(url: u))
            }
        }
        pendingURL = nil
        return w
    }

    private func attach(_ w: WKWebView) {
        webView = w
        hasWebView = true
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

    /// Swap the web view for one with a different controller (uBO on/off for this site, desktop mode).
    func rebuildWebView(loading u: URL?) {
        let old = webView
        old?.stopLoading()
        if let old { ExtensionHost.shared.tabNavigated(old) }
        webView = nil
        hasWebView = false
        pendingURL = u ?? url
        restoreState = nil
        ensureWebView()
        old?.removeFromSuperview()
        store?.objectWillChange.send()
    }

    func load(_ u: URL) {
        blockedURL = nil
        url = u
        if webView == nil { pendingURL = u; ensureWebView(); return }
        if ContentBlocker.shared.isSiteDisabled(u.host) == filteredContent { rebuildWebView(loading: u); return }
        webView?.load(URLRequest(url: u))
    }

    func snapshot() {
        guard let w = webView, w.window != nil, w.bounds.width > 0 else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 360
        w.takeSnapshot(with: cfg) { [weak self] img, _ in if let img { self?.thumbnail = img } }
    }

    func discard() {
        if let w = webView {
            restoreState = w.interactionState as? Data
            ExtensionHost.shared.tabNavigated(w)
            w.removeFromSuperview()
        }
        pendingURL = url
        webView = nil
        hasWebView = false
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let u = action.request.url else { return decisionHandler(.cancel, preferences) }
        let scheme = u.scheme?.lowercased() ?? ""
        if ["tel", "mailto", "sms", "facetime", "facetime-audio", "maps", "itms-apps", "itms-appss"].contains(scheme) {
            UIApplication.shared.open(u)
            return decisionHandler(.cancel, preferences)
        }
        if !["http", "https", "about", "blob", "data", "winext", "javascript", "file"].contains(scheme) {
            // youtube://, vnd.youtube:, intent://, twitter:// … stay in the browser.
            return decisionHandler(.cancel, preferences)
        }
        if action.targetFrame?.isMainFrame == true, scheme == "http" || scheme == "https" {
            let host = u.host?.lowercased()
            let wantFiltered = !ContentBlocker.shared.isSiteDisabled(host) && bypassHost != host
            if wantFiltered != filteredContent, action.navigationType != .backForward {
                decisionHandler(.cancel, preferences)
                DispatchQueue.main.async { self.rebuildWebView(loading: u) }
                return
            }
        }
        preferences.preferredContentMode = WebViewFactory.contentMode(for: u.host, desktop: desktop)
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, !response.canShowMIMEType {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
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
        if let h = webView.url?.host?.lowercased(), h != bypassHost { bypassHost = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url, u.scheme?.hasPrefix("http") == true { BrowserHistory.shared.record(u, title: webView.title ?? "") }
        store?.persistSoon()
        if store?.activeId == id { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.snapshot() } }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        // WKError.Code 104 = frame load blocked by a content rule list.
        if e.domain == "WebKitErrorDomain", e.code == 104 {
            blockedURL = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? URL(string: e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? "")
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS reclaimed this tab's page process. Reload only once it's on screen, like Safari: reloading every
        // background tab at once (often while the app itself is in the background) just gets them killed again.
        contentTerminated = true
        if isVisible { reviveIfNeeded() }
    }
}

// MARK: - UI delegate

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let store else { return nil }
        let t = store.newTab(url: nil, activate: true, opener: self)
        t.url = action.request.url
        return t.ensureWebView(configuration: configuration)
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

/// UIKit alerts styled by the system; used for JS dialogs.
@MainActor
enum Dialogs {
    static var top: UIViewController? {
        var vc = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
    static func alert(title: String, message: String, done: @escaping () -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in done() })
        guard let top else { return done() }
        top.present(a, animated: true)
    }
    static func confirm(title: String, message: String, completion: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(true) })
        guard let top else { return completion(false) }
        top.present(a, animated: true)
    }
    static func prompt(title: String, message: String, text: String, completion: @escaping (String?) -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addTextField { $0.text = text }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(a.textFields?.first?.text) })
        guard let top else { return completion(nil) }
        top.present(a, animated: true)
    }
}
