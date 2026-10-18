import SwiftUI

/// New-tab page: a Windows Phone start screen of live tiles.
struct StartPage: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @ObservedObject var pins = Pins.shared
    @ObservedObject var history = BrowserHistory.shared
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var editing = false

    var body: some View {
        GeometryReader { g in
            let cols = hsc == .regular ? max(6, Int(g.size.width / 150)) : 4
            let gap: CGFloat = 6
            let unit = (min(g.size.width, 1100) - 24 - gap * CGFloat(cols - 1)) / CGFloat(cols)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("start").font(MetroFont.header(56)).foregroundStyle(theme.fg).padding(.top, 8)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(unit * 2 + gap), spacing: gap), count: cols / 2), alignment: .leading, spacing: gap) {
                        ForEach(Array(pins.pins.enumerated()), id: \.element.id) { i, p in
                            tile(p, index: i).frame(width: unit * 2 + gap, height: unit * 2 + gap)
                        }
                    }
                    if !history.entries.isEmpty {
                        Text("recent").font(MetroFont.title(28)).foregroundStyle(theme.accent).padding(.top, 10)
                        ForEach(history.entries.prefix(8)) { e in
                            Button { store.open(e.url) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title.isEmpty ? e.url : e.title).font(.system(size: 18)).foregroundStyle(theme.fg).lineLimit(1)
                                    Text(URL(string: e.url)?.host ?? e.url).font(MetroFont.caption).foregroundStyle(theme.subtle).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.tilt)
                        }
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(theme.bg)
    }

    private func tile(_ p: Pins.Pin, index: Int) -> some View {
        let palette: [UInt32] = [theme.accentHex, 0xE51400, 0x1BA1E2, 0x60A917, 0xFA6800, 0xAA00FF, 0x00ABA9, 0xD80073]
        let known = Self.knownTile(p.url)
        let color = known?.color ?? palette[index % palette.count]
        return Button { store.open(p.url) } label: {
            ZStack(alignment: .bottomLeading) {
                Color(hex: color)
                VStack {
                    Spacer()
                    if let sym = known?.symbol {
                        Image(systemName: sym).font(.system(size: 44, weight: .light)).foregroundStyle(.white)
                    } else {
                        Text(String((URL(string: p.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? p.title).prefix(1)).uppercased())
                            .font(.system(size: 54, weight: .light)).foregroundStyle(.white)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                Text(p.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    .padding(8)
            }
        }
        .buttonStyle(.tilt)
        .contextMenu {
            Button(role: .destructive) { pins.pins.removeAll { $0.id == p.id } } label: { Label("unpin from start", systemImage: "pin.slash") }
            Button { store.newTab(url: URL(string: p.url)) } label: { Label("open in new tab", systemImage: "plus.square.on.square") }
        }
    }

    static func knownTile(_ url: String) -> (symbol: String, color: UInt32)? {
        let h = URL(string: url)?.host ?? ""
        if h.contains("youtube") { return ("play.rectangle.fill", 0xE51400) }
        if h == "x.com" || h.hasSuffix("twitter.com") { return ("bubble.left.and.text.bubble.right", 0x1D1D1D) }
        if h.contains("reddit") { return ("person.3", 0xFA6800) }
        if h.contains("wikipedia") { return ("book", 0x647687) }
        if h.contains("github") { return ("chevron.left.forwardslash.chevron.right", 0x6A00FF) }
        if h.contains("ycombinator") { return ("newspaper", 0xF0A30A) }
        return nil
    }
}
