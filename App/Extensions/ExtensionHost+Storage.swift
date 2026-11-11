import Foundation

extension ExtensionHost {
    func storageMessage(_ kind: ExtensionMessage, ext id: String, data: [String: Any]) -> String? {
        let area = data["area"] as? String ?? "local"
        let changes: [String: Any]
        switch kind {
        case .storageGet: return jsonString(storage.get(id, area, keys: data["keys"] as? [String]))
        case .storageSet: changes = storage.set(id, area, data["items"] as? [String: Any] ?? [:])
        case .storageRemove: changes = storage.remove(id, area, keys: data["keys"] as? [String] ?? [])
        default: changes = storage.clear(id, area)
        }
        guard !changes.isEmpty else { return nil }
        let payload: [String: Any] = ["area": area, "changes": changes]
        for ep in extensionEndpoints(id) + allContentEndpoints(id) {
            Task { _ = await deliver(ep, "storageChanged", payload) }
        }
        return nil
    }
}
