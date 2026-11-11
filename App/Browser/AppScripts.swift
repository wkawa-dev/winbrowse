import Foundation
import os
import WebKit

@MainActor
enum AppScripts {
    struct Modules: OptionSet, Hashable {
        let rawValue: Int
        static let media = Modules(rawValue: 1 << 0)
        static let passkeys = Modules(rawValue: 1 << 1)
        static let xfeed = Modules(rawValue: 1 << 2)
    }

    static let world = WKContentWorld.world(name: "winbrowse")
    static let channel = UUID().uuidString.lowercased()
    private static let log = ScriptLog()

    static func install(into ucc: WKUserContentController, modules: Modules) {
        ucc.removeScriptMessageHandler(forName: ScriptLog.name, contentWorld: world)
        ucc.add(log, contentWorld: world, name: ScriptLog.name)
        ucc.removeScriptMessageHandler(forName: PageErrors.name, contentWorld: world)
        ucc.add(PageErrors.shared, contentWorld: world, name: PageErrors.name)
        ucc.addUserScript(WKUserScript(source: pageSource(modules, channel: channel, load: bundled), injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false, in: .page))
        ucc.addUserScript(WKUserScript(source: isolatedSource(modules, channel: channel, load: bundled), injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false, in: world))
    }

    nonisolated static func pageSource(_ modules: Modules, channel: String, load: (String) -> String) -> String {
        let parts: [(Modules, String)] = [(.media, "page-media"), (.passkeys, "page-passkeys"), (.xfeed, "page-xfeed")]
        let calls = parts.filter { modules.contains($0.0) }.map { module, name in
            "try{(\(load(name)))(kit)}catch(e){kit.call(\(jsString(ScriptLog.name)),{module:\(jsString(name)),error:String(e&&e.stack||e)})}"
        }
        return "(function(){const kit=(\(load("page-kit")))(\(jsString(channel)));\n\(calls.joined(separator: "\n"))\n})();"
    }

    nonisolated static func isolatedSource(_ modules: Modules, channel: String, load: (String) -> String) -> String {
        var names = ["isolated-bridge", "isolated-errors"]
        if modules.contains(.media) { names.append("isolated-media") }
        let calls = names.map { name in
            "try{(\(load(name)))(c)}catch(e){window.webkit.messageHandlers[\(jsString(ScriptLog.name))].postMessage({module:\(jsString(name)),error:String(e&&e.stack||e)})}"
        }
        return "(function(){const c=\(jsString(channel));\n\(calls.joined(separator: "\n"))\n})();"
    }

    nonisolated static func bundled(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"), let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("missing bundled script \(name).js")
        }
        return text
    }
}

final class ScriptLog: NSObject, WKScriptMessageHandler {
    nonisolated static let name = "winlog"
    private let logger = Logger(subsystem: "dev.winbrowse.browser", category: "scripts")

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        let module = body["module"] as? String ?? "?"
        let error = body["error"] as? String ?? "\(message.body)"
        logger.error("\(module, privacy: .public) failed on \(message.frameInfo.securityOrigin.host, privacy: .public): \(error, privacy: .public)")
    }
}

@MainActor
final class PageErrors: NSObject, WKScriptMessageHandler {
    static let shared = PageErrors()
    nonisolated static let name = "winerror"
    static let limit = 50

    private var entries: [ObjectIdentifier: [PageError]] = [:]

    func entries(for webView: WKWebView) -> [PageError] { entries[ObjectIdentifier(webView)] ?? [] }

    func forget(_ webView: WKWebView) { entries[ObjectIdentifier(webView)] = nil }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let w = message.webView, let b = message.body as? [String: Any] else { return }
        let entry = PageError(kind: b["kind"] as? String ?? "error", message: String((b["message"] as? String ?? "").prefix(500)),
                              page: b["page"] as? String ?? "", source: b["source"] as? String ?? "", line: b["line"] as? Int ?? 0, date: Date())
        var list = entries[ObjectIdentifier(w)] ?? []
        list.append(entry)
        entries[ObjectIdentifier(w)] = Array(list.suffix(Self.limit))
    }
}
