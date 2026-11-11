import Foundation
import WebKit

@MainActor
final class PageHarness: NSObject, WKNavigationDelegate {
    enum Failure: Error { case navigation(Error), timeout }

    nonisolated static let origin = URL(string: "https://fixture.test/")!

    let webView: WKWebView
    private var pending: CheckedContinuation<Void, Error>?

    init(configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    convenience init(scripts: [WKUserScript] = [], configure: (WKUserContentController) -> Void = { _ in }) {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        for s in scripts { controller.addUserScript(s) }
        configure(controller)
        configuration.userContentController = controller
        self.init(configuration: configuration)
    }

    func load(html: String, baseURL: URL = PageHarness.origin) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pending = c
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func load(page name: String, baseURL: URL = PageHarness.origin) async throws {
        try await load(html: Fixtures.string("pages/\(name).html"), baseURL: baseURL)
    }

    @discardableResult
    func eval(_ body: String, in world: WKContentWorld? = nil, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world ?? .page)
    }

    func waitFor(_ condition: String, in world: WKContentWorld? = nil, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await eval("return Boolean(\(condition))", in: world) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.timeout
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    private func finish(_ error: Error?) {
        guard let c = pending else { return }
        pending = nil
        if let error { c.resume(throwing: Failure.navigation(error)) } else { c.resume() }
    }
}

enum AppSource {
    static let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")

    static func resource(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Resources").appendingPathComponent(name), encoding: .utf8)
    }
}
