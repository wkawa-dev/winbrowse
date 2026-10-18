import SwiftUI
import WebKit

struct BrowserView: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @Environment(\.horizontalSizeClass) private var hsc

    var body: some View {
        if let tab = store.active {
            if hsc == .regular {
                VStack(spacing: 0) {
                    TabStrip()
                    AddressBar(tab: tab, wide: true)
                    content(tab)
                }
                .background(theme.chrome.ignoresSafeArea())
            } else {
                VStack(spacing: 0) {
                    content(tab)
                    AddressBar(tab: tab, wide: false)
                }
                .background(theme.chrome.ignoresSafeArea(edges: .bottom))
                .background(theme.bg.ignoresSafeArea(edges: .top))
            }
        }
    }

    private func content(_ tab: Tab) -> some View {
        TabContent(tab: tab).id(tab.id)
    }
}

private struct TabContent: View {
    @ObservedObject var tab: Tab
    var body: some View {
        ZStack {
            WebContainer(tab: tab)
            if tab.url == nil { StartPage() }
            if let b = tab.blockedURL { BlockedPage(tab: tab, url: b) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Edge (Windows 10 Mobile) address bar: bottom on iPhone, top on iPad.
struct AddressBar: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @ObservedObject var tab: Tab
    @ObservedObject var blocker = ContentBlocker.shared
    let wide: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !wide && focused { suggestions }
            ZStack(alignment: .top) {
                if tab.isLoading && tab.progress < 1 { MetroDots().frame(height: 4).offset(y: -2) }
                HStack(spacing: wide ? 14 : 8) {
                    if wide {
                        RoundIcon(system: "arrow.left", size: 34) { tab.webView?.goBack() }.opacity(tab.canGoBack ? 1 : 0.35)
                        RoundIcon(system: "arrow.right", size: 34) { tab.webView?.goForward() }.opacity(tab.canGoForward ? 1 : 0.35)
                        RoundIcon(system: tab.isLoading ? "xmark" : "arrow.clockwise", size: 34) {
                            if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
                        }
                    }
                    field
                    if wide {
                        ExtensionButtons(tab: tab)
                    }
                    if !focused {
                        Button { tab.snapshot(); router.push(.tabs) } label: {
                            Text("\(store.tabs.count)").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.fg)
                                .frame(width: 24, height: 22)
                                .overlay(Rectangle().strokeBorder(theme.fg, lineWidth: 2))
                                .frame(width: 40, height: 40).contentShape(Rectangle())
                        }
                        .buttonStyle(.tilt)
                        .accessibilityLabel("tabs")
                        Button { withAnimation(.easeOut(duration: 0.2)) { router.menuOpen.toggle() } } label: {
                            Image(systemName: "ellipsis").font(.system(size: 18, weight: .bold)).foregroundStyle(theme.fg)
                                .frame(width: 36, height: 40).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("more")
                    } else {
                        Button("cancel") { focused = false }.font(.system(size: 16)).foregroundStyle(theme.fg)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            if wide && focused { suggestions }
        }
        .background(theme.chrome)
        .onChange(of: focused) { _, f in
            if f { text = tab.url?.absoluteString ?? "" }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            if !focused, let u = tab.url {
                Image(systemName: u.scheme == "https" ? "lock.fill" : (u.scheme == "winext" ? "puzzlepiece.extension.fill" : "globe"))
                    .font(.system(size: 11)).foregroundStyle(focused ? Color.black : theme.subtle)
            }
            ZStack(alignment: .leading) {
                TextField("", text: $text, prompt: Text("search or enter web address").foregroundStyle(focused ? Color.gray : theme.subtle))
                    .font(.system(size: 16))
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit { go(text) }
                    .foregroundStyle(focused ? Color.black : theme.fg)
                    .tint(theme.accent)
                    .opacity(focused ? 1 : 0.011)
                if !focused {
                    Text(displayText).font(.system(size: 16)).foregroundStyle(tab.url == nil ? theme.subtle : theme.fg).lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
            if !focused && tab.url != nil && !wide {
                Button {
                    if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.fg).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(focused ? Color.white : theme.chromeHi)
        .overlay(Rectangle().strokeBorder(focused ? theme.accent : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private var displayText: String {
        guard let u = tab.url else { return "search or enter web address" }
        if u.scheme == "winext" { return tab.title.isEmpty ? u.absoluteString : tab.title }
        var h = u.host ?? u.absoluteString
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    private var suggestions: some View {
        let q = text.trimmingCharacters(in: .whitespaces)
        let hits = q.isEmpty || q == tab.url?.absoluteString ? [] : BrowserHistory.shared.suggestions(for: q)
        return VStack(alignment: .leading, spacing: 0) {
            if !q.isEmpty && q != tab.url?.absoluteString {
                Button { go(q) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").foregroundStyle(theme.accent)
                        Text(q).font(.system(size: 18)).foregroundStyle(theme.fg).lineLimit(1)
                        Spacer()
                        Text(SearchEngine.current.name.lowercased()).font(MetroFont.caption).foregroundStyle(theme.subtle)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
                }
                .buttonStyle(.tilt)
            }
            ForEach(hits) { e in
                Button { go(e.url) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title.isEmpty ? e.url : e.title).font(.system(size: 17)).foregroundStyle(theme.fg).lineLimit(1)
                        Text(e.url).font(MetroFont.caption).foregroundStyle(theme.accent).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 7).contentShape(Rectangle())
                }
                .buttonStyle(.tilt)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.chrome)
    }

    private func go(_ s: String) {
        focused = false
        store.open(s, in: tab)
    }
}

/// Toolbar shortcuts to the extensions (iPad) — SponsorBlock, X-Posed, uBO.
struct ExtensionButtons: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var router: Router
    @ObservedObject var tab: Tab
    var body: some View {
        HStack(spacing: 10) {
            ForEach(ExtensionHost.shared.enabledExtensions.filter { $0.popup != nil || $0.options != nil }) { e in
                Button { store.extPresent(ext: e, page: e.popup ?? e.options!) } label: {
                    ExtensionIcon(ext: e, size: 24).frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.tilt)
                .accessibilityLabel(e.name)
            }
            Button { router.push(.ublock) } label: {
                UBOIcon(on: !ContentBlocker.shared.isSiteDisabled(tab.url?.host)).frame(width: 34, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.tilt)
            .accessibilityLabel("uBlock Origin")
        }
    }
}

struct ExtensionIcon: View {
    let ext: WebExtension
    var size: CGFloat = 28
    var body: some View {
        if let u = ext.iconURL, let img = UIImage(contentsOfFile: u.path) {
            Image(uiImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "puzzlepiece.extension").frame(width: size, height: size)
        }
    }
}

struct UBOIcon: View {
    var on = true
    var size: CGFloat = 24
    var body: some View {
        let path = UBOAssets.root.appendingPathComponent("img/icon_64.png").path
        Group {
            if let img = UIImage(contentsOfFile: path) {
                Image(uiImage: img).resizable().interpolation(.high)
            } else {
                Image(systemName: "shield.lefthalf.filled")
            }
        }
        .frame(width: size, height: size)
        .saturation(on ? 1 : 0).opacity(on ? 1 : 0.5)
    }
}

/// iPad tab strip, Edge style: flat tabs, accent underline on the active one.
struct TabStrip: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(store.tabs) { t in
                        TabChip(tab: t, active: t.id == store.activeId).id(t.id)
                    }
                    Button { store.newTab(url: nil) } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.fg)
                            .frame(width: 40, height: 34).contentShape(Rectangle())
                    }
                    .buttonStyle(.tilt)
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: store.activeId) { _, id in withAnimation { proxy.scrollTo(id) } }
        }
        .frame(height: 38)
        .background(theme.bg)
    }
}

private struct TabChip: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @ObservedObject var tab: Tab
    let active: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text(tab.displayTitle).font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? theme.fg : theme.subtle).lineLimit(1)
            Spacer(minLength: 0)
            Button { store.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.subtle)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(width: 200, height: 34)
        .background(active ? theme.chrome : theme.bg)
        .overlay(alignment: .top) { if active { Rectangle().fill(theme.accent).frame(height: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab) }
    }
}
