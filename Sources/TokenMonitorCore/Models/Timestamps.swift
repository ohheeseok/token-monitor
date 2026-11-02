import Foundation

enum Timestamps {
    /// Parses ISO 8601 with or without fractional seconds of any precision
    /// (Anthropic returns microseconds, e.g. `2026-11-02T09:30:00.218541+00:00`).
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withoutFraction = string.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression
        )
        return try? Date(withoutFraction, strategy: .iso8601)
    }

    static func fromEpochSeconds(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber: Date(timeIntervalSince1970: number.doubleValue)
        default: nil
        }
    }
}

enum WindowLabel {
    /// `300` → `5h`, `10080` → `wk`, otherwise hours or days.
    static func forMinutes(_ minutes: Int?) -> String {
        switch minutes {
        case 300: "5h"
        case 10080: "wk"
        case let m? where m % 1440 == 0: "\(m / 1440)d"
        case let m? where m % 60 == 0: "\(m / 60)h"
        case let m?: "\(m)m"
        case nil: "?"
        }
    }
}
