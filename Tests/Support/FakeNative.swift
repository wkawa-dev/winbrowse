import Foundation
import WebKit

@MainActor
final class FakeNative: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler {
    struct Message {
        let name: String
        let body: [String: Any]
    }

    private(set) var messages: [Message] = []
    var answer: (Message, @escaping (Any?) -> Void) -> Void = { _, reply in reply(nil) }

    func messages(_ name: String) -> [Message] { messages.filter { $0.name == name } }

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                                           replyHandler: @escaping (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            let m = Message(name: message.name, body: message.body as? [String: Any] ?? [:])
            messages.append(m)
            answer(m) { replyHandler($0, nil) }
        }
    }

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            messages.append(Message(name: message.name, body: message.body as? [String: Any] ?? [:]))
        }
    }
}

enum Footprint {
    struct NotAString: Error {}

    @MainActor
    static func take(_ page: PageHarness) async throws -> [String: String] {
        guard let json = try await page.eval(Fixtures.string("footprint.js")) as? String else { throw NotAString() }
        return try flatten(JSONSerialization.jsonObject(with: Data(json.utf8)), prefix: "")
    }

    static func differences(_ pristine: [String: String], _ app: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in Set(pristine.keys).union(app.keys) where pristine[key] != app[key] {
            out[key] = "\(pristine[key] ?? "absent") -> \(app[key] ?? "absent")"
        }
        return out
    }

    private static func flatten(_ value: Any, prefix: String) -> [String: String] {
        if let d = value as? [String: Any] {
            return d.reduce(into: [:]) { out, item in
                out.merge(flatten(item.value, prefix: prefix.isEmpty ? item.key : "\(prefix).\(item.key)")) { a, _ in a }
            }
        }
        if let a = value as? [String] { return [prefix: a.joined(separator: ",")] }
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return [prefix: data.map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"]
    }
}
