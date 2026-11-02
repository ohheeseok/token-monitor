import AppKit
import Observation
import ServiceManagement
import TokenMonitorCore

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, iconAndPercent
    var id: String { rawValue }
    var title: String { self == .icon ? "아이콘만" : "아이콘 + 가장 높은 사용률" }
}

/// State behind the settings window. Account edits are saved to accounts.json and applied to the
/// store immediately; secrets go to the Keychain through `AppKeychain`.
@MainActor
@Observable
final class SettingsModel {
    enum KeyStatus: Equatable {
        case unknown, missing, saved, checking, verified(String), failed(String)
    }

    enum ClaudeLoginStatus: Equatable {
        case checking, found, missing
    }

    private(set) var accounts: [AccountConfig]
    var openRouterKeyStatus: KeyStatus = .unknown
    var claudeStatus: [String: ClaudeLoginStatus] = [:]
    var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status
    var loginItemError: String?

    private let store: UsageStore
    private let file: AccountsFile
    private let onSaved: () -> Void

    init(store: UsageStore, file: AccountsFile, onSaved: @escaping () -> Void) {
        self.store = store
        self.file = file
        self.onSaved = onSaved
        accounts = store.accounts
    }

    /// Re-reads everything that can change outside the window.
    func refresh() {
        accounts = store.accounts
        loginItemStatus = SMAppService.mainApp.status
        Task { await checkOpenRouterKey() }
        for account in accounts where account.kind == .claude { checkClaudeLogin(account) }
    }

    // MARK: Accounts

    func update(_ account: AccountConfig) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }), accounts[index] != account else { return }
        let sourceChanged = accounts[index].claudeConfigDir != account.claudeConfigDir
        accounts[index] = account
        apply()
        if sourceChanged, account.kind == .claude { checkClaudeLogin(account) }
    }

    func move(_ id: String, by offset: Int) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard accounts.indices.contains(target) else { return }
        accounts.swapAt(index, target)
        apply()
    }

    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        claudeStatus[id] = nil
        apply()
    }

    /// Asks for a Claude Code config folder (the `CLAUDE_CONFIG_DIR` used to log in) and adds it.
    func addClaudeAccount() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "추가"
        panel.message = "CLAUDE_CONFIG_DIR로 로그인한 Claude Code 설정 폴더를 고르세요 (예: ~/.claude-account2)."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let path = url.path
        let isDefault = path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        guard !accounts.contains(where: { $0.kind == .claude && ($0.claudeConfigDir.map(Self.expand) ?? Self.defaultClaudeDir) == path })
        else { return }
        let count = accounts.filter { $0.kind == .claude }.count
        let account = AccountConfig(
            id: "claude-\(UUID().uuidString.prefix(8).lowercased())",
            kind: .claude,
            label: count == 0 ? "Claude" : "Claude \(count + 1)",
            claudeConfigDir: isDefault ? nil : path
        )
        accounts.append(account)
        apply()
        checkClaudeLogin(account)
    }

    func loginCommand(for account: AccountConfig) -> String {
        guard let dir = account.claudeConfigDir else { return "claude" }
        return "CLAUDE_CONFIG_DIR=\"\(Self.expand(dir))\" claude"
    }

    private func checkClaudeLogin(_ account: AccountConfig) {
        claudeStatus[account.id] = .checking
        let dir = account.claudeConfigDir
        Task {
            let found = await ClaudeCredentials.locateService(configDir: dir) != nil
            claudeStatus[account.id] = found ? .found : .missing
        }
    }

    private func apply() {
        try? file.save(accounts)
        store.setAccounts(accounts)
        onSaved()
    }

    static var defaultClaudeDir: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    // MARK: OpenRouter key

    /// Updates presence only; a verified/failed message from a save in this window is kept.
    func checkOpenRouterKey() async {
        let stored = (try? await AppKeychain.read(account: OpenRouterProvider.keychainAccount)) != nil
        if !stored {
            openRouterKeyStatus = .missing
        } else if openRouterKeyStatus == .unknown || openRouterKeyStatus == .missing {
            openRouterKeyStatus = .saved
        }
    }

    /// Saves the key, then verifies it with one request. The key is never displayed back.
    func saveOpenRouterKey(_ raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-or-"), !key.contains(where: \.isWhitespace) else {
            openRouterKeyStatus = .failed("OpenRouter 키 형식(sk-or-…)이 아닙니다.")
            return
        }
        openRouterKeyStatus = .checking
        do {
            try await AppKeychain.save(key, account: OpenRouterProvider.keychainAccount)
        } catch {
            openRouterKeyStatus = .failed("키체인에 저장하지 못했습니다.")
            return
        }
        do throws(ProviderFailure) {
            let snapshot = try await OpenRouterProvider(transport: URLSessionTransport()).fetch(now: Date())
            let spent = snapshot.money.map { UsageFormat.money($0.spent, currency: $0.currency) } ?? "-"
            openRouterKeyStatus = .verified("확인됨 · 사용액 \(spent)")
        } catch {
            openRouterKeyStatus = .failed("저장했지만 확인에 실패했습니다: \(UsageFormat.failure(error, now: Date()))")
        }
        if let account = accounts.first(where: { $0.kind == .openRouter }) {
            store.refresh(account.id, reason: .manual)
        }
    }

    func deleteOpenRouterKey() async {
        await AppKeychain.delete(account: OpenRouterProvider.keychainAccount)
        openRouterKeyStatus = .missing
    }

    // MARK: Launch at login

    /// Registers or unregisters only on the user's explicit toggle; the toggle reflects real status.
    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginItemError = "변경하지 못했습니다: \(error.localizedDescription)"
        }
        loginItemStatus = SMAppService.mainApp.status
    }
}
