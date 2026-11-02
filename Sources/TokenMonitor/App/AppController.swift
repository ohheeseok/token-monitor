import AppKit
import SwiftUI
import TokenMonitorCore

/// Owns the status item, the popover and the store. Left click toggles the popover;
/// right click shows a small menu (refresh, quit).
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store: UsageStore
    private let accountsFile = AccountsFile.standard
    private var accountsModified: Date?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(demo: Bool) {
        if demo {
            store = DemoData.makeStore()
        } else {
            store = UsageStore(accounts: accountsFile.load())
        }
        super.init()
        accountsModified = modificationDate(of: accountsFile.url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "사용량")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let actions = PopoverActions(
            refresh: { [weak self] in self?.store.refreshAll(reason: .manual) },
            openDashboard: { [weak self] in self?.openDashboard($0) },
            manageAccounts: { [weak self] in self?.manageAccounts() },
            quit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingController(rootView: PopoverView(store: store, actions: actions))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refreshAll(reason: .wake) }
        }
        store.start()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        reloadAccountsIfEdited()
        store.refreshAll(reason: .popoverOpened)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "새로고침", action: #selector(refreshFromMenu), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "계정 관리…", action: #selector(manageAccountsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "TokenMonitor 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshFromMenu() { store.refreshAll(reason: .manual) }
    @objc private func manageAccountsFromMenu() { manageAccounts() }

    // MARK: Actions

    static let dashboards: [ProviderKind: URL] = [
        .claude: URL(string: "https://claude.ai/settings/usage")!,
        .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!,
        .openRouter: URL(string: "https://openrouter.ai/activity")!,
    ]

    private func openDashboard(_ kind: ProviderKind) {
        guard let url = Self.dashboards[kind] else { return }
        popover.performClose(nil)
        NSWorkspace.shared.open(url)
    }

    /// Until the settings window exists (M4), accounts are edited in accounts.json.
    private func manageAccounts() {
        popover.performClose(nil)
        if !FileManager.default.fileExists(atPath: accountsFile.url.path) {
            try? accountsFile.save(store.accounts)
        }
        NSWorkspace.shared.open(accountsFile.url)
    }

    private func reloadAccountsIfEdited() {
        let modified = modificationDate(of: accountsFile.url)
        guard modified != accountsModified else { return }
        accountsModified = modified
        store.setAccounts(accountsFile.load())
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
