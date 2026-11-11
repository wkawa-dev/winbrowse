import Foundation

enum FetchPolicy {
    static func cookies(_ all: [HTTPCookie], for url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        return all.filter { c in
            let domain = c.domain.lowercased()
            let hostMatches = domain.hasPrefix(".") ? host == String(domain.dropFirst()) || host.hasSuffix(domain) : host == domain
            return hostMatches && url.path.hasPrefix(c.path) && (!c.isSecure || url.scheme == "https") && (c.expiresDate.map { $0 > now } ?? true)
        }
    }

    static func exposedHeaders(_ response: HTTPURLResponse?) -> [String: String] {
        var headers: [String: String] = [:]
        for (k, v) in response?.allHeaderFields ?? [:] {
            let name = String(describing: k).lowercased()
            if name != "set-cookie" && name != "set-cookie2" { headers[name] = String(describing: v) }
        }
        return headers
    }

    static func follow(_ request: URLRequest, from origin: URL, allowed: (URL) -> Bool) -> URLRequest? {
        guard let url = request.url, allowed(url) else { return nil }
        var next = request
        if url.host?.lowercased() != origin.host?.lowercased() { next.setValue(nil, forHTTPHeaderField: "Cookie") }
        return next
    }
}
