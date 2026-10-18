import Foundation
import WebKit

/// uBlock Origin network filtering: uBO's compiled declarativeNetRequest rulesets → WebKit content rule lists.
@MainActor
final class ContentBlocker: ObservableObject {
    static let shared = ContentBlocker()

    struct Ruleset: Identifiable, Hashable {
        let id: String
        let name: String
        let group: String
        let defaultOn: Bool
        let networkRules: Int
        let cosmetic: Int
        let lang: String?
    }

    @Published private(set) var rulesets: [Ruleset] = []
    @Published private(set) var status = "idle"
    @Published private(set) var compiling = false
    @Published private(set) var activeRuleCount = 0
    @Published var enabledIds: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabledIds).sorted(), forKey: "ubo.rulesets") }
    }
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "ubo.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "ubo.enabled") }
    }

    /// Sites with uBO switched off (the big power button). Hostnames; subdomains inherit.
    @Published var disabledSites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ubo.disabledSites") ?? []) {
        didSet { UserDefaults.standard.set(Array(disabledSites).sorted(), forKey: "ubo.disabledSites") }
    }

    func isSiteDisabled(_ host: String?) -> Bool {
        guard enabled else { return true }
        guard var h = host?.lowercased(), !h.isEmpty else { return false }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        while true {
            if disabledSites.contains(h) { return true }
            guard let dot = h.firstIndex(of: ".") else { return false }
            h = String(h[h.index(after: dot)...])
        }
    }

    func setSite(_ host: String, disabled: Bool) {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        if disabled { disabledSites.insert(h) } else {
            disabledSites = disabledSites.filter { !(h == $0 || h.hasSuffix("." + $0)) }
        }
    }

    private(set) var lists: [WKContentRuleList] = []
    var root: URL { UBOAssets.root }

    private init() {
        enabledIds = Set(UserDefaults.standard.stringArray(forKey: "ubo.rulesets") ?? [])
        loadDetails()
        if UserDefaults.standard.stringArray(forKey: "ubo.rulesets") == nil {
            enabledIds = Set(rulesets.filter(\.defaultOn).map(\.id))
        }
    }

    var version: String { (try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?" }

    private func loadDetails() {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("rulesets/ruleset-details.json")),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        rulesets = arr.compactMap { r in
            guard let id = r["id"] as? String, id != "ubol-tests", id != "ublock-experimental" else { return nil }
            let rules = (r["rules"] as? [String: Any])?["total"] as? Int ?? 0
            let css = r["css"] as? [String: Any]
            let langs = (r["lang"] as? String)?.split(separator: " ").map(String.init) ?? []
            let regionalDefault = r["group"] as? String == "regions" && langs.contains(lang)
            return Ruleset(id: id, name: r["name"] as? String ?? id, group: r["group"] as? String ?? "other",
                           defaultOn: (r["enabled"] as? Bool ?? false) || id == "adguard-mobile" || regionalDefault,
                           networkRules: rules, cosmetic: (css?["generic"] as? Int ?? 0) + (css?["specific"] as? Int ?? 0),
                           lang: r["lang"] as? String)
        }
    }

    // MARK: - Compile

    /// Compiles (or loads cached) rule lists for the enabled rulesets. Calls back with the lists to install.
    func prepare() async -> [WKContentRuleList] {
        guard enabled else { lists = []; activeRuleCount = 0; return [] }
        let ids = enabledIds.sorted()
        let sig = "ubo-\(version)-\(Converter.revision)-" + ids.joined(separator: ",").djb2
        let store = WKContentRuleListStore.default()!
        // Cached?
        var cached: [WKContentRuleList] = []
        let count = UserDefaults.standard.integer(forKey: "ubo.compiled.\(sig)")
        if count > 0 {
            for i in 0..<count {
                if let l = try? await store.contentRuleList(forIdentifier: "\(sig)-\(i)") { cached.append(l) } else { break }
            }
            if cached.count == count {
                lists = cached
                activeRuleCount = UserDefaults.standard.integer(forKey: "ubo.compiledRules.\(sig)")
                status = "\(activeRuleCount.formatted()) network rules"
                return cached
            }
        }
        compiling = true
        status = "compiling filter lists…"
        let rootURL = root
        let (blocks, allows) = await Task.detached(priority: .userInitiated) { Converter.convert(root: rootURL, ids: ids) }.value
        var out: [WKContentRuleList] = []
        var total = 0
        // Allow rules only cancel blocks within the same list, so every chunk carries all of them.
        let per = max(10_000, Converter.maxRulesPerList - allows.count)
        var pending: [ArraySlice<[String: Any]>] = stride(from: 0, to: max(blocks.count, 1), by: per).map { blocks[$0..<min(blocks.count, $0 + per)] }
        var withAllows = true
        var n = 0
        while !pending.isEmpty {
            let slice = pending.removeFirst()
            let rules = Array(slice) + (withAllows ? allows : [])
            status = "compiling filter lists… \(total.formatted()) rules"
            let json = await Task.detached { Converter.json(rules) }.value
            do {
                if let l = try await store.compileContentRuleList(forIdentifier: "\(sig)-\(n)", encodedContentRuleList: json) {
                    out.append(l); total += rules.count; n += 1
                }
            } catch {
                // Older WebKit (iOS 17) can reject a rule the current one accepts: bisect and drop only the bad piece.
                NSLog("[ubo] chunk of \(slice.count) failed: \(error.localizedDescription)")
                if slice.count > 200 {
                    let mid = slice.startIndex + slice.count / 2
                    pending.insert(contentsOf: [slice[slice.startIndex..<mid], slice[mid..<slice.endIndex]], at: 0)
                } else if slice.count <= 1 && withAllows && out.isEmpty {
                    withAllows = false   // the allow rules themselves don't compile: carry on without them
                    pending = stride(from: 0, to: blocks.count, by: per).map { blocks[$0..<min(blocks.count, $0 + per)] }
                } else if slice.count > 1 {
                    pending.insert(contentsOf: slice.map { [$0][...] }, at: 0)
                }
            }
        }
        UserDefaults.standard.set(out.count, forKey: "ubo.compiled.\(sig)")
        UserDefaults.standard.set(total, forKey: "ubo.compiledRules.\(sig)")
        // Drop lists from older signatures.
        if let old = try? await store.availableIdentifiers() {
            for id in old where id.hasPrefix("ubo-") && !id.hasPrefix(sig) { try? await store.removeContentRuleList(forIdentifier: id) }
        }
        lists = out
        activeRuleCount = total
        compiling = false
        status = "\(total.formatted()) network rules"
        return out
    }
}

