#if DEBUG
import Foundation
import Network
import Security
import WebKit

/// Debug-only control port for driving the simulator from a terminal:
///   T=$(cat /tmp/winbrowse-debug-token)
///   curl -H "X-Debug-Token: $T" 'localhost:8899/open?url=https://m.youtube.com'
///   curl -H "X-Debug-Token: $T" -d 'document.title' 'localhost:8899/eval?world=page'   (world: page | ext:<id> | ubo | bg:<id>)
///   curl -H "X-Debug-Token: $T" 'localhost:8899/state'
/// Bound to loopback only; every request needs the per-run token (also logged at start) and a loopback Host header.
@MainActor
final class DebugServer {
    static let shared = DebugServer()
    private var listener: NWListener?
    private nonisolated static let tokenPath = "/tmp/winbrowse-debug-token"
    private nonisolated static let token: String = {
        var b = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        let t = b.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: tokenPath, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        return t
    }()

    func start(port: UInt16 = 8899) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard listener == nil, let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return }
        _ = Self.token
        l.newConnectionHandler = { c in
            c.start(queue: .main)
            Self.receive(c, buffer: Data())
        }
        l.start(queue: .main)
        listener = l
        NSLog("[debug] control port \(port) (loopback, token in \(Self.tokenPath))")
    }

    private nonisolated static func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, _ in
            var buf = buffer
            if let data { buf.append(data) }
            if let req = parse(buf) {
                Task { @MainActor in
                    let ok = req.token == token && ["localhost", "127.0.0.1", "[::1]"].contains(req.host)
                    let body = ok ? await DebugServer.shared.handle(req.path, req.query, req.body) : "forbidden"
                    let out = "HTTP/1.1 \(ok ? "200 OK" : "403 Forbidden")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    c.send(content: Data(out.utf8), completion: .contentProcessed { _ in c.cancel() })
                }
            } else if !done {
                receive(c, buffer: buf)
            } else { c.cancel() }
        }
    }

    private nonisolated static func parse(_ d: Data) -> (path: String, query: [String: String], body: String, token: String, host: String)? {
        guard let s = String(data: d, encoding: .utf8), let headEnd = s.range(of: "\r\n\r\n") else { return nil }
        let head = s[..<headEnd.lowerBound]
        let body = String(s[headEnd.upperBound...])
        let lines = head.split(separator: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var len = 0, tok = "", host = ""
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            let name = l[..<c].lowercased(), val = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { len = Int(val) ?? 0 }
            else if name == "x-debug-token" { tok = val }
            else if name == "host" { host = val.lowercased().replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression) }
        }
        if body.utf8.count < len { return nil }
        let comps = URLComponents(string: String(parts[1]))
        var q: [String: String] = [:]
        for i in comps?.queryItems ?? [] { q[i.name] = i.value ?? "" }
        return (comps?.path ?? "/", q, body, tok, host)
    }

    private func handle(_ path: String, _ q: [String: String], _ body: String) async -> String {
        let store = BrowserStore.shared
        switch path {
        case "/open":
            guard let s = q["url"] else { return "missing url" }
            if q["new"] != nil { store.newTab(url: URL(string: s)) } else { store.open(s) }
            return "ok"
        case "/state":
            return jsonString([
                "tabs": store.extTabs.map(\.json),
                "ubo": ContentBlocker.shared.status,
                "rules": ContentBlocker.shared.activeRuleCount,
            ])
        case "/eval":
            let world = q["world"] ?? "page"
            if world.hasPrefix("bg:") {
                return await ExtensionHost.shared.debugEvalBackground(String(world.dropFirst(3)), body)
            }
            guard let w = store.active?.webView else { return "no webview" }
            let cw: WKContentWorld
            if world == "page" { cw = .page }
            else if world == "ubo" { cw = UBOScripts.shared.world }
            else if world.hasPrefix("ext:"), let e = ExtensionHost.shared.ext(String(world.dropFirst(4))) { cw = e.world }
            else { return "bad world" }
            do {
                let r = try await w.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: cw)
                return r.map { jsonString(jsonSafe($0)) } ?? "undefined"
            } catch { return "error: \(error)" }
        case "/focus":
            NotificationCenter.default.post(name: .init("debug.focusAddress"), object: nil); return "ok"
        case "/field":
            // Reads the address field; `press=address.cut|address.paste` taps that button first, `type=` inserts text.
            guard let f = DebugUI.findAddressField() else { return "no field" }
            if let id = q["press"], let b = DebugUI.find(UIButton.self, id: id, in: f.rightView) { b.sendActions(for: .primaryActionTriggered) }
            if let t = q["type"] { f.insertText(t) }
            let sel = f.selectedTextRange.flatMap { f.text(in: $0) } ?? ""
            return jsonString(["text": f.text ?? "", "selected": sel, "editing": f.isFirstResponder, "rightView": f.rightView.map { "\($0.frame)" } ?? "none"])
        case "/menu":
            Router.shared.toggleMenu(); return "ok"
        case "/route":
            let r: [String: Route] = ["tabs": .tabs, "settings": .settings, "extensions": .extensions, "ublock": .ublock, "history": .history]
            if let x = r[q["r"] ?? ""] { Router.shared.push(x) } else { Router.shared.popToRoot(); store.presentedExtensionPage = nil }
            return "ok"
        case "/popup":
            guard let e = ExtensionHost.shared.ext(q["ext"] ?? ""), let p = q["page"] ?? e.popup ?? e.options else { return "no" }
            store.extPresent(ext: e, page: p); return "ok"
        case "/ubo":
            if let site = q["site"] { ContentBlocker.shared.setSite(site, disabled: q["off"] == "1") }
            if let t = store.active { t.rebuildWebView(loading: t.url) }
            return "ok"
        case "/ext":
            if let id = q["id"] { ExtensionHost.shared.setEnabled(id, q["on"] == "1"); WebViewFactory.shared.rebuildScripts(); store.active?.webView?.reload() }
            return "ok"
        case "/select":
            if let i = Int(q["i"] ?? ""), i < store.tabs.count { store.select(store.tabs[i]) }
            return "ok"
        default:
            return "unknown"
        }
    }
}

extension ExtensionHost {
    func debugEvalBackground(_ id: String, _ code: String) async -> String {
        guard let w = backgroundWebView(id) else { return "no background" }
        do {
            let r = try await w.callAsyncJavaScript(code, arguments: [:], in: nil, contentWorld: .page)
            return r.map { jsonString(jsonSafe($0)) } ?? "undefined"
        } catch { return "error: \(error)" }
    }
}

@MainActor
enum DebugUI {
    static func findAddressField() -> UITextField? {
        for sc in UIApplication.shared.connectedScenes {
            for w in (sc as? UIWindowScene)?.windows ?? [] { if let f = find(UITextField.self, id: nil, in: w) { return f } }
        }
        return nil
    }

    static func find<T: UIView>(_ type: T.Type, id: String?, in v: UIView?) -> T? {
        guard let v else { return nil }
        if let t = v as? T, id == nil || t.accessibilityIdentifier == id { return t }
        for s in v.subviews { if let r = find(type, id: id, in: s) { return r } }
        return nil
    }
}
#endif
