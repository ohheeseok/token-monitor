import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case codex, claude, antigravity, openRouter
}

/// One configured source of usage data. Claude can have several (one per Claude Code config dir).
public struct AccountConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ProviderKind
    public var label: String
    /// Claude only: the `CLAUDE_CONFIG_DIR` used to log in; nil means the default profile.
    public var claudeConfigDir: String?
    public var enabled: Bool

    public init(id: String, kind: ProviderKind, label: String, claudeConfigDir: String? = nil, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.label = label
        self.claudeConfigDir = claudeConfigDir
        self.enabled = enabled
    }

    public static let defaults: [AccountConfig] = [
        AccountConfig(id: "codex", kind: .codex, label: "Codex"),
        AccountConfig(id: "antigravity", kind: .antigravity, label: "Antigravity"),
        AccountConfig(id: "claude-default", kind: .claude, label: "Claude"),
        AccountConfig(id: "openrouter", kind: .openRouter, label: "OpenRouter"),
    ]
}

/// A rate-limit window expressed as percent used (never "remaining").
public struct UsageWindow: Codable, Sendable, Hashable, Identifiable {
    /// Stable within an account, e.g. `codex:300`, `session`, `weekly:opus`, `gemini-5h`.
    public var id: String
    /// Short label for bars: `5h`, `wk`, `Opus wk`.
    public var label: String
    /// Grouping shown above windows (Antigravity model groups); nil when the provider has none.
    public var group: String?
    /// 0...100, may exceed 100 on overage. Rendering clamps; the value does not.
    public var usedPercent: Double
    public var resetsAt: Date?
    public var windowMinutes: Int?

    public init(id: String, label: String, group: String? = nil, usedPercent: Double, resetsAt: Date?, windowMinutes: Int?) {
        self.id = id
        self.label = label
        self.group = group
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }
}

/// Pay-as-you-go spend. `limit == nil` means no cap is configured (not zero).
public struct MoneyUsage: Codable, Sendable, Hashable {
    public var currency: String
    /// Lifetime spend on this key.
    public var spent: Decimal
    public var limit: Decimal?
    public var remaining: Decimal?
    /// How often the limit resets (`daily`, `weekly`, `monthly`), nil when it never does.
    public var limitReset: String?
    public var spentToday: Decimal?
    public var spentThisWeek: Decimal?
    public var spentThisMonth: Decimal?
    /// Account-wide credits (`/credits`): everything purchased, and everything used by all keys.
    public var creditsPurchased: Decimal?
    public var creditsUsed: Decimal?

    public init(currency: String, spent: Decimal, limit: Decimal?, remaining: Decimal?, limitReset: String? = nil,
                spentToday: Decimal? = nil, spentThisWeek: Decimal? = nil, spentThisMonth: Decimal? = nil,
                creditsPurchased: Decimal? = nil, creditsUsed: Decimal? = nil) {
        self.currency = currency
        self.spent = spent
        self.limit = limit
        self.remaining = remaining
        self.limitReset = limitReset
        self.spentToday = spentToday
        self.spentThisWeek = spentThisWeek
        self.spentThisMonth = spentThisMonth
        self.creditsPurchased = creditsPurchased
        self.creditsUsed = creditsUsed
    }

    /// Account balance left to spend; nil when `/credits` was not available.
    public var creditsRemaining: Decimal? {
        guard let creditsPurchased, let creditsUsed else { return nil }
        return creditsPurchased - creditsUsed
    }

    /// Share of the current limit period that is used. Derived from `limit - remaining`, not from
    /// lifetime `spent`, because the limit may reset while lifetime spend keeps growing.
    public var usedPercent: Double? {
        guard let limit, limit > 0, let remaining else { return nil }
        return NSDecimalNumber(decimal: (limit - remaining) / limit * 100).doubleValue
    }
}

public struct UsageSnapshot: Codable, Sendable, Hashable {
    public var windows: [UsageWindow]
    public var money: MoneyUsage?
    public var plan: String?
    /// Opaque, non-reversible fingerprint of the authenticated account, used to detect that a
    /// config dir / CLI login now belongs to someone else.
    public var identity: String?
    public var fetchedAt: Date

    public init(windows: [UsageWindow] = [], money: MoneyUsage? = nil, plan: String? = nil, identity: String? = nil, fetchedAt: Date) {
        self.windows = windows
        self.money = money
        self.plan = plan
        self.identity = identity
        self.fetchedAt = fetchedAt
    }

    /// The window closest to its limit; used for compact rows and the menu-bar figure.
    public var mostConstrained: UsageWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }
}

public enum ProviderFailure: Error, Sendable, Codable, Hashable {
    /// Nothing to query yet (no API key saved, CLI never logged in).
    case notConfigured(String)
    case cliUnavailable(String)
    case unsupportedVersion(String)
    case missingCredentials
    /// The owner (Claude Code / Codex) must renew the session; we never refresh tokens ourselves.
    case expiredCredentials
    case keychainUnreadable
    case rateLimited(retryAt: Date?)
    case forbidden(String)
    case server(status: Int)
    case network(String)
    case schema(String)
    case timedOut
}
