import SwiftUI

/// Rectangular outlined Metro button; `filled` uses the accent like a primary action.
struct MetroButton: View {
    @EnvironmentObject var theme: Theme
    let title: String
    var filled = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title.lowercased()).font(.system(size: 17, weight: .semibold)).opacity(busy ? 0 : 1)
                if busy { MetroDots(color: filled ? .white : nil) }
            }
            .foregroundStyle(filled ? Color.white : theme.fg)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(filled ? theme.accent : Color.clear)
            .overlay(Rectangle().strokeBorder(filled ? theme.accent : theme.fg, lineWidth: 2))
        }
        .buttonStyle(.tilt)
        .disabled(busy)
    }
}

/// The Windows Phone indeterminate progress: dots sliding across.
struct MetroDots: View {
    @EnvironmentObject var theme: Theme
    var color: Color?

    var body: some View {
        TimelineView(.animation) { tl in
            GeometryReader { g in
                let t = tl.date.timeIntervalSinceReferenceDate
                ForEach(0..<5, id: \.self) { i in
                    let p = (t / 2.2 + Double(i) * -0.07).truncatingRemainder(dividingBy: 1)
                    let p2 = p < 0 ? p + 1 : p
                    // Fast in, crawl through the middle, fast out.
                    let eased = p2 < 0.35 ? p2 / 0.35 * 0.4 : (p2 < 0.65 ? 0.4 + (p2 - 0.35) / 0.3 * 0.2 : 0.6 + (p2 - 0.65) / 0.35 * 0.4)
                    Rectangle().fill(color ?? theme.accent).frame(width: 4, height: 4)
                        .position(x: eased * g.size.width, y: g.size.height / 2)
                }
            }
        }
        .frame(height: 6)
    }
}

/// Windows Phone style on/off switch.
struct MetroToggle: View {
    @EnvironmentObject var theme: Theme
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17)).foregroundStyle(theme.fg).multilineTextAlignment(.leading)
                    if let detail { Text(detail).font(MetroFont.caption).foregroundStyle(theme.subtle).multilineTextAlignment(.leading) }
                }
                Spacer(minLength: 12)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Rectangle().strokeBorder(theme.fg, lineWidth: 2).frame(width: 50, height: 22)
                    Rectangle().fill(isOn ? theme.accent : Color.clear).frame(width: 40, height: 12).padding(.horizontal, 5)
                    Rectangle().fill(theme.fg).frame(width: 12, height: 22)
                }
                .frame(width: 50, height: 22)
                Text(isOn ? "on" : "off").font(.system(size: 15)).foregroundStyle(theme.subtle).frame(width: 28, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Section header in the accent colour, settings-page style.
struct MetroGroup<C: View>: View {
    @EnvironmentObject var theme: Theme
    let title: String
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(MetroFont.title(28)).foregroundStyle(theme.accent)
            content
        }
    }
}

struct MetroRow: View {
    @EnvironmentObject var theme: Theme
    let title: String
    var value: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 17)).foregroundStyle(theme.fg)
            if let value { Text(value).font(MetroFont.caption).foregroundStyle(theme.subtle).lineLimit(3) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Big lowercase list item, the Windows Phone menu look.
struct MetroMenuItem: View {
    @EnvironmentObject var theme: Theme
    let title: String
    var detail: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title.lowercased()).font(.system(size: 21)).foregroundStyle(theme.fg).lineLimit(1)
                    if let detail { Text(detail).font(MetroFont.caption).foregroundStyle(theme.subtle).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9).padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tilt)
    }
}

/// Motion timings, Windows 10 Mobile style: quick off the mark, then decelerating.
enum Metro {
    /// The context menu peeling open off the edge of the screen.
    static let menuOpen = Animation.timingCurve(0.12, 0.86, 0.2, 1, duration: 0.34)
    /// ...and folding back down.
    static let menuClose = Animation.timingCurve(0.45, 0, 0.75, 1, duration: 0.2)
}

/// The screen edge the Metro context menu hangs from.
enum MenuHinge { case bottom, top }

/// The Windows 10 Mobile context menu: a rectangle with one corner sliced off at 45°,
/// the way the phone's app-bar menu peels away from the edge of the screen.
struct Chamfer: Shape {
    enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }
    var corner: Corner = .topTrailing
    var size: CGFloat = 28

    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = min(size, min(r.width, r.height) / 2)
        switch corner {
        case .topLeading:
            p.move(to: CGPoint(x: r.minX + c, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        case .topTrailing:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        case .bottomLeading:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        case .bottomTrailing:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
            p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// The Metro peel: the menu is hinged to one edge of the screen and swings open
/// off it, tipping back in 3D as it comes, instead of popping into place.
struct PeelModifier: ViewModifier {
    /// 0 = closed, 1 = open.
    let progress: Double
    let hinge: MenuHinge

    func body(content: Content) -> some View {
        let p = min(1, max(0, progress))
        let tilt = (hinge == .bottom ? -1.0 : 1.0) * 13 * (1 - p)
        return content
            .opacity(min(1, p * 2.8))
            .scaleEffect(0.97 + 0.03 * p, anchor: hinge == .bottom ? .bottom : .top)
            .offset(y: hinge == .bottom ? 46 * (1 - p) : -46 * (1 - p))
            .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0),
                              anchor: hinge == .bottom ? .bottom : .top, perspective: 0.42)
    }
}

extension AnyTransition {
    /// The Windows 10 Mobile context menu peeling open off its screen edge.
    static func metroPeel(_ hinge: MenuHinge) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PeelModifier(progress: 0, hinge: hinge), identity: PeelModifier(progress: 1, hinge: hinge)),
            removal: .modifier(active: PeelModifier(progress: 0, hinge: hinge), identity: PeelModifier(progress: 1, hinge: hinge))
        )
    }
}

extension View {
    /// The Metro reveal: an item rises into place once the menu has peeled open.
    func rise(_ shown: Bool, delay: Double = 0) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .animation(.easeOut(duration: 0.28).delay(delay), value: shown)
    }
}

/// Toast in the Windows Phone notification style (top banner).
struct ToastView: View {
    @EnvironmentObject var theme: Theme
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.9)).frame(width: 4)
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(theme.accent)
        .frame(maxWidth: 560)
    }
}
