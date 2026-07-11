import Foundation
import FoundationModels
import LocalAssistCore

/// One open (incomplete) reminder as the lookup tool sees it: title and
/// optional due date, nothing else. The tool is read-only by design — the
/// only path that writes reminders is the user-confirmed executor.
public struct OpenReminder: Equatable, Sendable {
    public var title: String
    public var dueDate: Date?

    public init(title: String, dueDate: Date? = nil) {
        self.title = title
        self.dueDate = dueDate
    }
}

/// Read-only seam over the user's open reminders so the tool is testable
/// without EventKit permissions.
public protocol ReminderLookupProviding: Sendable {
    func openReminders() async throws -> [OpenReminder]
}

/// Scriptable provider for tests and previews.
public struct StaticReminderProvider: ReminderLookupProviding {
    public var reminders: [OpenReminder]

    public init(reminders: [OpenReminder] = []) {
        self.reminders = reminders
    }

    public func openReminders() async throws -> [OpenReminder] {
        reminders
    }
}

/// The model can check calendar free/busy and resolve contacts, but it was
/// blind to the reminders it already helped create — so a note mentioning
/// the dentist could produce "Book the dentist" while that exact reminder
/// sat open. This tool lists open reminders so a suggestion can defer to
/// one that already exists instead of duplicating it.
public struct RemindersLookupTool: FoundationModels.Tool {
    public let name = "checkOpenReminders"
    public let description = """
    Lists the user's open reminders, optionally filtered by a keyword. \
    Call this before proposing a new task or reminder so you never suggest \
    one that already exists.
    """

    @Generable(description: "Filter for the user's open reminders.")
    public struct Arguments: Sendable {
        @Guide(description: """
        Keyword to match against open reminder titles, such as 'dentist'. \
        Empty string lists all open reminders.
        """)
        public var searchTerm: String

        public init(searchTerm: String) {
            self.searchTerm = searchTerm
        }
    }

    private let provider: any ReminderLookupProviding
    private let counter: ToolInvocationCounter?
    private let calendar: Calendar

    public init(
        provider: any ReminderLookupProviding,
        counter: ToolInvocationCounter? = nil,
        calendar: Calendar = .current
    ) {
        self.provider = provider
        self.counter = counter
        self.calendar = calendar
    }

    public func call(arguments: Arguments) async throws -> String {
        await counter?.increment()

        // Bounded like the calendar tool: a hung EventKit read fails the
        // tool call rather than stalling generation.
        let lookupProvider = provider
        let all = try await LocalAssistDeadline.run(
            .seconds(8),
            stage: "reminders-lookup-tool",
            operation: { try await lookupProvider.openReminders() }
        )
        let term = arguments.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)

        let matches = term.isEmpty
            ? all
            : all.filter { $0.title.lowercased().contains(term.lowercased()) }

        guard !all.isEmpty else {
            return "The user has no open reminders."
        }
        guard !matches.isEmpty else {
            return "No open reminders match '\(term)'. Nothing similar exists yet."
        }

        // Dated reminders first, soonest first — the ones most likely to
        // collide with a new suggestion. Undated ones follow.
        let sorted = matches.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (lhsDue?, rhsDue?):
                return lhsDue < rhsDue
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return lhs.title < rhs.title
            }
        }

        let described = sorted.prefix(5).map { reminder in
            if let dueDate = reminder.dueDate {
                return "'\(reminder.title)' (due \(LocalAssistDates.dateOnlyString(from: dueDate, timeZone: calendar.timeZone)))"
            }
            return "'\(reminder.title)' (no due date)"
        }
        return "Open reminders: \(described.joined(separator: "; "))."
    }
}
