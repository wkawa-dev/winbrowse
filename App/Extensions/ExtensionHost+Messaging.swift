import Foundation
import WebKit

extension ExtensionHost {
    func frameHello(_ id: String, from ep: Endpoint) -> String? {
        guard case .content(let w, let f, _, let frameId) = ep else { return nil }
        var list = frames[ObjectIdentifier(w)] ?? []
        list.removeAll { $0.ext == id && $0.id == frameId }
        list.append(FrameRef(frame: f, ext: id, id: frameId))
        frames[ObjectIdentifier(w)] = list
        return nil
    }

    func sendMessage(_ kind: ExtensionMessage, ext id: String, from ep: Endpoint, data: [String: Any]) async -> String {
        let payload: [String: Any] = ["msg": data["msg"] ?? NSNull(), "sender": senderJSON(ep)]
        if kind == .tabsSendMessage {
            guard let tid = data["tabId"] as? Int, let w = tabs?.extWebView(tabId: tid) else { return Self.notHandled }
            return await firstHandled(contentEndpoints(id, tab: w, frameId: data["frameId"] as? Int), payload)
        }
        return await firstHandled(extensionTargets(id, from: ep), payload)
    }

    func connect(_ kind: ExtensionMessage, ext id: String, from ep: Endpoint, data: [String: Any]) async -> String? {
        guard let pid = data["portId"] as? String else { return nil }
        let targets: [Endpoint]
        if kind == .tabsConnect {
            guard let tid = data["tabId"] as? Int, let w = tabs?.extWebView(tabId: tid) else { return Self.notConnected }
            targets = contentEndpoints(id, tab: w)
        } else {
            targets = extensionTargets(id, from: ep)
        }
        let payload: [String: Any] = ["portId": pid, "name": data["name"] ?? "", "sender": senderJSON(ep)]
        var accepted: [Endpoint] = []
        for t in targets {
            if let reply = await deliver(t, "portConnect", payload), Self.object(reply)["accepted"] as? Bool == true { accepted.append(t) }
        }
        guard !accepted.isEmpty else { return Self.notConnected }
        ports[pid] = Port(a: ep, b: accepted)
        return jsonString(["connected": true])
    }

    func portMessage(_ kind: ExtensionMessage, from ep: Endpoint, data: [String: Any]) async -> String? {
        guard let pid = data["portId"] as? String, let p = ports[pid] else { return nil }
        let others = p.a.same(as: ep) ? p.b : [p.a]
        if kind == .portDisconnect {
            ports[pid] = nil
            for t in others { _ = await deliver(t, "portDisconnect", ["portId": pid]) }
        } else {
            for t in others { _ = await deliver(t, "portMessage", ["portId": pid, "msg": data["msg"] ?? NSNull()]) }
        }
        return nil
    }

    func dropPorts(where gone: (Endpoint) -> Bool) {
        for (pid, p) in ports {
            if gone(p.a) {
                for b in p.b { Task { _ = await deliver(b, "portDisconnect", ["portId": pid]) } }
                ports[pid] = nil
            } else if p.b.contains(where: gone) {
                var remaining = p
                remaining.b.removeAll(where: gone)
                if remaining.b.isEmpty {
                    Task { _ = await deliver(p.a, "portDisconnect", ["portId": pid]) }
                    ports[pid] = nil
                } else {
                    ports[pid] = remaining
                }
            }
        }
    }

    private static let notHandled = jsonString(["handled": false])
    private static let notConnected = jsonString(["connected": false])

    private static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private func extensionTargets(_ id: String, from ep: Endpoint) -> [Endpoint] {
        var targets = extensionEndpoints(id, excluding: ep.webView)
        if case .background = ep { targets.removeAll { if case .background = $0 { return true }; return false } }
        return targets
    }

    private func firstHandled(_ eps: [Endpoint], _ payload: [String: Any]) async -> String {
        for ep in eps {
            if let reply = await deliver(ep, "message", payload), Self.object(reply)["handled"] as? Bool == true { return reply }
        }
        return Self.notHandled
    }
}
