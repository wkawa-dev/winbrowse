import SwiftUI

/// New-tab page: intentionally blank.
struct StartPage: View {
    @EnvironmentObject var theme: Theme

    var body: some View {
        theme.bg.ignoresSafeArea()
    }
}
