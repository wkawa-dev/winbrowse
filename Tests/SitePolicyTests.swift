import Foundation
import Testing
@testable import WinBrowse

struct SitePolicyTests {
    let policy = SitePolicy(enabled: .all,
                            userOff: ["shop.example": .blocking, "news.example": [.cosmetic]],
                            bundledOff: ["news.example": [.scriptlets], "video.example": [.network]])

    @Test func userChoicesApplyToSubdomainsAndReplaceBundledDefaults() {
        #expect(policy.protections(for: "WWW.Shop.Example") == [.backgroundMedia, .passkeys])
        #expect(policy.protections(for: "m.shop.example") == [.backgroundMedia, .passkeys])
        #expect(policy.protections(for: "news.example") == Protections.all.subtracting(.cosmetic))
        #expect(policy.protections(for: "cdn.video.example") == Protections.all.subtracting(.network))
        #expect(policy.protections(for: "other.example") == .all)
        #expect(policy.protections(for: nil) == .all)
    }

    @Test func globalSwitchesWinOverEverySite() {
        var p = policy
        p.enabled = [.passkeys]
        #expect(p.protections(for: "other.example") == [.passkeys])
        #expect(p.protections(for: "shop.example") == [.passkeys])
    }

    @Test func proceedingPastABlockedPageLiftsOnlyNetworkBlockingForThatSite() {
        #expect(policy.protections(for: "ads.example", bypass: "ads.example") == Protections.all.subtracting(.network))
        #expect(policy.protections(for: "www.ads.example", bypass: "ads.example") == Protections.all.subtracting(.network))
        #expect(policy.protections(for: "other.example", bypass: "ads.example") == .all)
    }

    @Test func settingASiteBackToItsInheritedValueRemovesTheEntry() {
        var p = policy
        p.set(.network, on: false, for: "a.other.example")
        #expect(p.userOff["a.other.example"] == [.network])
        p.set(.network, on: true, for: "a.other.example")
        #expect(p.userOff["a.other.example"] == nil)

        p.set(.scriptlets, on: true, for: "video.example")
        #expect(p.userOff["video.example"] == nil)
        p.set(.network, on: true, for: "video.example")
        #expect(p.userOff["video.example"] == [])
        #expect(p.protections(for: "video.example") == .all)
    }

    @Test func trustedSitesFromEarlierVersionsKeepUBlockOriginOff() {
        #expect(SitePolicy.migrate(trustedSites: ["www.Example.com", "example.com", "news.example"])
            == ["example.com": .blocking, "news.example": .blocking])
    }

    @Test func bundledConfigurationIsValid() throws {
        let data = try Data(contentsOf: AppSource.root.appendingPathComponent("Resources/site-config.json"))
        let config = try JSONDecoder().decode(SiteConfig.self, from: data)
        let repository = AppSource.root.deletingLastPathComponent()

        #expect(config.mobileSiteOnTablets("m.youtube.com"))
        #expect(!config.mobileSiteOnTablets("example.com"))
        for site in config.sites {
            #expect(site.domain == SitePolicy.normalize(site.domain), "\(site.domain) must be lowercase without www.")
            #expect(Protections(names: site.off ?? []).names.count == (site.off ?? []).count, "\(site.domain) names an unknown protection")
            #expect(FileManager.default.fileExists(atPath: repository.appendingPathComponent(site.case).path), "\(site.case) is missing")
        }
    }
}
