import Foundation
import Testing
@testable import WinBrowse

struct ExtensionMessageTests {
    @Test func everyMessageTheShimSendsIsKnownToTheHostAndViceVersa() throws {
        let shim = try AppSource.resource("winext-shim.js")
        let pattern = try NSRegularExpression(pattern: #"(?:call|fireAndForget)\('([a-zA-Z.]+)'"#)
        let sent = Set(pattern.matches(in: shim, range: NSRange(shim.startIndex..., in: shim)).map { m in
            String(shim[Range(m.range(at: 1), in: shim)!])
        })

        #expect(sent == Set(ExtensionMessage.allCases.map(\.rawValue)))
    }

    @Test func contentScriptsCannotDriveTabsScriptingOrTheNetwork() {
        let allowed = Set(ExtensionMessage.allCases.filter(\.contentScriptsMayCall))
        #expect(allowed == [.frameHello, .storageGet, .storageSet, .storageRemove, .storageClear,
                            .runtimeSendMessage, .runtimeConnect, .runtimeOpenOptionsPage, .portPost, .portDisconnect])
    }

    static let dir = URL(fileURLWithPath: "/bundle/sponsorblock", isDirectory: true)

    @Test(arguments: [("icons/logo.png", true), ("/js/content.js", true), ("../sponsorblock-evil/x.js", false),
                      ("../../etc/passwd", false), ("icons/../../xposed/content.js", false), ("", false)])
    func filePathsStayInsideTheExtension(path: String, inside: Bool) {
        #expect((ExtensionFiles.resolve(path, in: Self.dir) != nil) == inside)
    }

    static let manifest: [String: Any] = ["web_accessible_resources": [
        ["resources": ["icons/*.svg", "page-script.js"], "matches": ["https://*.youtube.com/*"]],
    ]]

    @Test func webPagesMayLoadOnlyResourcesTheManifestExposesToThem() {
        let page = URL(string: "https://m.youtube.com/watch?v=1")!
        let load = { (path: String, document: URL?) in
            ExtensionFiles.loadable(path, by: document, extensionId: "sponsorblock", manifest: Self.manifest)
        }

        #expect(load("icons/skip.svg", page))
        #expect(load("page-script.js", page))
        #expect(!load("popup.html", page))
        #expect(!load("icons/skip.png", page))
        #expect(!load("icons/skip.svg", URL(string: "https://example.com/")!))
        #expect(!load("__winext/shim.js", page))
        #expect(load("popup.html", URL(string: "winext://sponsorblock/popup.html")!))
        #expect(!load("popup.html", URL(string: "winext://xposed/options.html")!))
        #expect(load("popup.html", nil))
    }
}
