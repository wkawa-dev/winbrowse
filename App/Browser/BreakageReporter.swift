import UIKit
import WebKit

@MainActor
enum BreakageReporter {
    static func report(for tab: Tab) -> BreakageReport {
        let info = Bundle.main.infoDictionary ?? [:]
        let host = ExtensionHost.shared
        return BreakageReport(
            url: BreakageReport.redact(tab.url),
            appVersion: "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
            userAgent: host.userAgent,
            desktopSite: tab.desktop,
            protections: tab.protections.names,
            rulesets: ContentBlocker.shared.enabledIds.sorted(),
            filterListVersion: ContentBlocker.shared.version,
            extensions: host.extensions.map { .init(id: $0.id, version: $0.version, enabled: host.isEnabled($0.id)) },
            compile: ContentBlocker.shared.report,
            errors: BreakageReport.redact(tab.webView.map(PageErrors.shared.entries) ?? []),
            created: Date()
        )
    }

    static func share(for tab: Tab) {
        let report = report(for: tab)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(report.fileName)
        guard let data = try? report.json(), (try? data.write(to: file, options: .atomic)) != nil, let top = Dialogs.top else {
            Toasts.shared.show("couldn't create the report")
            return
        }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        }
        top.present(sheet, animated: true)
    }
}
