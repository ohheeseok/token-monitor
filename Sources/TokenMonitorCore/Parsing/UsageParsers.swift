import Foundation

/// Pure response → model conversions. Lenient about unknown fields and missing windows
/// (these are private, drifting schemas); strict only about what we need to show a number.
package enum UsageParsers {
    typealias JSON = [String: Any]

    static func object(_ data: Data) throws(ProviderFailure) -> JSON {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
            throw .schema("response is not a JSON object")
        }
        return object
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    static func decimal(_ value: Any?) -> Decimal? {
        guard let number = number(value) else { return nil }
        return Decimal(string: String(number))
    }

    // MARK: Claude — GET api.anthropic.com/api/oauth/usage

    package static func claude(_ data: Data, now: Date) throws(ProviderFailure) -> UsageSnapshot {
        let body = try object(data)
        var windows = claudeLimits(body["limits"])
        if windows.isEmpty { windows = claudeLegacyWindows(body) }
        guard !windows.isEmpty || body["limits"] is [Any] || body.keys.contains("five_hour") else {
            throw .schema("no limits or five_hour in Claude usage")
        }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }

    /// `limits: [{kind: session|weekly|weekly_scoped, percent, resets_at, scope: {model: {display_name}}}]`
    ///
    /// The window length comes from `group` (`session` / `weekly`); `kind` varies by plan (`weekly`,
    /// `weekly_all`, `weekly_scoped`). `is_active` is ignored: Pro reports its session limit as
    /// inactive while still carrying a real percent and reset time.
    static func claudeLimits(_ value: Any?) -> [UsageWindow] {
        guard let limits = value as? [JSON] else { return [] }
        return limits.compactMap { limit in
            guard let kind = limit["kind"] as? String, let percent = number(limit["percent"]) else { return nil }
            let resetsAt = Timestamps.parse(limit["resets_at"] as? String)
            let model = ((limit["scope"] as? JSON)?["model"] as? JSON)?["display_name"] as? String
            let group = limit["group"] as? String ?? (kind.hasPrefix("weekly") ? "weekly" : kind)
            switch (group, model) {
            case ("session", nil):
                return UsageWindow(id: "session", label: "5h", usedPercent: percent, resetsAt: resetsAt, windowMinutes: 300)
            case ("weekly", nil):
                return UsageWindow(id: "weekly", label: "wk", usedPercent: percent, resetsAt: resetsAt, windowMinutes: 10080)
            case ("weekly", let model?):
                return UsageWindow(id: "weekly:\(model.lowercased())", label: "\(model) wk",
                                   usedPercent: percent, resetsAt: resetsAt, windowMinutes: 10080)
            default:
                let id = model.map { "\(kind):\($0.lowercased())" } ?? kind
                return UsageWindow(id: id, label: model ?? kind, usedPercent: percent, resetsAt: resetsAt, windowMinutes: nil)
            }
        }
    }

    /// Older shape: `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet` with `utilization`.
    static func claudeLegacyWindows(_ body: JSON) -> [UsageWindow] {
        let fields: [(key: String, id: String, label: String, minutes: Int)] = [
            ("five_hour", "session", "5h", 300),
            ("seven_day", "weekly", "wk", 10080),
            ("seven_day_opus", "weekly:opus", "Opus wk", 10080),
            ("seven_day_sonnet", "weekly:sonnet", "Sonnet wk", 10080),
        ]
        return fields.compactMap { field in
            guard let window = body[field.key] as? JSON, let used = number(window["utilization"]) else { return nil }
            return UsageWindow(id: field.id, label: field.label, usedPercent: used,
                               resetsAt: Timestamps.parse(window["resets_at"] as? String), windowMinutes: field.minutes)
        }
    }

    // MARK: Codex — app-server account/rateLimits/read

    package static func codex(_ data: Data, now: Date) throws(ProviderFailure) -> UsageSnapshot {
        let body = try object(data)
        var snapshots: [(id: String, limit: JSON)] = []
        if let byID = body["rateLimitsByLimitId"] as? JSON, !byID.isEmpty {
            snapshots = byID.keys.sorted().compactMap { key in (byID[key] as? JSON).map { (key, $0) } }
        } else if let single = body["rateLimits"] as? JSON {
            snapshots = [((single["limitId"] as? String) ?? "codex", single)]
        }
        guard !snapshots.isEmpty else { throw .schema("no rateLimits in Codex response") }

        var plan: String?
        var windows: [UsageWindow] = []
        for (limitID, limit) in snapshots {
            plan = plan ?? limit["planType"] as? String
            let prefix = limitID == "codex" ? nil : (limit["limitName"] as? String ?? limitID)
            for key in ["primary", "secondary"] {
                guard let window = limit[key] as? JSON, let used = number(window["usedPercent"]) else { continue }
                let minutes = number(window["windowDurationMins"]).map { Int($0) }
                let base = WindowLabel.forMinutes(minutes)
                windows.append(UsageWindow(
                    id: "\(limitID):\(minutes.map(String.init) ?? key)",
                    label: prefix.map { "\($0) \(base)" } ?? base,
                    usedPercent: used,
                    resetsAt: Timestamps.fromEpochSeconds(window["resetsAt"]),
                    windowMinutes: minutes
                ))
            }
        }
        return UsageSnapshot(windows: windows, plan: plan, fetchedAt: now)
    }

    // MARK: Antigravity — `agy -p /usage --output-format json`

    package static func antigravity(_ data: Data, now: Date) throws(ProviderFailure) -> UsageSnapshot {
        let body = try object(data)
        guard answeredAsCommand(body) else { throw .schema("agy did not answer /usage as a command") }
        let command = body["command"] as? JSON
        let groups = (command?["data"] as? JSON)?["groups"] as? [JSON] ?? []
        var windows: [UsageWindow] = []
        for group in groups {
            let groupName = group["name"] as? String
            for bucket in group["buckets"] as? [JSON] ?? [] {
                guard let remaining = number(bucket["remaining_fraction"]) else { continue }
                let window = bucket["window"] as? String
                let minutes: Int? = switch window { case "5h": 300; case "weekly": 10080; default: nil }
                windows.append(UsageWindow(
                    id: bucket["id"] as? String ?? "\(groupName ?? "?"):\(window ?? "?")",
                    label: minutes.map { WindowLabel.forMinutes($0) } ?? (window ?? "?"),
                    group: groupName,
                    usedPercent: max(0, (1 - remaining) * 100),
                    resetsAt: Timestamps.parse(bucket["reset_time"] as? String),
                    windowMinutes: minutes
                ))
            }
        }
        guard !windows.isEmpty else { throw .schema("agy reported no quota buckets") }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }

    /// True only for a reply that is explicitly the `/usage` command and spent no model turn.
    /// Anything else means the CLI sent `/usage` to the model as a prompt.
    static func answeredAsCommand(_ body: JSON) -> Bool {
        (body["command"] as? JSON)?["name"] as? String == "usage" && number(body["num_turns"]) == 0
    }

    package static func antigravityAnsweredAsCommand(_ data: Data) -> Bool {
        guard let body = try? object(data) else { return false }
        return answeredAsCommand(body)
    }

    // MARK: OpenRouter — GET /api/v1/key

    package static func openRouter(_ data: Data, now: Date) throws(ProviderFailure) -> UsageSnapshot {
        guard let key = try object(data)["data"] as? JSON, let spent = decimal(key["usage"]) else {
            throw .schema("no data.usage in OpenRouter response")
        }
        let money = MoneyUsage(
            currency: "USD",
            spent: spent,
            limit: decimal(key["limit"]),
            remaining: decimal(key["limit_remaining"]),
            limitReset: key["limit_reset"] as? String,
            spentToday: decimal(key["usage_daily"]),
            spentThisWeek: decimal(key["usage_weekly"]),
            spentThisMonth: decimal(key["usage_monthly"])
        )
        var windows: [UsageWindow] = []
        if let percent = money.usedPercent {
            windows.append(UsageWindow(id: "limit", label: "$", usedPercent: percent, resetsAt: nil, windowMinutes: nil))
        }
        return UsageSnapshot(windows: windows, money: money, plan: (key["is_free_tier"] as? Bool) == true ? "free" : nil, fetchedAt: now)
    }

    /// `GET /api/v1/credits`: `{"data": {"total_credits": 40, "total_usage": 23.19}}`.
    package static func openRouterCredits(_ data: Data) throws(ProviderFailure) -> (purchased: Decimal, used: Decimal) {
        guard let body = try object(data)["data"] as? JSON,
              let purchased = decimal(body["total_credits"]), let used = decimal(body["total_usage"])
        else { throw .schema("no data.total_credits in OpenRouter response") }
        return (purchased, used)
    }
}
