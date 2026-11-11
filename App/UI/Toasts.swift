import Combine
import SwiftUI
import WebKit

@MainActor
final class Toasts: ObservableObject {
    static let shared = Toasts()
    @Published var message: String?
    func show(_ s: String) {
        withAnimation(.easeOut(duration: 0.2)) { message = s }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if message == s { withAnimation(.easeOut(duration: 0.2)) { message = nil } }
        }
    }
}
