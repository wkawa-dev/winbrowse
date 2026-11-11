import Combine
import UIKit
import WebKit

@MainActor
enum Dialogs {
    static var top: UIViewController? {
        var vc = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    static func alert(title: String, message: String, done: @escaping () -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in done() })
        guard let top else { return done() }
        top.present(a, animated: true)
    }

    static func confirm(title: String, message: String, completion: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(true) })
        guard let top else { return completion(false) }
        top.present(a, animated: true)
    }

    static func prompt(title: String, message: String, text: String, completion: @escaping (String?) -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addTextField { $0.text = text }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(a.textFields?.first?.text) })
        guard let top else { return completion(nil) }
        top.present(a, animated: true)
    }
}
