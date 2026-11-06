import Foundation

/// Codex usage through the documented `codex app-server` method `account/rateLimits/read`.
/// Codex owns its credentials; we start the server, ask once, and stop it.
public struct CodexProvider: UsageProvider {
    public init() {}

    public func fetch(now: Date) async throws(ProviderFailure) -> UsageSnapshot {
        guard let codex = Executables.find("codex") else { throw .cliUnavailable("codex") }
        let rpc = JSONRPCProcess(executable: codex, arguments: ["app-server"])
        defer { rpc.stop() }
        let data: Data
        do {
            try rpc.start()
            _ = try await rpc.request(
                "initialize",
                params: ["clientInfo": ["name": "token-monitor", "version": "0.1.0"]],
                timeout: .seconds(15)
            )
            rpc.notify("initialized")
            data = try await rpc.request("account/rateLimits/read", timeout: .seconds(15))
        } catch {
            switch error {
            case .launchFailed: throw .cliUnavailable("codex app-server failed to start")
            case .timedOut: throw .timedOut
            case .exited: throw .cliUnavailable("codex app-server exited")
            case .rpcError(let code, let message):
                throw message.localizedCaseInsensitiveContains("auth") ? .missingCredentials : .server(status: code ?? 0)
            }
        }
        var snapshot = try UsageParsers.codex(data, now: now)
        if let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let accountID = body["accountId"] as? String {
            snapshot.identity = Fingerprint.of(accountID)
        }
        return snapshot
    }
}

/// Antigravity quota through `agy -p /usage`. Versions before 1.4.12 send `/usage` to the model as a
/// prompt and spend quota, so they are refused before execution. agy updates itself often, so later
/// 1.x versions are accepted (1.4.12 and 1.5.2 checked by hand); if one ever replies as a prompt,
/// the provider disables itself for the rest of the app session. A new major version is refused.
public struct AntigravityProvider: UsageProvider {
    public static let minimumVersion = [1, 4, 12]
    static let tripped = Flag()

    public init() {}

    public func fetch(now: Date) async throws(ProviderFailure) -> UsageSnapshot {
        guard !Self.tripped.isSet else { throw .unsupportedVersion("agy answered /usage as a prompt; disabled until restart") }
        guard let agy = Executables.find("agy") else { throw .cliUnavailable("agy") }
        var env = ProcessInfo.processInfo.environment
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"

        let version = try await run(agy, ["--version"], env: env, timeout: .seconds(5))
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSupported(version) else { throw .unsupportedVersion("agy \(version)") }

        let result = try await run(
            agy, ["-p", "/usage", "--output-format", "json", "--print-timeout", "20s"], env: env, timeout: .seconds(30)
        )
        if result.timedOut { throw .timedOut }
        let stderr = String(decoding: result.stderr, as: UTF8.self).lowercased()
        if result.exitCode != 0, ["not logged in", "not signed in", "sign in", "unauthenticated"].contains(where: stderr.contains) {
            throw .missingCredentials
        }
        if result.exitCode == 0, !result.stdout.isEmpty, !UsageParsers.antigravityAnsweredAsCommand(result.stdout) {
            Self.tripped.set()
            throw .unsupportedVersion("agy \(version) answered /usage as a prompt; disabled until restart")
        }
        return try UsageParsers.antigravity(result.stdout, now: now)
    }

    private func run(_ url: URL, _ args: [String], env: [String: String], timeout: Duration) async throws(ProviderFailure) -> ProcessResult {
        do {
            return try await ProcessRunner.run(url, arguments: args, environment: env, timeout: timeout)
        } catch {
            throw .cliUnavailable("agy failed to launch")
        }
    }

    /// Plain `major.minor.patch` with the same major as `minimumVersion` and not below it.
    /// Anything else (pre-release suffixes, extra text) is refused.
    public static func isSupported(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let numbers = parts as? [Int], numbers[0] == minimumVersion[0] else { return false }
        return numbers.lexicographicallyPrecedes(minimumVersion) == false
    }
}
