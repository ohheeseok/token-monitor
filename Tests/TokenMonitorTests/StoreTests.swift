import Foundation
import Testing
import TokenMonitorCore

@MainActor
@Suite struct UsageStoreTests {
    let claude = AccountConfig(id: "claude-2", kind: .claude, label: "Claude 2", claudeConfigDir: "/tmp/a")
    let window = UsageWindow(id: "session", label: "5h", usedPercent: 40, resetsAt: nil, windowMinutes: 300)

    func makeStore(_ provider: UsageProvider, cache: SnapshotCache? = nil, accounts: [AccountConfig]? = nil) -> UsageStore {
        UsageStore(accounts: accounts ?? [claude], cache: cache, now: { referenceNow }, random: { 0.5 }) { _ in provider }
    }

    @Test func successIsApplied() async {
        let snapshot = UsageSnapshot(windows: [window], fetchedAt: referenceNow)
        let store = makeStore(ImmediateProvider(result: .success(snapshot)))
        await store.refresh(claude.id, reason: .manual)?.value
        let state = store.state(for: claude.id)
        #expect(state.lastGood == snapshot)
        #expect(!state.isRefreshing)
        #expect(state.nextDueAt == referenceNow.addingTimeInterval(300))
    }

    @Test func secondTriggerWhileInFlightIsCoalesced() async {
        let gated = GatedProvider(.success(UsageSnapshot(fetchedAt: referenceNow)))
        let store = makeStore(gated)
        let first = store.refresh(claude.id, reason: .manual)
        #expect(first != nil)
        #expect(store.refresh(claude.id, reason: .manual) == nil)
        while !(await gated.isWaiting) { await Task.yield() }
        await gated.release()
        await first?.value
        #expect(await gated.calls == 1)
    }

    @Test func resultArrivingAfterReconfigurationIsDropped() async {
        let gated = GatedProvider(.success(UsageSnapshot(windows: [window], fetchedAt: referenceNow)))
        let store = makeStore(gated)
        let task = store.refresh(claude.id, reason: .manual)
        while !(await gated.isWaiting) { await Task.yield() }

        var moved = claude
        moved.claudeConfigDir = "/tmp/b" // same id, now a different Claude login
        moved.enabled = false
        store.setAccounts([moved])
        await gated.release()
        await task?.value
        #expect(store.state(for: claude.id).lastGood == nil)
    }

    @Test func renamingKeepsInFlightRequestAndItsResult() async {
        let gated = GatedProvider(.failure(.rateLimited(retryAt: referenceNow.addingTimeInterval(600))))
        let store = makeStore(gated)
        let task = store.refresh(claude.id, reason: .manual)
        while !(await gated.isWaiting) { await Task.yield() }

        var renamed = claude
        renamed.label = "Work"
        store.setAccounts([renamed])
        #expect(store.refresh(claude.id, reason: .manual) == nil) // still coalesced
        await gated.release()
        await task?.value
        #expect(await gated.calls == 1)
        #expect(store.state(for: claude.id).notBefore == referenceNow.addingTimeInterval(600))
    }

    @Test func cacheRestoresSnapshotsOnlyForUnchangedAccounts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SnapshotCache(url: dir.appendingPathComponent("cache.json"))
        let snapshot = UsageSnapshot(windows: [window], fetchedAt: referenceNow)

        let store = makeStore(ImmediateProvider(result: .success(snapshot)), cache: cache)
        await store.refresh(claude.id, reason: .manual)?.value

        #expect(cache.load(accounts: [claude])[claude.id]?.lastGood == snapshot)
        var moved = claude
        moved.claudeConfigDir = "/tmp/other"
        #expect(cache.load(accounts: [moved])[claude.id] == nil)

        let attributes = try FileManager.default.attributesOfItem(atPath: cache.url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func rateLimitCooldownSurvivesRelaunch() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SnapshotCache(url: dir.appendingPathComponent("cache.json"))
        let retryAt = referenceNow.addingTimeInterval(900)

        let store = makeStore(ImmediateProvider(result: .failure(.rateLimited(retryAt: retryAt))), cache: cache)
        await store.refresh(claude.id, reason: .manual)?.value

        let relaunched = makeStore(ImmediateProvider(result: .success(UsageSnapshot(fetchedAt: referenceNow))), cache: cache)
        #expect(relaunched.refresh(claude.id, reason: .launch) == nil)
    }

    @Test func disabledAccountsAreNotRefreshed() {
        var off = claude
        off.enabled = false
        let store = makeStore(ImmediateProvider(result: .success(UsageSnapshot(fetchedAt: referenceNow))), accounts: [off])
        #expect(store.refresh(off.id, reason: .manual) == nil)
    }
}