/// DNR JSON → WebKit content-blocker JSON.
enum Converter {
    static let revision = 4
    static let maxRulesPerList = 140_000

    static func json(_ rules: [[String: Any]]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: rules) else { return "[]" }
        return String(data: d, encoding: .utf8) ?? "[]"
    }

    static func convert(root: URL, ids: [String]) -> (blocks: [[String: Any]], allows: [[String: Any]]) {
        var blocks: [[String: Any]] = []
        var allows: [[String: Any]] = []
        for id in ids {
            let u = root.appendingPathComponent("rulesets/main/\(id).json")
            guard let d = try? Data(contentsOf: u), let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { continue }
            for r in arr {
                for w in rules(from: r) {
                    if (w["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" { allows.append(w) } else { blocks.append(w) }
                }
            }
        }
        return (blocks, allows)
    }

    private static let typeMap: [String: String] = [
        "stylesheet": "style-sheet", "script": "script", "image": "image", "font": "font", "media": "media",
        "xmlhttprequest": "raw", "websocket": "raw", "other": "raw", "object": "raw", "csp_report": "raw",
        "webtransport": "raw", "webbundle": "raw", "ping": "ping",
    ]
    /// Everything except documents, as DNR's default (no main_frame) best maps onto WebKit.
    private static let subresourceTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping"]

    static func rules(from r: [String: Any]) -> [[String: Any]] {
        guard let action = r["action"] as? [String: Any], let type = action["type"] as? String,
              let c = r["condition"] as? [String: Any] else { return [] }
        // Things WebKit can't express.
        if c["regexFilter"] != nil || c["requestMethods"] != nil || c["excludedRequestMethods"] != nil
            || c["tabIds"] != nil || c["responseHeaders"] != nil || c["excludedResponseHeaders"] != nil { return [] }

        var wkAction: [String: Any]
        switch type {
        case "block": wkAction = ["type": "block"]
        case "allow": wkAction = ["type": "ignore-previous-rules"]
        case "upgradeScheme": wkAction = ["type": "make-https"]
        case "redirect":
            // Redirects to neutered scripts/frames can't be done; blocking a script uBO meant to replace breaks pages, so skip those.
            let rt = c["resourceTypes"] as? [String] ?? []
            if rt.isEmpty || rt.contains(where: { ["script", "sub_frame", "main_frame"].contains($0) }) { return [] }
            if (action["redirect"] as? [String: Any])?["transform"] != nil { return [] }
            wkAction = ["type": "block"]
        case "allowAllRequests":
            guard let f = c["urlFilter"] as? String, let re = urlFilterRegex(f) else { return [] }
            let rt = c["resourceTypes"] as? [String] ?? []
            guard rt.contains("main_frame") else { return [] }
            return [["trigger": ["url-filter": ".*", "if-top-url": [re]], "action": ["type": "ignore-previous-rules"]]]
        default: return []
        }

        // URL patterns.
        var filters: [String] = []
        if let f = c["urlFilter"] as? String {
            guard let re = urlFilterRegex(f) else { return [] }
            filters = [re]
        } else if let rd = c["requestDomains"] as? [String] {
            filters = rd.compactMap { urlFilterRegex("||\($0)^") }
        } else {
            filters = [".*"]
        }
        if filters.isEmpty { return [] }
        let pureHost = (c["urlFilter"] as? String).map(isPureHostFilter) ?? (c["requestDomains"] != nil)

        var trigger: [String: Any] = [:]
        if c["isUrlFilterCaseSensitive"] as? Bool == true { trigger["url-filter-is-case-sensitive"] = true }
        if let dt = c["domainType"] as? String { trigger["load-type"] = [dt == "firstParty" ? "first-party" : "third-party"] }
        if let inc = c["initiatorDomains"] as? [String] {
            let d = inc.compactMap(wkDomain)
            if d.isEmpty { return [] }
            trigger["if-domain"] = d
        } else if let exc = c["excludedInitiatorDomains"] as? [String] {
            let d = exc.compactMap(wkDomain)
            if !d.isEmpty { trigger["unless-domain"] = d }
        }

        // Resource types (may split into a subresource rule + a frame rule).
        var variants: [[String: Any]] = []
        if let rt = c["resourceTypes"] as? [String] {
            let sub = Array(Set(rt.compactMap { typeMap[$0] })).sorted()
            let main = rt.contains("main_frame"), frame = rt.contains("sub_frame")
            if !sub.isEmpty { variants.append(["resource-type": sub]) }
            if main && frame { variants.append(["resource-type": ["document"]]) }
            else if frame { variants.append(["resource-type": ["document"], "load-context": ["child-frame"]]) }
            else if main { variants.append(["resource-type": ["document"], "load-context": ["top-frame"]]) }
        } else if let ex = c["excludedResourceTypes"] as? [String] {
            let exSet = Set(ex.compactMap { typeMap[$0] })
            var sub = subresourceTypes.filter { !exSet.contains($0) }
            if ex.contains("image") { sub.removeAll { $0 == "svg-document" } }
            if !sub.isEmpty { variants.append(["resource-type": sub]) }
            if !ex.contains("sub_frame") { variants.append(["resource-type": ["document"], "load-context": ["child-frame"]]) }
        } else if pureHost || type != "block" {
            // ||host^ filters also block frames and top-level navigation (uBO's strict blocking).
            variants.append([:])
        } else {
            variants.append(["resource-type": subresourceTypes])
        }

        var out: [[String: Any]] = []
        for f in filters {
            for v in variants {
                var t = trigger
                t["url-filter"] = f
                for (k, val) in v { t[k] = val }
                out.append(["trigger": t, "action": wkAction])
            }
        }
        // denyallow=: cancel the block for the excluded request domains.
        if type == "block", let ex = c["excludedRequestDomains"] as? [String] {
            for d in ex {
                guard let re = urlFilterRegex("||\(d)^") else { continue }
                var t = trigger
                t["url-filter"] = re
                out.append(["trigger": t, "action": ["type": "ignore-previous-rules"]])
            }
        }
        return out
    }

    static func isPureHostFilter(_ f: String) -> Bool {
        guard f.hasPrefix("||"), f.hasSuffix("^") else { return false }
        return f.dropFirst(2).dropLast().allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    private static func wkDomain(_ d: String) -> String? {
        guard d.allSatisfy({ $0.isASCII }), !d.contains("*") else { return nil }
        return "*" + d.lowercased()
    }

    /// DNR urlFilter syntax (||, |, ^, *) → a WebKit-compatible regex.
    static func urlFilterRegex(_ filter: String) -> String? {
        var f = Substring(filter)
        guard f.allSatisfy({ $0.isASCII }) else { return nil }
        var out = ""
        if f.hasPrefix("||") { out = "^[a-z][a-z0-9.+-]*://([^/:?#]*\\.)?"; f = f.dropFirst(2) }
        else if f.hasPrefix("|") { out = "^"; f = f.dropFirst() }
        var endAnchor = false
        if f.hasSuffix("|") { endAnchor = true; f = f.dropLast() }
        let chars = Array(f)
        for (i, ch) in chars.enumerated() {
            switch ch {
            case "*":
                if !out.hasSuffix(".*") { out += ".*" }
            case "^":
                if i == chars.count - 1 { out += endAnchor ? "([^a-zA-Z0-9_.%-])?" : "([^a-zA-Z0-9_.%-].*)?$" }
                else { out += "[^a-zA-Z0-9_.%-]" }
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$", "|":
                out += "\\" + String(ch)
            default:
                out.append(ch)
            }
        }
        if endAnchor { out += "$" }
        if out.isEmpty { return ".*" }
        // Trailing $ added by a final ^; don't double it.
        if out.hasSuffix("$$") { out.removeLast() }
        return out
    }
}

extension String {
    var djb2: String {
        var h: UInt64 = 5381
        for b in utf8 { h = (h &* 33) ^ UInt64(b) }
        return String(h, radix: 36)
    }
}
