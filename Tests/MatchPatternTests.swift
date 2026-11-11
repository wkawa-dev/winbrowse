import Foundation
import JavaScriptCore
import Testing
@testable import WinBrowse

struct MatchPatternTests {
    static let cases: [(String, String, Bool)] = [
        ("<all_urls>", "https://example.com/", true),
        ("<all_urls>", "winext://sponsorblock/popup.html", false),
        ("*://*/*", "http://a.b.c/x?y", true),
        ("*://*/*", "ftp://a.b/x", false),
        ("https://*.x.com/*", "https://x.com/home", true),
        ("https://*.x.com/*", "https://mobile.x.com/home", true),
        ("https://*.x.com/*", "https://evilx.com/home", false),
        ("https://*.x.com/*", "https://x.com.evil.org/", false),
        ("https://*.x.com/*", "http://x.com/", false),
        ("https://x.com/*", "https://x.com:8443/a", true),
        ("*://*.youtube.com/watch*", "https://m.youtube.com/watch?v=1", true),
        ("*://*.youtube.com/watch*", "https://m.youtube.com/shorts/1", false),
        ("https://example.com/a.b", "https://example.com/aXb", false),
        ("https://example.com/", "https://example.com/page", false),
    ]

    @Test(arguments: cases)
    func patternMatchesLikeChrome(pattern: String, url: String, expected: Bool) {
        #expect(MatchPattern.matches(pattern, URL(string: url)!) == expected)
    }

    @Test func hostPermissionsCoverOnlyWebURLs() {
        #expect(MatchPattern.permits(["https://*.ajay.app/*"], URL(string: "https://sponsor.ajay.app/api/skipSegments")!))
        #expect(!MatchPattern.permits(["https://*.ajay.app/*"], URL(string: "https://example.com/")!))
        #expect(!MatchPattern.permits(["<all_urls>"], URL(string: "file:///etc/hosts")!))
        #expect(!MatchPattern.permits([], URL(string: "https://example.com/")!))
    }

    @Test func javaScriptGuardAgreesWithTheSwiftMatcher() throws {
        let context = try #require(JSContext())
        func guardResult(_ href: String, _ matches: [String], _ exclude: [String] = []) -> Bool {
            context.setObject(["href": href], forKeyedSubscript: "location" as NSString)
            return context.evaluateScript(MatchPattern.jsGuard(matches, exclude: exclude)).toBool()
        }

        for (pattern, url, expected) in Self.cases {
            #expect(guardResult(url, [pattern]) == expected, "\(pattern) on \(url)")
        }
        #expect(!guardResult("https://x.com/i/flow/login", ["https://x.com/*"], ["https://x.com/i/*"]))
        #expect(guardResult("https://x.com/home", ["https://x.com/*"], ["https://x.com/i/*"]))
        #expect(context.exception == nil)
    }
}
