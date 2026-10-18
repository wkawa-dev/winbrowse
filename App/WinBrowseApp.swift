import SwiftUI
import WebKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in BackgroundMedia.shared.configureSession() }
        return true
    }
}

@MainActor
enum AppBoot {
    private static var booted = false

    static func boot() {
        guard !booted else { return }
        booted = true
        let host = ExtensionHost.shared
        host.load()
        host.tabs = BrowserStore.shared
        host.userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " + WebViewFactory.safariSuffix
        WebViewFactory.shared.rebuildScripts()
        BrowserStore.shared.restore()
        BrowserStore.shared.observeMemoryWarnings()
        Task {
            await reloadBlocking()
            // Pages loaded before the filters finished compiling get a fresh, filtered load.
            if let t = BrowserStore.shared.active, t.url != nil, ContentBlocker.shared.activeRuleCount > 0 { t.webView?.reload() }
        }
        // Background pages after the window exists (they're parked in it to avoid timer throttling).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { host.startBackgrounds() }
        #if DEBUG
        DebugServer.shared.start()
        #endif
        // Grab the real UA for the extension fetch proxy.
        let probe = WKWebView(frame: .zero, configuration: WebViewFactory.shared.configuration())
        probe.evaluateJavaScript("navigator.userAgent") { r, _ in
            if let ua = r as? String { host.userAgent = ua }
            _ = probe
        }
    }

    static func reloadBlocking() async {
        let lists = await ContentBlocker.shared.prepare()
        WebViewFactory.shared.applyRuleLists(lists)
        WebViewFactory.shared.rebuildScripts()
    }
}

@main
struct WinBrowseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var phase

    @StateObject private var theme = Theme.shared
    @StateObject private var router = Router.shared
    @StateObject private var store = BrowserStore.shared
    @StateObject private var toasts = Toasts.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(theme)
                .environmentObject(router)
                .environmentObject(store)
                .environmentObject(toasts)
                .preferredColorScheme(theme.scheme)
                .tint(theme.accent)
                .onAppear { AppBoot.boot() }
                .onOpenURL { u in
                    if u.scheme == "http" || u.scheme == "https" { store.newTab(url: u) }
                }
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .background:
                store.persistNow()
                ExtensionHost.shared.storage.flush()
                BackgroundMedia.shared.didEnterBackground()
            case .inactive:
                BackgroundMedia.shared.willResignActive()
            case .active:
                BackgroundMedia.shared.willEnterForeground()
                store.active?.reviveIfNeeded()
            @unknown default: break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var router: Router
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var toasts: Toasts

    var body: some View {
        ZStack(alignment: .top) {
            BrowserView()
            if router.menuOpen, let t = store.active {
                MenuOverlay(tab: t).zIndex(2)
            }
            if let top = router.path.last {
                page(top)
                    .id(router.path.count)
                    .transition(router.forward ? .turnstile : .turnstileBack)
                    .zIndex(3)
            }
            if let m = toasts.message {
                ToastView(text: m).padding(.horizontal, 12).padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity)).zIndex(5)
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .fullScreenCover(item: $store.presentedExtensionPage) { req in
            ExtensionPageView(req: req)
                .environmentObject(theme).environmentObject(store).environmentObject(router)
                .preferredColorScheme(theme.scheme)
        }
    }

    @ViewBuilder private func page(_ r: Route) -> some View {
        switch r {
        case .tabs: TabsView()
        case .settings: SettingsView()
        case .extensions: ExtensionsView()
        case .ublock: UBlockView()
        case .history: HistoryView()
        }
    }
}
