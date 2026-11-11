import Foundation
import UniformTypeIdentifiers
import WebKit

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

        let document = task.request.mainDocumentURL
        guard ExtensionFiles.loadable(path, by: document, extensionId: id, manifest: e.manifest) else { return fail(task, 403) }
        guard let file = ExtensionFiles.resolve(path, in: e.dir), var data = try? Data(contentsOf: file) else { return fail(task, 404) }
        let ext = file.pathExtension.lowercased()
        var mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        if ext == "js" || ext == "mjs" { mime = "text/javascript" }
        if ext == "html" || ext == "htm" {
            var html = String(decoding: data, as: UTF8.self)
            let inject = "<script src=\"/__winext/shim.js?ctx=page&tab=\(tabId)\"></script>"
            if let r = html.range(of: "<head>", options: .caseInsensitive) { html.insert(contentsOf: inject, at: r.upperBound) }
            else if let r = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) { html.insert(contentsOf: inject, at: r.upperBound) }
            else { html = inject + html }
            if !html.contains("name=\"viewport\"") {
                html = html.replacingOccurrences(of: inject, with: inject + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
            }
            data = Data(html.utf8)
        }
        if ext == "css" {
            let css = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "chrome-extension://__MSG_@@extension_id__/", with: e.baseURL)
            data = Data(css.utf8)
        }
        respond(task, url, data, mime, cors: document.map { $0.scheme != "winext" } ?? false)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, _ url: URL, _ data: Data, _ mime: String, cors: Bool = false) {
        var headers = ["Content-Type": mime.hasPrefix("text/") ? "\(mime); charset=utf-8" : mime,
                       "Content-Length": "\(data.count)",
                       "Cache-Control": "no-cache"]
        if cors { headers["Access-Control-Allow-Origin"] = "*" }
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
