import SwiftUI
import WebKit

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
