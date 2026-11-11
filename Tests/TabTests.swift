import Foundation
import Testing
@testable import WinBrowse

@MainActor
struct TabTests {
    @Test func proceedingPastABlockedPageBuildsOneWebViewForTheTargetSite() throws {
        let target = URL(string: "https://blocked.invalid/page")!
        let tab = Tab(id: 9_001, url: URL(string: "https://start.invalid/")!, store: BrowserStore.shared)
        tab.ensureWebView()

        tab.bypassHost = target.host
        tab.rebuildWebView(loading: target)
        let rebuilt = try #require(tab.webView)
        #expect(tab.protections == tab.wanted(for: target))
        #expect(!tab.protections.contains(.network))

        tab.load(target)
        #expect(tab.webView === rebuilt)
    }

    @Test func discardingKeepsTheURLAndRebuildsOnDemand() {
        let tab = Tab(id: 9_002, url: URL(string: "https://start.invalid/")!, store: BrowserStore.shared)
        tab.ensureWebView()
        tab.discard()
        #expect(!tab.hasWebView)
        #expect(tab.ensureWebView() === tab.webView)
        #expect(tab.url == URL(string: "https://start.invalid/"))
    }
}
