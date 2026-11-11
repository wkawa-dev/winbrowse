import Foundation

struct PublicSuffixList {
    static let shared: PublicSuffixList = {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { preconditionFailure("missing public_suffix_list.dat") }
        return PublicSuffixList(text)
    }()

    private let rules: Set<String>
    private let wildcards: Set<String>
    private let exceptions: Set<String>

    init(_ text: String) {
        var rules = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let token = line.split(whereSeparator: \.isWhitespace).first, !token.hasPrefix("//") else { continue }
            let rule = Self.ascii(String(token))
            if rule.hasPrefix("!") { exceptions.insert(String(rule.dropFirst())) }
            else if rule.hasPrefix("*.") { wildcards.insert(String(rule.dropFirst(2))) }
            else { rules.insert(rule) }
        }
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
    }

    func publicSuffix(_ host: String) -> String? {
        guard let labels = Self.labels(host) else { return nil }
        return labels.suffix(listedSuffixLength(labels) ?? 1).joined(separator: ".")
    }

    func registrableDomain(_ host: String) -> String? {
        guard let labels = Self.labels(host) else { return nil }
        let count = listedSuffixLength(labels) ?? 1
        guard labels.count > count else { return nil }
        return labels.suffix(count + 1).joined(separator: ".")
    }

    func permits(rpId: String, host: String) -> Bool {
        let rp = Self.ascii(rpId), origin = Self.ascii(host)
        guard rp == origin || origin.hasSuffix("." + rp) else { return false }
        return rp == "localhost" || registrableDomain(rp) != nil
    }

    private func listedSuffixLength(_ labels: [String]) -> Int? {
        var longest: Int?
        for i in labels.indices {
            let candidate = labels[i...].joined(separator: ".")
            if exceptions.contains(candidate) { return labels.count - i - 1 }
            if rules.contains(candidate) { longest = max(longest ?? 0, labels.count - i) }
            if i > 0, wildcards.contains(candidate) { longest = max(longest ?? 0, labels.count - i + 1) }
        }
        return longest
    }

    private static func labels(_ host: String) -> [String]? {
        let labels = ascii(host).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return labels.isEmpty || labels.contains(where: \.isEmpty) ? nil : labels
    }

    static func ascii(_ domain: String) -> String {
        domain.precomposedStringWithCanonicalMapping.lowercased().split(separator: ".", omittingEmptySubsequences: false).map { label in
            label.unicodeScalars.allSatisfy(\.isASCII) ? String(label) : "xn--" + punycode(String(label))
        }.joined(separator: ".")
    }

    static func punycode(_ input: String) -> String {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        let points = input.unicodeScalars.map { Int($0.value) }
        var output = String(String.UnicodeScalarView(input.unicodeScalars.filter(\.isASCII)))
        let basic = output.count
        if basic > 0 { output.append("-") }
        func digit(_ d: Int) -> Character { Character(UnicodeScalar(UInt8(d < 26 ? d + 97 : d + 22))) }
        func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
            var d = first ? delta / damp : delta / 2
            d += d / count
            var k = 0
            while d > (base - tMin) * tMax / 2 { d /= base - tMin; k += base }
            return k + (base - tMin + 1) * d / (d + skew)
        }
        var n = 128, delta = 0, bias = 72, handled = basic
        while handled < points.count {
            let next = points.filter { $0 >= n }.min()!
            delta += (next - n) * (handled + 1)
            n = next
            for c in points {
                if c < n { delta += 1 }
                guard c == n else { continue }
                var q = delta, k = base
                while true {
                    let t = k <= bias ? tMin : min(tMax, k - bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta, handled + 1, handled == basic)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return output
    }
}
