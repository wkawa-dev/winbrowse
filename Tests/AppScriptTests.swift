import CryptoKit
import Foundation
import Testing
import WebKit
@testable import WinBrowse

@MainActor
struct AppScriptTests {
    static let blank = "<!doctype html><title>blank</title>"
    static let xOrigin = URL(string: "https://x.com/")!
    static let polyfills = ["PublicKeyCredential.isConditionalMediationAvailable", "PublicKeyCredential.getClientCapabilities", "PublicKeyCredential.parseCreationOptionsFromJSON",
                            "PublicKeyCredential.parseRequestOptionsFromJSON"]

    let native = FakeNative()

    func appPage(_ modules: AppScripts.Modules = [.media, .passkeys, .xfeed]) -> PageHarness {
        let load = { (name: String) in (try? AppSource.resource("\(name).js")) ?? "" }
        let page = AppScripts.pageSource(modules, channel: "test", load: load)
        let isolated = AppScripts.isolatedSource(modules, channel: "test", load: load)
        return PageHarness(scripts: [
            WKUserScript(source: page, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page),
            WKUserScript(source: isolated, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: AppScripts.world),
        ]) { ucc in
            ucc.addScriptMessageHandler(native, contentWorld: AppScripts.world, name: "winpasskey")
            ucc.add(native, contentWorld: AppScripts.world, name: "winmedia")
            ucc.add(native, contentWorld: AppScripts.world, name: ScriptLog.name)
            ucc.add(native, contentWorld: AppScripts.world, name: PageErrors.name)
        }
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(condition())
    }

    @Test func appScriptsLeaveNoTraceThatFeatureProbesCanSee() async throws {
        let pristine = PageHarness()
        try await pristine.load(html: Self.blank, baseURL: Self.xOrigin)
        let app = appPage()
        try await app.load(html: Self.blank, baseURL: Self.xOrigin)

        let diff = try await Footprint.differences(Footprint.take(pristine), Footprint.take(app))
            .filter { item in !Self.polyfills.contains { item.key.hasPrefix("properties.\($0).") || item.key == "properties.\($0)" } }
        #expect(diff.isEmpty, "\(diff.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))")
        #expect(native.messages(ScriptLog.name).isEmpty, "\(native.messages(ScriptLog.name).map(\.body))")
    }

    @Test func visibilityIsPinnedOnlyAfterThePagePlaysSound() async throws {
        let page = appPage([.media])
        try await page.load(page: "audio")
        let fire = "document.dispatchEvent(new Event('visibilitychange')); return window.seen"

        try await page.eval("window.seen = 0; document.addEventListener('visibilitychange', () => window.seen++)")
        #expect(try await page.eval(fire) as? Int == 1)
        try await page.eval("window.startAudio()")
        try await page.waitFor("!document.getElementById('player').paused")
        #expect(try await page.eval(fire) as? Int == 1)
        #expect(try await page.eval("return document.visibilityState") as? String == "visible")
        try await eventually { native.messages("winmedia").contains { $0.body["state"] as? String == "playing" } }
    }

