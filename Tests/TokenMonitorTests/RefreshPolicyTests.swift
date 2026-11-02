import Foundation
import Testing
import TokenMonitorCore

@Suite struct RefreshPolicyTests {
    let policy = RefreshPolicy()
    let snapshot = UsageSnapshot(fetchedAt: referenceNow)

    @Test func inFlightRequestsCoalesce() {
        var state = AccountState()
        state.isRefreshing = true
        #expect(!policy.shouldRefresh(state, reason: .manual, now: referenceNow))
    }

    @Test func serverCooldownBlocksEvenManualRefresh() {
        var state = AccountState()
        policy.applyFailure(.rateLimited(retryAt: referenceNow.addingTimeInterval(600)), to: &state, now: referenceNow, random: 0)
        #expect(!policy.shouldRefresh(state, reason: .manual, now: referenceNow.addingTimeInterval(599)))
        #expect(policy.shouldRefresh(state, reason: .manual, now: referenceNow.addingTimeInterval(600)))
        #expect(state.nextDueAt == referenceNow.addingTimeInterval(600))
    }

    @Test func rateLimitWithoutRetryAfterStillBacksOff() {
        var state = AccountState()
        policy.applyFailure(.rateLimited(retryAt: nil), to: &state, now: referenceNow, random: 0)
        #expect(state.notBefore == referenceNow.addingTimeInterval(60))
    }

    @Test func timerWaitsForJitteredInterval() {
        var state = AccountState()
        policy.applySuccess(snapshot, to: &state, kind: .claude, now: referenceNow, random: 0.5)
        #expect(state.nextDueAt == referenceNow.addingTimeInterval(300))
        #expect(!policy.shouldRefresh(state, reason: .timer, now: referenceNow.addingTimeInterval(299)))
        #expect(policy.shouldRefresh(state, reason: .timer, now: referenceNow.addingTimeInterval(300)))

        policy.applySuccess(snapshot, to: &state, kind: .claude, now: referenceNow, random: 0)
        #expect(state.nextDueAt == referenceNow.addingTimeInterval(240))
    }

    @Test func popoverRefreshesOnlyStaleData() {
        var state = AccountState()
        state.lastAttemptAt = referenceNow
        #expect(!policy.shouldRefresh(state, reason: .popoverOpened, now: referenceNow.addingTimeInterval(30)))
        #expect(policy.shouldRefresh(state, reason: .popoverOpened, now: referenceNow.addingTimeInterval(60)))
    }

    @Test func popoverDoesNotShortcutFailureBackoff() {
        var state = AccountState()
        state.lastAttemptAt = referenceNow
        for _ in 0..<5 { policy.applyFailure(.server(status: 503), to: &state, now: referenceNow, random: 0.5) }
        #expect(!policy.shouldRefresh(state, reason: .popoverOpened, now: referenceNow.addingTimeInterval(120)))
        #expect(policy.shouldRefresh(state, reason: .manual, now: referenceNow.addingTimeInterval(120)))
    }

    @Test func transientFailuresBackOffExponentiallyWithCap() {
        var state = AccountState()
        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            policy.applyFailure(.server(status: 503), to: &state, now: referenceNow, random: 0.5)
            delays.append(state.nextDueAt!.timeIntervalSince(referenceNow))
        }
        #expect(delays == [60, 120, 240, 480, 960, 1800, 1800])
    }

    @Test func userActionFailuresRecheckSlowlyAndKeepLastGood() {
        var state = AccountState()
        policy.applySuccess(snapshot, to: &state, kind: .claude, now: referenceNow, random: 0.5)
        policy.applyFailure(.expiredCredentials, to: &state, now: referenceNow, random: 0.5)
        #expect(state.lastGood == snapshot)
        #expect(state.failure == .expiredCredentials)
        #expect(state.nextDueAt == referenceNow.addingTimeInterval(900))
    }

    @Test func successClearsFailureAndCooldown() {
        var state = AccountState()
        policy.applyFailure(.rateLimited(retryAt: referenceNow), to: &state, now: referenceNow, random: 0)
        policy.applySuccess(snapshot, to: &state, kind: .codex, now: referenceNow, random: 0.5)
        #expect(state.failure == nil)
        #expect(state.notBefore == nil)
        #expect(state.consecutiveFailures == 0)
    }

    @Test func staleAfterTwoIntervals() {
        var state = AccountState()
        #expect(policy.isStale(state, kind: .claude, now: referenceNow))
        state.lastSuccessAt = referenceNow
        #expect(!policy.isStale(state, kind: .claude, now: referenceNow.addingTimeInterval(600)))
        #expect(policy.isStale(state, kind: .claude, now: referenceNow.addingTimeInterval(601)))
    }
}
