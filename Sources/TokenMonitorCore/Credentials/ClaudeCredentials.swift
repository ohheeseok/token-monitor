import CryptoKit
import Foundation

/// Read-only access to the OAuth credential that Claude Code stores for a config directory.
///
/// Claude Code (2.1.x) names its Keychain item `Claude Code-credentials` for the default profile and
/// `Claude Code-credentials-<first 8 hex of sha256(NFC(configDir))>` when `CLAUDE_CONFIG_DIR` is set;
/// the account is `$USER`. The item's ACL trusts `/usr/bin/security`, so reading through that tool
/// does not trigger a Keychain prompt. We never write, refresh or delete these credentials.
public enum ClaudeCredentials {
    public static let baseService = "Claude Code-credentials"

    public struct Credential: Sendable {
        public let accessToken: String
        public let expiresAt: Date?
        public let subscriptionType: String?
        public let source: String

        package init(accessToken: String, expiresAt: Date?, subscriptionType: String?, source: String) {
            self.accessToken = accessToken
            self.expiresAt = expiresAt
            self.subscriptionType = subscriptionType
            self.source = source
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        case notFound
        case unreadable(exitCode: Int32)
        case malformed
    }

    public static var keychainAccount: String {
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        return user.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil ? user : "claude-code-user"
    }

    /// `nil` configDir means the default profile (`~/.claude` with no `CLAUDE_CONFIG_DIR`).
    public static func serviceName(configDir: String?) -> String {
        guard let configDir else { return baseService }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(baseService)-\(hex.prefix(8))"
    }

    /// Spellings of a config dir that Claude Code may have hashed, most likely first.
    public static func candidateSpellings(for configDir: String) -> [String] {
        let expanded = (configDir as NSString).expandingTildeInPath
        let trimmed = expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
        let resolved = (trimmed as NSString).resolvingSymlinksInPath
        var seen = Set<String>()
        return [configDir, expanded, trimmed, resolved].filter { seen.insert($0).inserted }
    }

    /// Finds the Keychain service that exists for this profile without reading the secret.
    public static func locateService(configDir: String?) async -> String? {
        let services = configDir.map { candidateSpellings(for: $0).map { serviceName(configDir: $0) } }
            ?? [baseService]
        for service in services where await itemExists(service: service) {
            return service
        }
        return nil
    }

    static func itemExists(service: String) async -> Bool {
        let result = try? await ProcessRunner.run(
            Executables.security,
            arguments: ["find-generic-password", "-s", service, "-a", keychainAccount],
            timeout: .seconds(10)
        )
        return result?.exitCode == 0
    }

    public static func read(configDir: String?) async throws(Failure) -> Credential {
        if let service = await locateService(configDir: configDir) {
            let result: ProcessResult
            do {
                result = try await ProcessRunner.run(
                    Executables.security,
                    arguments: ["find-generic-password", "-s", service, "-a", keychainAccount, "-w"],
                    timeout: .seconds(10)
                )
            } catch {
                throw .unreadable(exitCode: -1)
            }
            guard result.exitCode == 0, !result.timedOut else { throw .unreadable(exitCode: result.exitCode) }
            return try parse(result.stdout, source: "keychain:\(service)")
        }
        // Only when no Keychain item exists at all: Claude Code's plaintext fallback file.
        let dir = (configDir ?? "~/.claude" as String)
        let file = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: file) else { throw .notFound }
        return try parse(data, source: "file")
    }

    package static func parse(_ data: Data, source: String) throws(Failure) -> Credential {
        struct Payload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String?
                let expiresAt: Double?
                let subscriptionType: String?
            }
            let claudeAiOauth: OAuth?
        }
        guard let oauth = (try? JSONDecoder().decode(Payload.self, from: data))?.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty
        else { throw .malformed }
        return Credential(
            accessToken: token,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: oauth.subscriptionType,
            source: source
        )
    }
}
