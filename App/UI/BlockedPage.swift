import SwiftUI
import WebKit

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
                    if let h = url.host { SiteSettings.shared.set(.network, on: false, for: h) }
                    tab.blockedURL = nil
                    tab.rebuildWebView(loading: url)
                }
            }
            .padding(20)
        }
        .background(theme.bg)
    }
}
