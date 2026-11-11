import CryptoKit
import LocalAuthentication
import Security
import UIKit
import WebKit

@MainActor
final class Passkeys: NSObject, ObservableObject, WKScriptMessageHandlerWithReply {
    static let shared = Passkeys()

    struct Credential: Codable, Identifiable, Hashable {
        var id: String
        var rpId: String
        var userHandle: String
        var userName: String
        var displayName: String
        var key: Data
        var created: Date
        var lastUsed: Date?
    }

    @Published private(set) var credentials: [Credential] = []
    #if DEBUG
    var autoApprove = false
    #endif

    private static let service = "dev.winbrowse.passkeys"
    private var cancelers: [String: () -> Void] = [:]

    override init() {
        super.init()
        credentials = Self.loadAll()
    }

    func install(into ucc: WKUserContentController) {
        ucc.removeScriptMessageHandler(forName: "winpasskey", contentWorld: AppScripts.world)
        ucc.addScriptMessageHandler(self, contentWorld: AppScripts.world, name: "winpasskey")
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let b = message.body as? [String: Any], let op = b["op"] as? String else { return replyHandler(nil, "bad request") }
        let req = b["req"] as? Int ?? 0
        let origin = message.frameInfo.securityOrigin
        let originString = Self.originString(origin)
        let key = "\(originString)#\(req)"
        if op == "cancel" { cancelers.removeValue(forKey: key)?(); return replyHandler(nil, nil) }

        guard origin.protocol == "https" || (origin.protocol == "http" && origin.host == "localhost") else {
            return replyHandler(Self.err("SecurityError", "Passkeys need a secure origin."), nil)
        }
        let host = origin.host.lowercased()
        if !message.frameInfo.isMainFrame {
            let topURL = message.webView?.url
            if topURL.map({ Self.originString($0) }) != originString {
                return replyHandler(Self.err("NotAllowedError", "Passkeys aren't available in cross-origin frames."), nil)
            }
        }
        let webView = message.webView
        guard webView?.window != nil else {
            return replyHandler(Self.err("NotAllowedError", "Passkeys are only available in the tab on screen."), nil)
        }

        Task {
            let result: [String: Any]
            switch op {
            case "create": result = await create(b, host: host, origin: originString, key: key)
            case "get": result = await get(b, host: host, origin: originString, key: key, webView: webView)
            default: result = Self.err("NotSupportedError", "Unknown operation")
            }
            cancelers.removeValue(forKey: key)
            replyHandler(result, nil)
        }
    }

    private static func err(_ name: String, _ msg: String) -> [String: Any] { ["error": name, "message": msg] }

    static func originString(scheme: String, host: String, port: Int) -> String {
        let s = scheme.lowercased(), h = host.lowercased()
        let defaultPort = s == "https" ? 443 : 80
        return port == 0 || port == defaultPort ? "\(s)://\(h)" : "\(s)://\(h):\(port)"
    }

    static func originString(_ o: WKSecurityOrigin) -> String {
        originString(scheme: o.protocol, host: o.host, port: o.port)
    }

    static func originString(_ u: URL) -> String {
        originString(scheme: u.scheme ?? "", host: u.host ?? "", port: u.port ?? 0)
    }

    private static func validRP(_ rpId: String, host: String) -> Bool {
        let rp = rpId.lowercased()
        guard rp == host || host.hasSuffix("." + rp) else { return false }
        return rp.contains(".") || rp == "localhost"
    }

