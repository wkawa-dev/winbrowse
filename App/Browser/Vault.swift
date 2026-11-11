import Foundation
import Security
import UIKit
import WebKit

@MainActor
enum Vault {
    private static let service = "dev.winbrowse.vault"
    private static let account = "state"
    private static let seenKey = "vault.seen"
    private static let softLimit = 2_000_000

    private static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    private static var pendingCookies: [[String: Any]] = []

    static func restoreFilesIfFreshInstall() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: seenKey) == nil else { return }
        defaults.set(true, forKey: seenKey)
        guard let blob = read(),
              let raw = try? (blob as NSData).decompressed(using: .lzfse) as Data,
              let snap = try? PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any] else { return }

        if let d = snap["defaults"] as? [String: Any] {
            for (k, v) in d where k != seenKey { defaults.set(v, forKey: k) }
        }
        if let files = snap["files"] as? [String: Data] {
            for (rel, data) in files {
                let u = support.appendingPathComponent(rel)
                try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: u, options: .atomic)
            }
        }
        pendingCookies = snap["cookies"] as? [[String: Any]] ?? []
    }

    static func restoreCookies() async {
        let cookies = pendingCookies.compactMap { HTTPCookie(properties: Dictionary(uniqueKeysWithValues: $0.map { (HTTPCookiePropertyKey($0.key), $0.value) })) }
        pendingCookies = []
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in cookies { await store.setCookie(c) }
    }

    static func snapshot() {
        let background = BackgroundTask()
        background.begin()
        Task {
            let now = Date()
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                .filter { ($0.expiresDate ?? .distantFuture) > now }
                .compactMap { c -> [String: Any]? in
                    guard let p = c.properties else { return nil }
                    return Dictionary(uniqueKeysWithValues: p.map { ($0.key.rawValue, $0.value) })
                }
            let defaults = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
            var files = collectFiles()
            var blob = encode(cookies: cookies, defaults: defaults, files: files)
            if let b = blob, b.count > softLimit {
                files["history.json"] = nil
                if let d = files["tabs.json"] { files["tabs.json"] = strippedTabState(d) }
                blob = encode(cookies: cookies, defaults: defaults, files: files)
            }
            if let blob { write(blob) }
            background.end()
        }
    }

    private static func collectFiles() -> [String: Data] {
        var out: [String: Data] = [:]
        for rel in ["tabs.json", "history.json"] {
            if let d = try? Data(contentsOf: support.appendingPathComponent(rel)) { out[rel] = d }
        }
        let ext = ExtensionStorage.root
        for u in (try? FileManager.default.contentsOfDirectory(at: ext, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "json" {
            if let d = try? Data(contentsOf: u) { out["winext/" + u.lastPathComponent] = d }
        }
        return out
    }

    private static func strippedTabState(_ d: Data) -> Data {
        guard var j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let tabs = j["tabs"] as? [[String: Any]] else { return d }
        j["tabs"] = tabs.map { var t = $0; t["state"] = nil; return t }
        return (try? JSONSerialization.data(withJSONObject: j)) ?? d
    }

    private static func encode(cookies: [[String: Any]], defaults: [String: Any], files: [String: Data]) -> Data? {
        let snap: [String: Any] = ["v": 1, "cookies": cookies, "defaults": defaults, "files": files]
        guard let raw = try? PropertyListSerialization.data(fromPropertyList: snap, format: .binary, options: 0) else { return nil }
        return try? (raw as NSData).compressed(using: .lzfse) as Data
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private static func write(_ data: Data) {
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
    }
}

@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
