import SwiftUI
import WebKit

struct WebContainer: UIViewRepresentable {
    @ObservedObject var tab: Tab

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
