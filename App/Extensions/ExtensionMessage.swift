import Foundation

enum ExtensionMessage: String, CaseIterable {
    case frameHello = "frame.hello"
    case storageGet = "storage.get"
    case storageSet = "storage.set"
    case storageRemove = "storage.remove"
    case storageClear = "storage.clear"
    case runtimeSendMessage = "runtime.sendMessage"
    case runtimeConnect = "runtime.connect"
    case runtimeOpenOptionsPage = "runtime.openOptionsPage"
    case portPost = "port.post"
    case portDisconnect = "port.disconnect"
    case tabsQuery = "tabs.query"
    case tabsGet = "tabs.get"
    case tabsCreate = "tabs.create"
    case tabsUpdate = "tabs.update"
    case tabsRemove = "tabs.remove"
    case tabsReload = "tabs.reload"
    case tabsSendMessage = "tabs.sendMessage"
    case tabsConnect = "tabs.connect"
    case scriptingExecute = "scripting.execute"
    case scriptingCSS = "scripting.css"
    case actionOpenPopup = "action.openPopup"
    case fetch
    case cryptoDigest = "crypto.digest"

    var contentScriptsMayCall: Bool {
        switch self {
        case .frameHello, .storageGet, .storageSet, .storageRemove, .storageClear,
             .runtimeSendMessage, .runtimeConnect, .runtimeOpenOptionsPage, .portPost, .portDisconnect:
            return true
        default:
            return false
        }
    }
}

enum ExtensionFiles {
    static func resolve(_ path: String, in dir: URL) -> URL? {
        let base = dir.standardizedFileURL.pathComponents
        let file = dir.appendingPathComponent(path).standardizedFileURL
        guard file.pathComponents.count > base.count, file.pathComponents.starts(with: base) else { return nil }
        return file
    }

    static func loadable(_ path: String, by document: URL?, extensionId: String, manifest: [String: Any]) -> Bool {
        guard let document, let scheme = document.scheme?.lowercased() else { return true }
        if scheme == "winext", document.host == extensionId { return true }
        guard !path.hasPrefix("__winext/") else { return false }
        return webAccessible(path, to: document, manifest: manifest)
    }

    static func webAccessible(_ path: String, to document: URL, manifest: [String: Any]) -> Bool {
        let p = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let paths = manifest["web_accessible_resources"] as? [String] { return paths.contains { glob($0, p) } }
        for entry in manifest["web_accessible_resources"] as? [[String: Any]] ?? [] {
            guard (entry["resources"] as? [String] ?? []).contains(where: { glob($0, p) }) else { continue }
            if (entry["matches"] as? [String] ?? []).contains(where: { MatchPattern.matches($0, document) }) { return true }
        }
        return false
    }

    private static func glob(_ pattern: String, _ path: String) -> Bool {
        let p = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let regex = "^" + p.split(separator: "*", omittingEmptySubsequences: false).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}
