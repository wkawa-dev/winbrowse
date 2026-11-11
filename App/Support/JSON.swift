import Foundation

func jsonSafe(_ v: Any) -> Any {
    if JSONSerialization.isValidJSONObject([v]) { return v }
    return String(describing: v)
}

func jsonString(_ v: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) else { return "null" }
    return String(data: d, encoding: .utf8) ?? "null"
}

func jsString(_ s: String) -> String {
    jsonString(s).replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}
