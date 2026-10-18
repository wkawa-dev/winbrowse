import SwiftUI

/// Windows Phone pivot: swipeable sections with large lowercase headers; the selected header leads.
struct Pivot<Content: View>: View {
    @EnvironmentObject var theme: Theme
    let titles: [String]
    @Binding var selection: Int
    var appTitle: String = ""
    @ViewBuilder var content: (Int) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !appTitle.isEmpty {
                Text(appTitle).font(MetroFont.appTitle).foregroundStyle(theme.fg)
                    .padding(.horizontal, 20).padding(.top, 8)
            }
            headers
            TabView(selection: $selection) {
                ForEach(titles.indices, id: \.self) { i in
                    content(i).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    /// Headers rotate so the selected one is first, wrapping like the real pivot control.
    private var headers: some View {
        let ordered = titles.indices.map { (selection + $0) % titles.count }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                ForEach(ordered, id: \.self) { i in
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { selection = i }
                    } label: {
                        Text(titles[i])
                            .font(MetroFont.header(i == selection ? 50 : 50))
                            .foregroundStyle(i == selection ? theme.fg : theme.subtle.opacity(0.55))
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .animation(.easeOut(duration: 0.25), value: selection)
        }
        .scrollDisabled(true)
        .frame(height: 66)
        .clipped()
    }
}
