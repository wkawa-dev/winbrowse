import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @State private var engine = SearchEngine.current
    @State private var bgAudio = BackgroundMedia.shared.enabled
    @State private var cleared: String?

    var body: some View {
        MetroPage(title: "settings") {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    MetroGroup(title: "search") {
                        ForEach(SearchEngine.allCases) { e in
                            Button { engine = e; SearchEngine.current = e } label: {
                                HStack {
                                    Text(e.name.lowercased()).font(.system(size: 19)).foregroundStyle(engine == e ? theme.accent : theme.fg)
                                    Spacer()
                                    if engine == e { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.tilt)
                        }
                    }

                    MetroGroup(title: "media") {
                        MetroToggle(title: "background play", detail: "keep audio and video playing with the screen locked or in another app", isOn: $bgAudio)
                            .onChange(of: bgAudio) { _, v in
                                BackgroundMedia.shared.enabled = v
                                WebViewFactory.shared.rebuildScripts()
                            }
                    }

                    MetroGroup(title: "privacy") {
                        MetroButton(title: "clear history") { BrowserHistory.shared.clear(); flash("history cleared") }
                        MetroButton(title: "clear cookies & site data") {
                            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                                flash("site data cleared")
                            }
                        }
                        if let cleared { Text(cleared).font(MetroFont.caption).foregroundStyle(theme.accent) }
                    }

                    MetroGroup(title: "theme") {
                        HStack(spacing: 10) {
                            MetroButton(title: "dark", filled: !theme.light) { theme.light = false }
                            MetroButton(title: "light", filled: theme.light) { theme.light = true }
                        }
                        Text("accent colour").font(MetroFont.caption).foregroundStyle(theme.subtle)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                            ForEach(Theme.accents, id: \.hex) { a in
                                Button { theme.accentHex = a.hex } label: {
                                    Color(hex: a.hex).aspectRatio(1, contentMode: .fit)
                                        .overlay(Rectangle().strokeBorder(theme.fg, lineWidth: theme.accentHex == a.hex ? 3 : 0))
                                }
                                .buttonStyle(.tilt)
                                .accessibilityLabel(a.name)
                            }
                        }
                        .frame(maxWidth: 420)
                    }

                    MetroGroup(title: "about") {
                        MetroRow(title: "WinBrowse \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")",
                                 value: "WebKit with SponsorBlock, uBlock Origin, X-Posed and The Ad Blocker for X built in.")
                        ForEach(ExtensionHost.shared.extensions) { e in
                            MetroRow(title: e.fullName, value: "\(e.version)\(e.homepage.map { " · \($0)" } ?? "")")
                        }
                        MetroRow(title: "uBlock Origin Lite rulesets", value: "\(ContentBlocker.shared.version) · GPLv3 · github.com/uBlockOrigin/uBOL-home")
                    }
                    Color.clear.frame(height: 60)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: 700, alignment: .leading)
            }
        }
    }

    private func flash(_ s: String) {
        cleared = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if cleared == s { cleared = nil } }
    }
}

struct HistoryView: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @ObservedObject var history = BrowserHistory.shared
    @State private var q = ""

    var body: some View {
        MetroPage(title: "history") {
            TextField("", text: $q, prompt: Text("search history").foregroundStyle(Color.gray))
                .font(.system(size: 17)).foregroundStyle(Color.black).tint(theme.accent)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 10).frame(height: 40).background(Color.white)
                .padding(.horizontal, 18).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(list) { e in
                        Button { store.open(e.url); router.popToRoot() } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title.isEmpty ? e.url : e.title).font(.system(size: 18)).foregroundStyle(theme.fg).lineLimit(1)
                                Text("\(URL(string: e.url)?.host ?? e.url) · \(e.date.formatted(.relative(presentation: .named)))")
                                    .font(MetroFont.caption).foregroundStyle(theme.subtle).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.tilt)
                        .contextMenu { Button(role: .destructive) { history.remove(e) } label: { Label("delete", systemImage: "trash") } }
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 40)
            }
        }
    }

    private var list: [BrowserHistory.Entry] {
        let s = q.lowercased()
        if s.isEmpty { return Array(history.entries.prefix(400)) }
        return history.entries.filter { $0.url.lowercased().contains(s) || $0.title.lowercased().contains(s) }
    }
}
