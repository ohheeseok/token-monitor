import Foundation
import TokenMonitorCore

/// Fixed data resembling the Orca screenshots, for `--demo` and snapshot rendering.
@MainActor
enum DemoData {
    nonisolated static let now = Date(timeIntervalSince1970: 1_793_600_000)

    static let accounts: [AccountConfig] = [
        AccountConfig(id: "codex", kind: .codex, label: "Codex"),
        AccountConfig(id: "antigravity", kind: .antigravity, label: "Antigravity"),
        AccountConfig(id: "claude-default", kind: .claude, label: "Claude"),
        AccountConfig(id: "claude-2", kind: .claude, label: "Claude 개인", claudeConfigDir: "~/.claude-account2"),
        AccountConfig(id: "openrouter", kind: .openRouter, label: "OpenRouter"),
        AccountConfig(id: "claude-expired", kind: .claude, label: "Claude 예전", claudeConfigDir: "~/.claude-old"),
    ]

    static func snapshot(for account: AccountConfig) -> Result<UsageSnapshot, ProviderFailure> {
        func window(_ id: String, _ label: String, group: String? = nil, used: Double, minutes: Int, resetIn: TimeInterval) -> UsageWindow {
            UsageWindow(id: id, label: label, group: group, usedPercent: used,
                        resetsAt: now.addingTimeInterval(resetIn), windowMinutes: minutes)
        }
        switch account.id {
        case "codex":
            return .success(UsageSnapshot(windows: [
                window("5h", "5h", used: 0, minutes: 300, resetIn: 4 * 3600 + 59 * 60),
                window("wk", "wk", used: 25, minutes: 10080, resetIn: 5 * 86400 + 17 * 3600),
            ], plan: "plus", fetchedAt: now))
        case "antigravity":
            return .success(UsageSnapshot(windows: [
                window("gemini-weekly", "wk", group: "Gemini Models", used: 1.7, minutes: 10080, resetIn: 5 * 86400),
                window("gemini-5h", "5h", group: "Gemini Models", used: 2.5, minutes: 300, resetIn: 4 * 3600 + 59 * 60),
                window("3p-weekly", "wk", group: "Claude and GPT models", used: 0, minutes: 10080, resetIn: 7 * 86400),
                window("3p-5h", "5h", group: "Claude and GPT models", used: 0, minutes: 300, resetIn: 5 * 3600),
                window("argon-weekly", "wk", group: "Gemini 4 Argon", used: 0.8, minutes: 10080, resetIn: 4 * 86400),
            ], fetchedAt: now))
        case "claude-default":
            return .success(UsageSnapshot(windows: [
                window("session", "5h", used: 22, minutes: 300, resetIn: 3 * 3600 + 53 * 60),
            ], plan: "team", fetchedAt: now))
        case "claude-2":
            return .success(UsageSnapshot(windows: [
                window("session", "5h", used: 74, minutes: 300, resetIn: 3 * 3600 + 33 * 60),
                window("weekly", "wk", used: 93, minutes: 10080, resetIn: 2 * 86400 + 2 * 3600),
            ], plan: "pro", fetchedAt: now))
        case "openrouter":
            return .success(UsageSnapshot(money: MoneyUsage(
                currency: "USD", spent: Decimal(string: "23.16")!, limit: nil, remaining: nil, limitReset: nil,
                spentToday: Decimal(string: "0.42")!, spentThisWeek: Decimal(string: "3.10")!, spentThisMonth: Decimal(string: "11.87")!
            ), fetchedAt: now))
        default:
            return .failure(.expiredCredentials)
        }
    }

    static func makeStore() -> UsageStore {
        let store = UsageStore(accounts: accounts, cache: nil, now: { now }, random: { 0.5 }) { account in
            DemoProvider(result: snapshot(for: account))
        }
        return store
    }

    /// Fills the store synchronously enough for rendering: waits for every demo fetch.
    static func populate(_ store: UsageStore) async {
        for account in store.enabledAccounts {
            await store.refresh(account.id, reason: .manual)?.value
        }
    }
}

private struct DemoProvider: UsageProvider {
    let result: Result<UsageSnapshot, ProviderFailure>
    func fetch(now: Date) async throws(ProviderFailure) -> UsageSnapshot { try result.get() }
}
