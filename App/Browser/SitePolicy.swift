import Foundation

struct Protections: OptionSet, Hashable, Codable {
    let rawValue: Int

    static let network = Protections(rawValue: 1 << 0)
    static let cosmetic = Protections(rawValue: 1 << 1)
    static let scriptlets = Protections(rawValue: 1 << 2)
    static let backgroundMedia = Protections(rawValue: 1 << 3)
    static let passkeys = Protections(rawValue: 1 << 4)

    static let blocking: Protections = [.network, .cosmetic, .scriptlets]
    static let all: Protections = [.blocking, .backgroundMedia, .passkeys]

    static let names: [(Protections, String)] = [
        (.network, "network"), (.cosmetic, "cosmetic"), (.scriptlets, "scriptlets"), (.backgroundMedia, "backgroundMedia"), (.passkeys, "passkeys"),
    ]

    init(rawValue: Int) { self.rawValue = rawValue }

    init(names: [String]) {
        self = Protections(Self.names.filter { names.contains($0.1) }.map(\.0))
    }

    var names: [String] { Self.names.filter { contains($0.0) }.map(\.1) }
}

struct SiteConfig: Decodable {
    struct Site: Decodable {
        let domain: String
        let off: [String]?
        let mobileSiteOnTablets: Bool?
        let reason: String
        let `case`: String
    }

    let sites: [Site]

    static let empty = SiteConfig(sites: [])

    var off: [String: Protections] {
        Dictionary(sites.compactMap { s in s.off.map { (s.domain, Protections(names: $0)) } }) { a, _ in a }
    }

    func mobileSiteOnTablets(_ host: String?) -> Bool {
        let table = Dictionary(sites.compactMap { s in s.mobileSiteOnTablets.map { (s.domain, $0) } }) { a, _ in a }
        return SitePolicy.normalize(host).flatMap { SitePolicy.lookup($0, in: table) } ?? false
    }
}

struct SitePolicy: Equatable {
    var enabled: Protections
    var userOff: [String: Protections]
    var bundledOff: [String: Protections]

    func protections(for host: String?, bypass: String? = nil) -> Protections {
        var p = enabled
        guard let h = Self.normalize(host) else { return p }
        p.subtract(off(for: h))
        if Self.normalize(bypass) == h { p.remove(.network) }
        return p
    }

    func off(for host: String) -> Protections {
        Self.lookup(host, in: userOff) ?? Self.lookup(host, in: bundledOff) ?? []
    }

    mutating func set(_ protection: Protections, on: Bool, for host: String) {
        guard let h = Self.normalize(host) else { return }
        var off = off(for: h)
        if on { off.subtract(protection) } else { off.formUnion(protection) }
        var inherited = self
        inherited.userOff[h] = nil
        if off == inherited.off(for: h) { userOff[h] = nil } else { userOff[h] = off }
    }

    mutating func reset(_ host: String) {
        guard let h = Self.normalize(host) else { return }
        userOff[h] = nil
    }

    static func migrate(trustedSites: [String]) -> [String: Protections] {
        Dictionary(trustedSites.compactMap(normalize).map { ($0, Protections.blocking) }) { a, _ in a }
    }

    static func normalize(_ host: String?) -> String? {
        guard var h = host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    static func lookup<Value>(_ host: String, in table: [String: Value]) -> Value? {
        var h = Substring(host)
        while true {
            if let v = table[String(h)] { return v }
            guard let dot = h.firstIndex(of: ".") else { return nil }
            h = h[h.index(after: dot)...]
        }
    }
}
