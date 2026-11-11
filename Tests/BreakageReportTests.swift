import Foundation
import Testing
@testable import WinBrowse

struct BreakageReportTests {
    @Test func urlsLoseCredentialsQueriesAndFragments() {
        #expect(BreakageReport.redact(URL(string: "https://user:pw@shop.example/cart?session=abc#pay")) == "https://shop.example/cart")
        #expect(BreakageReport.redact(URL(string: "https://shop.example/search?q=shoes"), keepQuery: true) == "https://shop.example/search?q=shoes")
        #expect(BreakageReport.redact("https://cdn.example/app.js?token=1") == "https://cdn.example/app.js")
        #expect(BreakageReport.redact("inline") == "inline")
    }

    @Test func pageErrorsAreRedactedBeforeTheyLeaveTheDevice() throws {
        let error = PageError(kind: "error", message: "boom", page: "https://a.example/p?id=7", source: "https://a.example/a.js?v=2", line: 3, date: Date(timeIntervalSince1970: 0))
        let report = BreakageReport(url: "https://a.example/p", appVersion: "1.0 (1)", system: "iOS 26.1", userAgent: "UA", desktopSite: false,
                                    protections: ["network"], rulesets: ["easylist"], filterListVersion: "1", extensions: [], compile: nil,
                                    errors: BreakageReport.redact([error]), created: Date(timeIntervalSince1970: 0))
        let json = try #require(String(data: report.json(), encoding: .utf8))

        #expect(!json.contains("id=7") && !json.contains("v=2"))
        #expect(json.contains("\"source\" : \"https://a.example/a.js\""))
        #expect(report.fileName == "winbrowse-report-a.example.json")
    }
}
