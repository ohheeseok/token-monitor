import AppKit
import ServiceManagement
import TokenMonitorCore

/// Command-line modes. Run the bundled executable so Keychain identity matches the app:
/// `TokenMonitor.app/Contents/MacOS/TokenMonitor --fetch`.
@MainActor
enum CommandMode {
    nonisolated static let names: Set<String> = ["--set-openrouter-key", "--fetch", "--render-snapshots", "--login-item"]

    nonisolated static func handles(_ args: [String]) -> Bool { args.first.map(names.contains) ?? false }

    static func run(_ args: [String]) async -> Int32 {
        switch args.first {
        case "--set-openrouter-key":
            return await setOpenRouterKey()
        case "--fetch":
            await fetchOnce(claudeDirs: values(of: "--claude-dir", in: args))
            return 0
        case "--render-snapshots":
            guard let dir = args.dropFirst().first else { print("usage: --render-snapshots <dir>"); return 1 }
            return await SnapshotRenderer.renderDemo(to: URL(fileURLWithPath: dir))
        case "--login-item":
            return loginItem(args.dropFirst().first ?? "status")
        default:
            return 64 // EX_USAGE
        }
    }

    static func values(of flag: String, in args: [String]) -> [String] {
        zip(args, args.dropFirst()).filter { $0.0 == flag }.map(\.1)
    }

    /// Reads the key without echo when run in a terminal (or from piped stdin), saves it, then verifies it
    /// against OpenRouter. The key itself is never printed.
    static func setOpenRouterKey() async -> Int32 {
        let input: String?
        if isatty(STDIN_FILENO) != 0 {
            var buffer = [CChar](repeating: 0, count: 512)
            input = readpassphrase("OpenRouter API key (입력 내용은 표시되지 않음): ", &buffer, buffer.count, 0)
                .map { String(cString: $0) }
            for index in buffer.indices { buffer[index] = 0 }
        } else {
            input = readLine(strippingNewline: true)
        }
        guard let key = input?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            print("키가 입력되지 않았습니다.")
            return 1
        }
        guard key.hasPrefix("sk-or-"), !key.contains(where: \.isWhitespace) else {
            print("OpenRouter 키 형식(sk-or-…)이 아닙니다. 저장하지 않았습니다.")
            return 1
        }
        do {
            try await AppKeychain.save(key, account: OpenRouterProvider.keychainAccount)
        } catch {
            print("키체인 저장 실패: \(error)")
            return 1
        }
        do throws(ProviderFailure) {
            let snapshot = try await OpenRouterProvider(transport: URLSessionTransport()).fetch(now: Date())
            let limit = snapshot.money?.limit.map { "$\($0)" } ?? "한도 없음"
            print("저장했습니다. 사용액 $\(snapshot.money?.spent ?? 0) / \(limit)")
            return 0
        } catch {
            print("저장은 했지만 확인 요청이 실패했습니다: \(error)")
            return 1
        }
    }

    /// Runs every provider once and prints normalized windows (no secrets).
    static func fetchOnce(claudeDirs: [String]) async {
        let accounts = AccountsFile.standard.load() + claudeDirs.enumerated().map { index, dir in
            AccountConfig(id: "claude-\(index + 2)", kind: .claude, label: "Claude \(index + 2)", claudeConfigDir: dir)
        }
        for account in accounts {
            let provider = ProviderFactory.make(for: account)
            do throws(ProviderFailure) {
                let snapshot = try await provider.fetch(now: Date())
                let windows = snapshot.windows.map { window in
                    let group = window.group.map { "\($0) / " } ?? ""
                    let reset = window.resetsAt.map { " reset \(Int($0.timeIntervalSinceNow / 60))m" } ?? ""
                    return "\(group)\(window.label) \(String(format: "%.1f", window.usedPercent))%\(reset)"
                }
                let money = snapshot.money.map { " $\($0.spent) / \($0.limit.map { "$\($0)" } ?? "no limit")" } ?? ""
                print("✔ \(account.label) [\(snapshot.plan ?? "-")]\(money) id=\(snapshot.identity ?? "-")")
                windows.forEach { print("    \($0)") }
            } catch {
                print("✘ \(account.label): \(error)")
            }
        }
    }

    static func loginItem(_ action: String) -> Int32 {
        do {
            switch action {
            case "register": try SMAppService.mainApp.register()
            case "unregister": try SMAppService.mainApp.unregister()
            default: break
            }
            print(describe(SMAppService.mainApp.status))
            return 0
        } catch {
            print("failed: \(error) status=\(describe(SMAppService.mainApp.status))")
            return 1
        }
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}
