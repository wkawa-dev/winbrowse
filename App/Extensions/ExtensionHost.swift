import CryptoKit
import Foundation
import UIKit
import WebKit

/// What the extension runtime needs from the browser.
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

/// Runs bundled Chrome extensions inside WKWebView: content scripts in their own content worlds, background
/// service workers in hidden web views, extension pages over the winext:// scheme, plus chrome.* plumbing.
@MainActor
final class ExtensionHost: NSObject {
    static let shared = ExtensionHost()

    private(set) var extensions: [WebExtension] = []
    let storage = ExtensionStorage()
    weak var tabs: ExtensionTabProvider?
    lazy var schemeHandler = WinextSchemeHandler(host: self)
    var userAgent: String = ""

    private var backgrounds: [String: WKWebView] = [:]
    private var backgroundReady: [String: Bool] = [:]
    private var backgroundWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private struct PageRef { weak var webView: WKWebView?; let ext: String; let tabId: Int }
    private var pages: [ObjectIdentifier: PageRef] = [:]
    /// Content-script frames that said hello, per tab web view.
    private struct FrameRef { let frame: WKFrameInfo; let ext: String; let url: String }
    private var frames: [ObjectIdentifier: [FrameRef]] = [:]
    private lazy var shimSource: String = {
        let u = Bundle.main.url(forResource: "winext-shim", withExtension: "js")!
        return (try? String(contentsOf: u, encoding: .utf8)) ?? ""
    }()

    // Ports
    private enum Endpoint {
        case background(String)
        case page(WKWebView, String)
        case content(WKWebView, WKFrameInfo, String)
        var webView: WKWebView? {
            switch self {
            case .background: return nil
            case .page(let w, _): return w
            case .content(let w, _, _): return w
            }
        }
    }
    private struct Port { var a: Endpoint; var b: [Endpoint] }
    private var ports: [String: Port] = [:]

