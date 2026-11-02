import AppKit
import SwiftUI
import TokenMonitorCore

/// Renders the popover with demo data to PNGs (compact/detail × dark/light) for visual review.
/// The real popover is translucent; snapshots use an opaque background so they are reproducible.
@MainActor
enum SnapshotRenderer {
    static func renderDemo(to directory: URL) async -> Int32 {
        _ = NSApplication.shared
        let store = DemoData.makeStore()
        await DemoData.populate(store)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let actions = PopoverActions(refresh: {}, openDashboard: { _ in }, manageAccounts: {}, quit: {})

        for mode in DisplayMode.allCases {
            for scheme in [ColorScheme.dark, .light] {
                UserDefaults.standard.set(mode.rawValue, forKey: "displayMode")
                let view = PopoverView(store: store, actions: actions, now: { DemoData.now })
                    .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = directory.appendingPathComponent("popover-\(mode.rawValue)-\(scheme == .dark ? "dark" : "light").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
            }
        }
        let settingsFile = AccountsFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("tm-demo-accounts.json"))
        let model = SettingsModel(store: store, file: settingsFile, onSaved: {})
        model.openRouterKeyStatus = .verified("확인됨 · 잔액 $16.81")
        for account in store.accounts where account.kind == .claude {
            model.claudeStatus[account.id] = account.claudeConfigDir == "~/.claude-old" ? .missing : .found
        }
        for scheme in [ColorScheme.dark, .light] {
            let name = "settings-\(scheme == .dark ? "dark" : "light").png"
            write(SettingsView(model: model, previewOnly: true).environment(\.colorScheme, scheme),
                  appearance: scheme == .dark ? .darkAqua : .aqua, to: directory.appendingPathComponent(name))
        }
        return 0
    }

    private static func write(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }
}
