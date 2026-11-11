import Foundation

@MainActor
final class SiteSettings: ObservableObject {
    static let shared = SiteSettings()

    private static let key = "site.protectionsOff"
    private static let legacyKey = "ubo.disabledSites"

    let config: SiteConfig
    @Published private(set) var userOff: [String: Protections]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, config: SiteConfig = SiteSettings.bundledConfig()) {
        self.defaults = defaults
        self.config = config
        if let raw = defaults.dictionary(forKey: Self.key) as? [String: Int] {
            userOff = raw.mapValues(Protections.init(rawValue:))
        } else {
            userOff = SitePolicy.migrate(trustedSites: defaults.stringArray(forKey: Self.legacyKey) ?? [])
            defaults.set(userOff.mapValues(\.rawValue), forKey: Self.key)
            defaults.removeObject(forKey: Self.legacyKey)
        }
    }

    var policy: SitePolicy {
        var enabled: Protections = [.passkeys]
        if ContentBlocker.shared.enabled { enabled.formUnion(.blocking) }
        if BackgroundMedia.shared.enabled { enabled.insert(.backgroundMedia) }
        return SitePolicy(enabled: enabled, userOff: userOff, bundledOff: config.off)
    }

    func protections(for host: String?, bypass: String? = nil) -> Protections {
        policy.protections(for: host, bypass: bypass)
    }

    func set(_ protection: Protections, on: Bool, for host: String) {
        var p = policy
        p.set(protection, on: on, for: host)
        userOff = p.userOff
        defaults.set(userOff.mapValues(\.rawValue), forKey: Self.key)
    }

    func reset(_ host: String) {
        var p = policy
        p.reset(host)
        userOff = p.userOff
        defaults.set(userOff.mapValues(\.rawValue), forKey: Self.key)
    }

    nonisolated static func bundledConfig() -> SiteConfig {
        guard let url = Bundle.main.url(forResource: "site-config", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .empty }
        do { return try JSONDecoder().decode(SiteConfig.self, from: data) } catch { preconditionFailure("site-config.json is invalid: \(error)") }
    }
}
