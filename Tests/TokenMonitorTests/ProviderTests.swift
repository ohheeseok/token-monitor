import Foundation
import Testing
import TokenMonitorCore

private func credential(_ token: String) -> ClaudeCredentials.Credential {
    ClaudeCredentials.Credential(accessToken: token, expiresAt: nil, subscriptionType: "team", source: "test")
}

/// Hands out a sequence of credentials, one per read.
private final class CredentialSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]
    init(_ tokens: [String]) { self.tokens = tokens }
    func next() -> ClaudeCredentials.Credential {
        lock.withLock { credential(tokens.count > 1 ? tokens.removeFirst() : tokens[0]) }
    }
}

@Suite struct ClaudeProviderTests {
    let usage = Fixture.data("claude-usage-team")
    let profile = Fixture.data("claude-profile")

    @Test func successAttachesPlanAndIdentity() async throws {
        let transport = FakeTransport([(200, [:], usage), (200, [:], profile)])
        let provider = ClaudeProvider(configDir: nil, transport: transport) { _ in credential("A") }
        let snapshot = try await provider.fetch(now: referenceNow)
        #expect(snapshot.plan == "team")
        #expect(snapshot.windows.count == 1)
        #expect(transport.authorizationHeaders == ["Bearer A", "Bearer A"])
    }

    @Test func expiredTokenWithoutRenewalReportsExpiredAndDoesNotRetry() async {
        let transport = FakeTransport([(401, [:], Data())])
        let provider = ClaudeProvider(configDir: nil, transport: transport) { _ in credential("A") }
        await #expect(throws: ProviderFailure.expiredCredentials) {
            try await provider.fetch(now: referenceNow)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func tokenPastExpiryIsNotSent() async {
        let transport = FakeTransport([(200, [:], usage)])
        let expired = ClaudeCredentials.Credential(
            accessToken: "A", expiresAt: referenceNow.addingTimeInterval(-1), subscriptionType: "pro", source: "test"
        )
        let provider = ClaudeProvider(
            configDir: nil, transport: transport, readCredential: { _ in expired }, clock: { referenceNow }
        )
        await #expect(throws: ProviderFailure.expiredCredentials) {
            try await provider.fetch(now: referenceNow)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func retriesOnceWhenClaudeCodeRenewedTheToken() async throws {
        let transport = FakeTransport([(401, [:], Data()), (200, [:], usage), (200, [:], profile)])
        let sequence = CredentialSequence(["old", "new"])
        let provider = ClaudeProvider(configDir: nil, transport: transport) { _ in sequence.next() }
        _ = try await provider.fetch(now: referenceNow)
        #expect(transport.authorizationHeaders == ["Bearer old", "Bearer new", "Bearer new"])
    }

    @Test func relativeRetryAfterCountsFromResponseReceipt() async {
        let transport = FakeTransport([(429, ["Retry-After": "120"], Data())])
        let receivedAt = referenceNow.addingTimeInterval(10)
        let provider = ClaudeProvider(
            configDir: nil, transport: transport, readCredential: { _ in credential("A") }, clock: { receivedAt }
        )
        await #expect(throws: ProviderFailure.rateLimited(retryAt: receivedAt.addingTimeInterval(120))) {
            try await provider.fetch(now: referenceNow)
        }
    }

    @Test func httpDateRetryAfter() async {
        let transport = FakeTransport([(429, ["Retry-After": "Mon, 02 Nov 2026 06:00:00 GMT"], Data())])
        let provider = ClaudeProvider(configDir: nil, transport: transport) { _ in credential("A") }
        await #expect(throws: ProviderFailure.rateLimited(retryAt: date("2026-11-02T06:00:00Z"))) {
            try await provider.fetch(now: referenceNow)
        }
    }

    @Test func profileIsFetchedOncePerToken() async throws {
        let transport = FakeTransport([(200, [:], usage), (200, [:], profile), (200, [:], usage)])
        let provider = ClaudeProvider(configDir: nil, transport: transport) { _ in credential("A") }
        let first = try await provider.fetch(now: referenceNow)
        let second = try await provider.fetch(now: referenceNow)
        #expect(transport.requests.count == 3)
        #expect(first.identity == second.identity)
    }

    @Test func missingKeychainItemIsMissingCredentials() async {
        let provider = ClaudeProvider(configDir: "/nope", transport: FakeTransport([])) { _ throws(ClaudeCredentials.Failure) in
            throw .notFound
        }
        await #expect(throws: ProviderFailure.missingCredentials) {
            try await provider.fetch(now: referenceNow)
        }
    }
}

@Suite struct OpenRouterProviderTests {
    @Test func noKeyIsNotConfigured() async {
        let provider = OpenRouterProvider(transport: FakeTransport([])) { nil }
        await #expect(throws: ProviderFailure.notConfigured("OpenRouter API key")) {
            try await provider.fetch(now: referenceNow)
        }
    }

    @Test func invalidKeyIsExpiredCredentials() async {
        let provider = OpenRouterProvider(transport: FakeTransport([(401, [:], Data())])) { "sk-or-v1-x" }
        await #expect(throws: ProviderFailure.expiredCredentials) {
            try await provider.fetch(now: referenceNow)
        }
    }

    @Test func identityChangesWithKey() async throws {
        let data = Fixture.data("openrouter-key")
        let a = try await OpenRouterProvider(transport: FakeTransport([(200, [:], data)])) { "key-a" }.fetch(now: referenceNow)
        let b = try await OpenRouterProvider(transport: FakeTransport([(200, [:], data)])) { "key-b" }.fetch(now: referenceNow)
        #expect(a.identity != nil && a.identity != b.identity)
    }

    @Test func addsAccountBalanceFromCredits() async throws {
        let transport = FakeTransport([
            (200, [:], Fixture.data("openrouter-key-unlimited")), (200, [:], Fixture.data("openrouter-credits")),
        ])
        let snapshot = try await OpenRouterProvider(transport: transport) { "key" }.fetch(now: referenceNow)
        #expect(snapshot.money?.creditsRemaining == Decimal(string: "16.809116311"))
        #expect(transport.requests.map(\.url?.path) == ["/api/v1/key", "/api/v1/credits"])
    }

    @Test func balanceFailureKeepsKeyNumbers() async throws {
        let transport = FakeTransport([(200, [:], Fixture.data("openrouter-key")), (429, [:], Data())])
        let snapshot = try await OpenRouterProvider(transport: transport) { "key" }.fetch(now: referenceNow)
        #expect(snapshot.money?.spent == Decimal(string: "17.55"))
        #expect(snapshot.money?.creditsRemaining == nil)
    }
}

@Suite struct AppKeychainTests {
    @Test func refusesSecretsThatWouldNeedShellEscaping() async {
        await #expect(throws: AppKeychain.Failure.unsupportedCharacters) {
            try await AppKeychain.save("abc\" ; delete-keychain", account: "test")
        }
        await #expect(throws: AppKeychain.Failure.unsupportedCharacters) {
            try await AppKeychain.save("", account: "test")
        }
    }
}
