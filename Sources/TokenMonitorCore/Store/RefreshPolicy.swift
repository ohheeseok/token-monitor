import Foundation

public enum RefreshReason: Sendable {
    case launch, timer, popoverOpened, manual, wake
}

/// Everything the UI needs about one account. Freshness, failure and last good data are independent:
/// an expired login can coexist with a useful (stale) snapshot.
public struct AccountState: Sendable, Codable, Hashable {
    public var lastGood: UsageSnapshot?
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var isRefreshing = false
    public var failure: ProviderFailure?
    public var consecutiveFailures = 0
    /// Next background refresh.
    public var nextDueAt: Date?
    /// Hard cooldown from the server (429 Retry-After). Nothing, not even a manual refresh, goes earlier.
    public var notBefore: Date?

    public init() {}
}

/// Pure scheduling decisions; the store applies them. Starting values, not documented limits.
public struct RefreshPolicy: Sendable {
    public var intervals: [ProviderKind: TimeInterval] = [.claude: 300, .codex: 300, .antigravity: 600, .openRouter: 600]
    public var jitter = 0.2
    /// Opening the popover refreshes data older than this.
    public var popoverStaleness: TimeInterval = 60
    public var backoffBase: TimeInterval = 60
    public var backoffCap: TimeInterval = 1800
    /// Re-check interval for failures that need the user (expired login, missing key, unsupported CLI).
    public var userActionRecheck: TimeInterval = 900

    public init() {}

    public func interval(for kind: ProviderKind) -> TimeInterval { intervals[kind] ?? 600 }

    public func shouldRefresh(_ state: AccountState, reason: RefreshReason, now: Date) -> Bool {
        if state.isRefreshing { return false }
        if let notBefore = state.notBefore, now < notBefore { return false }
        switch reason {
        case .launch, .manual, .wake:
            return true
        case .timer:
            return state.nextDueAt.map { now >= $0 } ?? true
        case .popoverOpened:
            // Opening the popover never shortcuts a failure backoff; only stale-but-healthy data.
            if state.failure != nil, let due = state.nextDueAt, now < due { return false }
            guard let last = state.lastAttemptAt else { return true }
            return now.timeIntervalSince(last) >= popoverStaleness
        }
    }

    /// `random` returns a value in 0..<1 (injected for deterministic tests).
    public func applySuccess(_ snapshot: UsageSnapshot, to state: inout AccountState, kind: ProviderKind, now: Date, random: Double) {
        state.lastGood = snapshot
        state.lastSuccessAt = now
        state.failure = nil
        state.consecutiveFailures = 0
        state.notBefore = nil
        state.nextDueAt = now.addingTimeInterval(jittered(interval(for: kind), random: random))
    }

    public func applyFailure(_ failure: ProviderFailure, to state: inout AccountState, now: Date, random: Double) {
        state.failure = failure
        state.consecutiveFailures += 1
        if let notBefore = state.notBefore, notBefore <= now { state.notBefore = nil }
        switch failure {
        case .rateLimited(let retryAt):
            let until = max(retryAt ?? .distantPast, now.addingTimeInterval(backoff(state.consecutiveFailures)))
            state.notBefore = until
            state.nextDueAt = until.addingTimeInterval(backoffBase * random)
        case .expiredCredentials, .missingCredentials, .notConfigured, .unsupportedVersion,
             .cliUnavailable, .forbidden, .schema:
            state.nextDueAt = now.addingTimeInterval(userActionRecheck)
        case .network, .server, .timedOut, .keychainUnreadable:
            state.nextDueAt = now.addingTimeInterval(jittered(backoff(state.consecutiveFailures), random: random))
        }
    }

    /// Data is stale once it is older than two refresh intervals (or was never fetched).
    public func isStale(_ state: AccountState, kind: ProviderKind, now: Date) -> Bool {
        guard let last = state.lastSuccessAt else { return true }
        return now.timeIntervalSince(last) > 2 * interval(for: kind)
    }

    func backoff(_ failures: Int) -> TimeInterval {
        min(backoffCap, backoffBase * pow(2, Double(max(0, failures - 1))))
    }

    func jittered(_ value: TimeInterval, random: Double) -> TimeInterval {
        value * (1 - jitter + 2 * jitter * random)
    }
}
