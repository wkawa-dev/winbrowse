#if DEBUG
import Foundation
import Network
import os
import Security
import WebKit

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

    func start(port: UInt16 = 8_899) {
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
        Logger(subsystem: "dev.winbrowse.browser", category: "debug").notice("control port \(port) on loopback, token in \(Self.tokenPath, privacy: .public)")
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

    private struct DebugRoute {
        let path: String
        let help: String
        let run: @MainActor ([String: String], String) async -> String
    }

    private func handle(_ path: String, _ q: [String: String], _ body: String) async -> String {
        guard let route = routes.first(where: { $0.path == path }) else { return "unknown route \(path); see /help" }
        return await route.run(q, body)
    }

    private var routes: [DebugRoute] {
        let store = BrowserStore.shared
        let pages: [String: Route] = ["tabs": .tabs, "settings": .settings, "extensions": .extensions, "ublock": .ublock, "history": .history, "passkeys": .passkeys]
        return [
            DebugRoute(path: "/help", help: "this list") { [unowned self] _, _ in
                routes.map { "\($0.path)  \($0.help)" }.joined(separator: "\n")
            },
            DebugRoute(path: "/open", help: "url=<url> [new=1]: load in the active tab or a new one") { q, _ in
                guard let s = q["url"] else { return "missing url" }
                if q["new"] != nil { store.newTab(url: URL(string: s)) } else { store.open(s) }
                return "ok"
            },
            DebugRoute(path: "/state", help: "tabs, filter status and rule count as JSON") { _, _ in
                jsonString(["tabs": store.extTabs.map(\.json), "ubo": ContentBlocker.shared.status, "rules": ContentBlocker.shared.activeRuleCount,
                            "protections": store.active?.protections.names ?? []])
            },
            DebugRoute(path: "/eval", help: "world=page|ubo|winbrowse|ext:<id>|bg:<id>, body = script; returns JSON") { q, body in
                await Self.eval(body, world: q["world"] ?? "page")
            },
            DebugRoute(path: "/wait", help: "js=<expression> [timeout=<seconds>]: wait until it is true in the page") { q, _ in
                guard let js = q["js"] else { return "missing js" }
                let deadline = Date().addingTimeInterval(Double(q["timeout"] ?? "") ?? 10)
                while Date() < deadline {
                    if await Self.eval("return Boolean(\(js))", world: "page") == "true" { return "ok" }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                return "timeout"
            },
            DebugRoute(path: "/protections", help: "site=<host> [set=network,cosmetic,...]: read or set the protections that are on") { q, _ in
                guard let site = q["site"] else { return "missing site" }
                if let set = q["set"] {
                    let on = Protections(names: set.split(separator: ",").map(String.init))
                    for (p, _) in Protections.names { SiteSettings.shared.set(p, on: on.contains(p), for: site) }
                    if let t = store.active { t.rebuildWebView(loading: t.url) }
                }
                return jsonString(SiteSettings.shared.protections(for: site).names)
            },
            DebugRoute(path: "/rulesets", help: "[set=id,id,...]: read or set the enabled filter lists, recompiling them") { q, _ in
                if let set = q["set"] {
                    ContentBlocker.shared.enabledIds = Set(set.split(separator: ",").map(String.init))
                    await AppBoot.reloadBlocking()
                    store.recycleWebViews()
                }
                let report = ContentBlocker.shared.report.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                return jsonString(["enabled": ContentBlocker.shared.enabledIds.sorted(), "all": ContentBlocker.shared.rulesets.map(\.id), "report": report ?? NSNull()])
            },
            DebugRoute(path: "/errors", help: "page errors recorded in the active tab") { _, _ in
                guard let w = store.active?.webView, let d = try? JSONEncoder().encode(PageErrors.shared.entries(for: w)) else { return "[]" }
                return String(decoding: d, as: UTF8.self)
            },
            DebugRoute(path: "/report", help: "the breakage report for the active tab") { _, _ in
                guard let t = store.active, let d = try? BreakageReporter.report(for: t).json() else { return "no tab" }
                return String(decoding: d, as: UTF8.self)
            },
            DebugRoute(path: "/focus", help: "focus the address field") { _, _ in
                NotificationCenter.default.post(name: .init("debug.focusAddress"), object: nil)
                return "ok"
            },
            DebugRoute(path: "/field", help: "[press=address.cut|address.paste] [type=<text>]: read or drive the address field") { q, _ in
                guard let f = DebugUI.findAddressField() else { return "no field" }
                if let id = q["press"], let b = DebugUI.find(UIButton.self, id: id, in: f.rightView) { b.sendActions(for: .primaryActionTriggered) }
                if let t = q["type"] { f.insertText(t) }
                let sel = f.selectedTextRange.flatMap { f.text(in: $0) } ?? ""
                return jsonString(["text": f.text ?? "", "selected": sel, "editing": f.isFirstResponder, "rightView": f.rightView.map { "\($0.frame)" } ?? "none"])
            },
            DebugRoute(path: "/menu", help: "toggle the app menu") { _, _ in
                Router.shared.toggleMenu()
                return "ok"
            },
            DebugRoute(path: "/route", help: "r=tabs|settings|extensions|ublock|history|passkeys, or nothing to go back to the browser") { q, _ in
                if let page = pages[q["r"] ?? ""] { Router.shared.push(page) } else { Router.shared.popToRoot(); store.presentedExtensionPage = nil }
                return "ok"
            },
            DebugRoute(path: "/popup", help: "ext=<id> [page=<path>]: open an extension's popup or options page") { q, _ in
                guard let e = ExtensionHost.shared.ext(q["ext"] ?? ""), let p = q["page"] ?? e.popup ?? e.options else { return "no such extension page" }
                store.extPresent(ext: e, page: p)
                return "ok"
            },
            DebugRoute(path: "/ext", help: "id=<id> on=0|1: turn an extension off or on") { q, _ in
                guard let id = q["id"] else { return "missing id" }
                ExtensionHost.shared.setEnabled(id, q["on"] == "1")
                WebViewFactory.shared.rebuildScripts()
                store.active?.webView?.reload()
                return "ok"
            },
            DebugRoute(path: "/passkeys", help: "[auto=0|1] [delete=<credential id>] [clear=1]: test hooks; lists saved passkeys without key material") { q, _ in
                let pk = Passkeys.shared
                if let a = q["auto"] { pk.autoApprove = a == "1" }
                if q["clear"] == "1" { for c in pk.credentials { pk.delete(c) } }
                if let id = q["delete"], let c = pk.credentials.first(where: { $0.id == id }) { pk.delete(c) }
                return jsonString(pk.credentials.map {
                    ["id": $0.id, "rpId": $0.rpId, "userHandle": $0.userHandle, "user": $0.userName, "created": $0.created.timeIntervalSince1970] as [String: Any]
                })
            },
            DebugRoute(path: "/select", help: "i=<index>: switch to a tab") { q, _ in
                guard let i = Int(q["i"] ?? ""), store.tabs.indices.contains(i) else { return "no such tab" }
                store.select(store.tabs[i])
                return "ok"
            },
        ]
    }

    private static func eval(_ body: String, world: String) async -> String {
        if world.hasPrefix("bg:") { return await ExtensionHost.shared.debugEvalBackground(String(world.dropFirst(3)), body) }
        guard let w = BrowserStore.shared.active?.webView else { return "no webview" }
        let cw: WKContentWorld
        switch world {
        case "page": cw = .page
        case "ubo": cw = UBOScripts.shared.world
        case "winbrowse": cw = AppScripts.world
        default:
            guard world.hasPrefix("ext:"), let e = ExtensionHost.shared.ext(String(world.dropFirst(4))) else { return "bad world" }
            cw = e.world
        }
        do {
            let r = try await w.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: cw)
            return r.map { jsonString(jsonSafe($0)) } ?? "undefined"
        } catch { return "error: \(error)" }
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
