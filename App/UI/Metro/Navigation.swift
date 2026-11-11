import SwiftUI

enum Route: Hashable {
    case tabs
    case settings
    case extensions
    case ublock
    case history
    case passkeys
}

/// Pages pushed over the browser, with the Metro turnstile transition.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var path: [Route] = []
    @Published var forward = true
    @Published var menuOpen = false

    /// The "…" menu: it peels open off the screen edge, never pops.
    func toggleMenu() {
        if menuOpen { closeMenu() } else { openMenu() }
    }

    func openMenu() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(Metro.menuOpen) { menuOpen = true }
    }

    func closeMenu() {
        withAnimation(Metro.menuClose) { menuOpen = false }
    }

    func push(_ r: Route) {
        forward = true
        withAnimation(.easeOut(duration: 0.28)) {
            menuOpen = false
            path.append(r)
        }
    }

    func pop() {
        guard !path.isEmpty else { return }
        forward = false
        withAnimation(.easeOut(duration: 0.24)) { _ = path.removeLast() }
    }

    func popToRoot() {
        guard !path.isEmpty else { return }
        forward = false
        withAnimation(.easeOut(duration: 0.24)) { path.removeAll() }
    }
}

/// Standard page frame: small uppercase app title, big lowercase header, content.
struct MetroPage<Content: View>: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var router: Router
    var title: String
    var subtitle: String = "WINBROWSE"
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { router.pop() } label: {
                    Image(systemName: "arrow.left").font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 30, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.tilt)
                .foregroundStyle(theme.fg)
                Text(subtitle.uppercased()).font(MetroFont.appTitle).foregroundStyle(theme.fg).lineLimit(1)
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Text(title.lowercased())
                .font(MetroFont.header(46))
                .foregroundStyle(theme.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 6)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg.ignoresSafeArea())
        .gesture(
            DragGesture(minimumDistance: 15, coordinateSpace: .global)
                .onEnded { v in if v.startLocation.x < 30, v.translation.width > 80 { router.pop() } }
        )
    }
}
