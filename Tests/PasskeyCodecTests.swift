import CryptoKit
import Foundation
import Security
import Testing
@testable import WinBrowse

struct PasskeyCodecTests {
    let key = P256.Signing.PrivateKey()

    @Test func registrationAuthDataFollowsTheWebAuthnLayout() throws {
        let credentialId = Data((0..<16).map { UInt8($0) })
        let a = PasskeyCodec.registrationAuthData(rpId: "example.com", credentialId: credentialId, publicKey: key.publicKey)

        #expect(a.prefix(32) == Data(SHA256.hash(data: Data("example.com".utf8))))
        #expect(a[32] == 0x45)
        #expect(a[33..<37] == Data(count: 4))
        #expect(a[37..<53] == Data(count: 16))
        #expect(a[53] == 0 && a[54] == 16)
        #expect(a[55..<71] == credentialId)

        var reader = CBORReader(a.suffix(from: 71))
        guard case .map(let cose) = try reader.next() else { Issue.record("COSE key is not a map"); return }
        #expect(reader.atEnd)
        #expect(cose[.int(1)] == .int(2))
        #expect(cose[.int(3)] == .int(-7))
        #expect(cose[.int(-1)] == .int(1))
        guard case .bytes(let x) = cose[.int(-2)], case .bytes(let y) = cose[.int(-3)] else { Issue.record("missing coordinates"); return }
        #expect(try P256.Signing.PublicKey(rawRepresentation: x + y).rawRepresentation == key.publicKey.rawRepresentation)
    }

    @Test(arguments: [16, 300])
    func attestationObjectDecodesAsNoneAttestation(credentialLength: Int) throws {
        let authData = PasskeyCodec.registrationAuthData(rpId: "example.com", credentialId: Data(count: credentialLength), publicKey: key.publicKey)
        var reader = CBORReader(PasskeyCodec.attestationObject(authData: authData))

        #expect(try reader.next() == .map([.text("fmt"): .text("none"), .text("attStmt"): .map([:]), .text("authData"): .bytes(authData)]))
        #expect(reader.atEnd)
    }

    @Test func assertionSignatureVerifiesWithAnIndependentImplementation() throws {
        let authData = PasskeyCodec.assertionAuthData(rpId: "example.com")
        let clientData = PasskeyCodec.clientData(type: "webauthn.get", challenge: "abc", origin: "https://example.com")
        let signature = try PasskeyCodec.assertionSignature(key, authData: authData, clientData: clientData)

        #expect(authData.count == 37 && authData[32] == 0x05)
        let attributes = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        let publicKey = try #require(SecKeyCreateWithData(key.publicKey.x963Representation as CFData, attributes as CFDictionary, nil))
        let signed = authData + Data(SHA256.hash(data: clientData))
        #expect(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, signed as CFData, signature as CFData, nil))
    }

    @Test func clientDataUsesTheBrowserKeyOrderAndUnescapedSlashes() {
        let clientData = PasskeyCodec.clientData(type: "webauthn.create", challenge: "c-_1", origin: "https://a.example")

        #expect(String(decoding: clientData, as: UTF8.self)
            == #"{"type":"webauthn.create","challenge":"c-_1","origin":"https://a.example","crossOrigin":false}"#)
    }
}