    private func create(_ b: [String: Any], host: String, origin: String, key requestKey: String) async -> [String: Any] {
        let rp = b["rp"] as? [String: Any] ?? [:]
        let rpId = ((rp["id"] as? String) ?? host).lowercased()
        guard Self.validRP(rpId, host: host) else { return Self.err("SecurityError", "The relying party ID is not a registrable domain suffix of the origin.") }
        let algs = b["algs"] as? [Int] ?? []
        guard algs.isEmpty || algs.contains(-7) else { return Self.err("NotSupportedError", "Only ES256 passkeys are supported.") }
        if (b["attachment"] as? String) == "cross-platform" { return Self.err("NotAllowedError", "Security keys aren't supported in WinBrowse.") }
        guard let challenge = b["challenge"] as? String,
              let user = b["user"] as? [String: Any], let userHandle = user["id"] as? String else { return Self.err("TypeError", "Missing challenge or user.") }
        let userName = user["name"] as? String ?? ""
        let displayName = user["displayName"] as? String ?? userName

        let exclude = Set((b["exclude"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        if credentials.contains(where: { $0.rpId == rpId && exclude.contains($0.id) }) {
            return Self.err("InvalidStateError", "A passkey for this account is already saved in WinBrowse.")
        }

        let shown = userName.isEmpty ? displayName : userName
        guard await confirm(key: requestKey, title: "Save a passkey?",
                            message: "Create a passkey for \(shown.isEmpty ? "your account" : shown) on \(rpId). It is stored in WinBrowse and unlocked with \(Self.biometryName).",
                            action: "Continue"),
            await verifyUser(reason: "Create a passkey for \(rpId)") else {
            return Self.err("NotAllowedError", "The operation either timed out or was not allowed.")
        }

        let privateKey = P256.Signing.PrivateKey()
        var idBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, idBytes.count, &idBytes)
        let credId = Data(idBytes)

        let clientData = PasskeyCodec.clientData(type: "webauthn.create", challenge: challenge, origin: origin)
        let authData = PasskeyCodec.registrationAuthData(rpId: rpId, credentialId: credId, publicKey: privateKey.publicKey)
        let cred = Credential(id: credId.b64u, rpId: rpId, userHandle: userHandle, userName: userName, displayName: displayName,
                              key: privateKey.rawRepresentation, created: Date(), lastUsed: nil)
        let replaced = credentials.first { $0.rpId == rpId && $0.userHandle == userHandle }
        guard save(cred) else { return Self.err("UnknownError", "Couldn't save the passkey to the keychain.") }
        if let replaced { remove(replaced) }
        credentials.insert(cred, at: 0)
        Toasts.shared.show("passkey saved for \(rpId)")

        var out: [String: Any] = [
            "id": cred.id, "clientDataJSON": clientData.b64u,
            "attestationObject": PasskeyCodec.attestationObject(authData: authData).b64u,
            "authenticatorData": authData.b64u, "publicKey": privateKey.publicKey.derRepresentation.b64u,
        ]
        if let ext = b["extensions"] as? [String: Any], ext["credProps"] != nil { out["extensions"] = ["credProps": ["rk": true]] }
        return out
    }

    private func get(_ b: [String: Any], host: String, origin: String, key requestKey: String, webView: WKWebView?) async -> [String: Any] {
        let rpId = ((b["rpId"] as? String) ?? host).lowercased()
        guard Self.validRP(rpId, host: host) else { return Self.err("SecurityError", "The relying party ID is not a registrable domain suffix of the origin.") }
        guard let challenge = b["challenge"] as? String else { return Self.err("TypeError", "Missing challenge.") }
        let allow = Set((b["allow"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let conditional = b["conditional"] as? Bool ?? false
        let matches = credentials.filter { $0.rpId == rpId && (allow.isEmpty || allow.contains($0.id)) }

        if matches.isEmpty {
            if conditional { return ["pending": true] }
            Toasts.shared.show("no passkey for \(rpId) saved in WinBrowse")
            return Self.err("NotAllowedError", "The operation either timed out or was not allowed.")
        }
        if conditional {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let webView, webView.window == nil { return ["pending": true] }
        }
        guard let chosen = await choose(matches, rpId: rpId, key: requestKey),
              await verifyUser(reason: "Sign in to \(rpId)") else {
            return conditional ? ["pending": true] : Self.err("NotAllowedError", "The operation either timed out or was not allowed.")
        }
        guard let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: chosen.key) else { return Self.err("UnknownError", "Passkey is damaged.") }

        let clientData = PasskeyCodec.clientData(type: "webauthn.get", challenge: challenge, origin: origin)
        let authData = PasskeyCodec.assertionAuthData(rpId: rpId)
        guard let sig = try? PasskeyCodec.assertionSignature(privateKey, authData: authData, clientData: clientData) else {
            return Self.err("UnknownError", "Signing failed.")
        }
        var used = chosen; used.lastUsed = Date()
        if save(used), let i = credentials.firstIndex(where: { $0.id == used.id }) { credentials[i] = used }
        return [
            "id": chosen.id, "clientDataJSON": clientData.b64u, "authenticatorData": authData.b64u,
            "signature": sig.b64u, "userHandle": chosen.userHandle,
        ]
    }

    static var biometryName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "your passcode"
        }
    }

    private func verifyUser(reason: String) async -> Bool {
        #if DEBUG
        if autoApprove { return true }
        #endif
        let c = LAContext()
        var error: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return await (try? c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    private func confirm(key: String, title: String, message: String, action: String) async -> Bool {
        #if DEBUG
        if autoApprove { return true }
        #endif
        return await withCheckedContinuation { cont in
            var resumed = false
            let finish: (Bool) -> Void = { v in if !resumed { resumed = true; cont.resume(returning: v) } }
            let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in finish(false) })
            a.addAction(UIAlertAction(title: action, style: .default) { _ in finish(true) })
            a.preferredAction = a.actions.last
            present(a, key: key, finish: finish)
        }
    }

    private func choose(_ list: [Credential], rpId: String, key: String) async -> Credential? {
        #if DEBUG
        if autoApprove { return list.first }
        #endif
        return await withCheckedContinuation { cont in
            var resumed = false
            let finish: (Credential?) -> Void = { v in if !resumed { resumed = true; cont.resume(returning: v) } }
            let a = UIAlertController(title: "Sign in to \(rpId)?",
                                      message: "Use a passkey saved in WinBrowse.", preferredStyle: list.count > 1 ? .actionSheet : .alert)
            for c in list {
                let label = c.userName.isEmpty ? (c.displayName.isEmpty ? "passkey" : c.displayName) : c.userName
                a.addAction(UIAlertAction(title: list.count > 1 ? label : "Continue as \(label)", style: .default) { _ in finish(c) })
            }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in finish(nil) })
            if list.count == 1 { a.preferredAction = a.actions.first }
            present(a, key: key) { _ in finish(nil) }
        }
    }

    private func present(_ a: UIAlertController, key: String, finish: @escaping (Bool) -> Void) {
        guard let top = Dialogs.top else { return finish(false) }
        if let pop = a.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        cancelers[key] = { [weak a] in a?.dismiss(animated: true); finish(false) }
        top.present(a, animated: true)
    }

    private static func baseQuery(_ id: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let id { q[kSecAttrAccount as String] = id }
        return q
    }

    private func save(_ c: Credential) -> Bool {
        guard let data = try? JSONEncoder().encode(c) else { return false }
        SecItemDelete(Self.baseQuery(c.id) as CFDictionary)
        var q = Self.baseQuery(c.id)
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "WinBrowse passkey · \(c.rpId)"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    private static func loadAll() -> [Credential] {
        var q = baseQuery()
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [Data] else { return [] }
        return items.compactMap { try? JSONDecoder().decode(Credential.self, from: $0) }.sorted { $0.created > $1.created }
    }

    func delete(_ c: Credential) { remove(c) }

    private func remove(_ c: Credential) {
        SecItemDelete(Self.baseQuery(c.id) as CFDictionary)
        credentials.removeAll { $0.id == c.id }
    }
}
