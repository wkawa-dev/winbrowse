import Foundation
import os
import UIKit
import WebKit

@MainActor
protocol ExtensionTabProvider: AnyObject {
    var extTabs: [ExtTabInfo] { get }
    func extWebView(tabId: Int) -> WKWebView?
    func extTabId(for webView: WKWebView) -> Int?
    func extCreateTab(url: URL, active: Bool) -> Int
    func extUpdateTab(tabId: Int, url: URL?, active: Bool?)
    func extRemoveTab(tabId: Int)
    func extReloadTab(tabId: Int)
    func extPresent(ext: WebExtension, page: String)
}

struct ExtTabInfo {
    var id: Int
    var index: Int
    var url: String
    var title: String
    var active: Bool
    var loading: Bool
    var audible: Bool

    var json: [String: Any] {
        ["id": id, "index": index, "windowId": 1, "active": active, "highlighted": active, "selected": active,
         "pinned": false, "incognito": false, "url": url, "pendingUrl": url, "title": title,
         "status": loading ? "loading" : "complete", "discarded": false, "autoDiscardable": true,
         "audible": audible, "mutedInfo": ["muted": false], "width": 390, "height": 844, "groupId": -1]
    }
}

@MainActor
final class ExtensionHost: NSObject {
    static let shared = ExtensionHost()
    static let bundledIds = ["sponsorblock", "xposed", "xadblock"]

    enum Endpoint {
        case background(String)
        case page(WKWebView, String)
        case content(WKWebView, WKFrameInfo, String, frameId: Int)

        var webView: WKWebView? {
            switch self {
            case .background: return nil
            case .page(let w, _): return w
            case .content(let w, _, _, _): return w
            }
        }

        var isContentScript: Bool {
            if case .content = self { return true }
            return false
        }

        func same(as other: Endpoint) -> Bool {
            switch (self, other) {
            case (.background(let x), .background(let y)): return x == y
            case (.page(let x, _), .page(let y, _)): return x === y
            case (.content(let x, _, let a, let f), .content(let y, _, let b, let g)): return x === y && a == b && f == g
            default: return false
            }
        }
    }

    enum Background {
        case loading(WKWebView, [CheckedContinuation<Void, Never>])
        case ready(WKWebView)
        case failed(WKWebView)

        var webView: WKWebView {
            switch self {
            case .loading(let w, _), .ready(let w), .failed(let w): return w
            }
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    struct PageRef { weak var webView: WKWebView?; let ext: String; let tabId: Int }
    struct FrameRef { var frame: WKFrameInfo; let ext: String; let id: Int }
    struct Port { var a: Endpoint; var b: [Endpoint] }

    private(set) var extensions: [WebExtension] = []
    let storage = ExtensionStorage()
    weak var tabs: ExtensionTabProvider?
    lazy var schemeHandler = WinextSchemeHandler(host: self)
    var userAgent: String = ""
    let log = Logger(subsystem: "dev.winbrowse.browser", category: "extensions")

    private(set) var backgrounds: [String: Background] = [:]
    var pages: [ObjectIdentifier: PageRef] = [:]
    var frames: [ObjectIdentifier: [FrameRef]] = [:]
    var ports: [String: Port] = [:]
    private lazy var shimSource: String = AppScripts.bundled("winext-shim")

    func isEnabled(_ id: String) -> Bool { UserDefaults.standard.object(forKey: "ext.enabled.\(id)") as? Bool ?? true }
    func setEnabled(_ id: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "ext.enabled.\(id)")
        if on { startBackground(id) } else { stopBackground(id) }
    }

    var enabledExtensions: [WebExtension] { extensions.filter { isEnabled($0.id) } }
    func ext(_ id: String) -> WebExtension? { extensions.first { $0.id == id } }

    func load() {
        guard extensions.isEmpty, let root = Bundle.main.url(forResource: "Extensions-bundle", withExtension: nil) else { return }
        for id in Self.bundledIds {
            if let e = WebExtension.load(id: id, dir: root.appendingPathComponent(id)) { extensions.append(e) }
        }
        applyDefaults()
    }

    private func applyDefaults() {
        guard !UserDefaults.standard.bool(forKey: "ext.defaults.sponsorblock.v1") else { return }
        UserDefaults.standard.set(true, forKey: "ext.defaults.sponsorblock.v1")
        let auto = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "hook", "filler", "music_offtopic"]
        var sel: [[String: Any]] = auto.map { ["name": $0, "option": 2] }
        sel.append(["name": "poi_highlight", "option": 1])
        sel.append(["name": "exclusive_access", "option": 0])
        sel.append(["name": "chapter", "option": 0])
        _ = storage.set("sponsorblock", "sync", ["categorySelections": sel, "autoSkipOnMusicVideos": true])
        storage.flush()
    }

