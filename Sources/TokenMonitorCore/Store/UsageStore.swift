import Foundation
import Observation

/// Owns every account's state and the single place where refreshes are decided and applied.
/// All triggers (launch, timer, popover, manual, wake) go through `refresh(_:reason:)`.
@MainActor
@Observable
public final class UsageStore {
    public private(set) var accounts: [AccountConfig]
    public private(set) var states: [String: AccountState] = [:]

    public let policy: RefreshPolicy
    @ObservationIgnored private var providers: [String: UsageProvider] = [:]
    /// Bumped when an account is reconfigured or removed; results from older generations are dropped.
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var timer: Task<Void, Never>?

    @ObservationIgnored private let makeProvider: @MainActor (AccountConfig) -> UsageProvider
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let random: () -> Double
    @ObservationIgnored private let cache: SnapshotCache?

    public init(
        accounts: [AccountConfig],
        policy: RefreshPolicy = RefreshPolicy(),
        cache: SnapshotCache? = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        random: @escaping () -> Double = { Double.random(in: 0..<1) },
        makeProvider: @escaping @MainActor (AccountConfig) -> UsageProvider = { ProviderFactory.make(for: $0) }
    ) {
        self.accounts = accounts
        self.policy = policy
        self.cache = cache
        self.now = now
        self.random = random
        self.makeProvider = makeProvider
        states = cache?.load(accounts: accounts) ?? [:]
        for account in accounts { providers[account.id] = makeProvider(account) }
    }

    public var enabledAccounts: [AccountConfig] { accounts.filter(\.enabled) }

    public func state(for id: String) -> AccountState { states[id] ?? AccountState() }

    public func isStale(_ account: AccountConfig) -> Bool {
        policy.isStale(state(for: account.id), kind: account.kind, now: now())
    }

    // MARK: Refreshing

    /// Starts the background timer and does the launch refresh.
    public func start(tickEvery interval: Duration = .seconds(30)) {
        refreshAll(reason: .launch)
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.refreshAll(reason: .timer)
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func refreshAll(reason: RefreshReason) {
        for account in enabledAccounts { refresh(account.id, reason: reason) }
    }

    /// Returns the in-flight task when a refresh was started (tests await it), nil when skipped.
    @discardableResult
    public func refresh(_ id: String, reason: RefreshReason) -> Task<Void, Never>? {
        guard let account = accounts.first(where: { $0.id == id }), account.enabled,
              let provider = providers[id]
        else { return nil }
        let started = now()
        guard policy.shouldRefresh(state(for: id), reason: reason, now: started) else { return nil }

        let generation = generations[id, default: 0]
        states[id, default: AccountState()].isRefreshing = true
        states[id]?.lastAttemptAt = started

        let task = Task { [weak self, now] in
            let result: Result<UsageSnapshot, ProviderFailure>
            do throws(ProviderFailure) {
                result = .success(try await provider.fetch(now: now()))
            } catch {
                result = .failure(error)
            }
            self?.apply(result, to: account, generation: generation)
        }
        inFlight[id] = task
        return task
    }

    private func apply(_ result: Result<UsageSnapshot, ProviderFailure>, to account: AccountConfig, generation: Int) {
        guard generations[account.id, default: 0] == generation,
              let current = accounts.first(where: { $0.id == account.id }),
              SnapshotCache.key(current) == SnapshotCache.key(account)
        else { return }
        inFlight[account.id] = nil
        var state = states[account.id] ?? AccountState()
        state.isRefreshing = false
        switch result {
        case .success(let snapshot):
            policy.applySuccess(snapshot, to: &state, kind: account.kind, now: now(), random: random())
        case .failure(let failure):
            policy.applyFailure(failure, to: &state, now: now(), random: random())
        }
        states[account.id] = state
        cache?.save(states, accounts: accounts)
    }

    // MARK: Configuration

    /// Replaces the account list. Display-only edits (label, enabled) keep state and any in-flight request;
    /// when an account's source changes (kind or Claude config dir) or it is removed, its request is
    /// cancelled, late results are dropped, and its state starts over.
    public func setAccounts(_ newAccounts: [AccountConfig]) {
        let oldByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: newAccounts.map { ($0.id, $0) })
        for old in accounts where newByID[old.id].map({ SnapshotCache.key($0) != SnapshotCache.key(old) }) ?? true {
            inFlight.removeValue(forKey: old.id)?.cancel()
            generations[old.id, default: 0] += 1
            states[old.id] = nil
            providers[old.id] = nil
        }
        accounts = newAccounts
        for account in newAccounts {
            let old = oldByID[account.id]
            let sourceChanged = old.map { SnapshotCache.key($0) != SnapshotCache.key(account) } ?? true
            if sourceChanged { providers[account.id] = makeProvider(account) }
            if account.enabled, sourceChanged || old?.enabled == false {
                refresh(account.id, reason: .manual)
            }
        }
        cache?.save(states, accounts: accounts)
    }
}
