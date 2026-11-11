import Foundation
import Testing
@testable import WinBrowse

struct FetchPolicyTests {
    static func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = false, expires: Date? = nil) -> HTTPCookie {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "1", .domain: domain, .path: path]
        if secure { p[.secure] = "TRUE" }
        if let expires { p[.expires] = expires }
        return HTTPCookie(properties: p)!
    }

    @Test func sendsOnlyCookiesThatBelongToTheRequestURL() {
        let now = Date()
        let jar = [
            Self.cookie("site", domain: ".ajay.app"),
            Self.cookie("exact", domain: "sponsor.ajay.app"),
            Self.cookie("sibling", domain: "other.ajay.app"),
            Self.cookie("lookalike", domain: ".evilajay.app"),
            Self.cookie("secure", domain: ".ajay.app", secure: true),
            Self.cookie("scoped", domain: ".ajay.app", path: "/admin"),
            Self.cookie("expired", domain: ".ajay.app", expires: now.addingTimeInterval(-60)),
        ]
        let names = { (url: String) in Set(FetchPolicy.cookies(jar, for: URL(string: url)!, now: now).map(\.name)) }

        #expect(names("https://sponsor.ajay.app/api") == ["site", "exact", "secure"])
        #expect(names("http://sponsor.ajay.app/api") == ["site", "exact"])
        #expect(names("https://ajay.app/admin/x") == ["site", "secure", "scoped"])
    }

    @Test func neverExposesSetCookieToExtensionScripts() {
        let response = HTTPURLResponse(url: URL(string: "https://a.example/")!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Set-Cookie": "sid=1", "Content-Type": "application/json"])
        #expect(FetchPolicy.exposedHeaders(response) == ["content-type": "application/json"])
    }

    @Test func redirectsKeepCookiesOnlyOnTheSameHostAndStayWithinPermissions() throws {
        var request = URLRequest(url: URL(string: "https://sponsor.ajay.app/next")!)
        request.setValue("sid=1", forHTTPHeaderField: "Cookie")
        let origin = URL(string: "https://sponsor.ajay.app/start")!
        let allowed = { (url: URL) in url.host?.hasSuffix("ajay.app") == true }

        #expect(FetchPolicy.follow(request, from: origin, allowed: allowed)?.value(forHTTPHeaderField: "Cookie") == "sid=1")
        request.url = URL(string: "https://cdn.ajay.app/next")
        let crossHost = try #require(FetchPolicy.follow(request, from: origin, allowed: allowed))
        #expect(crossHost.value(forHTTPHeaderField: "Cookie") == nil)
        request.url = URL(string: "https://example.com/next")
        #expect(FetchPolicy.follow(request, from: origin, allowed: allowed) == nil)
    }
}
