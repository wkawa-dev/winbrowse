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

    @Test func reportsGoOnlyToAnHTTPSEndpoint() {
        #expect(ReportUpload.endpoint(configured: nil) == nil)
        #expect(ReportUpload.endpoint(configured: "") == nil)
        #expect(ReportUpload.endpoint(configured: "http://reports.example/api/reports") == nil)
        #expect(ReportUpload.endpoint(configured: "https://reports.example/api/reports")?.path == "/api/reports")
    }

    @Test func uploadsCompactJSONWithoutCookies() throws {
        let endpoint = try #require(URL(string: "https://reports.example/api/reports"))
        let request = try ReportUpload.request(for: sample(errors: []), to: endpoint)

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpShouldHandleCookies == false)
        let body = try #require(request.httpBody.map { String(decoding: $0, as: UTF8.self) })
        #expect(!body.contains("\n"))
        #expect(body.contains("\"url\":\"https://shop.example/cart\""))
    }

    @Test func refusesReportsLargerThanTheServerAccepts() throws {
        let endpoint = try #require(URL(string: "https://reports.example/api/reports"))
        let page = PageError(kind: "error", message: String(repeating: "x", count: 500), page: "https://a.example/p", source: "https://a.example/a.js", line: 1, date: Date(timeIntervalSince1970: 0))
        do {
            _ = try ReportUpload.request(for: sample(errors: Array(repeating: page, count: 600)), to: endpoint)
            Issue.record("a report over the limit was accepted")
        } catch ReportUpload.Failure.tooLarge {}
    }

    private func sample(errors: [PageError]) -> BreakageReport {
        BreakageReport(url: "https://shop.example/cart", appVersion: "1.0 (1)", system: "iOS 26.1", userAgent: "UA", desktopSite: false,
                       protections: ["network"], rulesets: ["easylist"], filterListVersion: "1", extensions: [], compile: nil,
                       errors: errors, created: Date(timeIntervalSince1970: 0))
    }
}