    func startBackgrounds() {
        for e in enabledExtensions { startBackground(e.id) }
    }

    private func startBackground(_ id: String) {
        guard backgrounds[id] == nil, let e = ext(id), !e.backgroundScripts.isEmpty else { return }
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(schemeHandler, forURLScheme: "winext")
        cfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "winext")
        let w = WKWebView(frame: CGRect(x: -4, y: -4, width: 2, height: 2), configuration: cfg)
        w.isUserInteractionEnabled = false
        w.navigationDelegate = self
        w.isInspectable = true
        if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            win.insertSubview(w, at: 0)
        }
        backgrounds[id] = .loading(w, [])
        w.load(URLRequest(url: URL(string: "winext://\(id)/__winext/background.html")!))
    }

    func backgroundWebView(_ id: String) -> WKWebView? { backgrounds[id]?.webView }

    private func backgroundId(_ webView: WKWebView) -> String? {
        backgrounds.first { $0.value.webView === webView }?.key
    }

    private func settle(_ id: String, as state: Background) {
        if case .loading(_, let waiters) = backgrounds[id] { waiters.forEach { $0.resume() } }
        backgrounds[id] = state
    }

    private func stopBackground(_ id: String) {
        backgrounds[id]?.webView.removeFromSuperview()
        if case .loading(_, let waiters) = backgrounds[id] { waiters.forEach { $0.resume() } }
        backgrounds[id] = nil
    }

    fileprivate func backgroundDidLoad(_ webView: WKWebView) {
        guard let id = backgroundId(webView), let e = ext(id) else { return }
        settle(id, as: .ready(webView))
        let key = "ext.installedVersion.\(id)"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(e.version, forKey: key)
        let event: (String, [Any])
        if let previous, previous == e.version { event = ("runtime.onStartup", []) }
        else if let previous { event = ("runtime.onInstalled", [["reason": "update", "previousVersion": previous]]) }
        else { event = ("runtime.onInstalled", [["reason": "install"]]) }
        Task { _ = await deliver(.background(id), "event", ["path": event.0, "args": event.1]) }
    }

    fileprivate func backgroundDidFail(_ webView: WKWebView, _ error: Error) {
        guard let id = backgroundId(webView) else { return }
        log.error("background page of \(id, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)")
        settle(id, as: .failed(webView))
    }

    private func waitForBackground(_ id: String) async {
        guard case .loading = backgrounds[id] else { return }
        await withCheckedContinuation { c in
            if case .loading(let w, let waiters) = backgrounds[id] { backgrounds[id] = .loading(w, waiters + [c]) } else { c.resume() }
        }
    }

    func install(into ucc: WKUserContentController) {
        for e in extensions {
            ucc.removeScriptMessageHandler(forName: "winext", contentWorld: e.world)
        }
        for e in enabledExtensions {
            ucc.addScriptMessageHandler(self, contentWorld: e.world, name: "winext")
            for s in userScripts(for: e) { ucc.addUserScript(s) }
        }
    }

    func installPages(into ucc: WKUserContentController) {
        ucc.removeScriptMessageHandler(forName: "winext", contentWorld: .page)
        ucc.addScriptMessageHandler(self, contentWorld: .page, name: "winext")
    }

    func shimInstall(_ e: WebExtension, ctx: String, tabId: Int = -1) -> String {
        let cfg = "{\"id\":\"\(e.id)\",\"ctx\":\"\(ctx)\",\"tabId\":\(tabId),\"uiLang\":\"\(Locale.preferredLanguages.first ?? "en-US")\",\"manifest\":\(e.manifestJSON),\"messages\":\(e.messagesJSON)}"
        return shimSource + "\n;__winextInstall(\(cfg));\n"
    }

    private func userScripts(for e: WebExtension) -> [WKUserScript] {
        var out: [WKUserScript] = []
        let allMatches = e.contentScripts.filter { !$0.mainWorld }.flatMap(\.matches)
        if !allMatches.isEmpty {
            let anyAllFrames = e.contentScripts.contains { !$0.mainWorld && $0.allFrames }
            let src = "if(\(MatchPattern.jsGuard(allMatches))){\n\(shimInstall(e, ctx: "content"))\n}"
            out.append(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: !anyAllFrames, in: e.world))
        }
        out += compatScripts(for: e)
        for cs in e.contentScripts {
            let guardExpr = MatchPattern.jsGuard(cs.matches, exclude: cs.excludeMatches)
            let time: WKUserScriptInjectionTime = cs.runAt == "document_start" ? .atDocumentStart : .atDocumentEnd
            if !cs.css.isEmpty {
                let css = cs.css.map { e.file($0) }.joined(separator: "\n")
                    .replacingOccurrences(of: "chrome-extension://__MSG_@@extension_id__/", with: e.baseURL)
                let src = "if(\(guardExpr)){(\(AppScripts.bundled("isolated-style")))(\(jsString(css)))}"
                out.append(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: !cs.allFrames, in: e.world))
            }
            guard !cs.js.isEmpty else { continue }
            let code = cs.js.map { e.file($0) + "\n;" }.joined(separator: "\n")
            if cs.mainWorld {
                out.append(WKUserScript(source: "if(\(guardExpr)){\n\(code)\n}", injectionTime: time, forMainFrameOnly: !cs.allFrames, in: .page))
            } else {
                out.append(WKUserScript(source: "if(!\(guardExpr)){throw 'winext:skip'}\n\(code)", injectionTime: time, forMainFrameOnly: !cs.allFrames, in: e.world))
            }
        }
        return out
    }

    private func compatScripts(for e: WebExtension) -> [WKUserScript] {
        guard e.id == "xadblock" else { return [] }
        let guardExpr = MatchPattern.jsGuard(["https://x.com/*", "https://*.x.com/*", "https://twitter.com/*", "https://*.twitter.com/*"])
        let isolated = """
        if(\(guardExpr)){const g=Document.prototype.getElementById;Document.prototype.getElementById=function(id){const r=g.call(this,id);
        if(r||id!=='react-root')return r;return this.querySelector('[data-testid="primaryColumn"]')?.closest('body > div')||this.body}}
        """
        return [WKUserScript(source: isolated, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: e.world)]
    }

    func makePageWebView(ext e: WebExtension, path: String, tabId: Int) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(schemeHandler, forURLScheme: "winext")
        cfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "winext")
        cfg.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isInspectable = true
        w.isOpaque = false
        pages[ObjectIdentifier(w)] = PageRef(webView: w, ext: e.id, tabId: tabId)
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        w.load(URLRequest(url: URL(string: "winext://\(e.id)/\(clean)\(clean.contains("?") ? "&" : "?")__tab=\(tabId)")!))
        return w
    }

    func releasePage(_ w: WKWebView) {
        pages[ObjectIdentifier(w)] = nil
        dropPorts { $0.webView === w }
    }

    func tabNavigated(_ w: WKWebView) {
        frames[ObjectIdentifier(w)] = nil
        dropPorts { $0.webView === w }
    }

    func tabUpdated(_ info: ExtTabInfo, change: [String: Any]) {
        broadcastToBackgrounds("tabs.onUpdated", [info.id, change, info.json])
    }

    func tabRemoved(_ tabId: Int) {
        broadcastToBackgrounds("tabs.onRemoved", [tabId, ["windowId": 1, "isWindowClosing": false]])
    }

    func tabActivated(_ tabId: Int) {
        broadcastToBackgrounds("tabs.onActivated", [["tabId": tabId, "windowId": 1]])
    }

    private func broadcastToBackgrounds(_ path: String, _ args: [Any]) {
        for (id, b) in backgrounds where b.isReady {
            Task { _ = await deliver(.background(id), "event", ["path": path, "args": args]) }
        }
    }

    func deliver(_ ep: Endpoint, _ kind: String, _ payload: Any) async -> String? {
        let arguments: [String: Any] = ["kind": kind, "payload": jsonString(payload)]
        let body = "return await globalThis.__winext.receive(kind, payload)"
        do {
            switch ep {
            case .background(let id):
                await waitForBackground(id)
                guard case .ready(let w) = backgrounds[id] else { return nil }
                return try await w.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page) as? String
            case .page(let w, _):
                return try await w.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page) as? String
            case .content(let w, let f, let id, let frameId):
                guard let e = ext(id) else { return nil }
                do {
                    return try await w.callAsyncJavaScript(body, arguments: arguments, in: f, contentWorld: e.world) as? String
                } catch {
                    frames[ObjectIdentifier(w)]?.removeAll { $0.ext == id && $0.id == frameId }
                    throw error
                }
            }
        } catch {
            return nil
        }
    }

    func extensionEndpoints(_ id: String, excluding: WKWebView? = nil) -> [Endpoint] {
        var out: [Endpoint] = []
        if backgrounds[id] != nil { out.append(.background(id)) }
        for p in pages.values where p.ext == id {
            if let w = p.webView, w !== excluding { out.append(.page(w, id)) }
        }
        return out
    }

    func contentEndpoints(_ id: String, tab w: WKWebView, frameId: Int? = nil) -> [Endpoint] {
        (frames[ObjectIdentifier(w)] ?? [])
            .filter { $0.ext == id && (frameId == nil || $0.id == frameId) }
            .sorted { $0.id == 0 && $1.id != 0 }
            .map { .content(w, $0.frame, id, frameId: $0.id) }
    }

    func allContentEndpoints(_ id: String) -> [Endpoint] {
        guard let tabs else { return [] }
        return tabs.extTabs.compactMap { tabs.extWebView(tabId: $0.id) }.flatMap { contentEndpoints(id, tab: $0) }
    }

    func senderJSON(_ ep: Endpoint) -> [String: Any] {
        switch ep {
        case .background(let id):
            return ["id": id, "url": "winext://\(id)/__winext/background.html", "origin": "winext://\(id)"]
        case .page(let w, let id):
            var s: [String: Any] = ["id": id, "url": w.url?.absoluteString ?? "", "origin": "winext://\(id)"]
            if let t = tabInfo(for: w) { s["tab"] = t.json }
            return s
        case .content(let w, let f, let id, let frameId):
            let url = f.request.url?.absoluteString ?? w.url?.absoluteString ?? ""
            var s: [String: Any] = ["id": id, "url": url, "frameId": frameId, "documentLifecycle": "active",
                                    "origin": "\(f.securityOrigin.protocol)://\(f.securityOrigin.host)"]
            if let t = tabInfo(for: w) { s["tab"] = t.json }
            return s
        }
    }

    private func tabInfo(for w: WKWebView) -> ExtTabInfo? {
        guard let tid = tabs?.extTabId(for: w) else { return nil }
        return tabs?.extTabs.first { $0.id == tid }
    }
}

