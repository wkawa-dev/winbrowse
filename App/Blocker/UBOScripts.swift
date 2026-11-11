import Foundation
import WebKit

enum UBOAssets {
    static var root: URL { Bundle.main.url(forResource: "Extensions-bundle", withExtension: nil)!.appendingPathComponent("ubo") }
    static func text(_ rel: String) -> String { (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
    static func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }
}

@MainActor
final class UBOScripts: NSObject {
    static let shared = UBOScripts()
    let world = WKContentWorld.world(name: "ubo")

    private struct Specific {
        var selectors: [String]
        var selectorLists: [[Int]]
        var byHost: [String: Int]
        var regexes: [(String, NSRegularExpression, Int)]
    }
    private var specific: [String: Specific] = [:]

    func install(into ucc: WKUserContentController, rulesets ids: [String], parts: Protections) {
        ucc.removeScriptMessageHandler(forName: "ubo", contentWorld: world)
        if parts.contains(.scriptlets) { installScriptlets(into: ucc, rulesets: ids) }
        if parts.contains(.cosmetic) {
            ucc.addScriptMessageHandler(self, contentWorld: world, name: "ubo")
            installCosmetic(into: ucc, rulesets: ids)
        }
    }

    private let guardHTTP = "if(location.protocol==='http:'||location.protocol==='https:'||location.protocol==='about:'||location.protocol==='blob:')"

    private func installScriptlets(into ucc: WKUserContentController, rulesets ids: [String]) {
        let scriptletDetails = Self.scriptletWorlds()
        for world in ["main", "isolated"] {
            let files = ids.filter { scriptletDetails[$0]?.contains(world.uppercased()) == true }
                .map { "rulesets/scripting/scriptlet/\(world)/\($0).js" }
                .filter(UBOAssets.exists)
            guard !files.isEmpty else { continue }
            let src = (["rulesets/scripting/scriptlet/\(world)/scriptlet-begin.js"] + files + ["rulesets/scripting/scriptlet/\(world)/scriptlet-end.js"])
                .map(UBOAssets.text).joined(separator: "\n;\n")
            ucc.addUserScript(WKUserScript(source: "\(guardHTTP){\n\(src)\n}", injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                           in: world == "main" ? .page : self.world))
        }
    }

    private func installCosmetic(into ucc: WKUserContentController, rulesets ids: [String]) {
        let api = ["js/css-api.js", "js/isolated-api.js", "js/css-procedural-api.js"].map(UBOAssets.text).joined(separator: "\n;\n")
        let specificLoader = """
        (async function(){
          const ctx = self.isolatedAPI.contexts;
          const r = await window.webkit.messageHandlers.ubo.postMessage({type:'specific', hostnames: ctx.hostnames, entities: ctx.entities, hostname: location.hostname||''});
          if (!r) return;
          const {s, p} = JSON.parse(r);
          if (s.length) self.cssAPI.insert(`${s.join(',\\n')}{display:none!important;}`);
          if (!p.length) return;
          self.listsProceduralFiltererAPI = new self.ProceduralFiltererAPI();
          const d = p.filter(a => a.cssable), q = p.filter(a => !a.cssable);
          if (d.length) self.listsProceduralFiltererAPI.addDeclaratives(d);
          if (q.length) self.listsProceduralFiltererAPI.addProcedurals(q);
        })();
        """
        ucc.addUserScript(WKUserScript(source: "\(guardHTTP){\n\(Self.cssShim)\n\(api)\n\(specificLoader)\n}", injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false, in: world))

        let genericFiles = ids.map { "rulesets/scripting/generic/\($0).js" }.filter(UBOAssets.exists)
        if !genericFiles.isEmpty {
            let unhide = Self.genericUnhide(ids)
            let src = (genericFiles + ["js/css-generic.js"]).map(UBOAssets.text).joined(separator: "\n;\n")
            let skip = "const __h=location.hostname;const __u=new Set(\(jsonString(unhide)));let __skip=false;for(let h=__h;h;){if(__u.has(h)){__skip=true;break}const i=h.indexOf('.');if(i<0)break;h=h.slice(i+1)}"
            ucc.addUserScript(WKUserScript(source: "\(guardHTTP){\(skip)\nif(!__skip){\n\(src)\n}}", injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: false, in: world))
        }
    }

