import Foundation

/// Spend for one OpenRouter API key via `GET /api/v1/key`, plus the account balance from
/// `GET /api/v1/credits` (works with a normal key). The key lives in TokenMonitor's own Keychain item.
public struct OpenRouterProvider: UsageProvider {
    public static let keychainAccount = "openrouter-api-key"
    static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!

    public typealias KeyReader = @Sendable () async throws(AppKeychain.Failure) -> String?

    private let transport: HTTPTransport
    private let readKey: KeyReader
    /// Time of response receipt, for relative `Retry-After` deadlines.
    private let clock: @Sendable () -> Date

    public init(
        transport: HTTPTransport,
        readKey: @escaping KeyReader = { () throws(AppKeychain.Failure) in try await AppKeychain.read(account: OpenRouterProvider.keychainAccount) },
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.clock = clock
        self.readKey = readKey
    }

    public func fetch(now: Date) async throws(ProviderFailure) -> UsageSnapshot {
        let key: String?
        do { key = try await readKey() } catch { throw .keychainUnreadable }
        guard let key, !key.isEmpty else { throw .notConfigured("OpenRouter API key") }

        let (data, response) = try await get(Self.keyURL, key: key)
        guard response.statusCode == 200 else { throw HTTPStatus.failure(for: response, now: clock()) }

        var snapshot = try UsageParsers.openRouter(data, now: now)
        snapshot.identity = Fingerprint.of(key)
        // Best effort: the key's own numbers are still worth showing if the balance call fails.
        if let (data, response) = try? await get(Self.creditsURL, key: key), response.statusCode == 200,
           let credits = try? UsageParsers.openRouterCredits(data) {
            snapshot.money?.creditsPurchased = credits.purchased
            snapshot.money?.creditsUsed = credits.used
        }
        return snapshot
    }

    private func get(_ url: URL, key: String) async throws(ProviderFailure) -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do { return try await transport.send(request) } catch { throw HTTPStatus.networkFailure(error) }
    }
}
