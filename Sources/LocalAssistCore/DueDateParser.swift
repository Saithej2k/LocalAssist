import Foundation

/// Deterministically resolves natural-language due hints ("Friday",
/// "next week", "asap") into concrete dates so confirmed actions can write
/// real alarms into Reminders and Calendar.
///
/// Injectable `now` and `calendar` keep every branch unit-testable.
public struct DueDateParser: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func date(from hint: String?, relativeTo now: Date = Date()) -> Date? {
        guard let resolved = baseDate(from: hint, relativeTo: now) else {
            return nil
        }
        // An explicit clock time ("3pm", "11:30") overrides the branch's
        // default hour, so "tomorrow 3pm" lands at 15:00, not the generic
        // 9am reminder slot.
        guard let hint, let time = CommandTimeParser.components(in: hint.lowercased()) else {
            return resolved
        }
        return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: resolved)
            ?? resolved
    }

    private func baseDate(from hint: String?, relativeTo now: Date) -> Date? {
        guard let rawHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHint.isEmpty
        else {
            return nil
        }

        let hint = rawHint.lowercased()
        if let literal = literalDate(in: rawHint, relativeTo: now) {
            return at(hour: 17, of: literal)
        }
        if hint.contains("asap") || hint.contains("as soon as possible") || hint.contains("urgent") {
            return calendar.date(byAdding: .hour, value: 2, to: now)
        }
        if hint.contains("tonight") {
            return at(hour: 20, of: now)
        }
        if hint.contains("today") {
            return at(hour: 17, of: now)
        }
        if hint.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: now).flatMap { at(hour: 9, of: $0) }
        }
        if hint.contains("next week") {
            return nextWeekday(.monday, after: now, minimumDaysAhead: 1).flatMap { at(hour: 9, of: $0) }
        }
        if hint.contains("this week") {
            return nextWeekday(.friday, after: now, minimumDaysAhead: 0).flatMap { at(hour: 17, of: $0) }
        }
        if let weekday = Weekday.allCases.first(where: { hint.contains($0.name) }) {
            return nextWeekday(weekday, after: now, minimumDaysAhead: 0).flatMap { at(hour: 9, of: $0) }
        }

        return nil
    }

    private func literalDate(in hint: String, relativeTo now: Date) -> Date? {
        let words = hint
            .components(separatedBy: .whitespacesAndNewlines)
            .map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}"))
            }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return nil
        }

        var candidates: [String] = []
        for start in words.indices {
            let upperBound = min(words.count, start + 4)
            for end in (start + 1)...upperBound {
                candidates.append(words[start..<end].joined(separator: " "))
            }
        }

        for candidate in candidates {
            if let date = parseLiteral(candidate, relativeTo: now) {
                return date
            }
        }
        return nil
    }

    private func parseLiteral(_ value: String, relativeTo now: Date) -> Date? {
        let formatsWithYear = [
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "M/d/yyyy",
            "MM/dd/yyyy",
            "MMM d yyyy",
            "MMMM d yyyy",
            "MMM d, yyyy",
            "MMMM d, yyyy",
        ]
        for format in formatsWithYear {
            if let date = formatter(format).date(from: value) {
                return calendar.startOfDay(for: date)
            }
        }

        let currentYear = calendar.component(.year, from: now)
        let formatsWithoutYear = [
            "M/d yyyy",
            "MM/dd yyyy",
            "MMM d yyyy",
            "MMMM d yyyy",
            "MMM d, yyyy",
            "MMMM d, yyyy",
        ]
        for format in formatsWithoutYear {
            let candidate = "\(value) \(currentYear)"
            if let date = formatter(format).date(from: candidate) {
                let start = calendar.startOfDay(for: date)
                if start >= calendar.startOfDay(for: now) {
                    return start
                }
                return calendar.date(byAdding: .year, value: 1, to: start)
            }
        }

        return nil
    }

    /// `DateFormatter.init` is one of the more expensive Foundation calls,
    /// and `literalDate` tries up to 4 windows × 14 formats per parse. Each
    /// `(calendar timezone, format)` pair maps to one formatter, built at
    /// first use and reused forever. `nonisolated(unsafe)` is fine here:
    /// the dictionary is only mutated behind `formatterLock`, and each
    /// formatter is only read after it is stored — the exact single-writer
    /// / many-reader pattern `SharedContainerCache` already uses.
    private static let formatterLock = NSLock()
    private nonisolated(unsafe) static var formatterCache: [FormatterKey: DateFormatter] = [:]

    private struct FormatterKey: Hashable {
        let timeZoneIdentifier: String
        let format: String
    }

    private func formatter(_ format: String) -> DateFormatter {
        let key = FormatterKey(
            timeZoneIdentifier: calendar.timeZone.identifier,
            format: format
        )
        Self.formatterLock.lock()
        defer { Self.formatterLock.unlock() }
        if let cached = Self.formatterCache[key] {
            return cached
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        Self.formatterCache[key] = formatter
        return formatter
    }

    private func at(hour: Int, of day: Date) -> Date? {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    private func nextWeekday(_ weekday: Weekday, after date: Date, minimumDaysAhead: Int) -> Date? {
        let currentWeekday = calendar.component(.weekday, from: date)
        var daysAhead = (weekday.calendarValue - currentWeekday + 7) % 7
        if daysAhead < max(minimumDaysAhead, 1), daysAhead == 0 {
            daysAhead = 7
        }
        return calendar.date(byAdding: .day, value: daysAhead, to: date)
    }

    private enum Weekday: CaseIterable {
        case monday, tuesday, wednesday, thursday, friday, saturday, sunday

        var name: String {
            switch self {
            case .monday: "monday"
            case .tuesday: "tuesday"
            case .wednesday: "wednesday"
            case .thursday: "thursday"
            case .friday: "friday"
            case .saturday: "saturday"
            case .sunday: "sunday"
            }
        }

        /// `Calendar.component(.weekday)` is 1-based starting at Sunday.
        var calendarValue: Int {
            switch self {
            case .sunday: 1
            case .monday: 2
            case .tuesday: 3
            case .wednesday: 4
            case .thursday: 5
            case .friday: 6
            case .saturday: 7
            }
        }
    }
}
