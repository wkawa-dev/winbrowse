import Foundation

enum MatchPattern {
    static func regex(_ pattern: String) -> String {
        if pattern == "<all_urls>" { return "^(https?|wss?|file|ftp)://" }
        guard let r = pattern.range(of: "://") else { return "^$" }
        let scheme = String(pattern[..<r.lowerBound])
        let rest = pattern[r.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let host = String(rest[..<slash])
        let path = String(rest[slash...])
        var s = "^"
        s += scheme == "*" ? "https?" : esc(scheme)
        s += "://"
        if host == "*" { s += "[^/]*" }
        else if host.hasPrefix("*.") { s += "([^/]*\\.)?" + esc(String(host.dropFirst(2))) + "(:[0-9]+)?" }
        else { s += esc(host) + "(:[0-9]+)?" }
        s += path.isEmpty ? "/.*" : path.split(separator: "*", omittingEmptySubsequences: false)
            .map { esc(String($0)) }.joined(separator: ".*")
        return s + "$"
    }

    static func matches(_ pattern: String, _ url: URL) -> Bool {
        url.absoluteString.range(of: regex(pattern), options: .regularExpression) != nil
    }

    static func permits(_ hostPermissions: [String], _ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return hostPermissions.contains { matches($0, url) }
    }

    static func jsGuard(_ matches: [String], exclude: [String] = []) -> String {
        func arr(_ ps: [String]) -> String {
            "[" + ps.map { "/" + regex($0).replacingOccurrences(of: "/", with: "\\/") + "/" }.joined(separator: ",") + "]"
        }
        let inc = "\(arr(matches)).some(r=>r.test(location.href))"
        if exclude.isEmpty { return "(\(inc))" }
        return "(\(inc)&&!\(arr(exclude)).some(r=>r.test(location.href)))"
    }

    private static func esc(_ s: String) -> String {
        var o = ""
        for c in s { if "\\^$.|?*+()[]{}".contains(c) { o.append("\\") }; o.append(c) }
        return o
    }
}
