import Foundation

/// chrome.storage backing store: one JSON file per extension + area (session is memory only).
@MainActor
final class ExtensionStorage {
    private var data: [String: [String: Any]] = [:] // "<ext>/<area>" → items
    private var dirty: Set<String> = []
    private var saveScheduled = false

    static let root: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("winext", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private func key(_ ext: String, _ area: String) -> String { "\(ext)/\(area == "sync" ? "sync" : area)" }
    private func fileURL(_ k: String) -> URL { Self.root.appendingPathComponent(k.replacingOccurrences(of: "/", with: ".") + ".json") }

    private func items(_ ext: String, _ area: String) -> [String: Any] {
        let k = key(ext, area)
        if let d = data[k] { return d }
        var d: [String: Any] = [:]
        if area != "session", let raw = try? Data(contentsOf: fileURL(k)),
           let j = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] { d = j }
        data[k] = d
        return d
    }

    func get(_ ext: String, _ area: String, keys: [String]?) -> [String: Any] {
        if area == "managed" { return [:] }
        let all = items(ext, area)
        guard let keys else { return all }
        var out: [String: Any] = [:]
        for k in keys { if let v = all[k] { out[k] = v } }
        return out
    }

    /// Returns chrome.storage.onChanged-shaped changes.
    func set(_ ext: String, _ area: String, _ new: [String: Any]) -> [String: Any] {
        var all = items(ext, area)
        var changes: [String: Any] = [:]
        for (k, v) in new {
            if v is NSNull { continue }
            var c: [String: Any] = ["newValue": v]
            if let old = all[k] {
                if (old as AnyObject).isEqual(v) { continue }
                c["oldValue"] = old
            }
            all[k] = v
            changes[k] = c
        }
        commit(ext, area, all)
        return changes
    }

    func remove(_ ext: String, _ area: String, keys: [String]) -> [String: Any] {
        var all = items(ext, area)
        var changes: [String: Any] = [:]
        for k in keys { if let old = all.removeValue(forKey: k) { changes[k] = ["oldValue": old] } }
        commit(ext, area, all)
        return changes
    }

    func clear(_ ext: String, _ area: String) -> [String: Any] {
        remove(ext, area, keys: Array(items(ext, area).keys))
    }

    private func commit(_ ext: String, _ area: String, _ all: [String: Any]) {
        let k = key(ext, area)
        data[k] = all
        guard area != "session" else { return }
        dirty.insert(k)
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.flush() }
    }

    func flush() {
        saveScheduled = false
        for k in dirty {
            guard let d = data[k], let raw = try? JSONSerialization.data(withJSONObject: d) else { continue }
            try? raw.write(to: fileURL(k), options: .atomic)
        }
        dirty.removeAll()
    }
}