extension ExtensionHost: WKScriptMessageHandlerWithReply {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let extId = body["ext"] as? String, let webView = message.webView else { return replyHandler(nil, "bad message") }
        let ep: Endpoint
        if message.world.name == "winext.\(extId)" {
            ep = .content(webView, message.frameInfo, extId, frameId: body["frame"] as? Int ?? (message.frameInfo.isMainFrame ? 0 : -1))
        } else if message.world == .page, message.frameInfo.securityOrigin.protocol == "winext",
                  message.frameInfo.securityOrigin.host == extId {
            ep = backgrounds[extId]?.webView === webView ? .background(extId) : .page(webView, extId)
        } else {
            return replyHandler(nil, "forbidden")
        }
        guard ext(extId) != nil else { return replyHandler(nil, "unknown extension") }
        guard let kind = ExtensionMessage(rawValue: type) else { return replyHandler(nil, "unknown message type \(type)") }
        guard !ep.isContentScript || kind.contentScriptsMayCall else { return replyHandler(nil, "\(type) is not available to content scripts") }
        let dataStr = body["data"] as? String ?? "null"
        let data = (try? JSONSerialization.jsonObject(with: Data(dataStr.utf8), options: .fragmentsAllowed)) as? [String: Any] ?? [:]
        Task { @MainActor in
            await replyHandler(handle(kind, ext: extId, from: ep, data: data), nil)
        }
    }

    private func handle(_ kind: ExtensionMessage, ext id: String, from ep: Endpoint, data: [String: Any]) async -> String? {
        switch kind {
        case .frameHello: return frameHello(id, from: ep)
        case .storageGet, .storageSet, .storageRemove, .storageClear: return storageMessage(kind, ext: id, data: data)
        case .runtimeSendMessage, .tabsSendMessage: return await sendMessage(kind, ext: id, from: ep, data: data)
        case .runtimeConnect, .tabsConnect: return await connect(kind, ext: id, from: ep, data: data)
        case .portPost, .portDisconnect: return await portMessage(kind, from: ep, data: data)
        case .tabsQuery, .tabsGet, .tabsCreate, .tabsUpdate, .tabsRemove, .tabsReload: return tabsMessage(kind, ext: id, from: ep, data: data)
        case .scriptingExecute: return await executeScript(ext: id, data: data, from: ep)
        case .scriptingCSS: return await insertCSS(ext: id, data: data, from: ep)
        case .runtimeOpenOptionsPage, .actionOpenPopup: return present(kind, ext: id)
        case .fetch: return await NativeFetch.perform(data, userAgent: userAgent, ext: ext(id))
        case .cryptoDigest: return digest(data)
        }
    }
}

extension ExtensionHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        backgroundDidLoad(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        backgroundDidFail(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        backgroundDidFail(webView, error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let id = backgroundId(webView) else { return }
        settle(id, as: .loading(webView, []))
        webView.reload()
    }
}
