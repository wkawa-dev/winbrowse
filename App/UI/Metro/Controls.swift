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
    var color: Color? = nil

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
    var detail: String? = nil
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
    var value: String? = nil
    var accent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 17)).foregroundStyle(theme.fg)
            if let value { Text(value).font(MetroFont.caption).foregroundStyle(accent ? theme.accent : theme.subtle).lineLimit(3) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Big lowercase list item, the Windows Phone menu look.
struct MetroMenuItem: View {
    @EnvironmentObject var theme: Theme
    let title: String
    var detail: String? = nil
    var icon: String? = nil
    var size: CGFloat = 21
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let icon { Image(systemName: icon).font(.system(size: size * 0.8, weight: .light)).foregroundStyle(theme.fg).frame(width: 26) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title.lowercased()).font(.system(size: size)).foregroundStyle(theme.fg).lineLimit(1)
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
