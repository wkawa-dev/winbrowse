import UIKit
import WebKit

@MainActor
final class WebViewFactory {
    static let shared = WebViewFactory()

    struct Setup: Hashable {
        let protections: Protections
        let extensionPage: Bool
    }

    private var controllers: [Setup: WKUserContentController] = [:]
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

    func controller(for setup: Setup) -> WKUserContentController {
        if let c = controllers[setup] { return c }
        let c = WKUserContentController()
        install(into: c, setup)
        controllers[setup] = c
        return c
    }

    func setup(of controller: WKUserContentController) -> Setup? {
        controllers.first { $0.value === controller }?.key
    }

    func rebuildScripts() {
        for (s, c) in controllers {
            c.removeAllUserScripts()
            install(into: c, s)
        }
    }

    private func install(into c: WKUserContentController, _ s: Setup) {
        let p = s.protections
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
        if s.extensionPage { ExtensionHost.shared.installPages(into: c) }
        c.removeAllContentRuleLists()
        if p.contains(.network) { for l in ruleLists { c.add(l) } }
    }

    func applyRuleLists(_ lists: [WKContentRuleList]) {
        ruleLists = lists
        for (s, c) in controllers {
            c.removeAllContentRuleLists()
            if s.protections.contains(.network) { for l in lists { c.add(l) } }
        }
    }

    func configuration(_ protections: Protections, desktop: Bool = false, extensionPage: Bool = false) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        c.userContentController = controller(for: Setup(protections: protections, extensionPage: extensionPage))
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
