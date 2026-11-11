import CryptoKit
import Foundation
import WebKit

extension ExtensionHost {
    func digest(_ data: [String: Any]) -> String? {
        guard let b64 = data["data"] as? String, let d = Data(base64Encoded: b64) else { return nil }
        let out: Data
        switch data["alg"] as? String ?? "SHA-256" {
        case "SHA-1": out = Data(Insecure.SHA1.hash(data: d))
        case "SHA-384": out = Data(SHA384.hash(data: d))
        case "SHA-512": out = Data(SHA512.hash(data: d))
        default: out = Data(SHA256.hash(data: d))
        }
        return jsonString(out.base64EncodedString())
    }
}

enum NativeFetch {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpCookieStorage = nil
        c.requestCachePolicy = .useProtocolCachePolicy
        c.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 0)
        return URLSession(configuration: c)
    }()

    @MainActor
    static func perform(_ d: [String: Any], userAgent: String, ext: WebExtension?) async -> String {
        guard let s = d["url"] as? String, let url = URL(string: s) else { return jsonString(["error": "bad url"]) }
        guard let ext, ext.canAccess(url) else { return jsonString(["error": "host not permitted by extension host_permissions"]) }
        var req = URLRequest(url: url)
        req.httpMethod = d["method"] as? String ?? "GET"
        for (k, v) in d["headers"] as? [String: String] ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil, !userAgent.isEmpty { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let b = d["body"] as? String, let body = Data(base64Encoded: b) { req.httpBody = body }
        if (d["credentials"] as? String) == "include" {
            let matching = await FetchPolicy.cookies(WKWebsiteDataStore.default().httpCookieStore.allCookies(), for: url)
            if let header = HTTPCookie.requestHeaderFields(with: matching)["Cookie"], !header.isEmpty {
                let existing = req.value(forHTTPHeaderField: "Cookie") ?? ""
                req.setValue(existing.isEmpty ? header : existing + "; " + header, forHTTPHeaderField: "Cookie")
            }
        }
        do {
            let (data, resp) = try await session.data(for: req, delegate: RedirectGuard(ext: ext, origin: url))
            let http = resp as? HTTPURLResponse
            return jsonString(["status": http?.statusCode ?? 200,
                               "statusText": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 200),
                               "headers": FetchPolicy.exposedHeaders(http), "url": resp.url?.absoluteString ?? s,
                               "redirected": resp.url != url, "body": data.base64EncodedString()])
        } catch {
            return jsonString(["error": error.localizedDescription])
        }
    }
}

final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    let ext: WebExtension
    let origin: URL

    init(ext: WebExtension, origin: URL) {
        self.ext = ext
        self.origin = origin
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(FetchPolicy.follow(request, from: origin, allowed: ext.canAccess))
    }
}
