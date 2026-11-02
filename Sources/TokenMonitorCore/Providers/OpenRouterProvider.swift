import Foundation

/// Spend for one OpenRouter API key via `GET /api/v1/key`. The key lives in TokenMonitor's own
/// Keychain item. Account-wide balance (`/credits`) needs a management key and is out of scope for v1.
public struct OpenRouterProvider: UsageProvider {
    public static let keychainAccount = "openrouter-api-key"
    static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!

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

        var request = URLRequest(url: Self.keyURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) } catch { throw HTTPStatus.networkFailure(error) }
        guard response.statusCode == 200 else { throw HTTPStatus.failure(for: response, now: clock()) }

        var snapshot = try UsageParsers.openRouter(data, now: now)
        snapshot.identity = Fingerprint.of(key)
        return snapshot
    }
}