    private static var cssShim: String {
        """
        if (!self.chrome || !self.chrome.runtime) {
          const styles = [];
          let sheet = null;
          const flush = () => { const css = styles.join('\\n'); if (sheet) sheet.set(css); else sheet = (\(AppScripts.bundled("isolated-style")))(css); };
          self.chrome = { runtime: { sendMessage: async (m) => {
            if (m.what === 'insertCSS') { if (m.css && !styles.includes(m.css)) { styles.push(m.css); flush(); } }
            else if (m.what === 'removeCSS') { const i = styles.indexOf(m.css); if (i >= 0) { styles.splice(i, 1); flush(); } }
          } }, storage: { session: { get: async () => ({}), set: async () => {} }, local: { get: async () => ({}) } } };
        }
        """
    }

    private static func scriptletWorlds() -> [String: Set<String>] {
        guard let d = try? Data(contentsOf: UBOAssets.root.appendingPathComponent("rulesets/scriptlet-details.json")),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[Any]] else { return [:] }
        var out: [String: Set<String>] = [:]
        for e in arr where e.count == 2 {
            if let id = e[0] as? String, let w = e[1] as? [String: Any] { out[id] = Set(w.keys) }
        }
        return out
    }

    private static func genericUnhide(_ ids: [String]) -> [String] {
        guard let d = try? Data(contentsOf: UBOAssets.root.appendingPathComponent("rulesets/generic-details.json")),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[Any]] else { return [] }
        var out: [String] = []
        for e in arr where e.count == 2 {
            guard let id = e[0] as? String, ids.contains(id), let det = e[1] as? [String: Any] else { continue }
            out += det["unhide"] as? [String] ?? []
        }
        return out
    }

    private func loadSpecific(_ id: String) -> Specific? {
        if let s = specific[id] { return s }
        guard let d = try? Data(contentsOf: UBOAssets.root.appendingPathComponent("rulesets/scripting/specific/\(id).json")),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let selectors = j["selectors"] as? [String] ?? []
        let lists = (j["selectorLists"] as? [String] ?? []).map { $0.split(separator: ",").compactMap { Int($0) } }
        let refs = j["selectorListRefs"] as? [Int] ?? []
        let hosts = j["hostnames"] as? [String] ?? []
        var byHost: [String: Int] = [:]
        for (i, h) in hosts.enumerated() where i < refs.count { byHost[h] = refs[i] }
        var regexes: [(String, NSRegularExpression, Int)] = []
        let rx = j["regexes"] as? [Any] ?? []
        var i = 0
        while i + 2 < rx.count {
            if let sub = rx[i] as? String, let pat = rx[i + 1] as? String, let idx = rx[i + 2] as? Int,
               let re = try? NSRegularExpression(pattern: pat) { regexes.append((sub, re, idx)) }
            i += 3
        }
        let s = Specific(selectors: selectors, selectorLists: lists, byHost: byHost, regexes: regexes)
        specific[id] = s
        return s
    }

    func specificSelectors(hostnames: [String], entities: [String], hostname: String) -> (s: [String], p: [Any]) {
        var sel = Set<String>(), exc = Set<String>()
        for id in ContentBlocker.shared.enabledIds.sorted() {
            guard let sp = loadSpecific(id) else { continue }
            func addList(_ li: Int) {
                guard li >= 0, li < sp.selectorLists.count else { return }
                for v in sp.selectorLists[li] {
                    if v >= 0 { if v < sp.selectors.count { sel.insert(sp.selectors[v]) } }
                    else { let k = ~v; if k < sp.selectors.count { exc.insert(sp.selectors[k]) } }
                }
            }
            for h in hostnames + entities { if let li = sp.byHost[h] { addList(li) } }
            for (sub, re, li) in sp.regexes where hostname.contains(sub) {
                if re.firstMatch(in: hostname, range: NSRange(hostname.startIndex..., in: hostname)) != nil { addList(li) }
            }
        }
        sel.subtract(exc)
        var plain: [String] = [], proc: [Any] = []
        for s in sel {
            if s.hasPrefix("{"), let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) { proc.append(o) } else { plain.append(s) }
        }
        return (plain, proc)
    }
}

extension UBOScripts: WKScriptMessageHandlerWithReply {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let b = message.body as? [String: Any], b["type"] as? String == "specific" else { return replyHandler(nil, nil) }
        let r = specificSelectors(hostnames: b["hostnames"] as? [String] ?? [], entities: b["entities"] as? [String] ?? [],
                                  hostname: b["hostname"] as? String ?? "")
        replyHandler(jsonString(["s": r.s, "p": r.p]), nil)
    }
}
