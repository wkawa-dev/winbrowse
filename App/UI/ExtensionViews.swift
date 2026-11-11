import SwiftUI
import WebKit

struct ExtensionsView: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @State private var tick = 0

    var body: some View {
        MetroPage(title: "extensions") {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Button { router.push(.ublock) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            UBOIcon(size: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("uBlock Origin").font(MetroFont.title(24)).foregroundStyle(theme.fg)
                                Text("filter lists \(ContentBlocker.shared.version) · \(ContentBlocker.shared.status)")
                                    .font(MetroFont.caption).foregroundStyle(theme.subtle)
                                Text("network filtering, cosmetic filtering and scriptlets from uBO's own filter compiler")
                                    .font(.system(size: 14)).foregroundStyle(theme.subtle)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(theme.subtle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.tilt)

                    ForEach(ExtensionHost.shared.extensions) { e in
                        ExtensionCard(ext: e, onChange: { tick += 1 })
                    }
                    Text("toggling an extension reloads open tabs.").font(MetroFont.caption).foregroundStyle(theme.subtle)
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 18)
                .id(tick)
            }
        }
    }
}

private struct ExtensionCard: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    let ext: WebExtension
    let onChange: () -> Void
    @State private var on: Bool

    init(ext: WebExtension, onChange: @escaping () -> Void) {
        self.ext = ext
        self.onChange = onChange
        _on = State(initialValue: ExtensionHost.shared.isEnabled(ext.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                ExtensionIcon(ext: ext, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ext.name).font(MetroFont.title(24)).foregroundStyle(theme.fg)
                    Text("version \(ext.version)").font(MetroFont.caption).foregroundStyle(theme.subtle)
                    Text(ext.summary).font(.system(size: 14)).foregroundStyle(theme.subtle).lineLimit(3)
                }
            }
            MetroToggle(title: "enabled", isOn: $on)
                .onChange(of: on) { _, v in
                    ExtensionHost.shared.setEnabled(ext.id, v)
                    WebViewFactory.shared.rebuildScripts()
                    for t in store.tabs { t.webView?.reload() }
                    onChange()
                }
            HStack(spacing: 10) {
                if let p = ext.popup { MetroButton(title: "open", filled: true) { store.extPresent(ext: ext, page: p) } }
                if let o = ext.options { MetroButton(title: "options") { store.extPresent(ext: ext, page: o) } }
            }
            .disabled(!on).opacity(on ? 1 : 0.4)
        }
    }
}
