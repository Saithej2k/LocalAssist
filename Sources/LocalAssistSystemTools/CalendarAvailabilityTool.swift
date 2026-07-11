import Foundation
import FoundationModels
import LocalAssistCore

/// Read-only seam over the user's calendar so the tool is testable without
/// EventKit permissions.
public protocol FreeBusyProviding: Sendable {
    func busyIntervals(from start: Date, to end: Date) async throws -> [DateInterval]
}

/// Scriptable provider for tests and previews.
public struct StaticFreeBusyProvider: FreeBusyProviding {
    public var intervals: [DateInterval]

    public init(intervals: [DateInterval] = []) {
        self.intervals = intervals
    }

    public func busyIntervals(from start: Date, to end: Date) async throws -> [DateInterval] {
        intervals.filter { $0.end > start && $0.start < end }
    }
}

/// Local actor-isolated agenda store used by the app's offline-first tool.
/// It is intentionally shaped like the EventKit provider seam, so swapping in
/// real calendar reads later does not touch `CalendarAvailabilityTool`.
public actor SampleAgendaStore: FreeBusyProviding {
    public struct AgendaEvent: Equatable, Sendable {
        public var title: String
        public var interval: DateInterval

        public init(title: String, interval: DateInterval) {
            self.title = title
            self.interval = interval
        }
    }

    private var events: [AgendaEvent]

    public init(events: [AgendaEvent]) {
        self.events = events
    }

    public static func seeded(
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> SampleAgendaStore {
        let parser = DueDateParser(calendar: calendar)
        let nextWeek = parser.date(from: "next week", relativeTo: now) ?? now
        let tomorrow = parser.date(from: "tomorrow", relativeTo: now) ?? now

        func event(_ title: String, day: Date, hour: Int, minutes: Int = 60) -> AgendaEvent? {
            guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) else {
                return nil
            }
            return AgendaEvent(
                title: title,
                interval: DateInterval(start: start, duration: TimeInterval(minutes * 60))
            )
        }

        return SampleAgendaStore(events: [
            event("Focus block", day: tomorrow, hour: 10, minutes: 90),
            event("Planning review", day: nextWeek, hour: 13, minutes: 60),
            event("Team check-in", day: nextWeek, hour: 15, minutes: 30),
        ].compactMap { $0 })
    }

    public func busyIntervals(from start: Date, to end: Date) async throws -> [DateInterval] {
        let window = DateInterval(start: start, end: end)
        return events
            .compactMap { $0.interval.intersection(with: window) }
            .sorted { $0.start < $1.start }
    }
}

/// A Foundation Models `Tool` the model can call autonomously while
/// generating: given a natural-language day hint it returns real free windows
/// from the user's calendar, so `calendarHold` suggestions land on times that
/// are actually open.
public struct CalendarAvailabilityTool: FoundationModels.Tool {
    public let name = "checkCalendarAvailability"
    public let description = """
    Checks the user's calendar for a given day and returns free time windows. \
    Call this before suggesting a meeting, sync, or calendar hold.
    """

    @Generable(description: "Day to check for free time.")
    public struct Arguments: Sendable {
        @Guide(description: "Natural-language day such as 'Friday', 'tomorrow', or 'next week'.")
        public var dayHint: String

        public init(dayHint: String) {
            self.dayHint = dayHint
        }
    }

    private let provider: any FreeBusyProviding
    private let counter: ToolInvocationCounter?
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(
        provider: any FreeBusyProviding,
        counter: ToolInvocationCounter? = nil,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.counter = counter
        self.calendar = calendar
        self.now = now
    }

    public func call(arguments: Arguments) async throws -> String {
        await counter?.increment()

        let reference = now()
        let day = DueDateParser(calendar: calendar).date(from: arguments.dayHint, relativeTo: reference)
            ?? calendar.date(byAdding: .day, value: 1, to: reference)
            ?? reference

        guard let windowStart = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day),
              let windowEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day)
        else {
            return "Calendar availability could not be determined for \(arguments.dayHint)."
        }

        // Bounded: a hung EventKit read must fail the tool call (which the
        // service maps to a typed tool failure) instead of stalling the
        // whole generation.
        let busyProvider = provider
        let busy = try await LocalAssistDeadline.run(
            .seconds(8),
            stage: "calendar-availability-tool",
            operation: { try await busyProvider.busyIntervals(from: windowStart, to: windowEnd) }
        )
        let free = FreeSlotCalculator.freeWindows(
            busy: busy,
            within: DateInterval(start: windowStart, end: windowEnd),
            minimumMinutes: 30
        )

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "EEEE HH:mm"

        guard !free.isEmpty else {
            return "The user's calendar is fully booked between 08:00 and 18:00 on \(formatter.string(from: windowStart).components(separatedBy: " ").first ?? arguments.dayHint)."
        }

        let slots = free.prefix(3).map { window in
            let start = formatter.string(from: window.start)
            let endFormatter = DateFormatter()
            endFormatter.calendar = calendar
            endFormatter.dateFormat = "HH:mm"
            return "\(start)–\(endFormatter.string(from: window.end))"
        }
        return "Free calendar windows: \(slots.joined(separator: ", "))."
    }
}

/// Pure interval math, kept separate so it is trivially unit-testable.
public enum FreeSlotCalculator {
    public static func freeWindows(
        busy: [DateInterval],
        within window: DateInterval,
        minimumMinutes: Int
    ) -> [DateInterval] {
        let minimum = TimeInterval(minimumMinutes * 60)
        let sorted = busy
            .compactMap { $0.intersection(with: window) }
            .sorted { $0.start < $1.start }

        var free: [DateInterval] = []
        var cursor = window.start

        for interval in sorted {
            if interval.start.timeIntervalSince(cursor) >= minimum {
                free.append(DateInterval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }

        if window.end.timeIntervalSince(cursor) >= minimum {
            free.append(DateInterval(start: cursor, end: window.end))
        }

        return free
    }
}
