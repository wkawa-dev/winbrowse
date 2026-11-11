import CryptoKit
import Foundation

/// WebAuthn byte formats for WinBrowse's passkey authenticator: authenticatorData, the "none" attestation object,
/// COSE public keys and ES256 assertions. Foundation and CryptoKit only, so it compiles outside the app and can be
/// checked against an independent verifier (see the removed handoff note.md §8).
enum PasskeyCodec {
    static let flagUserPresent: UInt8 = 0x01
    static let flagUserVerified: UInt8 = 0x04
    static let flagAttestedCredentialData: UInt8 = 0x40

    /// authenticatorData for a registration. Device-bound: the backup-eligible and backed-up bits (0x08, 0x10) are
    /// never set, because the private key never leaves this device.
    static func registrationAuthData(rpId: String, credentialId: Data, publicKey: P256.Signing.PublicKey) -> Data {
        var out = rpIdHash(rpId) + Data([flagUserPresent | flagUserVerified | flagAttestedCredentialData, 0, 0, 0, 0])
        out += Data(count: 16) // AAGUID: all zeros for "none" attestation
        out += Data([UInt8(credentialId.count >> 8), UInt8(credentialId.count & 0xFF)])
        out += credentialId
        out += coseKey(publicKey)
        return out
    }

    /// authenticatorData for an assertion. Sign count is 0, which WebAuthn allows for authenticators that don't count.
    static func assertionAuthData(rpId: String) -> Data {
        rpIdHash(rpId) + Data([flagUserPresent | flagUserVerified, 0, 0, 0, 0])
    }

    static func rpIdHash(_ rpId: String) -> Data {
        Data(SHA256.hash(data: Data(rpId.utf8)))
    }

    /// COSE_Key for ES256: {1: 2 (EC2), 3: -7 (ES256), -1: 1 (P-256), -2: x, -3: y}.
    static func coseKey(_ publicKey: P256.Signing.PublicKey) -> Data {
        let raw = publicKey.rawRepresentation // x || y, 32 bytes each
        var out = Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20])
        out += raw.prefix(32)
        out += Data([0x22, 0x58, 0x20])
        out += raw.suffix(32)
        return out
    }

    /// attestationObject with fmt "none": {fmt, attStmt: {}, authData}.
    static func attestationObject(authData: Data) -> Data {
        var out = Data([0xA3])
        out += cborText("fmt") + cborText("none")
        out += cborText("attStmt") + Data([0xA0])
        out += cborText("authData") + cborBytes(authData)
        return out
    }

    /// clientDataJSON with the key order browsers use: type, challenge, origin, crossOrigin.
    static func clientData(type: String, challenge: String, origin: String) -> Data {
        func q(_ s: String) -> String {
            let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
            return d.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }
        return Data("{\"type\":\(q(type)),\"challenge\":\(q(challenge)),\"origin\":\(q(origin)),\"crossOrigin\":false}".utf8)
    }

    /// ES256 signature over authenticatorData || SHA-256(clientDataJSON), DER encoded as WebAuthn requires.
    /// CryptoKit's signature(for:) hashes its input with SHA-256 itself, which gives that digest.
    static func assertionSignature(_ key: P256.Signing.PrivateKey, authData: Data, clientData: Data) throws -> Data {
        try key.signature(for: authData + Data(SHA256.hash(data: clientData))).derRepresentation
    }

    static func cborText(_ s: String) -> Data {
        precondition(s.utf8.count < 24, "cborText only encodes short literals")
        return Data([0x60 | UInt8(s.utf8.count)]) + Data(s.utf8)
    }

    static func cborBytes(_ d: Data) -> Data {
        if d.count < 24 { return Data([0x40 | UInt8(d.count)]) + d }
        if d.count < 256 { return Data([0x58, UInt8(d.count)]) + d }
        return Data([0x59, UInt8(d.count >> 8), UInt8(d.count & 0xFF)]) + d
    }
}

extension Data {
    /// base64url without padding, the form WebAuthn uses on the wire.
    var b64u: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
