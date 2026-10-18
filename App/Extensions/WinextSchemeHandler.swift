import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves bundled extension files at winext://<ext>/<path>, plus generated runtime files under /__winext/.
@MainActor
final class WinextSchemeHandler: NSObject, WKURLSchemeHandler {
    unowned let host: ExtensionHost
    init(host: ExtensionHost) { self.host = host }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let id = url.host, let e = host.ext(id) else {
            return fail(task, 404)
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let tabId = Int(query.first { $0.name == "__tab" }?.value ?? "") ?? -1

        if path == "__winext/background.html" {
            let tag = e.backgroundIsModule ? "<script type=\"module\"" : "<script"
            let scripts = e.backgroundScripts.map { "\(tag) src=\"/\($0.trimmingCharacters(in: CharacterSet(charactersIn: "./")))\"></script>" }.joined()
            let html = "<!doctype html><meta charset=\"utf-8\"><title>background</title><script src=\"/__winext/shim.js?ctx=background\"></script>\(scripts)"
            return respond(task, url, Data(html.utf8), "text/html")
        }
        if path == "__winext/shim.js" {
            let ctx = query.first { $0.name == "ctx" }?.value ?? "page"
            let t = Int(query.first { $0.name == "tab" }?.value ?? "") ?? -1
            return respond(task, url, Data(host.shimInstall(e, ctx: ctx, tabId: t).utf8), "text/javascript")
        }

        let file = e.dir.appendingPathComponent(path)
        guard file.standardizedFileURL.path.hasPrefix(e.dir.standardizedFileURL.path),
              var data = try? Data(contentsOf: file) else { return fail(task, 404) }
        let ext = file.pathExtension.lowercased()
        var mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        if ext == "js" || ext == "mjs" { mime = "text/javascript" }
        if ext == "html" || ext == "htm" {
            // Extension pages get chrome.* before any of their own scripts.
            var html = String(decoding: data, as: UTF8.self)
            let inject = "<script src=\"/__winext/shim.js?ctx=page&tab=\(tabId)\"></script>"
            if let r = html.range(of: "<head>", options: .caseInsensitive) { html.insert(contentsOf: inject, at: r.upperBound) }
            else if let r = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) { html.insert(contentsOf: inject, at: r.upperBound) }
            else { html = inject + html }
            // Pages are designed for a desktop popup; make them fit a phone.
            if !html.contains("name=\"viewport\"") {
                html = html.replacingOccurrences(of: inject, with: inject + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
            }
            data = Data(html.utf8)
        }
        if ext == "css" {
            let css = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "chrome-extension://__MSG_@@extension_id__/", with: e.baseURL)
            data = Data(css.utf8)
        }
        respond(task, url, data, mime)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, _ url: URL, _ data: Data, _ mime: String) {
        let headers = ["Content-Type": mime.hasPrefix("text/") ? "\(mime); charset=utf-8" : mime,
                       "Content-Length": "\(data.count)",
                       "Access-Control-Allow-Origin": "*",
                       "Cache-Control": "no-cache"]
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(r)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        let r = HTTPURLResponse(url: task.request.url ?? URL(string: "winext://x/")!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!
        task.didReceive(r)
        task.didReceive(Data())
        task.didFinish()
    }
}

/// Cross-origin fetch for extension pages, with the browser's cookies when credentials: 'include'.
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
    static func perform(_ d: [String: Any], userAgent: String) async -> String {
        guard let s = d["url"] as? String, let url = URL(string: s) else { return jsonString(["error": "bad url"]) }
        var req = URLRequest(url: url)
        req.httpMethod = d["method"] as? String ?? "GET"
        for (k, v) in d["headers"] as? [String: String] ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil, !userAgent.isEmpty { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let b = d["body"] as? String, let body = Data(base64Encoded: b) { req.httpBody = body }
        if (d["credentials"] as? String) == "include" {
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let matching = cookies.filter { c in
                guard let h = url.host?.lowercased() else { return false }
                let dom = c.domain.lowercased()
                let hostOK = dom.hasPrefix(".") ? (h == String(dom.dropFirst()) || h.hasSuffix(dom)) : h == dom
                return hostOK && url.path.hasPrefix(c.path) && (!c.isSecure || url.scheme == "https")
                    && (c.expiresDate.map { $0 > Date() } ?? true)
            }
            if !matching.isEmpty {
                let header = HTTPCookie.requestHeaderFields(with: matching)["Cookie"] ?? ""
                if let existing = req.value(forHTTPHeaderField: "Cookie"), !existing.isEmpty {
                    req.setValue(existing + "; " + header, forHTTPHeaderField: "Cookie")
                } else { req.setValue(header, forHTTPHeaderField: "Cookie") }
            }
        }
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] { headers[String(describing: k).lowercased()] = String(describing: v) }
            return jsonString(["status": http?.statusCode ?? 200,
                               "statusText": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 200),
                               "headers": headers, "url": resp.url?.absoluteString ?? s,
                               "redirected": resp.url != url, "body": data.base64EncodedString()])
        } catch {
            return jsonString(["error": error.localizedDescription])
        }
    }
}
