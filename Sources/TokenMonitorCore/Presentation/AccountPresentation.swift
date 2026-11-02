import Foundation

/// Display-ready description of one account, derived from its config and state. Pure, so the popover
/// views stay dumb and the wording is testable.
public struct AccountPresentation: Sendable, Identifiable, Hashable {
    public enum Severity: Sendable, Hashable { case normal, warning, critical }

    public struct Meter: Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        public var percentText: String
        /// 0...1 for the bar.
        public var fraction: Double
        public var severity: Severity
    }

    /// One line in the detail card: an optional group title, then two fixed meter slots
    /// (short window, weekly window) so columns line up across every account.
    public struct Line: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String?
        public var slots: [Meter?]
    }

    public var id: String
    public var kind: ProviderKind
    public var title: String
    public var plan: String?
    /// Gray text next to the title in compact rows (group of the tightest window, or a status).
    public var subtitle: String?
    /// Compact row: time until the tightest window resets (or its label when unknown).
    public var compactTrailing: String?
    public var compactPercent: String?
    public var compactSeverity: Severity
    /// Detail header: "4h 59m 후 초기화".
    public var resetText: String?
    public var lines: [Line]
    /// OpenRouter: "잔액 $16.81 · 충전 $40.00", "이 키 $23.16 사용 · 한도 없음" and period breakdown.
    public var moneyLines: [String]
    /// Problem shown in place of (or below) data, e.g. "로그인 만료".
    public var statusText: String?
    public var isStale: Bool
    public var isRefreshing: Bool
    public var hasData: Bool

    public static func make(account: AccountConfig, state: AccountState, policy: RefreshPolicy, now: Date) -> AccountPresentation {
        let snapshot = state.lastGood
        let windows = snapshot?.windows ?? []
        let tightest = snapshot?.mostConstrained
        let stale = policy.isStale(state, kind: account.kind, now: now)
        let status = state.failure.map { UsageFormat.failure($0, now: now) }
            ?? (snapshot == nil ? nil : (stale ? UsageFormat.ago(state.lastSuccessAt, now: now) : nil))

        let subtitle: String? = if snapshot == nil || state.failure != nil {
            status ?? (state.isRefreshing ? "불러오는 중…" : nil)
        } else {
            tightest?.group.map { "\(UsageFormat.groupName($0)) · \(UsageFormat.windowName(tightest!))" }
        }

        return AccountPresentation(
            id: account.id,
            kind: account.kind,
            title: account.label,
            plan: snapshot?.plan.map(UsageFormat.plan),
            subtitle: subtitle,
            compactTrailing: tightest.map { window in
                window.resetsAt.map { UsageFormat.countdown(to: $0, now: now) } ?? window.label
            } ?? snapshot?.money.map { money in
                money.creditsRemaining.map { "\(UsageFormat.money($0, currency: money.currency)) 남음" }
                    ?? UsageFormat.money(money.spent, currency: money.currency)
            },
            compactPercent: tightest.map { UsageFormat.percent($0.usedPercent) },
            compactSeverity: tightest.map { UsageFormat.severity($0.usedPercent) } ?? .normal,
            resetText: resetWindow(windows).flatMap(\.resetsAt).map { "\(UsageFormat.countdown(to: $0, now: now)) 후 초기화" },
            lines: lines(windows),
            moneyLines: snapshot?.money.map(moneyLines) ?? [],
            statusText: status,
            isStale: stale && snapshot != nil,
            isRefreshing: state.isRefreshing,
            hasData: snapshot != nil
        )
    }

    /// The reset users care about first: the shortest (5h) window, else the earliest reset.
    static func resetWindow(_ windows: [UsageWindow]) -> UsageWindow? {
        windows.filter { $0.resetsAt != nil }
            .min { ($0.windowMinutes ?? .max, $0.resetsAt!) < ($1.windowMinutes ?? .max, $1.resetsAt!) }
    }

    package static func lines(_ windows: [UsageWindow]) -> [Line] {
        var order: [String?] = []
        var byGroup: [String?: [UsageWindow]] = [:]
        for window in windows where window.id != "limit" {
            if byGroup[window.group] == nil { order.append(window.group) }
            byGroup[window.group, default: []].append(window)
        }
        return order.flatMap { group -> [Line] in
            let windows = (byGroup[group] ?? []).sorted { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
            // A lone weekly window sits in the weekly slot so it lines up under other "wk" meters.
            if windows.count == 1, windows[0].windowMinutes == 10080 {
                return [Line(id: group ?? "line-0", title: group.map(UsageFormat.groupName), slots: [nil, meter(windows[0])])]
            }
            // Two per line (Claude Max can have four ungrouped windows).
            return stride(from: 0, to: windows.count, by: 2).map { start in
                let pair = windows[start..<min(start + 2, windows.count)].map { Optional(meter($0)) }
                return Line(id: "\(group ?? "line")-\(start)", title: start == 0 ? group.map(UsageFormat.groupName) : nil,
                            slots: pair + (pair.count == 1 ? [nil] : []))
            }
        }
    }

    static func meter(_ window: UsageWindow) -> Meter {
        Meter(id: window.id, label: window.label, percentText: UsageFormat.percent(window.usedPercent),
              fraction: min(1, max(0, window.usedPercent / 100)), severity: UsageFormat.severity(window.usedPercent))
    }

    static func moneyLines(_ money: MoneyUsage) -> [String] {
        let spent = UsageFormat.money(money.spent, currency: money.currency)
        let limit = money.limit.map { "한도 \(UsageFormat.money($0, currency: money.currency))" } ?? "한도 없음"
        var lines: [String] = []
        if let remaining = money.creditsRemaining, let purchased = money.creditsPurchased {
            lines.append("잔액 \(UsageFormat.money(remaining, currency: money.currency)) · 충전 \(UsageFormat.money(purchased, currency: money.currency))")
        }
        lines.append("\(lines.isEmpty ? "" : "이 키 ")\(spent) 사용 · \(limit)")
        let periods = [("오늘", money.spentToday), ("이번 주", money.spentThisWeek), ("이번 달", money.spentThisMonth)]
            .compactMap { name, value in value.map { "\(name) \(UsageFormat.money($0, currency: money.currency))" } }
        if !periods.isEmpty { lines.append(periods.joined(separator: " · ")) }
        return lines
    }
}

