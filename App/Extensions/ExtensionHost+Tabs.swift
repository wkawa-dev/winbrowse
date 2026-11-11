import Foundation
import WebKit

extension ExtensionHost {
    func tabsMessage(_ kind: ExtensionMessage, ext id: String, from ep: Endpoint, data: [String: Any]) -> String? {
        let activeId = tabs?.extTabs.first(where: \.active)?.id ?? -1
        switch kind {
        case .tabsQuery:
            return jsonString(queryTabs(data).map(\.json))
        case .tabsGet:
            guard let tid = data["tabId"] as? Int else { return nil }
            return tabJSON(tid)
        case .tabsCreate:
            let url = (data["url"] as? String).flatMap { resolve($0, ext: id) } ?? URL(string: "about:blank")!
            return tabJSON(tabs?.extCreateTab(url: url, active: data["active"] as? Bool ?? true) ?? -1)
        case .tabsUpdate:
            let props = data["props"] as? [String: Any] ?? [:]
            let tid = data["tabId"] as? Int ?? activeId
            tabs?.extUpdateTab(tabId: tid, url: (props["url"] as? String).flatMap { resolve($0, ext: id) }, active: props["active"] as? Bool)
            return tabJSON(tid)
        case .tabsRemove:
            for t in data["ids"] as? [Int] ?? [] { tabs?.extRemoveTab(tabId: t) }
            return nil
        default:
            tabs?.extReloadTab(tabId: data["tabId"] as? Int ?? activeId)
            return nil
        }
    }

    func executeScript(ext id: String, data: [String: Any], from ep: Endpoint) async -> String? {
        guard let e = ext(id), let w = targetWebView(data["tabId"] as? Int, from: ep) else { return "[]" }
        let main = (data["world"] as? String) == "MAIN"
        let world: WKContentWorld = main ? .page : e.world
        if !main {
            _ = try? await w.evaluateJavaScript(shimInstall(e, ctx: "content") + ";0", in: nil, contentWorld: world)
        }
        var code = (data["files"] as? [String] ?? []).map { e.file($0) }.joined(separator: "\n;\n")
        if let c = data["code"] as? String { code += "\n;" + c }
        do {
            let result = try await w.evaluateJavaScript(code, in: nil, contentWorld: world)
            return jsonString([["frameId": 0, "result": result.map(jsonSafe) ?? NSNull()]])
        } catch {
            log.error("\(id, privacy: .public) executeScript failed: \(error.localizedDescription, privacy: .public)")
            return jsonString(["__error": error.localizedDescription])
        }
    }

    func insertCSS(ext id: String, data: [String: Any], from ep: Endpoint) async -> String? {
        guard let e = ext(id), let w = targetWebView(data["tabId"] as? Int, from: ep) else { return nil }
        var css = (data["files"] as? [String] ?? []).map { e.file($0) }.joined(separator: "\n")
        if let c = data["css"] as? String { css += "\n" + c }
        do {
            _ = try await w.evaluateJavaScript("(\(AppScripts.bundled("isolated-style")))(\(jsString(css)));0", in: nil, contentWorld: e.world)
            return nil
        } catch {
            return jsonString(["__error": error.localizedDescription])
        }
    }

    func present(_ kind: ExtensionMessage, ext id: String) -> String? {
        guard let e = ext(id), let page = kind == .actionOpenPopup ? e.popup : e.options else { return nil }
        tabs?.extPresent(ext: e, page: page)
        return nil
    }

    private func tabJSON(_ tid: Int) -> String? {
        tabs?.extTabs.first { $0.id == tid }.map { jsonString($0.json) }
    }

    private func queryTabs(_ q: [String: Any]) -> [ExtTabInfo] {
        var list = tabs?.extTabs ?? []
        if let a = q["active"] as? Bool { list = list.filter { $0.active == a } }
        if let urls = q["url"] {
            let patterns = (urls as? [String]) ?? [(urls as? String) ?? ""]
            list = list.filter { t in URL(string: t.url).map { u in patterns.contains { MatchPattern.matches($0, u) } } ?? false }
        }
        if let s = q["status"] as? String { list = list.filter { ($0.loading ? "loading" : "complete") == s } }
        if let a = q["audible"] as? Bool { list = list.filter { $0.audible == a } }
        return list
    }

    private func targetWebView(_ tabId: Int?, from ep: Endpoint) -> WKWebView? {
        if let tabId { return tabs?.extWebView(tabId: tabId) }
        if case .content(let w, _, _, _) = ep { return w }
        guard let active = tabs?.extTabs.first(where: \.active) else { return nil }
        return tabs?.extWebView(tabId: active.id)
    }

    private func resolve(_ s: String, ext id: String) -> URL? {
        if s.contains("://") || s.hasPrefix("about:") { return URL(string: s) }
        return URL(string: "winext://\(id)/" + s.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
