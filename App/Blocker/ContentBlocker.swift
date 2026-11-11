import Foundation
import os
import WebKit

@MainActor
final class ContentBlocker: ObservableObject {
    static let shared = ContentBlocker()

    struct Ruleset: Identifiable, Hashable {
        let id: String
        let name: String
        let group: String
        let defaultOn: Bool
        let networkRules: Int
        let cosmetic: Int
    }

    @Published private(set) var rulesets: [Ruleset] = []
    @Published private(set) var status = "idle"
    @Published private(set) var compiling = false
    @Published private(set) var activeRuleCount = 0
    @Published private(set) var report: CompileReport?
    private let log = Logger(subsystem: "dev.winbrowse.browser", category: "blocker")
    @Published var enabledIds: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabledIds).sorted(), forKey: "ubo.rulesets") }
    }
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "ubo.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "ubo.enabled") }
    }

    private(set) var lists: [WKContentRuleList] = []
    var root: URL { UBOAssets.root }

    private init() {
        enabledIds = Set(UserDefaults.standard.stringArray(forKey: "ubo.rulesets") ?? [])
        loadDetails()
        if UserDefaults.standard.stringArray(forKey: "ubo.rulesets") == nil {
            enabledIds = Set(rulesets.filter(\.defaultOn).map(\.id))
        }
    }

    var version: String { (try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?" }

    private func loadDetails() {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("rulesets/ruleset-details.json")),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        rulesets = arr.compactMap { r in
            guard let id = r["id"] as? String, id != "ubol-tests", id != "ublock-experimental" else { return nil }
            let rules = (r["rules"] as? [String: Any])?["total"] as? Int ?? 0
            let css = r["css"] as? [String: Any]
            let langs = (r["lang"] as? String)?.split(separator: " ").map(String.init) ?? []
            let regionalDefault = r["group"] as? String == "regions" && langs.contains(lang)
            return Ruleset(id: id, name: r["name"] as? String ?? id, group: r["group"] as? String ?? "other",
                           defaultOn: (r["enabled"] as? Bool ?? false) || id == "adguard-mobile" || regionalDefault,
                           networkRules: rules, cosmetic: (css?["generic"] as? Int ?? 0) + (css?["specific"] as? Int ?? 0))
        }
    }

    func prepare() async -> [WKContentRuleList] {
        guard enabled else { lists = []; activeRuleCount = 0; report = nil; return [] }
        let ids = enabledIds.sorted()
        let sig = "ubo-\(version)-\(RuleConverter.revision)-" + ids.joined(separator: ",").djb2
        let store = WKContentRuleListStore.default()!
        if let cached = await cachedLists(sig, store: store) { return cached }

        compiling = true
        status = "compiling filter lists…"
        let rootURL = root
        let conversion = await Task.detached(priority: .userInitiated) { RuleConverter.convert(root: rootURL, ids: ids) }.value
        var report = CompileReport(dropped: conversion.dropped)
        let exceptions = await RuleListCompiler.compilable(conversion.allows[...], with: [], store: store)
        report.rejectedExceptions = exceptions.rejected
        report.firstRejection = exceptions.firstError
        let per = max(10_000, RuleConverter.maxRulesPerList - exceptions.kept.count)
        var out: [WKContentRuleList] = []
        for start in stride(from: 0, to: max(conversion.blocks.count, 1), by: per) {
            status = "compiling filter lists… \(report.converted.formatted()) rules"
            let chunk = conversion.blocks[start..<min(conversion.blocks.count, start + per)]
            let id = "\(sig)-\(out.count)"
            if let l = await RuleListCompiler.compile(Array(chunk) + exceptions.kept, id, store: store) {
                out.append(l)
                report.converted += chunk.count
                continue
            }
            let blocks = await RuleListCompiler.compilable(chunk, with: exceptions.kept, store: store)
            report.rejected += blocks.rejected
            report.firstRejection = report.firstRejection ?? blocks.firstError
            if let l = await RuleListCompiler.compile(blocks.kept + exceptions.kept, id, store: store) {
                out.append(l)
                report.converted += blocks.kept.count
            }
        }
        report.converted += exceptions.kept.count
        report.lists = out.count
        if report.rejected + report.rejectedExceptions > 0 {
            log.error("WebKit rejected \(report.rejected) block and \(report.rejectedExceptions) exception rules: \(report.firstRejection ?? "", privacy: .public)")
        }
        UserDefaults.standard.set(out.count, forKey: "ubo.compiled.\(sig)")
        UserDefaults.standard.set(try? JSONEncoder().encode(report), forKey: "ubo.report.\(sig)")
        if let old = await store.availableIdentifiers() {
            for id in old where id.hasPrefix("ubo-") && !id.hasPrefix(sig) { try? await store.removeContentRuleList(forIdentifier: id) }
        }
        finish(out, report)
        compiling = false
        return out
    }

    private func cachedLists(_ sig: String, store: WKContentRuleListStore) async -> [WKContentRuleList]? {
        let count = UserDefaults.standard.integer(forKey: "ubo.compiled.\(sig)")
        guard count > 0, let data = UserDefaults.standard.data(forKey: "ubo.report.\(sig)"),
              let saved = try? JSONDecoder().decode(CompileReport.self, from: data) else { return nil }
        var cached: [WKContentRuleList] = []
        for i in 0..<count {
            guard let l = try? await store.contentRuleList(forIdentifier: "\(sig)-\(i)") else { return nil }
            cached.append(l)
        }
        finish(cached, saved)
        return cached
    }

    private func finish(_ out: [WKContentRuleList], _ report: CompileReport) {
        lists = out
        self.report = report
        activeRuleCount = report.converted
        status = "\(report.converted.formatted()) network rules"
    }
}
