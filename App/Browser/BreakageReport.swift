import Foundation

struct PageError: Codable, Equatable {
    let kind: String
    let message: String
    let page: String
    let source: String
    let line: Int
    let date: Date
}

struct BreakageReport: Codable {
    struct Extension: Codable, Equatable {
        let id: String
        let version: String
        let enabled: Bool
    }

    var url: String
    var appVersion: String
    var system: String
    var userAgent: String
    var desktopSite: Bool
    var protections: [String]
    var rulesets: [String]
    var filterListVersion: String
    var extensions: [Extension]
    var compile: CompileReport?
    var errors: [PageError]
    var created: Date

    static func redact(_ url: URL?, keepQuery: Bool = false) -> String {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        c.user = nil
        c.password = nil
        c.fragment = nil
        if !keepQuery { c.query = nil }
        return c.string ?? ""
    }

    static func redact(_ text: String) -> String {
        guard text.contains("://") else { return text }
        return redact(URL(string: text))
    }

    static func redact(_ errors: [PageError]) -> [PageError] {
        errors.map { PageError(kind: $0.kind, message: $0.message, page: redact($0.page), source: redact($0.source), line: $0.line, date: $0.date) }
    }

    func json(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    var fileName: String {
        let host = URL(string: url)?.host ?? "page"
        return "winbrowse-report-\(host).json"
    }
}
