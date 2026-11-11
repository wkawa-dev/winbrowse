import Foundation

enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    static var recording: Bool { ProcessInfo.processInfo.environment["WINBROWSE_RECORD"] == "1" }

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    static func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }

    static func string(_ path: String) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }

    static func json(_ path: String) throws -> Any { try JSONSerialization.jsonObject(with: data(path)) }

    static func canonical(_ value: Any) throws -> String {
        let d = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    static func golden(_ value: Any, _ path: String) throws -> (actual: String, expected: String) {
        let actual = try canonical(value)
        if recording { try Data(actual.utf8).write(to: url(path)) }
        return try (actual, string(path))
    }
}
