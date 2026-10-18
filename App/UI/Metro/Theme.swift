import SwiftUI

/// Windows Phone / Windows 10 Mobile visual language: flat, black, typographic, one accent colour.
@MainActor
final class Theme: ObservableObject {
    static let shared = Theme()

    static let accents: [(name: String, hex: UInt32)] = [
        ("lime", 0xA4C400), ("green", 0x60A917), ("emerald", 0x008A00), ("teal", 0x00ABA9),
        ("cyan", 0x1BA1E2), ("cobalt", 0x0050EF), ("indigo", 0x6A00FF), ("violet", 0xAA00FF),
        ("pink", 0xF472D0), ("magenta", 0xD80073), ("crimson", 0xA20025), ("red", 0xE51400),
        ("orange", 0xFA6800), ("amber", 0xF0A30A), ("yellow", 0xE3C800), ("brown", 0x825A2C),
        ("olive", 0x6D8764), ("steel", 0x647687), ("mauve", 0x76608A), ("taupe", 0x87794E),
    ]

    @Published var accentHex: UInt32 = UInt32(UserDefaults.standard.object(forKey: "theme.accent") as? Int ?? 0x0050EF) {
        didSet { UserDefaults.standard.set(Int(accentHex), forKey: "theme.accent") }
    }
    @Published var light: Bool = UserDefaults.standard.bool(forKey: "theme.light") {
        didSet { UserDefaults.standard.set(light, forKey: "theme.light") }
    }

    var accent: Color { Color(hex: accentHex) }
    var bg: Color { light ? .white : .black }
    var fg: Color { light ? .black : .white }
    var subtle: Color { light ? Color(white: 0.4) : Color(white: 0.6) }
    var chrome: Color { light ? Color(white: 0.87) : Color(white: 0.13) }
    var chromeHi: Color { light ? Color(white: 0.8) : Color(white: 0.2) }
    var scheme: ColorScheme { light ? .light : .dark }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum MetroFont {
    static func header(_ size: CGFloat = 52) -> Font { .system(size: size, weight: .light) }
    static func title(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .light) }
    static let body = Font.system(size: 17, weight: .regular)
    static let caption = Font.system(size: 13, weight: .regular)
    static let appTitle = Font.system(size: 14, weight: .semibold)
}

/// The Metro "tilt" press effect: content tips away from the finger.
struct TiltStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .rotation3DEffect(.degrees(configuration.isPressed ? 4 : 0), axis: (x: 1, y: -0.6, z: 0), perspective: 0.6)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == TiltStyle {
    static var tilt: TiltStyle { TiltStyle() }
}

/// Turnstile page transition (rotate about the leading edge).
struct TurnstileModifier: ViewModifier {
    let angle: Double
    let opacity: Double
    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.5)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static var turnstile: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: TurnstileModifier(angle: -75, opacity: 0), identity: TurnstileModifier(angle: 0, opacity: 1)),
            removal: .modifier(active: TurnstileModifier(angle: 75, opacity: 0), identity: TurnstileModifier(angle: 0, opacity: 1)))
    }
    static var turnstileBack: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: TurnstileModifier(angle: 75, opacity: 0), identity: TurnstileModifier(angle: 0, opacity: 1)),
            removal: .modifier(active: TurnstileModifier(angle: -75, opacity: 0), identity: TurnstileModifier(angle: 0, opacity: 1)))
    }
}

/// Round outlined app-bar glyph button.
struct RoundIcon: View {
    @EnvironmentObject var theme: Theme
    let system: String
    var label: String? = nil
    var showLabel = false
    var size: CGFloat = 40
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().strokeBorder(theme.fg, lineWidth: 2)
                    if filled { Circle().fill(theme.fg).padding(2) }
                    Image(systemName: system)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(filled ? theme.bg : theme.fg)
                }
                .frame(width: size, height: size)
                if showLabel, let label {
                    Text(label).font(.system(size: 11)).foregroundStyle(theme.fg).lineLimit(1).fixedSize()
                }
            }
        }
        .buttonStyle(.tilt)
        .accessibilityLabel(label ?? system)
    }
}

/// Small rectangular badge (format / Atmos).
struct Badge: View {
    @EnvironmentObject var theme: Theme
    let text: String
    var accent = false
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 2)
            .foregroundStyle(accent ? Color.white : theme.subtle)
            .background(accent ? theme.accent : Color.clear)
            .overlay(Rectangle().strokeBorder(accent ? Color.clear : theme.subtle.opacity(0.6), lineWidth: 1))
    }
}

/// Button with tilt + long-press that doesn't also fire the tap when the finger lifts.
struct PressableButton<Label: View>: View {
    let action: () -> Void
    var longPress: (() -> Void)?
    @ViewBuilder var label: Label
    @State private var suppress = false

    var body: some View {
        Button {
            if suppress { suppress = false; return }
            action()
        } label: { label }
        .buttonStyle(.tilt)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            guard let longPress else { return }
            suppress = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            longPress()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { suppress = false }
        })
    }
}
