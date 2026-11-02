import Foundation

/// Last good usage per account, so the popover has something to show right after launch.
/// Stores normalized usage only (no tokens), plus server cooldowns so a relaunch cannot bypass a 429.
public struct SnapshotCache: Sendable {
    struct File: Codable {
        static let currentVersion = 1
        var version = File.currentVersion
        var entries: [String: Entry]
    }

    struct Entry: Codable {
        var accountKey: String
        var snapshot: UsageSnapshot?
        var lastSuccessAt: Date?
        var notBefore: Date?
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    public static var standard: SnapshotCache {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenMonitor", isDirectory: true)
        return SnapshotCache(url: dir.appendingPathComponent("cache.json"))
    }

    /// Entries are keyed by account id and only restored if the account's configuration is unchanged.
    public func load(accounts: [AccountConfig]) -> [String: AccountState] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder.cache.decode(File.self, from: data),
              file.version == File.currentVersion
        else { return [:] }
        var states: [String: AccountState] = [:]
        for account in accounts {
            guard let entry = file.entries[account.id], entry.accountKey == Self.key(account) else { continue }
            var state = AccountState()
            state.lastGood = entry.snapshot
            state.lastSuccessAt = entry.lastSuccessAt
            state.notBefore = entry.notBefore
            state.nextDueAt = entry.notBefore
            states[account.id] = state
        }
        return states
    }

    public func save(_ states: [String: AccountState], accounts: [AccountConfig]) {
        var entries: [String: Entry] = [:]
        for account in accounts {
            guard let state = states[account.id] else { continue }
            entries[account.id] = Entry(accountKey: Self.key(account), snapshot: state.lastGood,
                                        lastSuccessAt: state.lastSuccessAt, notBefore: state.notBefore)
        }
        guard let data = try? JSONEncoder.cache.encode(File(entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func key(_ account: AccountConfig) -> String {
        "\(account.kind.rawValue)|\(account.claudeConfigDir ?? "")"
    }
}

extension JSONEncoder {
    static var cache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var cache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
