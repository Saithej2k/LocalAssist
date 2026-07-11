import Foundation

/// Deterministic calendar-semantics validation for model-generated date and
/// time strings. Guided generation constrains the *shape* ("YYYY-MM-DD",
/// "HH:mm"); this validates the *meaning* — February 30th matches the
/// pattern but is not a date, and only a real calendar can say so.
///
/// Every check is pure and injectable, so tests cover leap years, month
/// lengths, and time-zone boundaries without touching the model.
public enum GeneratedDateTimeValidator {
    public enum DateVerdict: Equatable, Sendable {
        case empty
        case valid(Date)
        /// Shape or calendar semantics failed ("2026-02-30", "2026-13-01").
        case invalid(String)
    }

    public enum TimeVerdict: Equatable, Sendable {
        case empty
        case valid(hour: Int, minute: Int)
        /// Shape or range failed ("25:00", "12:75").
        case invalid(String)
    }

    /// Validates an ISO-8601 calendar date string against real calendar
    /// semantics in the given time zone.
    public static func validateDate(
        _ value: String,
        calendar: Calendar = .current
    ) -> DateVerdict {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .empty
        }
        let parts = trimmed.components(separatedBy: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return .invalid("not YYYY-MM-DD")
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        // `isValidDate` applies real calendar rules — month lengths, leap
        // years — instead of the lenient rollover DateFormatter would do.
        guard components.isValidDate, let date = components.date else {
            return .invalid("no such calendar date")
        }
        return .valid(date)
    }

    /// Validates a 24-hour "HH:mm" clock time.
    public static func validateTime(_ value: String) -> TimeVerdict {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .empty
        }
        let parts = trimmed.components(separatedBy: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1])
        else {
            return .invalid("not HH:mm")
        }
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else {
            return .invalid("out of range")
        }
        return .valid(hour: hour, minute: minute)
    }
}
