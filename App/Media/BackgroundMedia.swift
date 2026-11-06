import AVFoundation
import MediaPlayer
import UIKit
import WebKit

/// Keeps web audio/video playing when the app is backgrounded or the screen locks.
/// Pages are told they're always visible (YouTube pauses on visibilitychange), and anything WebKit pauses on
/// backgrounding is resumed.
@MainActor
final class BackgroundMedia: NSObject {
    static let shared = BackgroundMedia()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "media.background") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "media.background") }
    }

    /// Web views that reported a playing media element.
    private var playing: [ObjectIdentifier: WeakWebView] = [:]
    private struct WeakWebView { weak var webView: WKWebView? }
    private var inBackground = false
    private var backgroundedAt = Date.distantPast
    /// Pauses this soon after backgrounding are WebKit's; later ones come from the lock screen / Control Center.
    private var inSystemPauseWindow: Bool { inBackground && Date().timeIntervalSince(backgroundedAt) < 4 }

    static let pageScript = """
    (function(){
      if (window.__winmedia) return; window.__winmedia = true;
      const def = (o, k, v) => { try { Object.defineProperty(o, k, { get: () => v, configurable: true }); } catch (e) {} };
      def(Document.prototype, 'hidden', false);
      def(Document.prototype, 'webkitHidden', false);
      def(Document.prototype, 'visibilityState', 'visible');
      def(Document.prototype, 'webkitVisibilityState', 'visible');
      const stop = (e) => { e.stopImmediatePropagation(); };
      for (const t of ['visibilitychange', 'webkitvisibilitychange']) {
        window.addEventListener(t, stop, true); document.addEventListener(t, stop, true);
      }
      try { Document.prototype.hasFocus = function () { return true; }; } catch (e) {}
      // Track media state for the host.
      const post = (m) => { try { window.webkit.messageHandlers.winmedia.postMessage(m); } catch (e) {} };
      let userPaused = 0;
      document.addEventListener('play', (e) => { if (e.target instanceof HTMLMediaElement) post({ state: 'playing' }); }, true);
      document.addEventListener('pause', (e) => {
        if (!(e.target instanceof HTMLMediaElement)) return;
        post({ state: 'paused', user: Date.now() - userPaused < 1500 });
      }, true);
      // A pause shortly after a tap/keypress is the user's; anything else while backgrounded is the system's.
      for (const t of ['touchend', 'mouseup', 'keydown', 'click']) document.addEventListener(t, () => { userPaused = Date.now(); }, true);
      navigator.mediaSession && navigator.mediaSession.setActionHandler && (() => {
        const orig = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
        navigator.mediaSession.setActionHandler = function (a, h) {
          if (a === 'pause' && h) { const wrapped = function (d) { userPaused = Date.now(); return h(d); }; return orig(a, wrapped); }
          return orig(a, h);
        };
      })();
      window.__winmediaResume = function () {
        let n = 0;
        for (const m of document.querySelectorAll('video, audio')) {
          if (m.paused && m.dataset.winmediaWas === '1' && !m.ended) { m.play().catch(() => {}); n++; }
        }
        return n;
      };
      window.__winmediaMark = function () {
        for (const m of document.querySelectorAll('video, audio')) m.dataset.winmediaWas = (!m.paused && !m.ended) ? '1' : '0';
      };
    })();
    """

    func isPlaying(_ w: WKWebView) -> Bool { playing[ObjectIdentifier(w)]?.webView != nil }

    /// Sets the playback category. Only activates the session when `activate` is true: activating a non-mixing
    /// session pauses music from other apps, so that is left to WebKit (when media actually plays) or to a page that
    /// is already playing when the app is backgrounded.
    func configureSession(activate: Bool = false) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        if activate { try? AVAudioSession.sharedInstance().setActive(true) }
    }

    func install(into ucc: WKUserContentController) {
        ucc.removeScriptMessageHandler(forName: "winmedia", contentWorld: .page)
        ucc.add(self, contentWorld: .page, name: "winmedia")
        if enabled {
            ucc.addUserScript(WKUserScript(source: Self.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
    }

    func willResignActive() {
        guard enabled else { return }
        for w in playing.values.compactMap(\.webView) {
            w.evaluateJavaScript("window.__winmediaMark && window.__winmediaMark()", in: nil, in: .page, completionHandler: nil)
        }
    }

    func didEnterBackground() {
        guard enabled else { return }
        inBackground = true
        backgroundedAt = Date()
        configureSession(activate: playing.values.contains { $0.webView != nil })
        // WebKit pauses video elements as the app leaves the foreground; start them again.
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.resumeAll() }
        }
    }

    func willEnterForeground() { inBackground = false }

    private func resumeAll() {
        guard inSystemPauseWindow else { return }
        for w in playing.values.compactMap(\.webView) {
            w.evaluateJavaScript("window.__winmediaResume && window.__winmediaResume()", in: nil, in: .page, completionHandler: nil)
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
                // System pause while backgrounded (WebKit / visibility): undo it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    w.evaluateJavaScript("window.__winmediaResume && window.__winmediaResume()", in: nil, in: .page, completionHandler: nil)
                }
            } else if !inBackground {
                playing[key] = nil
            }
        }
    }
}
