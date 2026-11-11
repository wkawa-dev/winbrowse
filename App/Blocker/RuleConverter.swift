import Foundation

struct CompileReport: Codable, Equatable {
    var converted = 0
    var dropped: [String: Int] = [:]
    var rejected = 0
    var rejectedExceptions = 0
    var firstRejection: String?
    var lists = 0

    var droppedTotal: Int { dropped.values.reduce(0, +) }
}

enum RuleConverter {
    static let revision = 5
    static let maxRulesPerList = 140_000

    static func json(_ rules: [[String: Any]]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: rules) else { return "[]" }
        return String(data: d, encoding: .utf8) ?? "[]"
    }

    struct Conversion {
        var blocks: [[String: Any]] = []
        var allows: [[String: Any]] = []
        var dropped: [String: Int] = [:]
    }

    enum Translation {
        case rules([[String: Any]])
        case dropped(String)
    }

    static func convert(root: URL, ids: [String]) -> Conversion {
        var out = Conversion()
        for id in ids {
            let u = root.appendingPathComponent("rulesets/main/\(id).json")
            guard let d = try? Data(contentsOf: u), let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { continue }
            for r in arr {
                switch translate(r) {
                case .dropped(let reason):
                    out.dropped[reason, default: 0] += 1
                case .rules(let rules):
                    for w in rules {
                        if (w["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" { out.allows.append(w) } else { out.blocks.append(w) }
                    }
                }
            }
        }
        return out
    }

    static func rules(from r: [String: Any]) -> [[String: Any]] {
        if case .rules(let rules) = translate(r) { return rules }
        return []
    }

    private static let typeMap: [String: String] = [
        "stylesheet": "style-sheet", "script": "script", "image": "image", "font": "font", "media": "media",
        "xmlhttprequest": "raw", "websocket": "raw", "other": "raw", "object": "raw", "csp_report": "raw",
        "webtransport": "raw", "webbundle": "raw", "ping": "ping",
    ]
    private static let subresourceTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping"]

    static func translate(_ r: [String: Any]) -> Translation {
        guard let action = r["action"] as? [String: Any], let type = action["type"] as? String,
              let c = r["condition"] as? [String: Any] else { return .dropped("malformed rule") }
        for key in ["regexFilter", "requestMethods", "excludedRequestMethods", "tabIds", "responseHeaders", "excludedResponseHeaders"] where c[key] != nil {
            return .dropped("\(key) condition")
        }

        let wkAction: [String: Any]
        switch type {
        case "block": wkAction = ["type": "block"]
        case "allow": wkAction = ["type": "ignore-previous-rules"]
        case "upgradeScheme": wkAction = ["type": "make-https"]
        case "redirect":
            let rt = c["resourceTypes"] as? [String] ?? []
            if rt.isEmpty || rt.contains(where: { ["script", "sub_frame", "main_frame"].contains($0) }) { return .dropped("script or frame redirect") }
            if (action["redirect"] as? [String: Any])?["transform"] != nil { return .dropped("URL transform") }
            wkAction = ["type": "block"]
        case "allowAllRequests":
            guard let f = c["urlFilter"] as? String, let re = urlFilterRegex(f) else { return .dropped("allowAllRequests without a usable urlFilter") }
            guard (c["resourceTypes"] as? [String] ?? []).contains("main_frame") else { return .dropped("allowAllRequests for frames only") }
            return .rules([["trigger": ["url-filter": ".*", "if-top-url": [re]], "action": ["type": "ignore-previous-rules"]]])
        default:
            return .dropped("\(type) action")
        }

        let filters: [String]
        if let f = c["urlFilter"] as? String {
            guard let re = urlFilterRegex(f) else { return .dropped("non-ASCII urlFilter") }
            filters = [re]
        } else if let rd = c["requestDomains"] as? [String] {
            filters = rd.compactMap { urlFilterRegex("||\($0)^") }
        } else {
            filters = [".*"]
        }
        if filters.isEmpty { return .dropped("non-ASCII requestDomains") }
        let pureHost = (c["urlFilter"] as? String).map(isPureHostFilter) ?? (c["requestDomains"] != nil)

        var trigger: [String: Any] = [:]
        if c["isUrlFilterCaseSensitive"] as? Bool == true { trigger["url-filter-is-case-sensitive"] = true }
        if let dt = c["domainType"] as? String { trigger["load-type"] = [dt == "firstParty" ? "first-party" : "third-party"] }
        if let inc = c["initiatorDomains"] as? [String] {
            let d = inc.compactMap(wkDomain)
            if d.isEmpty { return .dropped("wildcard or non-ASCII initiatorDomains") }
            trigger["if-domain"] = d
        } else if let exc = c["excludedInitiatorDomains"] as? [String] {
            let d = exc.compactMap(wkDomain)
            if !d.isEmpty { trigger["unless-domain"] = d }
        }

        let variants = resourceVariants(c, type: type, pureHost: pureHost)
        var out: [[String: Any]] = []
        for f in filters {
            for v in variants { out.append(["trigger": trigger.merging(v) { $1 }.merging(["url-filter": f]) { $1 }, "action": wkAction]) }
        }
        if type == "block", let excluded = c["excludedRequestDomains"] as? [String] {
            for d in excluded {
                guard let re = urlFilterRegex("||\(d)^") else { continue }
                for v in variants { out.append(["trigger": trigger.merging(v) { $1 }.merging(["url-filter": re]) { $1 }, "action": ["type": "ignore-previous-rules"]]) }
            }
        }
        return .rules(out)
    }

    private static func resourceVariants(_ c: [String: Any], type: String, pureHost: Bool) -> [[String: Any]] {
        if let rt = c["resourceTypes"] as? [String] {
            var variants: [[String: Any]] = []
            let sub = Array(Set(rt.compactMap { typeMap[$0] })).sorted()
            let main = rt.contains("main_frame"), frame = rt.contains("sub_frame")
            if !sub.isEmpty { variants.append(["resource-type": sub]) }
            if main && frame { variants.append(["resource-type": ["document"]]) }
            else if frame { variants.append(["resource-type": ["document"], "load-context": ["child-frame"]]) }
            else if main { variants.append(["resource-type": ["document"], "load-context": ["top-frame"]]) }
            return variants
        }
        if let ex = c["excludedResourceTypes"] as? [String] {
            var variants: [[String: Any]] = []
            let exSet = Set(ex.compactMap { typeMap[$0] })
            var sub = subresourceTypes.filter { !exSet.contains($0) }
            if ex.contains("image") { sub.removeAll { $0 == "svg-document" } }
            if !sub.isEmpty { variants.append(["resource-type": sub]) }
            if !ex.contains("sub_frame") { variants.append(["resource-type": ["document"], "load-context": ["child-frame"]]) }
            return variants
        }
        return pureHost || type != "block" ? [[:]] : [["resource-type": subresourceTypes]]
    }

    static func isPureHostFilter(_ f: String) -> Bool {
        guard f.hasPrefix("||"), f.hasSuffix("^") else { return false }
        return f.dropFirst(2).dropLast().allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    private static func wkDomain(_ d: String) -> String? {
        guard d.allSatisfy({ $0.isASCII }), !d.contains("*") else { return nil }
        return "*" + d.lowercased()
    }

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
        if out.hasSuffix("$$") { out.removeLast() }
        return out
    }
}

extension String {
    var djb2: String {
        var h: UInt64 = 5_381
        for b in utf8 { h = (h &* 33) ^ UInt64(b) }
        return String(h, radix: 36)
    }
}
