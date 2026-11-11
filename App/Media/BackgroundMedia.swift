import AVFoundation
import MediaPlayer
import UIKit
import WebKit

@MainActor
final class BackgroundMedia: NSObject {
    static let shared = BackgroundMedia()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "media.background") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "media.background") }
    }

    private var playing: [ObjectIdentifier: WeakWebView] = [:]
    private struct WeakWebView { weak var webView: WKWebView? }
    private var inBackground = false
    private var backgroundedAt = Date.distantPast
    private var inSystemPauseWindow: Bool { inBackground && Date().timeIntervalSince(backgroundedAt) < 4 }

    func isPlaying(_ w: WKWebView) -> Bool { playing[ObjectIdentifier(w)]?.webView != nil }

    func configureSession(activate: Bool = false) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        if activate { try? AVAudioSession.sharedInstance().setActive(true) }
    }

    func install(into ucc: WKUserContentController) {
        ucc.removeScriptMessageHandler(forName: "winmedia", contentWorld: AppScripts.world)
        ucc.add(self, contentWorld: AppScripts.world, name: "winmedia")
    }

    private func run(_ call: String, in w: WKWebView) {
        w.evaluateJavaScript("window.winbrowseMedia && window.winbrowseMedia.\(call)()", in: nil, in: AppScripts.world, completionHandler: nil)
    }

    func willResignActive() {
        guard enabled else { return }
        for w in playing.values.compactMap(\.webView) {
            run("mark", in: w)
        }
    }

    func didEnterBackground() {
        guard enabled else { return }
        inBackground = true
        backgroundedAt = Date()
        configureSession(activate: playing.values.contains { $0.webView != nil })
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.resumeAll() }
        }
    }

    func willEnterForeground() { inBackground = false }

    private func resumeAll() {
        guard inSystemPauseWindow else { return }
        for w in playing.values.compactMap(\.webView) {
            run("resume", in: w)
        }
    }
}

extension BackgroundMedia: WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let b = message.body as? [String: Any], let state = b["state"] as? String, let w = message.webView else { return }
        let key = ObjectIdentifier(w)
        if state == "playing" {
            playing[key] = WeakWebView(webView: w)
        } else if state == "paused" {
            let user = b["user"] as? Bool ?? false
            if inSystemPauseWindow && enabled && !user {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.run("resume", in: w) }
            } else if !inBackground {
                playing[key] = nil
            }
        }
    }
}
