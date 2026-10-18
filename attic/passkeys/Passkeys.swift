import CryptoKit
import LocalAuthentication
import Security
import UIKit
import WebKit

/// WinBrowse's own passkey authenticator (WebAuthn, ES256, "none" attestation).
/// A sideloaded browser can't reach iCloud Keychain passkeys from a WKWebView (that needs Apple's web-browser
/// entitlement), so passkeys are created and kept here: private keys in the keychain, every use gated by
/// Face ID / Touch ID / passcode, origin and rpId checked natively against the requesting frame.
@MainActor
final class Passkeys: NSObject, ObservableObject, WKScriptMessageHandlerWithReply {
    static let shared = Passkeys()

    struct Credential: Codable, Identifiable, Hashable {
        var id: String            // credential id, base64url
        var rpId: String
        var userHandle: String    // base64url
        var userName: String
        var displayName: String
        var key: Data             // P-256 private key, raw representation
        var created: Date
        var lastUsed: Date?
    }

    @Published private(set) var credentials: [Credential] = []
    #if DEBUG
    var autoApprove = false
    #endif

    private static let service = "dev.winbrowse.passkeys"
    private var cancelers: [Int: () -> Void] = [:]

    override init() {
        super.init()
        credentials = Self.loadAll()
    }

    static let script: String = {
        Bundle.main.url(forResource: "passkeys", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }()

    func install(into ucc: WKUserContentController) {
        ucc.removeScriptMessageHandler(forName: "winpasskey", contentWorld: .page)
        ucc.addScriptMessageHandler(self, contentWorld: .page, name: "winpasskey")
        ucc.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    // MARK: - Bridge

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let b = message.body as? [String: Any], let op = b["op"] as? String else { return replyHandler(nil, "bad request") }
        let req = b["req"] as? Int ?? 0
        if op == "cancel" { cancelers.removeValue(forKey: req)?(); return replyHandler(nil, nil) }

        let origin = message.frameInfo.securityOrigin
        guard origin.protocol == "https" || (origin.protocol == "http" && origin.host == "localhost") else {
            return replyHandler(Self.err("SecurityError", "Passkeys need a secure origin."), nil)
        }
        let host = origin.host.lowercased()
        var originString = "\(origin.protocol)://\(host)"
        if origin.port != 0 && origin.port != (origin.protocol == "https" ? 443 : 80) { originString += ":\(origin.port)" }
        // Cross-origin iframes would need permissions-policy checks; keep passkeys to the top site and its same-origin frames.
        if !message.frameInfo.isMainFrame, let top = message.webView?.url?.host?.lowercased(), top != host {
            return replyHandler(Self.err("NotAllowedError", "Passkeys aren't available in cross-origin frames."), nil)
        }
        let webView = message.webView

        Task {
            let result: [String: Any]
            switch op {
            case "create": result = await create(b, host: host, origin: originString, req: req)
            case "get": result = await get(b, host: host, origin: originString, req: req, webView: webView)
            default: result = Self.err("NotSupportedError", "Unknown operation")
            }
            replyHandler(result, nil)
        }
    }

    private static func err(_ name: String, _ msg: String) -> [String: Any] { ["error": name, "message": msg] }

    /// The rpId must be the origin's host or a registrable parent of it.
    private static func validRP(_ rpId: String, host: String) -> Bool {
        let rp = rpId.lowercased()
        guard rp == host || host.hasSuffix("." + rp) else { return false }
        return rp.contains(".") || rp == "localhost"
    }

    // MARK: - Registration

    private func create(_ b: [String: Any], host: String, origin: String, req: Int) async -> [String: Any] {
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
        guard await confirm(req: req, title: "Save a passkey?",
                            message: "Create a passkey for \(shown.isEmpty ? "your account" : shown) on \(rpId). It is stored in WinBrowse and unlocked with \(Self.biometryName).",
                            action: "Continue"),
              await verifyUser(reason: "Create a passkey for \(rpId)") else {
            return Self.err("NotAllowedError", "The operation either timed out or was not allowed.")
        }

        let key = P256.Signing.PrivateKey()
        var idBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, idBytes.count, &idBytes)
        let credId = Data(idBytes)

        let clientData = Self.clientData(type: "webauthn.create", challenge: challenge, origin: origin)
        let pub = key.publicKey.rawRepresentation // x || y
        var cose = Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20])
        cose += pub.prefix(32)
        cose += Data([0x22, 0x58, 0x20])
        cose += pub.suffix(32)
        var authData = Self.authDataHeader(rpId: rpId, flags: 0x01 | 0x04 | 0x08 | 0x10 | 0x40)
        authData += Data(count: 16) // AAGUID
        authData += Data([UInt8(credId.count >> 8), UInt8(credId.count & 0xff)])
        authData += credId
        authData += cose

        var att = Data([0xA3])
        att += Self.cborText("fmt") + Self.cborText("none")
        att += Self.cborText("attStmt") + Data([0xA0])
        att += Self.cborText("authData") + Self.cborBytes(authData)

        let cred = Credential(id: credId.b64u, rpId: rpId, userHandle: userHandle, userName: userName, displayName: displayName,
                              key: key.rawRepresentation, created: Date(), lastUsed: nil)
        guard save(cred) else { return Self.err("UnknownError", "Couldn't save the passkey to the keychain.") }
        credentials.insert(cred, at: 0)
        Toasts.shared.show("passkey saved for \(rpId)")

        var out: [String: Any] = [
            "id": cred.id, "clientDataJSON": clientData.b64u, "attestationObject": att.b64u,
            "authenticatorData": authData.b64u, "publicKey": key.publicKey.derRepresentation.b64u,
        ]
        if let ext = b["extensions"] as? [String: Any], ext["credProps"] != nil { out["extensions"] = ["credProps": ["rk": true]] }
        return out
    }

    // MARK: - Sign-in

    private func get(_ b: [String: Any], host: String, origin: String, req: Int, webView: WKWebView?) async -> [String: Any] {
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
            // Autofill-style sign-in: give the page a moment to settle, then offer the saved passkey(s).
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let webView, webView.window == nil { return ["pending": true] }
        }
        guard let chosen = await choose(matches, rpId: rpId, req: req),
              await verifyUser(reason: "Sign in to \(rpId)") else {
            return conditional ? ["pending": true] : Self.err("NotAllowedError", "The operation either timed out or was not allowed.")
        }
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: chosen.key) else { return Self.err("UnknownError", "Passkey is damaged.") }

        let clientData = Self.clientData(type: "webauthn.get", challenge: challenge, origin: origin)
        let authData = Self.authDataHeader(rpId: rpId, flags: 0x01 | 0x04 | 0x08 | 0x10)
        guard let sig = try? key.signature(for: authData + Data(SHA256.hash(data: clientData))) else {
            return Self.err("UnknownError", "Signing failed.")
        }
        var used = chosen; used.lastUsed = Date()
        if save(used), let i = credentials.firstIndex(where: { $0.id == used.id }) { credentials[i] = used }
        return [
            "id": chosen.id, "clientDataJSON": clientData.b64u, "authenticatorData": authData.b64u,
            "signature": sig.derRepresentation.b64u, "userHandle": chosen.userHandle,
        ]
    }

    // MARK: - WebAuthn encoding

    private static func clientData(type: String, challenge: String, origin: String) -> Data {
        // Hand-built so key order matches browsers (type, challenge, origin, crossOrigin).
        func q(_ s: String) -> String {
            let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
            return d.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }
        return Data("{\"type\":\(q(type)),\"challenge\":\(q(challenge)),\"origin\":\(q(origin)),\"crossOrigin\":false}".utf8)
    }

    private static func authDataHeader(rpId: String, flags: UInt8) -> Data {
        Data(SHA256.hash(data: Data(rpId.utf8))) + Data([flags, 0, 0, 0, 0]) // sign count 0: synced-passkey style
    }

    private static func cborText(_ s: String) -> Data { Data([0x60 | UInt8(s.utf8.count)]) + Data(s.utf8) }

    private static func cborBytes(_ d: Data) -> Data {
        if d.count < 24 { return Data([0x40 | UInt8(d.count)]) + d }
        if d.count < 256 { return Data([0x58, UInt8(d.count)]) + d }
        return Data([0x59, UInt8(d.count >> 8), UInt8(d.count & 0xff)]) + d
    }

    // MARK: - UI

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
        // No passcode set (or simulator): the explicit confirmation above is the only gate available.
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    private func confirm(req: Int, title: String, message: String, action: String) async -> Bool {
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
            present(a, req: req, finish: finish)
        }
    }

    private func choose(_ list: [Credential], rpId: String, req: Int) async -> Credential? {
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
            present(a, req: req) { _ in finish(nil) }
        }
    }

    private func present(_ a: UIAlertController, req: Int, finish: @escaping (Bool) -> Void) {
        guard let top = Dialogs.top else { return finish(false) }
        if let pop = a.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        cancelers[req] = { [weak a] in a?.dismiss(animated: true); finish(false) }
        top.present(a, animated: true)
    }

    // MARK: - Keychain

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

    func delete(_ c: Credential) {
        SecItemDelete(Self.baseQuery(c.id) as CFDictionary)
        credentials.removeAll { $0.id == c.id }
    }
}

extension Data {
    var b64u: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
