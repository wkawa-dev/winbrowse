import SwiftUI
import WebKit

struct UBlockView: View {
    @EnvironmentObject var theme: Theme
    @EnvironmentObject var store: BrowserStore
    @ObservedObject var blocker = ContentBlocker.shared
    @ObservedObject var sites = SiteSettings.shared
    @State private var pending: Set<String> = []
    @State private var dirty = false

    var body: some View {
        MetroPage(title: "uBlock Origin", subtitle: "filter lists \(blocker.version)") {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let tab = store.active, let host = SitePolicy.normalize(tab.url?.host) {
                        MetroGroup(title: "on \(host)") {
                            ForEach(Self.siteSwitches, id: \.1) { protection, title, detail in
                                MetroToggle(title: title, detail: detail, isOn: Binding(
                                    get: { sites.protections(for: host).contains(protection) },
                                    set: { on in
                                        sites.set(protection, on: on, for: host)
                                        tab.rebuildWebView(loading: tab.url)
                                    }
                                ))
                                .disabled(!sites.policy.enabled.contains(protection))
                            }
                        }
                    }

                    MetroGroup(title: "status") {
                        MetroToggle(title: "uBlock Origin", detail: blocker.status, isOn: $blocker.enabled)
                            .onChange(of: blocker.enabled) { _, _ in dirty = true }
                        if blocker.compiling { MetroDots() }
                        if let r = blocker.report, !blocker.compiling {
                            Text(Self.describe(r)).font(MetroFont.caption).foregroundStyle(theme.subtle)
                        }
                    }

                    let groups = ["default", "ads", "privacy", "annoyances", "regions"]
                    ForEach(groups, id: \.self) { g in
                        let sets = blocker.rulesets.filter { $0.group == g }
                        if !sets.isEmpty {
                            MetroGroup(title: g == "default" ? "built-in" : g) {
                                ForEach(sets) { r in
                                    MetroToggle(title: r.name, detail: "\(r.networkRules.formatted()) network · \(r.cosmetic.formatted()) cosmetic",
                                                isOn: Binding(get: { pending.contains(r.id) }, set: { v in
                                                    if v { pending.insert(r.id) } else { pending.remove(r.id) }
                                                    dirty = true
                                                }))
                                }
                            }
                        }
                    }

                    if !sites.userOff.isEmpty {
                        MetroGroup(title: "sites with their own settings") {
                            ForEach(sites.userOff.keys.sorted(), id: \.self) { host in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(host).font(.system(size: 17)).foregroundStyle(theme.fg)
                                        Text("off: " + Self.siteSwitches.filter { sites.userOff[host]?.contains($0.0) == true }.map(\.1).joined(separator: ", "))
                                            .font(MetroFont.caption).foregroundStyle(theme.subtle)
                                    }
                                    Spacer()
                                    Button("reset") { sites.reset(host) }.foregroundStyle(theme.accent)
                                }
                            }
                        }
                    }
                    Text("uBlock Origin © Raymond Hill, GPLv3. Filter lists compiled by uBO Lite for WebKit: network rules run as WebKit content blockers, cosmetic filters and scriptlets are injected into every frame.")
                        .font(MetroFont.caption).foregroundStyle(theme.subtle)
                    Color.clear.frame(height: 60)
                }
                .padding(.horizontal, 18)
            }
            if dirty {
                HStack { MetroButton(title: blocker.compiling ? "applying…" : "apply changes", filled: true, busy: blocker.compiling) { apply() } }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(theme.chrome.ignoresSafeArea(edges: .bottom))
            }
        }
        .onAppear { pending = blocker.enabledIds }
    }

    static func describe(_ r: CompileReport) -> String {
        var lines = ["\(r.converted.formatted()) WebKit rules in \(r.lists) lists."]
        if r.droppedTotal > 0 {
            let reasons = r.dropped.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \($0.value.formatted())" }.joined(separator: ", ")
            lines.append("\(r.droppedTotal.formatted()) filters need features WebKit lacks (\(reasons)).")
        }
        if r.rejected + r.rejectedExceptions > 0 {
            lines.append("WebKit refused \(r.rejected.formatted()) block rules and \(r.rejectedExceptions.formatted()) exceptions: \(r.firstRejection ?? "no message").")
        }
        return lines.joined(separator: " ")
    }

    static let siteSwitches: [(Protections, String, String)] = [
        (.network, "network blocking", "ads, trackers and malware requests"),
        (.cosmetic, "cosmetic filters", "hide ad slots and banners"),
        (.scriptlets, "scriptlets", "neutralise anti-adblock and ad scripts"),
        (.backgroundMedia, "background play", "keep audio and video playing in the background"),
        (.passkeys, "passkeys", "sign in with passkeys saved in WinBrowse"),
    ]

    private func apply() {
        blocker.enabledIds = pending
        Task {
            await AppBoot.reloadBlocking()
            dirty = false
            store.recycleWebViews()
        }
    }
}
