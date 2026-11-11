import Foundation
import WebKit

struct WebExtension: Identifiable {
    struct ContentScript {
        var matches: [String]
        var excludeMatches: [String]
        var js: [String]
        var css: [String]
        var runAt: String
        var allFrames: Bool
        var mainWorld: Bool
    }

    let id: String
    let dir: URL
    let manifest: [String: Any]
    let manifestJSON: String
    let messages: [String: Any]
    let messagesJSON: String
    let version: String
    let contentScripts: [ContentScript]
    let backgroundScripts: [String]
    let backgroundIsModule: Bool
    let popup: String?
    let options: String?
    let homepage: String?

    var world: WKContentWorld { WKContentWorld.world(name: "winext.\(id)") }
    var baseURL: String { "winext://\(id)/" }

    var name: String { localize(manifest["short_name"] as? String ?? manifest["name"] as? String ?? id, preferShort: true) }
    var fullName: String { localize(manifest["name"] as? String ?? id) }
    var summary: String { localize(manifest["description"] as? String ?? "") }

    var iconURL: URL? {
        guard let icons = manifest["icons"] as? [String: String] else { return nil }
        let best = icons.keys.compactMap(Int.init).sorted().last { $0 <= 128 } ?? icons.keys.compactMap(Int.init).max()
        guard let best, let p = icons[String(best)] else { return nil }
        return dir.appendingPathComponent(p.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func localize(_ s: String, preferShort: Bool = false) -> String {
        guard s.hasPrefix("__MSG_"), s.hasSuffix("__") else { return s }
        let key = String(s.dropFirst(6).dropLast(2))
        let m = (messages[key] ?? messages[key.lowercased()]) as? [String: Any]
        return m?["message"] as? String ?? s
    }

    static func load(id: String, dir: URL) -> WebExtension? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        var messages: [String: Any] = [:]
        func merge(_ locale: String) {
            let u = dir.appendingPathComponent("_locales/\(locale)/messages.json")
            guard let d = try? Data(contentsOf: u), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
            for (k, v) in j { messages[k] = v; messages[k.lowercased()] = v }
        }
        if let def = m["default_locale"] as? String { merge(def) }
        let lang = Locale.preferredLanguages.first ?? "en"
        let parts = lang.split(separator: "-").map(String.init)
        if let base = parts.first { merge(base) }
        if parts.count > 1 { merge("\(parts[0])_\(parts.last!)") }

        let scripts: [ContentScript] = (m["content_scripts"] as? [[String: Any]] ?? []).map { cs in
            ContentScript(matches: cs["matches"] as? [String] ?? [],
                          excludeMatches: cs["exclude_matches"] as? [String] ?? [],
                          js: cs["js"] as? [String] ?? [],
                          css: cs["css"] as? [String] ?? [],
                          runAt: cs["run_at"] as? String ?? "document_idle",
                          allFrames: cs["all_frames"] as? Bool ?? false,
                          mainWorld: (cs["world"] as? String) == "MAIN")
        }
        var bg: [String] = []
        var module = false
        if let b = m["background"] as? [String: Any] {
            if let sw = b["service_worker"] as? String { bg = [sw] }
            if let s = b["scripts"] as? [String] { bg = s }
            module = (b["type"] as? String) == "module"
        }
        let action = (m["action"] ?? m["browser_action"]) as? [String: Any]
        let opts = (m["options_ui"] as? [String: Any])?["page"] as? String ?? m["options_page"] as? String

        let messagesJSON = String(data: (try? JSONSerialization.data(withJSONObject: messages)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        return WebExtension(id: id, dir: dir, manifest: m,
                            manifestJSON: String(data: data, encoding: .utf8) ?? "{}",
                            messages: messages, messagesJSON: messagesJSON,
                            version: m["version"] as? String ?? "0",
                            contentScripts: scripts, backgroundScripts: bg, backgroundIsModule: module,
                            popup: action?["default_popup"] as? String, options: opts,
                            homepage: m["homepage_url"] as? String)
    }

    var hostPermissions: [String] {
        (manifest["host_permissions"] as? [String] ?? [])
            + (manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }.filter { $0 == "<all_urls>" || $0.contains("://") }
    }

    func canAccess(_ url: URL) -> Bool { MatchPattern.permits(hostPermissions, url) }

    func file(_ path: String) -> String {
        let p = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "./", with: "")
        return (try? String(contentsOf: dir.appendingPathComponent(p), encoding: .utf8)) ?? ""
    }
}