public enum UsageFormat {
    /// `59m`, `4h 59m`, `5d 17h` (Orca's style).
    public static func countdown(to date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "곧" }
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    public static func percent(_ value: Double) -> String {
        if value > 0, value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    public static func severity(_ percent: Double) -> AccountPresentation.Severity {
        percent >= 90 ? .critical : (percent >= 70 ? .warning : .normal)
    }

    public static func money(_ amount: Decimal, currency: String) -> String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))
    }

    public static func windowName(_ window: UsageWindow) -> String {
        switch window.windowMinutes {
        case 300: "5시간"
        case 10080: "주간"
        default: window.label
        }
    }

    /// "Claude and GPT models" → "Claude and GPT": the group header already says these are models.
    public static func groupName(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\s+models$"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    public static func plan(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pro": "Pro"
        case "max": "Max"
        case "team": "Team"
        case "plus": "Plus"
        case "enterprise": "Enterprise"
        case "free": "Free"
        default: raw.capitalized
        }
    }

    public static func ago(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 60 ? "\(minutes)분 전 데이터" : "\(minutes / 60)시간 전 데이터"
    }

    public static func failure(_ failure: ProviderFailure, now: Date) -> String {
        switch failure {
        case .notConfigured: "설정 필요"
        case .cliUnavailable: "CLI를 찾을 수 없음"
        case .unsupportedVersion: "지원하지 않는 CLI 버전"
        case .missingCredentials: "로그인 필요"
        case .expiredCredentials: "로그인 만료"
        case .keychainUnreadable: "키체인 접근 불가"
        case .rateLimited(let retryAt): retryAt.map { "요청 제한 · \(countdown(to: $0, now: now)) 후 재시도" } ?? "요청 제한"
        case .forbidden: "권한 없음"
        case .server: "서버 오류"
        case .network: "네트워크 오류"
        case .schema: "응답 형식이 바뀜"
        case .timedOut: "응답 시간 초과"
        }
    }
}

public enum MenuBarSummary {
    /// Highest used percent among enabled accounts with fresh data; nil when nothing is fresh.
    /// Stale numbers are left out so the menu bar never shows an old figure as current.
    @MainActor
    public static func peak(store: UsageStore, now: Date) -> Double? {
        store.enabledAccounts.compactMap { account -> Double? in
            let state = store.state(for: account.id)
            guard !store.policy.isStale(state, kind: account.kind, now: now) else { return nil }
            return state.lastGood?.windows.map(\.usedPercent).max()
        }.max()
    }
}
