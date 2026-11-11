import UIKit
import WebKit

@MainActor
final class WebViewFactory {
    static let shared = WebViewFactory()

    private var controllers: [Protections: WKUserContentController] = [:]
    private var ruleLists: [WKContentRuleList] = []

    var autoplayEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "media.autoplay") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "media.autoplay") }
    }

    nonisolated static func safariVersion(_ os: OperatingSystemVersion) -> String { "\(os.majorVersion).\(os.minorVersion)" }
    nonisolated static let safariSuffix = "Version/\(safariVersion(ProcessInfo.processInfo.operatingSystemVersion)) Mobile/15E148 Safari/604.1"
    nonisolated static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion(ProcessInfo.processInfo.operatingSystemVersion)) Safari/605.1.15"

    static func contentMode(for host: String?, desktop: Bool) -> WKWebpagePreferences.ContentMode {
        if desktop { return .desktop }
        guard UIDevice.current.userInterfaceIdiom == .pad else { return .mobile }
        return SiteSettings.shared.config.mobileSiteOnTablets(host) ? .mobile : .recommended
    }

    func controller(for protections: Protections) -> WKUserContentController {
        if let c = controllers[protections] { return c }
        let c = WKUserContentController()
        install(into: c, protections)
        controllers[protections] = c
        return c
    }

    func protections(of controller: WKUserContentController) -> Protections? {
        controllers.first { $0.value === controller }?.key
    }

    func rebuildScripts() {
        for (p, c) in controllers {
            c.removeAllUserScripts()
            install(into: c, p)
        }
    }

    private func install(into c: WKUserContentController, _ p: Protections) {
        var modules: AppScripts.Modules = []
        if p.contains(.backgroundMedia) { modules.insert(.media) }
        if p.contains(.passkeys) { modules.insert(.passkeys) }
        if ExtensionHost.shared.isEnabled("xadblock") { modules.insert(.xfeed) }
        AppScripts.install(into: c, modules: modules)
        BackgroundMedia.shared.install(into: c)
        Passkeys.shared.install(into: c)
        let ubo = p.intersection([.cosmetic, .scriptlets])
        if !ubo.isEmpty { UBOScripts.shared.install(into: c, rulesets: ContentBlocker.shared.enabledIds.sorted(), parts: ubo) }
        ExtensionHost.shared.install(into: c)
        c.removeAllContentRuleLists()
        if p.contains(.network) { for l in ruleLists { c.add(l) } }
    }

    func applyRuleLists(_ lists: [WKContentRuleList]) {
        ruleLists = lists
        for (p, c) in controllers {
            c.removeAllContentRuleLists()
            if p.contains(.network) { for l in lists { c.add(l) } }
        }
    }

    func configuration(_ protections: Protections, desktop: Bool = false) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        c.userContentController = controller(for: protections)
        c.setURLSchemeHandler(ExtensionHost.shared.schemeHandler, forURLScheme: "winext")
        c.allowsInlineMediaPlayback = true
        c.allowsPictureInPictureMediaPlayback = true
        c.allowsAirPlayForMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = autoplayEnabled ? [] : .all
        c.applicationNameForUserAgent = Self.safariSuffix
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        c.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .recommended
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.preferences.isElementFullscreenEnabled = true
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
        w.isInspectable = true
        w.isFindInteractionEnabled = true
        return w
    }
}
