import Foundation
import Testing
import WebKit
@testable import WinBrowse

struct RuleConverterTests {
    @Test func convertsDeclarativeNetRequestRulesToWebKitRules() throws {
        let cases = try #require(Fixtures.json("dnr/cases.json") as? [[String: Any]])
        var out: [String: Any] = [:]
        for c in cases {
            let name = try #require(c["name"] as? String)
            let rule = try #require(c["rule"] as? [String: Any])
            out[name] = RuleConverter.rules(from: rule)
        }

        let (actual, expected) = try Fixtures.golden(out, "dnr/cases.webkit.json")
        #expect(actual == expected, "run with WINBROWSE_RECORD=1 to rewrite the expected file, then review the diff")
    }

    @MainActor @Test func webKitCompilesEveryRuleTheConverterEmits() async throws {
        let cases = try #require(Fixtures.json("dnr/cases.webkit.json") as? [String: [[String: Any]]])
        let rules = cases.keys.sorted().flatMap { cases[$0]! }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(WKContentRuleListStore(url: dir))

        let list = try await store.compileContentRuleList(forIdentifier: "converter-cases", encodedContentRuleList: RuleConverter.json(rules))
        #expect(list != nil)
    }

    static let urlFilterCases: [(String, String, Bool)] = [
        ("||example.com^", "https://example.com/ad.js", true),
        ("||example.com^", "https://example.com", true),
        ("||example.com^", "https://cdn.example.com/x", true),
        ("||example.com^", "https://notexample.com/", false),
        ("||example.com^", "https://example.com.evil.org/", false),
        ("||example.com^", "https://example.community/", false),
        ("||example.com/ads/", "https://example.com/ads/1.gif", true),
        ("|https://a.com/x|", "https://a.com/x", true),
        ("|https://a.com/x|", "https://a.com/x/y", false),
        ("/banner/*/img^", "https://a.com/banner/9/img?x=1", true),
        ("/banner/*/img^", "https://a.com/banner/9/imgx", false),
        ("ads.js", "https://a.com/ads.js", true),
        ("ads.js", "https://a.com/adsXjs", false),
        ("a|b", "https://a.com/a|b", true),
        ("a|b", "https://a.com/a", false),
    ]

    @Test(arguments: urlFilterCases)
    func urlFilterRegexMatchesLikeUBlockOrigin(filter: String, url: String, expected: Bool) throws {
        let pattern = try #require(RuleConverter.urlFilterRegex(filter))
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)

        #expect((regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil) == expected, "\(pattern)")
        #expect(!pattern.contains("{"), "WebKit content rules do not support counted repetition")
    }

    @Test func refusesFiltersWebKitCannotMatch() {
        #expect(RuleConverter.urlFilterRegex("||bücher.de^") == nil)
    }
}