    @Test func passkeyCreationRoundTripsThroughTheBridge() async throws {
        let key = P256.Signing.PrivateKey()
        let credentialId = Data(repeating: 7, count: 16)
        native.answer = { m, reply in
            let auth = PasskeyCodec.registrationAuthData(rpId: "fixture.test", credentialId: credentialId, publicKey: key.publicKey)
            let clientData = PasskeyCodec.clientData(type: "webauthn.create", challenge: m.body["challenge"] as? String ?? "", origin: "https://fixture.test")
            reply(["id": credentialId.b64u, "clientDataJSON": clientData.b64u, "authenticatorData": auth.b64u,
                   "attestationObject": PasskeyCodec.attestationObject(authData: auth).b64u, "publicKey": key.publicKey.derRepresentation.b64u])
        }
        let page = appPage([.passkeys])
        try await page.load(html: Self.blank)

        let result = try #require(try await page.eval("""
        const cred = await navigator.credentials.create({ publicKey: {
          rp: { name: 'Fixture' }, user: { id: new Uint8Array([1, 2]), name: 'a', displayName: 'A' },
          challenge: new Uint8Array([9, 9, 9]), pubKeyCredParams: [{ type: 'public-key', alg: -7 }] } });
        return { credential: cred instanceof PublicKeyCredential, id: cred.id, rawId: cred.rawId.byteLength,
          type: JSON.parse(new TextDecoder().decode(cred.response.clientDataJSON)).type, json: cred.toJSON().id };
        """) as? [String: Any])
        #expect(result["credential"] as? Bool == true)
        #expect(result["id"] as? String == credentialId.b64u)
        #expect(result["json"] as? String == credentialId.b64u)
        #expect(result["rawId"] as? Int == 16)
        #expect(result["type"] as? String == "webauthn.create")
        let sent = try #require(native.messages("winpasskey").first?.body)
        #expect(sent["challenge"] as? String == Data([9, 9, 9]).b64u)
        #expect((sent["user"] as? [String: Any])?["id"] as? String == Data([1, 2]).b64u)
    }

    @Test func abortingAPendingConditionalRequestRejectsAndCancels() async throws {
        native.answer = { m, reply in reply(m.body["op"] as? String == "get" ? ["pending": true] : nil) }
        let page = appPage([.passkeys])
        try await page.load(html: Self.blank)

        let name = try await page.eval("""
        const c = new AbortController();
        const p = navigator.credentials.get({ mediation: 'conditional', signal: c.signal, publicKey: { challenge: new Uint8Array([1]) } });
        await new Promise((r) => setTimeout(r, 100));
        c.abort();
        try { await p; return 'resolved'; } catch (e) { return e.name; }
        """) as? String
        #expect(name == "AbortError")
        try await eventually { native.messages("winpasskey").contains { $0.body["op"] as? String == "cancel" } }
    }

    @Test func timeoutRejectsAndCancelsThePrompt() async throws {
        var held: [(Any?) -> Void] = []
        native.answer = { m, reply in if m.body["op"] as? String == "get" { held.append(reply) } else { reply(nil) } }
        let page = appPage([.passkeys])
        try await page.load(html: Self.blank)

        let name = try await page.eval("""
        try { await navigator.credentials.get({ publicKey: { challenge: new Uint8Array([1]), timeout: 50 } }); return 'resolved'; }
        catch (e) { return e.name; }
        """) as? String
        #expect(name == "NotAllowedError")
        try await eventually { native.messages("winpasskey").contains { $0.body["op"] as? String == "cancel" } }
        for reply in held { reply(nil) }
    }

    @Test func xTimelineResponsesLosePromotedEntries() async throws {
        let page = appPage([.xfeed])
        try await page.load(html: Self.blank, baseURL: Self.xOrigin)

        let result = try #require(try await page.eval("""
        const body = JSON.stringify({ entries: [{ entryId: 'tweet-1' }, { entryId: 'promoted-tweet-2' },
          { entryId: 'tweet-3', content: { itemContent: { promotedMetadata: {} } } }] });
        const timeline = 'data:application/json;x=/graphql/HomeTimeline,' + encodeURIComponent(body);
        const other = 'data:application/json,' + encodeURIComponent(body);
        const ids = (j) => j.entries.map((e) => e.entryId).join(' ');
        const viaURL = await fetch(new URL(timeline));
        const xhr = await new Promise((resolve) => { const x = new XMLHttpRequest(); x.onload = () => resolve(x.responseText); x.open('GET', timeline); x.send(); });
        return { string: ids(await (await fetch(timeline)).json()), url: ids(await viaURL.clone().json()), keepsURL: viaURL.url === new URL(timeline).href,
          xhr: ids(JSON.parse(xhr)), other: ids(await (await fetch(other)).json()) };
        """) as? [String: Any])
        #expect(result["string"] as? String == "tweet-1")
        #expect(result["url"] as? String == "tweet-1")
        #expect(result["keepsURL"] as? Bool == true)
        #expect(result["xhr"] as? String == "tweet-1")
        #expect(result["other"] as? String == "tweet-1 promoted-tweet-2 tweet-3")
    }

    @Test func pageErrorsReachTheAppWithoutTouchingThePageWorld() async throws {
        let page = appPage([])
        try await page.load(html: Self.blank)

        try await page.eval("""
        setTimeout(() => { throw new Error('boom'); });
        Promise.reject(new Error('nope'));
        const img = document.createElement('img'); img.src = 'https://unreachable.invalid/x.png'; document.body.appendChild(img);
        """)
        try await eventually { native.messages(PageErrors.name).count >= 3 }
        let kinds = Set(native.messages(PageErrors.name).compactMap { $0.body["kind"] as? String })
        let messages = native.messages(PageErrors.name).compactMap { $0.body["message"] as? String }.joined(separator: " | ")
        #expect(kinds == ["error", "rejection", "resource"], "\(messages)")
        #expect(messages.contains("boom") && messages.contains("nope"), "\(messages)")
    }
}
