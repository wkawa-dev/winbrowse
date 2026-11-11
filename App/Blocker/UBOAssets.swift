import Foundation
import WebKit

enum UBOAssets {
    static var root: URL { Bundle.main.url(forResource: "Extensions-bundle", withExtension: nil)!.appendingPathComponent("ubo") }
    static func text(_ rel: String) -> String { (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
    static func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }
}
