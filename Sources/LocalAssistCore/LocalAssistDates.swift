import Foundation

/// Single policy for ISO-8601 due-date strings across the app.
///
/// A bare calendar date like "2026-07-06" means "that day where the user is".
/// `ISO8601DateFormatter` defaults to GMT, which shifted bare dates into the
/// previous local day everywhere west of GMT: the normalizer dropped
/// due-today tasks as stale, and the Due Today widget and morning brief
/// skipped them. Bare dates therefore parse and format in an explicit time
/// zone, defaulting to the user's.
public enum LocalAssistDates {
    /// Accepts a full ISO-8601 timestamp or a bare calendar date.
    public static func parse(_ value: String, timeZone: TimeZone = .current) -> Date? {
        if let instant = ISO8601DateFormatter().date(from: value) {
            return instant
        }
        return dateOnlyFormatter(timeZone).date(from: value)
    }

    /// Formats just the calendar date, e.g. "2026-07-06".
    public static func dateOnlyString(from date: Date, timeZone: TimeZone = .current) -> String {
        dateOnlyFormatter(timeZone).string(from: date)
    }

    private static func dateOnlyFormatter(_ timeZone: TimeZone) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = timeZone
        return formatter
    }
}