    func isEnabled(_ id: String) -> Bool { UserDefaults.standard.object(forKey: "ext.enabled.\(id)") as? Bool ?? true }
    func setEnabled(_ id: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "ext.enabled.\(id)")
        if on { startBackground(id) } else { stopBackground(id) }
    }
    var enabledExtensions: [WebExtension] { extensions.filter { isEnabled($0.id) } }
    func ext(_ id: String) -> WebExtension? { extensions.first { $0.id == id } }

    // MARK: - Boot

    func load() {
        guard extensions.isEmpty, let root = Bundle.main.url(forResource: "Extensions-bundle", withExtension: nil) else { return }
        for id in ["sponsorblock", "xposed", "xadblock"] {
            if let e = WebExtension.load(id: id, dir: root.appendingPathComponent(id)) { extensions.append(e) }
        }
        applyDefaults()
    }

    /// Our out-of-the-box settings, written once before the extensions first start.
    private func applyDefaults() {
        // SponsorBlock: auto-skip every skippable category (its own default only auto-skips "sponsor").
        if !UserDefaults.standard.bool(forKey: "ext.defaults.sponsorblock.v1") {
            UserDefaults.standard.set(true, forKey: "ext.defaults.sponsorblock.v1")
            let auto = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "hook", "filler", "music_offtopic"]
            var sel: [[String: Any]] = auto.map { ["name": $0, "option": 2] }
            sel.append(["name": "poi_highlight", "option": 1])
            sel.append(["name": "exclusive_access", "option": 0])
            sel.append(["name": "chapter", "option": 0])
            _ = storage.set("sponsorblock", "sync", ["categorySelections": sel, "autoSkipOnMusicVideos": true])
            storage.flush()
        }
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
        if #available(iOS 16.4, *) { w.isInspectable = true }
        // Keep it attached to a window so WebKit doesn't throttle its timers.
        if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            win.insertSubview(w, at: 0)
        }
        backgrounds[id] = w
        backgroundReady[id] = false
        w.load(URLRequest(url: URL(string: "winext://\(id)/__winext/background.html")!))
    }

    func backgroundWebView(_ id: String) -> WKWebView? { backgrounds[id] }

    private func stopBackground(_ id: String) {
        backgrounds[id]?.removeFromSuperview()
        backgrounds[id] = nil
        backgroundReady[id] = nil
    }

    fileprivate func backgroundDidLoad(_ webView: WKWebView) {
        guard let id = backgrounds.first(where: { $0.value === webView })?.key, let e = ext(id) else { return }
        backgroundReady[id] = true
        backgroundWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
        let key = "ext.installedVersion.\(id)"
        let prev = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(e.version, forKey: key)
        let detail: [String: Any]
        if prev == nil { detail = ["reason": "install"] }
        else if prev != e.version { detail = ["reason": "update", "previousVersion": prev!] }
        else { detail = [:] }
        Task {
            if detail.isEmpty {
                _ = await deliver(.background(id), "event", ["path": "runtime.onStartup", "args": []])
            } else {
                _ = await deliver(.background(id), "event", ["path": "runtime.onInstalled", "args": [detail]])
            }
        }
    }

    private func waitForBackground(_ id: String) async {
        guard backgrounds[id] != nil, backgroundReady[id] == false else { return }
        await withCheckedContinuation { c in backgroundWaiters[id, default: []].append(c) }
    }

    // MARK: - User scripts for tab web views

    /// Installs every enabled extension's content scripts and bridges into a tab controller.
    func install(into ucc: WKUserContentController) {
        for e in extensions {
            ucc.removeScriptMessageHandler(forName: "winext", contentWorld: e.world)
        }
        ucc.removeScriptMessageHandler(forName: "winext", contentWorld: .page)
        ucc.addScriptMessageHandler(self, contentWorld: .page, name: "winext")   // winext:// pages opened in tabs
        for e in enabledExtensions {
            ucc.addScriptMessageHandler(self, contentWorld: e.world, name: "winext")
            for s in userScripts(for: e) { ucc.addUserScript(s) }
        }
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
                let lit = jsString(css)
                let src = """
                if(\(guardExpr)){(function(){const s=document.createElement('style');s.setAttribute('data-winext','\(e.id)');s.textContent=\(lit);
                const add=()=>{const p=document.head||document.documentElement;if(p){p.appendChild(s);return true}return false};
                if(!add()){const o=new MutationObserver(()=>{if(add())o.disconnect()});o.observe(document,{childList:true,subtree:true})}})()}
                """
                out.append(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: !cs.allFrames, in: e.world))
            }
            guard !cs.js.isEmpty else { continue }
            let code = cs.js.map { e.file($0) + "\n;" }.joined(separator: "\n")
            if cs.mainWorld {
                // Page world: wrap in a block so non-matching pages never see an exception.
                out.append(WKUserScript(source: "if(\(guardExpr)){\n\(code)\n}", injectionTime: time, forMainFrameOnly: !cs.allFrames, in: .page))
            } else {
                // Isolated world: bail out of the whole script on non-matching pages, keep top-level semantics intact.
                out.append(WKUserScript(source: "if(!\(guardExpr)){throw 'winext:skip'}\n\(code)", injectionTime: time, forMainFrameOnly: !cs.allFrames, in: e.world))
            }
        }
        return out
    }

    /// Small patches that keep older bundled extensions working against today's sites.
    private func compatScripts(for e: WebExtension) -> [WKUserScript] {
        guard e.id == "xadblock" else { return [] }
        let guardExpr = MatchPattern.jsGuard(["https://x.com/*", "https://*.x.com/*", "https://twitter.com/*", "https://*.twitter.com/*"])
        let main = (Bundle.main.url(forResource: "compat-xadblock-main", withExtension: "js")).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        // X no longer renders #react-root; the extension observes it, so hand it the app root instead (its own world only).
        let isolated = """
        if(\(guardExpr)){const g=Document.prototype.getElementById;Document.prototype.getElementById=function(id){const r=g.call(this,id);
        if(r||id!=='react-root')return r;return this.querySelector('[data-testid="primaryColumn"]')?.closest('body > div')||this.body}}
        """
        return [
            WKUserScript(source: "if(\(guardExpr)){\n\(main)\n}", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page),
            WKUserScript(source: isolated, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: e.world),
        ]
    }

    // MARK: - Extension pages (popup / options / background)

    func makePageWebView(ext e: WebExtension, path: String, tabId: Int) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(schemeHandler, forURLScheme: "winext")
        cfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "winext")
        cfg.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: .zero, configuration: cfg)
        if #available(iOS 16.4, *) { w.isInspectable = true }
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

    /// A tab navigated or closed: forget its frames and disconnect its ports.
    func tabNavigated(_ w: WKWebView) {
        frames[ObjectIdentifier(w)] = nil
        dropPorts { $0.webView === w }
    }

    func tabUpdated(_ info: ExtTabInfo, change: [String: Any]) {
        for id in backgrounds.keys where backgroundReady[id] == true {
            Task { _ = await deliver(.background(id), "event", ["path": "tabs.onUpdated", "args": [info.id, change, info.json]]) }
        }
    }

    func tabRemoved(_ tabId: Int) {
        for id in backgrounds.keys where backgroundReady[id] == true {
            Task { _ = await deliver(.background(id), "event", ["path": "tabs.onRemoved", "args": [tabId, ["windowId": 1, "isWindowClosing": false]]]) }
        }
    }

    func tabActivated(_ tabId: Int) {
        for id in backgrounds.keys where backgroundReady[id] == true {
            Task { _ = await deliver(.background(id), "event", ["path": "tabs.onActivated", "args": [["tabId": tabId, "windowId": 1]]]) }
        }
    }

    // MARK: - Delivery

    private func deliver(_ ep: Endpoint, _ kind: String, _ payload: Any) async -> String? {
        let json = jsonString(payload)
        let body = "return await globalThis.__winext.receive(kind, payload)"
        do {
            switch ep {
            case .background(let id):
                await waitForBackground(id)
                guard let w = backgrounds[id] else { return nil }
                return try await w.callAsyncJavaScript(body, arguments: ["kind": kind, "payload": json], in: nil, contentWorld: .page) as? String
            case .page(let w, _):
                return try await w.callAsyncJavaScript(body, arguments: ["kind": kind, "payload": json], in: nil, contentWorld: .page) as? String
            case .content(let w, let f, let id):
                guard let e = ext(id) else { return nil }
                return try await w.callAsyncJavaScript(body, arguments: ["kind": kind, "payload": json], in: f, contentWorld: e.world) as? String
            }
        } catch {
            if case .content(let w, let f, _) = ep { forget(frame: f, in: w) }
            return nil
        }
    }

    private func forget(frame: WKFrameInfo, in w: WKWebView) {
        frames[ObjectIdentifier(w)]?.removeAll { $0.frame == frame }
    }

    private func extensionEndpoints(_ id: String, excluding: WKWebView? = nil) -> [Endpoint] {
        var out: [Endpoint] = []
        if backgrounds[id] != nil { out.append(.background(id)) }
        for p in pages.values where p.ext == id {
            if let w = p.webView, w !== excluding { out.append(.page(w, id)) }
        }
        return out
    }

    private func contentEndpoints(_ id: String, tab w: WKWebView, frameId: Int? = nil) -> [Endpoint] {
        var refs = (frames[ObjectIdentifier(w)] ?? []).filter { $0.ext == id }
        if let frameId { refs = refs.filter { self.frameId($0.frame) == frameId } }
        // Main frame first.
        refs.sort { $0.frame.isMainFrame && !$1.frame.isMainFrame }
        return refs.map { .content(w, $0.frame, id) }
    }

    private func allContentEndpoints(_ id: String) -> [Endpoint] {
        guard let tabs else { return [] }
        return tabs.extTabs.compactMap { tabs.extWebView(tabId: $0.id) }.flatMap { contentEndpoints(id, tab: $0) }
    }

    private func firstHandled(_ eps: [Endpoint], _ payload: [String: Any]) async -> String {
        for ep in eps {
            if let r = await deliver(ep, "message", payload),
               let d = r.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               j["handled"] as? Bool == true {
                return r
            }
        }
        return "{\"handled\":false}"
    }

    private func broadcastStorage(_ id: String, area: String, changes: [String: Any]) {
        guard !changes.isEmpty else { return }
        let payload: [String: Any] = ["area": area, "changes": changes]
        for ep in extensionEndpoints(id) + allContentEndpoints(id) {
            Task { _ = await deliver(ep, "storageChanged", payload) }
        }
    }

    private func dropPorts(where pred: (Endpoint) -> Bool) {
        for (pid, p) in ports {
            if pred(p.a) {
                for b in p.b { Task { _ = await deliver(b, "portDisconnect", ["portId": pid]) } }
                ports[pid] = nil
            } else if p.b.contains(where: pred) {
                var np = p
                np.b.removeAll(where: pred)
                if np.b.isEmpty {
                    Task { _ = await deliver(p.a, "portDisconnect", ["portId": pid]) }
                    ports[pid] = nil
                } else { ports[pid] = np }
            }
        }
    }

    // MARK: - Senders

    private func frameId(_ f: WKFrameInfo) -> Int {
        f.isMainFrame ? 0 : abs(ObjectIdentifier(f).hashValue % 1_000_000) + 1
    }

    private func senderJSON(_ ep: Endpoint) -> [String: Any] {
        switch ep {
        case .background(let id):
            return ["id": id, "url": "winext://\(id)/__winext/background.html", "origin": "winext://\(id)"]
        case .page(let w, let id):
            var s: [String: Any] = ["id": id, "url": w.url?.absoluteString ?? "", "origin": "winext://\(id)"]
            if let tid = tabs?.extTabId(for: w), let t = tabs?.extTabs.first(where: { $0.id == tid }) { s["tab"] = t.json }
            return s
        case .content(let w, let f, let id):
            let url = f.request.url?.absoluteString ?? w.url?.absoluteString ?? ""
            var s: [String: Any] = ["id": id, "url": url, "frameId": frameId(f), "documentLifecycle": "active",
                                    "origin": "\(f.securityOrigin.protocol)://\(f.securityOrigin.host)"]
            if let tid = tabs?.extTabId(for: w), let t = tabs?.extTabs.first(where: { $0.id == tid }) { s["tab"] = t.json }
            return s
        }
    }
}

