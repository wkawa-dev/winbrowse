import Foundation
import Testing
import WebKit
@testable import WinBrowse

@MainActor
struct AppFootprintTests {
    static let origins = ["https://fixture.test/", "https://x.com/", "https://m.youtube.com/"]
    static let allowlist = "footprint-allowlist.json"

    @Test func everythingATabExposesToPagesIsInTheReviewedAllowlist() async throws {
        ExtensionHost.shared.load()
        WebViewFactory.shared.rebuildScripts()
        var observed: [String: [String: String]] = [:]
        for origin in Self.origins {
            let base = URL(string: origin)!
            let pristine = PageHarness()
            try await pristine.load(html: "<!doctype html><title>footprint</title>", baseURL: base)
            let tab = PageHarness(configuration: WebViewFactory.shared.configuration(filteredContent: true))
            try await tab.load(html: "<!doctype html><title>footprint</title>", baseURL: base)
            try await Task.sleep(nanoseconds: 300_000_000)
            observed[origin] = try await Footprint.differences(Footprint.take(pristine), Footprint.take(tab))
        }

        if Fixtures.recording { _ = try Fixtures.golden(observed, Self.allowlist) }
        guard let expected = try? Fixtures.json(Self.allowlist) as? [String: [String: String]] else {
            Issue.record("Tests/Fixtures/\(Self.allowlist) is missing: run with WINBROWSE_RECORD=1, then review every entry and document it in docs/footprint.md")
            return
        }
        for origin in Self.origins {
            let unexpected = (observed[origin] ?? [:]).filter { expected[origin]?[$0.key] != $0.value }
            let gone = (expected[origin] ?? [:]).keys.filter { observed[origin]?[$0] == nil }
            #expect(unexpected.isEmpty, "new differences on \(origin):\n\(unexpected.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))")
            #expect(gone.isEmpty, "differences that no longer happen on \(origin), remove them from the allowlist: \(gone.sorted())")
        }
    }
}
