import Combine
import SwiftUI
import WebKit

@MainActor
final class BrowserHistory: ObservableObject {
    static let shared = BrowserHistory()
    struct Entry: Codable, Identifiable, Hashable { var url: String; var title: String; var date: Date; var visits: Int; var id: String { url } }
    @Published private(set) var entries: [Entry] = []
    private var saveScheduled = false
    private static var fileURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("history.json") }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
    }

    func record(_ u: URL, title: String) {
        let s = u.absoluteString
        if let i = entries.firstIndex(where: { $0.url == s }) {
            var e = entries.remove(at: i)
            e.date = Date(); e.visits += 1
            if !title.isEmpty { e.title = title }
            entries.insert(e, at: 0)
        } else {
            entries.insert(Entry(url: s, title: title, date: Date(), visits: 1), at: 0)
        }
        if entries.count > 3_000 { entries.removeLast(entries.count - 3_000) }
        save()
    }

    func suggestions(for q: String, limit: Int = 6) -> [Entry] {
        let q = q.lowercased()
        guard !q.isEmpty else { return [] }
        return Array(entries.lazy.filter { $0.url.lowercased().contains(q) || $0.title.lowercased().contains(q) }
            .sorted { ($0.visits, $0.date) > ($1.visits, $1.date) }.prefix(limit))
    }

    func remove(_ e: Entry) { entries.removeAll { $0.url == e.url }; save() }
    func clear() { entries.removeAll(); save() }

    private func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let d = try? JSONEncoder().encode(self.entries) { try? d.write(to: Self.fileURL, options: .atomic) }
        }
    }
}
