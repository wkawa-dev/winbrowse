import UIKit
import WebKit

/// Builds tab web views. Two shared controllers: "filtered" (uBO network + cosmetic + scriptlets) and
/// "unfiltered" (for sites the user turned uBO off on); both carry the extensions and background audio.
@MainActor
final class WebViewFactory {
    static let shared = WebViewFactory()

    let filtered = WKUserContentController()
    let unfiltered = WKUserContentController()
    private var installedLists: [WKContentRuleList] = []

    static let safariSuffix = "Version/17.0 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// iPad gets desktop sites except YouTube, whose mobile site is the one that plays reliably in WebKit and that
    /// SponsorBlock + background play are tuned for here.
    static func contentMode(for host: String?, desktop: Bool) -> WKWebpagePreferences.ContentMode {
        if desktop { return .desktop }
        guard UIDevice.current.userInterfaceIdiom == .pad else { return .mobile }
        if let h = host?.lowercased(), h == "youtube.com" || h.hasSuffix(".youtube.com") { return .mobile }
        return .recommended
    }

    func rebuildScripts() {
        let host = ExtensionHost.shared
        for (ucc, withUBO) in [(filtered, true), (unfiltered, false)] {
            ucc.removeAllUserScripts()
            BackgroundMedia.shared.install(into: ucc)
            if withUBO, ContentBlocker.shared.enabled {
                UBOScripts.shared.install(into: ucc, rulesets: ContentBlocker.shared.enabledIds.sorted())
            }
            host.install(into: ucc)
        }
    }

    func applyRuleLists(_ lists: [WKContentRuleList]) {
        for l in installedLists { filtered.remove(l) }
        for l in lists { filtered.add(l) }
        installedLists = lists
    }

    func configuration(filteredContent: Bool = true, desktop: Bool = false) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        c.userContentController = filteredContent ? filtered : unfiltered
        c.setURLSchemeHandler(ExtensionHost.shared.schemeHandler, forURLScheme: "winext")
        c.allowsInlineMediaPlayback = true
        c.allowsPictureInPictureMediaPlayback = true
        c.allowsAirPlayForMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        c.applicationNameForUserAgent = Self.safariSuffix
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        c.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .recommended
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        if #available(iOS 16.4, *) { c.preferences.isElementFullscreenEnabled = true }
        c.upgradeKnownHostsToHTTPS = true
        c.dataDetectorTypes = []
        return c
    }

    func makeWebView(configuration c: WKWebViewConfiguration) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: c)
        w.allowsBackForwardNavigationGestures = true
        w.allowsLinkPreview = true
        w.isOpaque = false
        w.backgroundColor = .black
        w.scrollView.backgroundColor = .black
        w.scrollView.contentInsetAdjustmentBehavior = .automatic
        w.scrollView.keyboardDismissMode = .interactive
        if #available(iOS 16.4, *) { w.isInspectable = true }
        if #available(iOS 16.0, *) { w.isFindInteractionEnabled = true }
        return w
    }
}
