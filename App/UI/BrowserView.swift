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
    @State private var focused = false

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
    }

    private var field: some View {
        HStack(spacing: 6) {
            if !focused, let u = tab.url {
                Image(systemName: u.scheme == "https" ? "lock.fill" : (u.scheme == "winext" ? "puzzlepiece.extension.fill" : "globe"))
                    .font(.system(size: 11)).foregroundStyle(focused ? Color.black : theme.subtle)
            }
            ZStack(alignment: .leading) {
                AddressField(
                    text: $text,
                    focused: $focused,
                    url: tab.url?.absoluteString ?? "",
                    placeholder: "search or enter web address",
                    textColor: focused ? .black : UIColor(theme.fg),
                    placeholderColor: focused ? .gray : UIColor(theme.subtle),
                    tint: UIColor(theme.accent),
                    onSubmit: go
                )
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

/// UIKit text field behind the address bar. Focusing it selects the whole URL (so typing or paste replaces it),
/// and a toolbar above the keyboard offers cut and paste.
struct AddressField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let url: String
    let placeholder: String
    let textColor: UIColor
    let placeholderColor: UIColor
    let tint: UIColor
    let onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = .systemFont(ofSize: 16)
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
        field.rightView = context.coordinator.actions(for: field)
        field.rightViewMode = .whileEditing
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.textColor = textColor
        field.tintColor = tint
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: placeholderColor])
        context.coordinator.cut?.tintColor = tint
        if field.text != text { field.text = text }
        if focused && !field.isFirstResponder {
            // Async: becoming first responder calls delegate methods that write the bindings, which must not happen mid-update.
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !focused && field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 22)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressField
        private(set) var cut: UIButton?

        init(_ parent: AddressField) {
            self.parent = parent
            super.init()
        }

        /// Cut and paste buttons shown inside the field's trailing edge while editing.
        /// Paste is a system UIPasteControl, so it pastes without the "Allow Paste" prompt.
        func actions(for field: UITextField) -> UIView {
            let side: CGFloat = 26
            let cut = UIButton(type: .system, primaryAction: UIAction { [weak field] _ in field?.cut(nil) })
            cut.setImage(UIImage(systemName: "scissors", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)), for: .normal)
            cut.accessibilityLabel = "cut"
            cut.frame = CGRect(x: 0, y: 0, width: side, height: side)

            let config = UIPasteControl.Configuration()
            config.displayMode = .iconOnly
            config.cornerStyle = .fixed
            config.cornerRadius = 0
            config.baseForegroundColor = .white
            config.baseBackgroundColor = parent.tint
            let paste = UIPasteControl(configuration: config)
            paste.target = field
            paste.frame = CGRect(x: side + 6, y: 0, width: side, height: side)

            let box = UIView(frame: CGRect(x: 0, y: 0, width: side * 2 + 6 + 4, height: side))
            box.addSubview(cut)
            box.addSubview(paste)
            self.cut = cut
            return box
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            let url = parent.url
            field.text = url
            parent.text = url
            if !parent.focused { parent.focused = true }
            // Async so the tap's own caret placement lands first; the selection then covers the whole URL.
            DispatchQueue.main.async { field.selectAll(nil) }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.focused { parent.focused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit(field.text ?? "")
            return true
        }

        @objc func edited(_ field: UITextField) {
            parent.text = field.text ?? ""
        }
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
