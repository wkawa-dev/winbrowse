import Foundation
import Testing
@testable import WinBrowse

struct PublicSuffixListTests {
    static let list = PublicSuffixList(try! String(contentsOf: AppSource.root.appendingPathComponent("Resources/public_suffix_list.dat"), encoding: .utf8))

    @Test func passesTheOfficialTestVectors() throws {
        let text = try Fixtures.string("test_psl.txt")
        let pattern = try NSRegularExpression(pattern: #"checkPublicSuffix\((null|'[^']*'), (null|'[^']*')\);"#)
        var checked = 0
        for line in text.split(separator: "\n").map(String.init) where !line.hasPrefix("//") {
            guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            let value = { (i: Int) -> String? in
                let s = String(line[Range(m.range(at: i), in: line)!])
                return s == "null" ? nil : String(s.dropFirst().dropLast())
            }
            guard let input = value(1) else { continue }
            #expect(Self.list.registrableDomain(input) == value(2).map(PublicSuffixList.ascii), "\(input)")
            checked += 1
        }
        #expect(checked > 60)
    }

    @Test func encodesPunycodeLikeRFC3492() {
        #expect(PublicSuffixList.punycode("bücher") == "bcher-kva")
        #expect(PublicSuffixList.punycode("食狮") == "85x722f")
        #expect(PublicSuffixList.ascii("Bücher.Example") == "xn--bcher-kva.example")
    }

    static let relyingParties: [(String, String, Bool)] = [
        ("example.com", "login.example.com", true),
        ("login.example.com", "login.example.com", true),
        ("com", "example.com", false),
        ("co.uk", "bbc.co.uk", false),
        ("bbc.co.uk", "www.bbc.co.uk", true),
        ("github.io", "someone.github.io", false),
        ("someone.github.io", "someone.github.io", true),
        ("ample.com", "example.com", false),
        ("other.com", "example.com", false),
        ("localhost", "localhost", true),
        ("printer.local", "printer.local", true),
        ("local", "printer.local", false),
        ("github.io", "github.io", false),
    ]

    @Test(arguments: relyingParties)
    func relyingPartyMustBeTheHostOrARegistrableParent(rpId: String, host: String, allowed: Bool) {
        #expect(Self.list.permits(rpId: rpId, host: host) == allowed)
    }
}
