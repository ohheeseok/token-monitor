import CryptoKit
import Foundation

public protocol UsageProvider: Sendable {
    func fetch(now: Date) async throws(ProviderFailure) -> UsageSnapshot
}

enum Fingerprint {
    /// Short, non-reversible tag for an account identifier or token (never stored in clear).
    static func of(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ProviderFactory {
    public static func make(for account: AccountConfig, transport: HTTPTransport = URLSessionTransport()) -> UsageProvider {
        switch account.kind {
        case .codex: CodexProvider()
        case .claude: ClaudeProvider(configDir: account.claudeConfigDir, transport: transport)
        case .antigravity: AntigravityProvider()
        case .openRouter: OpenRouterProvider(transport: transport)
        }
    }
}
