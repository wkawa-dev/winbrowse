import SwiftUI

struct PasskeysView: View {
    @EnvironmentObject var theme: Theme
    @ObservedObject var passkeys = Passkeys.shared

    var body: some View {
        MetroPage(title: "passkeys") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Sites that support passkeys can save one in WinBrowse when you sign up or add a passkey in their security settings. Each sign-in is unlocked with \(Passkeys.biometryName). Passkeys stay on this device; ones in iCloud Keychain or another password manager can't be used here. Passkeys aren't backed up: re-signing WinBrowse with another Apple ID, or deleting it, may make them unreachable, so keep another way to sign in to each site.")
                        .font(MetroFont.caption).foregroundStyle(theme.subtle)
                    if passkeys.credentials.isEmpty {
                        Text("no passkeys yet").font(.system(size: 19)).foregroundStyle(theme.subtle).padding(.top, 8)
                    }
                    ForEach(passkeys.credentials) { c in
                        HStack {
                            MetroRow(title: c.rpId, value: [c.userName.isEmpty ? c.displayName : c.userName,
                                                            c.lastUsed.map { "used \($0.formatted(.relative(presentation: .named)))" } ?? "created \(c.created.formatted(date: .abbreviated, time: .omitted))"]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                            Button { passkeys.delete(c) } label: {
                                Image(systemName: "trash").foregroundStyle(theme.fg).frame(width: 40, height: 40).contentShape(Rectangle())
                            }
                            .buttonStyle(.tilt)
                            .accessibilityLabel("delete passkey for \(c.rpId)")
                        }
                        .contextMenu { Button(role: .destructive) { passkeys.delete(c) } label: { Label("delete", systemImage: "trash") } }
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 40)
            }
        }
    }
}
