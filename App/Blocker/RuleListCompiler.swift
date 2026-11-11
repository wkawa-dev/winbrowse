import Foundation
import WebKit

enum RuleListCompiler {
    static func compile(_ rules: [[String: Any]], _ id: String, store: WKContentRuleListStore) async -> WKContentRuleList? {
        let json = await Task.detached { RuleConverter.json(rules) }.value
        return try? await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json)
    }

    static func compilable(_ rules: ArraySlice<[String: Any]>, with exceptions: [[String: Any]],
                           store: WKContentRuleListStore) async -> (kept: [[String: Any]], rejected: Int, firstError: String?) {
        let json = await Task.detached { RuleConverter.json(Array(rules) + exceptions) }.value
        do {
            _ = try await store.compileContentRuleList(forIdentifier: "ubo-probe", encodedContentRuleList: json)
            return (Array(rules), 0, nil)
        } catch {
            guard rules.count > 1 else { return ([], rules.count, error.localizedDescription) }
            let mid = rules.startIndex + rules.count / 2
            let a = await compilable(rules[rules.startIndex..<mid], with: exceptions, store: store)
            let b = await compilable(rules[mid...], with: exceptions, store: store)
            return (a.kept + b.kept, a.rejected + b.rejected, a.firstError ?? b.firstError ?? error.localizedDescription)
        }
    }
}
