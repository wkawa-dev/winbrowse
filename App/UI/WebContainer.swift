import SwiftUI
import WebKit

/// Hosts the active tab's WKWebView; swapping tabs swaps the subview so pages keep running.
struct WebContainer: UIViewRepresentable {
    @ObservedObject var tab: Tab
    var bottomInset: CGFloat = 0

    func makeUIView(context: Context) -> ContainerView { ContainerView() }

    func updateUIView(_ v: ContainerView, context: Context) {
        let w = tab.ensureWebView()
        v.show(w)
    }

    final class ContainerView: UIView {
        private weak var current: WKWebView?
        override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .black; clipsToBounds = true }
        required init?(coder: NSCoder) { fatalError() }

        func show(_ w: WKWebView) {
            guard current !== w else { return }
            current?.removeFromSuperview()
            w.removeFromSuperview()
            w.frame = bounds
            w.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(w)
            current = w
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            current?.frame = bounds
        }
    }
}

/// Shown when uBO's strict blocking stopped a page (same wording as uBlock Origin's document-blocked page).
struct BlockedPage: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var tab: Tab
    let url: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("UBLOCK ORIGIN").font(MetroFont.appTitle).foregroundStyle(theme.fg)
                Text("page blocked").font(MetroFont.header(44)).foregroundStyle(theme.fg)
                Text("uBlock Origin has prevented the following page from loading:").font(.system(size: 17)).foregroundStyle(theme.fg)
                Text(url.absoluteString).font(.system(size: 14, design: .monospaced)).foregroundStyle(theme.accent)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(theme.chrome)
                Text("Because of a filter in one of the enabled lists. The site may be a tracker, an ad server or known malware.")
                    .font(.system(size: 15)).foregroundStyle(theme.subtle)
                HStack(spacing: 12) {
                    MetroButton(title: "go back") {
                        tab.blockedURL = nil
                        if tab.canGoBack { tab.webView?.goBack() }
                    }
                    MetroButton(title: "proceed", filled: true) {
                        tab.bypassHost = url.host?.lowercased()
                        tab.blockedURL = nil
                        tab.rebuildWebView(loading: url)
                    }
                }
                MetroButton(title: "always allow \(url.host ?? "this site")") {
                    if let h = url.host { ContentBlocker.shared.setSite(h, disabled: true) }
                    tab.blockedURL = nil
                    tab.rebuildWebView(loading: url)
                }
            }
            .padding(20)
        }
        .background(theme.bg)
    }
}