// MARK: - Script messages

extension ExtensionHost: WKScriptMessageHandlerWithReply {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let extId = body["ext"] as? String, let webView = message.webView else { return replyHandler(nil, "bad message") }
        // Who is talking? Content worlds are named after the extension; page-world callers must be that extension's own pages.
        let ep: Endpoint
        if message.world.name == "winext.\(extId)" {
            ep = .content(webView, message.frameInfo, extId)
        } else if message.world == .page, message.frameInfo.securityOrigin.protocol == "winext",
                  message.frameInfo.securityOrigin.host == extId {
            if let bg = backgrounds[extId], bg === webView { ep = .background(extId) } else { ep = .page(webView, extId) }
        } else {
            return replyHandler(nil, "forbidden")
        }
        guard ext(extId) != nil else { return replyHandler(nil, "unknown extension") }
        let dataStr = body["data"] as? String ?? "null"
        let data = (try? JSONSerialization.jsonObject(with: Data(dataStr.utf8), options: .fragmentsAllowed)) as? [String: Any] ?? [:]
        Task { @MainActor in
            let result = await handle(type, ext: extId, from: ep, data: data)
            replyHandler(result, nil)
        }
    }

    private func handle(_ type: String, ext id: String, from ep: Endpoint, data: [String: Any]) async -> String? {
        switch type {
        case "frame.hello":
            if case .content(let w, let f, _) = ep {
                var list = frames[ObjectIdentifier(w)] ?? []
                if f.isMainFrame { list.removeAll { $0.ext == id && $0.frame.isMainFrame } }
                list.removeAll { $0.ext == id && $0.frame == f }
                list.append(FrameRef(frame: f, ext: id, url: f.request.url?.absoluteString ?? ""))
                frames[ObjectIdentifier(w)] = list
            }
            return nil

        case "storage.get":
            let area = data["area"] as? String ?? "local"
            return jsonString(storage.get(id, area, keys: data["keys"] as? [String]))
        case "storage.set":
            let area = data["area"] as? String ?? "local"
            broadcastStorage(id, area: area, changes: storage.set(id, area, data["items"] as? [String: Any] ?? [:]))
            return nil
        case "storage.remove":
            let area = data["area"] as? String ?? "local"
            broadcastStorage(id, area: area, changes: storage.remove(id, area, keys: data["keys"] as? [String] ?? []))
            return nil
        case "storage.clear":
            let area = data["area"] as? String ?? "local"
            broadcastStorage(id, area: area, changes: storage.clear(id, area))
            return nil

        case "runtime.sendMessage":
            let payload: [String: Any] = ["msg": data["msg"] ?? NSNull(), "sender": senderJSON(ep)]
            var targets = extensionEndpoints(id, excluding: ep.webView)
            if case .background = ep { targets.removeAll { if case .background = $0 { return true }; return false } }
            return await firstHandled(targets, payload)

        case "tabs.sendMessage":
            guard let tid = data["tabId"] as? Int, let w = tabs?.extWebView(tabId: tid) else { return "{\"handled\":false}" }
            let payload: [String: Any] = ["msg": data["msg"] ?? NSNull(), "sender": senderJSON(ep)]
            return await firstHandled(contentEndpoints(id, tab: w, frameId: data["frameId"] as? Int), payload)

        case "runtime.connect", "tabs.connect":
            guard let pid = data["portId"] as? String else { return nil }
            var targets: [Endpoint]
            if type == "tabs.connect" {
                guard let tid = data["tabId"] as? Int, let w = tabs?.extWebView(tabId: tid) else { return "{\"connected\":false}" }
                targets = contentEndpoints(id, tab: w)
            } else {
                targets = extensionEndpoints(id, excluding: ep.webView)
                if case .background = ep { targets.removeAll { if case .background = $0 { return true }; return false } }
            }
            let payload: [String: Any] = ["portId": pid, "name": data["name"] ?? "", "sender": senderJSON(ep)]
            var accepted: [Endpoint] = []
            for t in targets {
                if let r = await deliver(t, "portConnect", payload), r.contains("\"accepted\":true") { accepted.append(t) }
            }
            if accepted.isEmpty { return "{\"connected\":false}" }
            ports[pid] = Port(a: ep, b: accepted)
            return "{\"connected\":true}"

        case "port.post":
            guard let pid = data["portId"] as? String, let p = ports[pid] else { return nil }
            let payload: [String: Any] = ["portId": pid, "msg": data["msg"] ?? NSNull()]
            let fromA = sameEndpoint(p.a, ep)
            for t in fromA ? p.b : [p.a] { _ = await deliver(t, "portMessage", payload) }
            return nil
        case "port.disconnect":
            guard let pid = data["portId"] as? String, let p = ports[pid] else { return nil }
            ports[pid] = nil
            let fromA = sameEndpoint(p.a, ep)
            for t in fromA ? p.b : [p.a] { _ = await deliver(t, "portDisconnect", ["portId": pid]) }
            return nil

        case "tabs.query":
            return jsonString(queryTabs(data, from: ep).map(\.json))
        case "tabs.get":
            guard let tid = data["tabId"] as? Int, let t = tabs?.extTabs.first(where: { $0.id == tid }) else { return nil }
            return jsonString(t.json)
        case "tabs.create":
            guard let s = data["url"] as? String, let u = resolve(s, ext: id) else {
                let tid = tabs?.extCreateTab(url: URL(string: "about:blank")!, active: true) ?? -1
                return jsonString(tabs?.extTabs.first { $0.id == tid }?.json ?? [:])
            }
            let tid = tabs?.extCreateTab(url: u, active: data["active"] as? Bool ?? true) ?? -1
            return jsonString(tabs?.extTabs.first { $0.id == tid }?.json ?? [:])
        case "tabs.update":
            let props = data["props"] as? [String: Any] ?? [:]
            let tid = data["tabId"] as? Int ?? tabs?.extTabs.first(where: \.active)?.id ?? -1
            tabs?.extUpdateTab(tabId: tid, url: (props["url"] as? String).flatMap { resolve($0, ext: id) }, active: props["active"] as? Bool)
            return jsonString(tabs?.extTabs.first { $0.id == tid }?.json ?? [:])
        case "tabs.remove":
            for t in data["ids"] as? [Int] ?? [] { tabs?.extRemoveTab(tabId: t) }
            return nil
        case "tabs.reload":
            let tid = data["tabId"] as? Int ?? tabs?.extTabs.first(where: \.active)?.id ?? -1
            tabs?.extReloadTab(tabId: tid)
            return nil

        case "scripting.execute":
            return await executeScript(ext: id, data: data, from: ep)
        case "scripting.css":
            guard let e = ext(id), let w = targetWebView(data["tabId"] as? Int, from: ep) else { return nil }
            var css = (data["files"] as? [String] ?? []).map { e.file($0) }.joined(separator: "\n")
            if let c = data["css"] as? String { css += "\n" + c }
            let js = "(()=>{const s=document.createElement('style');s.textContent=\(jsString(css));(document.head||document.documentElement).appendChild(s)})()"
            _ = try? await w.evaluateJavaScript(js, in: nil, contentWorld: e.world)
            return nil

        case "runtime.openOptionsPage":
            if let e = ext(id), let o = e.options { tabs?.extPresent(ext: e, page: o) }
            return nil
        case "action.openPopup":
            if let e = ext(id), let p = e.popup { tabs?.extPresent(ext: e, page: p) }
            return nil

        case "fetch":
            return await NativeFetch.perform(data, userAgent: userAgent, ext: ext(id))
        case "crypto.digest":
            guard let b64 = data["data"] as? String, let d = Data(base64Encoded: b64) else { return nil }
            let alg = data["alg"] as? String ?? "SHA-256"
            let out: Data
            switch alg {
            case "SHA-1": out = Data(Insecure.SHA1.hash(data: d))
            case "SHA-384": out = Data(SHA384.hash(data: d))
            case "SHA-512": out = Data(SHA512.hash(data: d))
            default: out = Data(SHA256.hash(data: d))
            }
            return jsonString(out.base64EncodedString())
        default:
            return nil
        }
    }

    private func sameEndpoint(_ a: Endpoint, _ b: Endpoint) -> Bool {
        switch (a, b) {
        case (.background(let x), .background(let y)): return x == y
        case (.page(let x, _), .page(let y, _)): return x === y
        case (.content(let x, let f, _), .content(let y, let g, _)): return x === y && f == g
        default: return false
        }
    }

    private func queryTabs(_ q: [String: Any], from ep: Endpoint) -> [ExtTabInfo] {
        var list = tabs?.extTabs ?? []
        if let a = q["active"] as? Bool { list = list.filter { $0.active == a } }
        if let ids = q["url"] {
            let pats = (ids as? [String]) ?? [(ids as? String) ?? ""]
            let res = pats.compactMap { try? NSRegularExpression(pattern: MatchPattern.regex($0)) }
            list = list.filter { t in res.contains { $0.firstMatch(in: t.url, range: NSRange(t.url.startIndex..., in: t.url)) != nil } }
        }
        if let s = q["status"] as? String { list = list.filter { ($0.loading ? "loading" : "complete") == s } }
        if let a = q["audible"] as? Bool { list = list.filter { $0.audible == a } }
        return list
    }

    private func targetWebView(_ tabId: Int?, from ep: Endpoint) -> WKWebView? {
        if let tabId { return tabs?.extWebView(tabId: tabId) }
        if case .content(let w, _, _) = ep { return w }
        guard let active = tabs?.extTabs.first(where: \.active) else { return nil }
        return tabs?.extWebView(tabId: active.id)
    }

    private func executeScript(ext id: String, data: [String: Any], from ep: Endpoint) async -> String? {
        guard let e = ext(id), let w = targetWebView(data["tabId"] as? Int, from: ep) else { return "[]" }
        let main = (data["world"] as? String) == "MAIN"
        let world: WKContentWorld = main ? .page : e.world
        if !main {
            // Make sure the extension's chrome.* exists in this world even if no content script matched.
            _ = try? await w.evaluateJavaScript(shimInstall(e, ctx: "content") + ";0", in: nil, contentWorld: world)
        }
        var code = (data["files"] as? [String] ?? []).map { e.file($0) }.joined(separator: "\n;\n")
        if let c = data["code"] as? String { code += "\n;" + c }
        let result = try? await w.evaluateJavaScript(code, in: nil, contentWorld: world)
        return jsonString([["frameId": 0, "result": result.map { jsonSafe($0) } ?? NSNull()]])
    }

    private func resolve(_ s: String, ext id: String) -> URL? {
        if s.contains("://") || s.hasPrefix("about:") { return URL(string: s) }
        return URL(string: "winext://\(id)/" + s.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

// MARK: - Background navigation

extension ExtensionHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        backgroundDidLoad(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let id = backgrounds.first(where: { $0.value === webView })?.key {
            backgroundReady[id] = false
            webView.reload()
        }
    }
}

// MARK: - JSON helpers

func jsonSafe(_ v: Any) -> Any {
    if JSONSerialization.isValidJSONObject([v]) { return v }
    return String(describing: v)
}

func jsonString(_ v: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) else { return "null" }
    return String(data: d, encoding: .utf8) ?? "null"
}

/// A JS string literal for arbitrary text (JSON escaping is valid JS; also guard U+2028/2029 and </script>).
func jsString(_ s: String) -> String {
    jsonString(s).replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}
