import Combine
import SwiftUI
import WebKit

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, startpage, brave
    var id: String { rawValue }
    var name: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .startpage: return "Startpage"
        case .brave: return "Brave Search"
        }
    }
    static var current: SearchEngine {
        get { SearchEngine(rawValue: UserDefaults.standard.string(forKey: "search.engine") ?? "") ?? .google }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "search.engine") }
    }
    func url(for q: String) -> URL? {
        var c: URLComponents
        switch self {
        case .google: c = URLComponents(string: "https://www.google.com/search")!
        case .duckduckgo: c = URLComponents(string: "https://duckduckgo.com/")!
        case .bing: c = URLComponents(string: "https://www.bing.com/search")!
        case .startpage: c = URLComponents(string: "https://www.startpage.com/do/search")!
        case .brave: c = URLComponents(string: "https://search.brave.com/search")!
        }
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        return c.url
    }
}
