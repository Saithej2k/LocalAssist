import Foundation
import FoundationModels
import LocalAssistCore

/// Seam over the system stores that confirmed actions write into, so executor
/// logic (due-date resolution, payload mapping, outcome reporting) is testable
/// without touching real Reminders or Calendar data.
public protocol SystemWriteStore: Sendable {
    /// Returns the system identifier of the created reminder.
    func createReminder(title: String, notes: String?, due: Date?) async throws -> String
    /// Returns the system identifier of the created event.
    func createCalendarHold(title: String, start: Date, durationMinutes: Int) async throws -> String
}

/// In-memory store for tests and previews.
public actor RecordingWriteStore: SystemWriteStore {
    public struct RecordedReminder: Equatable, Sendable {
        public var title: String
        public var notes: String?
        public var due: Date?
    }

    public struct RecordedHold: Equatable, Sendable {
        public var title: String
        public var start: Date
        public var durationMinutes: Int
    }

    public private(set) var reminders: [RecordedReminder] = []
    public private(set) var holds: [RecordedHold] = []

    public init() {}

    public func createReminder(title: String, notes: String?, due: Date?) async throws -> String {
        reminders.append(RecordedReminder(title: title, notes: notes, due: due))
        return "recorded-reminder-\(reminders.count)"
    }

    public func createCalendarHold(title: String, start: Date, durationMinutes: Int) async throws -> String {
        holds.append(RecordedHold(title: title, start: start, durationMinutes: durationMinutes))
        return "recorded-hold-\(holds.count)"
    }
}

/// Executes a user-confirmed action against real system stores. This is the
/// step that turns LocalAssist from a draft generator into a product: after
/// explicit confirmation, reminders and calendar holds are actually created.
public struct SystemActionExecutor: ToolActionExecuting {
    private let store: any SystemWriteStore
    private let parser: DueDateParser
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        store: any SystemWriteStore,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        parser = DueDateParser(calendar: calendar)
        self.calendar = calendar
        self.now = now
    }

    public func execute(_ action: PreparedToolAction) async throws -> ExecutedToolAction {
        try Task.checkCancellation()

        let draft = action.draft
        let title = draft.payload["title"] ?? draft.title

        switch draft.kind {
        case .reminder, .checklistItem:
            let due = parser.date(
                from: draft.payload["dueDate"] ?? draft.payload["dueHint"],
                relativeTo: now()
            )
            let identifier = try await store.createReminder(
                title: title,
                notes: draft.payload["notes"],
                due: due
            )
            let dueText = due.map { " due \(Self.format($0, calendar: calendar))" } ?? ""
            return ExecutedToolAction(
                id: action.id,
                kind: draft.kind,
                outcome: .executed(
                    detail: "Created reminder “\(title)”\(dueText).",
                    systemIdentifier: identifier
                )
            )

        case .calendarHold:
            let start = parser.date(from: draft.payload["date"] ?? draft.payload["dateHint"], relativeTo: now())
                ?? defaultHoldStart()
            let identifier = try await store.createCalendarHold(
                title: title,
                start: start,
                durationMinutes: 30
            )
            return ExecutedToolAction(
                id: action.id,
                kind: .calendarHold,
                outcome: .executed(
                    detail: "Held 30 minutes on \(Self.format(start, calendar: calendar)) for “\(title)”.",
                    systemIdentifier: identifier
                )
            )

        case .messageDraft:
            let subject = draft.payload["subject"] ?? title
            let body = draft.payload["body"] ?? ""
            return ExecutedToolAction(
                id: action.id,
                kind: .messageDraft,
                outcome: .simulated(
                    detail: "Message draft ready — subject: \(subject). \(body)"
                )
            )

        case .none:
            return ExecutedToolAction(
                id: action.id,
                kind: .none,
                outcome: .skipped(reason: "No system action was required.")
            )
        }
    }

    private func defaultHoldStart() -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now()) ?? now()
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private static func format(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "EEEE d MMM HH:mm"
        return formatter.string(from: date)
    }
}

#if canImport(EventKit)
    import EventKit

    /// Live Reminders/Calendar writes. Access is requested lazily on first
    /// write and every write happens only after explicit user confirmation
    /// upstream (`PreparedToolAction.requiresConfirmation`).
    public final class EventKitWriteStore: SystemWriteStore, @unchecked Sendable {
        private let store = EKEventStore()

        public init() {}

        public func createReminder(title: String, notes: String?, due: Date?) async throws -> String {
            guard try await store.requestFullAccessToReminders() else {
                throw SystemAccessError.remindersAccessDenied
            }

            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.notes = notes
            reminder.calendar = store.defaultCalendarForNewReminders()
            if let due {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: due
                )
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }

            try store.save(reminder, commit: true)
            return reminder.calendarItemIdentifier
        }

        public func createCalendarHold(title: String, start: Date, durationMinutes: Int) async throws -> String {
            guard try await store.requestFullAccessToEvents() else {
                throw SystemAccessError.calendarAccessDenied
            }

            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
            event.calendar = store.defaultCalendarForNewEvents

            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier ?? event.calendarItemIdentifier
        }
    }

    public extension SystemActionExecutor {
        /// Executor wired to real EventKit stores.
        static func live() -> SystemActionExecutor {
            SystemActionExecutor(store: EventKitWriteStore())
        }
    }
#endif

public enum LocalAssistToolkit {
    /// The default tool set the model can call during generation, wired to
    /// the user's real calendar and contacts. System access is requested on
    /// the first tool call, and a denied/failed lookup surfaces as a tool
    /// failure that the service handles — generation never crashes on
    /// permissions.
    public static func liveTools(counter: ToolInvocationCounter? = nil) -> [any FoundationModels.Tool] {
        var tools: [any FoundationModels.Tool] = []
        #if canImport(EventKit)
            tools.append(CalendarAvailabilityTool(provider: EventKitFreeBusyProvider(), counter: counter))
        #endif
        #if canImport(Contacts)
            tools.append(ContactsLookupTool(resolver: ContactsFrameworkResolver(), counter: counter))
        #endif
        return tools.isEmpty ? sampleTools(counter: counter) : tools
    }

    /// Seeded in-memory agenda and contacts for previews, screenshots, and
    /// platforms without EventKit.
    public static func sampleTools(
        counter: ToolInvocationCounter? = nil,
        agendaStore: SampleAgendaStore = .seeded()
    ) -> [any FoundationModels.Tool] {
        [
            CalendarAvailabilityTool(provider: agendaStore, counter: counter),
            ContactsLookupTool(
                resolver: StaticContactResolver(contacts: [
                    ResolvedContact(displayName: "Mira Chen", hasEmail: true, hasPhone: true),
                    ResolvedContact(displayName: "Priya Patel", hasEmail: true, hasPhone: false),
                ]),
                counter: counter
            ),
        ]
    }
}
