import Foundation

enum ReportUpload {
    enum Failure: Error {
        case notConfigured
        case tooLarge
        case rejected
    }

    static let limit = 256 * 1_024

    static var endpoint: URL? {
        endpoint(configured: Bundle.main.object(forInfoDictionaryKey: "WBReportsURL") as? String)
    }

    static func endpoint(configured text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    static func request(for report: BreakageReport, to endpoint: URL) throws -> URLRequest {
        let body = try report.json(pretty: false)
        guard body.count <= limit else { throw Failure.tooLarge }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.httpBody = body
        return request
    }

    static func send(_ report: BreakageReport) async throws {
        guard let endpoint else { throw Failure.notConfigured }
        let (_, response) = try await session.data(for: request(for: report, to: endpoint))
        guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw Failure.rejected }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()
}
