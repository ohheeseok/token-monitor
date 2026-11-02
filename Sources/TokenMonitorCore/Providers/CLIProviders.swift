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

/// Antigravity quota through `agy -p /usage`. Only CLI versions we have verified answer `/usage`
/// as a command; older ones send it to the model as a prompt and spend quota, so anything
/// unverified is refused before execution. If a verified version ever replies as a prompt anyway,
/// the provider disables itself for the rest of the app session.
public struct AntigravityProvider: UsageProvider {
    public static let verifiedVersions: Set<String> = ["1.4.12"]
    static let tripped = Flag()

    public init() {}

    public func fetch(now: Date) async throws(ProviderFailure) -> UsageSnapshot {
        guard !Self.tripped.isSet else { throw .unsupportedVersion("agy answered /usage as a prompt; disabled until restart") }
        guard let agy = Executables.find("agy") else { throw .cliUnavailable("agy") }
        var env = ProcessInfo.processInfo.environment
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"

        let version = try await run(agy, ["--version"], env: env, timeout: .seconds(5))
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.verifiedVersions.contains(version) else { throw .unsupportedVersion("agy \(version)") }

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
}
