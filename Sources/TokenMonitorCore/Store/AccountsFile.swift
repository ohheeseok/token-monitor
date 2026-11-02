import Foundation

/// The configured accounts, persisted as JSON next to the cache. Missing or unreadable → defaults.
public struct AccountsFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var standard: AccountsFile {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenMonitor", isDirectory: true)
        return AccountsFile(url: dir.appendingPathComponent("accounts.json"))
    }

    public func load() -> [AccountConfig] {
        guard let data = try? Data(contentsOf: url),
              let accounts = try? JSONDecoder().decode([AccountConfig].self, from: data),
              !accounts.isEmpty
        else { return AccountConfig.defaults }
        return accounts
    }

    public func save(_ accounts: [AccountConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(accounts).write(to: url, options: .atomic)
    }
}
