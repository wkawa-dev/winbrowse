import Foundation

enum RuleConverter {
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
    private static let subresourceTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping"]

    static func rules(from r: [String: Any]) -> [[String: Any]] {
        guard let action = r["action"] as? [String: Any], let type = action["type"] as? String,
              let c = r["condition"] as? [String: Any] else { return [] }
        if c["regexFilter"] != nil || c["requestMethods"] != nil || c["excludedRequestMethods"] != nil
            || c["tabIds"] != nil || c["responseHeaders"] != nil || c["excludedResponseHeaders"] != nil { return [] }

        var wkAction: [String: Any]
        switch type {
        case "block": wkAction = ["type": "block"]
        case "allow": wkAction = ["type": "ignore-previous-rules"]
        case "upgradeScheme": wkAction = ["type": "make-https"]
        case "redirect":
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
