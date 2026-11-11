import Foundation
import WebKit

/// uBlock Origin network filtering: uBO's compiled declarativeNetRequest rulesets → WebKit content rule lists.
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
        let lang: String?
    }

    @Published private(set) var rulesets: [Ruleset] = []
    @Published private(set) var status = "idle"
    @Published private(set) var compiling = false
    @Published private(set) var activeRuleCount = 0
    @Published var enabledIds: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabledIds).sorted(), forKey: "ubo.rulesets") }
    }
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "ubo.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "ubo.enabled") }
    }

    /// Sites with uBO switched off (the big power button). Hostnames; subdomains inherit.
    @Published var disabledSites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ubo.disabledSites") ?? []) {
        didSet { UserDefaults.standard.set(Array(disabledSites).sorted(), forKey: "ubo.disabledSites") }
    }

    func isSiteDisabled(_ host: String?) -> Bool {
        guard enabled else { return true }
        guard var h = host?.lowercased(), !h.isEmpty else { return false }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        while true {
            if disabledSites.contains(h) { return true }
            guard let dot = h.firstIndex(of: ".") else { return false }
            h = String(h[h.index(after: dot)...])
        }
    }

    func setSite(_ host: String, disabled: Bool) {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        if disabled { disabledSites.insert(h) } else {
            disabledSites = disabledSites.filter { !(h == $0 || h.hasSuffix("." + $0)) }
        }
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
                           networkRules: rules, cosmetic: (css?["generic"] as? Int ?? 0) + (css?["specific"] as? Int ?? 0),
                           lang: r["lang"] as? String)
        }
    }

    // MARK: - Compile

    /// Compiles (or loads cached) rule lists for the enabled rulesets. Calls back with the lists to install.
    func prepare() async -> [WKContentRuleList] {
        guard enabled else { lists = []; activeRuleCount = 0; return [] }
        let ids = enabledIds.sorted()
        let sig = "ubo-\(version)-\(RuleConverter.revision)-" + ids.joined(separator: ",").djb2
        let store = WKContentRuleListStore.default()!
        // Cached?
        var cached: [WKContentRuleList] = []
        let count = UserDefaults.standard.integer(forKey: "ubo.compiled.\(sig)")
        if count > 0 {
            for i in 0..<count {
                if let l = try? await store.contentRuleList(forIdentifier: "\(sig)-\(i)") { cached.append(l) } else { break }
            }
            if cached.count == count {
                lists = cached
                activeRuleCount = UserDefaults.standard.integer(forKey: "ubo.compiledRules.\(sig)")
                status = "\(activeRuleCount.formatted()) network rules"
                return cached
            }
        }
        compiling = true
        status = "compiling filter lists…"
        let rootURL = root
        let (blocks, allows) = await Task.detached(priority: .userInitiated) { RuleConverter.convert(root: rootURL, ids: ids) }.value
        var out: [WKContentRuleList] = []
        var total = 0
        // Allow rules only cancel blocks within the same list, so every chunk carries all of them.
        let per = max(10_000, RuleConverter.maxRulesPerList - allows.count)
        var pending: [ArraySlice<[String: Any]>] = stride(from: 0, to: max(blocks.count, 1), by: per).map { blocks[$0..<min(blocks.count, $0 + per)] }
        var withAllows = true
        var n = 0
        while !pending.isEmpty {
            let slice = pending.removeFirst()
            let rules = Array(slice) + (withAllows ? allows : [])
            status = "compiling filter lists… \(total.formatted()) rules"
            let json = await Task.detached { RuleConverter.json(rules) }.value
            do {
                if let l = try await store.compileContentRuleList(forIdentifier: "\(sig)-\(n)", encodedContentRuleList: json) {
                    out.append(l); total += rules.count; n += 1
                }
            } catch {
                // Older WebKit (iOS 17) can reject a rule the current one accepts: bisect and drop only the bad piece.
                NSLog("[ubo] chunk of \(slice.count) failed: \(error.localizedDescription)")
                if slice.count > 200 {
                    let mid = slice.startIndex + slice.count / 2
                    pending.insert(contentsOf: [slice[slice.startIndex..<mid], slice[mid..<slice.endIndex]], at: 0)
                } else if slice.count <= 1 && withAllows && out.isEmpty {
                    withAllows = false // the allow rules themselves don't compile: carry on without them
                    pending = stride(from: 0, to: blocks.count, by: per).map { blocks[$0..<min(blocks.count, $0 + per)] }
                } else if slice.count > 1 {
                    pending.insert(contentsOf: slice.map { [$0][...] }, at: 0)
                }
            }
        }
        UserDefaults.standard.set(out.count, forKey: "ubo.compiled.\(sig)")
        UserDefaults.standard.set(total, forKey: "ubo.compiledRules.\(sig)")
        // Drop lists from older signatures.
        if let old = await store.availableIdentifiers() {
            for id in old where id.hasPrefix("ubo-") && !id.hasPrefix(sig) { try? await store.removeContentRuleList(forIdentifier: id) }
        }
        lists = out
        activeRuleCount = total
        compiling = false
        status = "\(total.formatted()) network rules"
        return out
    }
}
