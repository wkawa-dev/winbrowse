import SwiftUI
import WebKit

struct ExtensionPageView: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    let req: BrowserStore.ExtensionPageRequest

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ExtensionIcon(ext: req.ext, size: 22)
                Text(req.ext.name.uppercased()).font(MetroFont.appTitle).foregroundStyle(theme.fg)
                Spacer()
                if let o = req.ext.options, o != req.page {
                    Button("options") { store.presentedExtensionPage = .init(ext: req.ext, page: o, tabId: req.tabId) }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
                }
                Button { store.presentedExtensionPage = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.fg)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            ExtensionPageWebView(req: req)
        }
        .background(theme.chrome.ignoresSafeArea())
    }
}

private struct ExtensionPageWebView: UIViewRepresentable {
    let req: BrowserStore.ExtensionPageRequest
    func makeUIView(context: Context) -> WKWebView {
        let w = ExtensionHost.shared.makePageWebView(ext: req.ext, path: req.page, tabId: req.tabId)
        w.navigationDelegate = context.coordinator
        w.uiDelegate = context.coordinator
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { ExtensionHost.shared.releasePage(uiView) }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = action.request.url {
                Task { @MainActor in
                    BrowserStore.shared.presentedExtensionPage = nil
                    BrowserStore.shared.newTab(url: u)
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = action.request.url, u.scheme == "http" || u.scheme == "https", action.targetFrame?.isMainFrame != false {
                Task { @MainActor in
                    BrowserStore.shared.presentedExtensionPage = nil
                    BrowserStore.shared.newTab(url: u)
                }
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }
}
