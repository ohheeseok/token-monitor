import Foundation

/// Claude subscription usage for one Claude Code config dir.
///
/// Reads the access token Claude Code stored (never refreshes or rewrites it). On 401 it re-reads the
/// credential once and retries only if Claude Code has since replaced the token; otherwise the owner
/// has to renew the session by running Claude Code.
public actor ClaudeProvider: UsageProvider {
    public typealias CredentialReader = @Sendable (String?) async throws(ClaudeCredentials.Failure) -> ClaudeCredentials.Credential

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    private let configDir: String?
    private let transport: HTTPTransport
    private let readCredential: CredentialReader
    /// Time of response receipt, for relative `Retry-After` deadlines.
    private let clock: @Sendable () -> Date
    /// Identity is looked up once per distinct token, not on every refresh.
    private var identityByToken: (token: String, identity: String?)?

    public init(
        configDir: String?,
        transport: HTTPTransport,
        readCredential: @escaping CredentialReader = { dir throws(ClaudeCredentials.Failure) in try await ClaudeCredentials.read(configDir: dir) },
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configDir = configDir
        self.transport = transport
        self.clock = clock
        self.readCredential = readCredential
    }

    public func fetch(now: Date) async throws(ProviderFailure) -> UsageSnapshot {
        var credential = try await credential()
        var (data, response) = try await get(Self.usageURL, token: credential.accessToken)
        if response.statusCode == 401 {
            let reread = try await self.credential()
            guard reread.accessToken != credential.accessToken else { throw .expiredCredentials }
            credential = reread
            (data, response) = try await get(Self.usageURL, token: credential.accessToken)
        }
        guard response.statusCode == 200 else { throw HTTPStatus.failure(for: response, now: clock()) }

        var snapshot = try UsageParsers.claude(data, now: now)
        snapshot.plan = credential.subscriptionType
        snapshot.identity = await identity(for: credential.accessToken)
        return snapshot
    }

    private func credential() async throws(ProviderFailure) -> ClaudeCredentials.Credential {
        do {
            return try await readCredential(configDir)
        } catch {
            switch error {
            case .notFound: throw .missingCredentials
            case .unreadable: throw .keychainUnreadable
            case .malformed: throw .missingCredentials
            }
        }
    }

    private func get(_ url: URL, token: String) async throws(ProviderFailure) -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenMonitor/0.1", forHTTPHeaderField: "User-Agent")
        do {
            return try await transport.send(request)
        } catch {
            throw HTTPStatus.networkFailure(error)
        }
    }

    /// Fingerprint of the account UUID from /api/oauth/profile. Best effort: nil if the call fails.
    private func identity(for token: String) async -> String? {
        if let cached = identityByToken, cached.token == token { return cached.identity }
        var identity: String?
        if let (data, response) = try? await get(Self.profileURL, token: token), response.statusCode == 200,
           let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let uuid = (body["account"] as? [String: Any])?["uuid"] as? String {
            identity = Fingerprint.of(uuid)
        }
        identityByToken = (token, identity)
        return identity
    }
}
