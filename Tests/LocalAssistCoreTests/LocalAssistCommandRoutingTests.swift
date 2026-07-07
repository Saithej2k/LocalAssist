import Foundation
import XCTest
@testable import LocalAssistCore

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// Tuesday, July 7, 2026, noon UTC.
private var referenceNow: Date {
    utcCalendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 12))!
}

/// Direct-command routing: which inputs skip the brief for the router path,
/// and how the deterministic router parses type/recipient/date/time/draft.
final class LocalAssistCommandRoutingTests: XCTestCase {
    // MARK: - Detector

    func testDetectorAcceptsDirectCommands() {
        XCTAssertTrue(DirectCommandDetector.isDirectCommand(
            "text Priya that Sunday brunch works, 11am at the usual place"
        ))
        XCTAssertTrue(DirectCommandDetector.isDirectCommand("email HR about leave next week"))
        XCTAssertTrue(DirectCommandDetector.isDirectCommand("tell mom I landed safely"))
        XCTAssertTrue(DirectCommandDetector.isDirectCommand("remind me to pick up groceries"))
        XCTAssertTrue(DirectCommandDetector.isDirectCommand("meeting with Rahul Thursday 3pm"))
        // Compound message commands stay routed — drafting is the point.
        XCTAssertTrue(DirectCommandDetector.isDirectCommand(
            "text Priya about brunch and remind me to book a table"
        ))
    }

    func testDetectorLeavesCapturesOnTheBriefPath() {
        // No routing verb: the brief pipeline already makes this a reminder.
        XCTAssertFalse(DirectCommandDetector.isDirectCommand("pick up groceries"))
        // Compound scheduling belongs to the brief path, which extracts
        // every clause instead of keeping only the first.
        XCTAssertFalse(DirectCommandDetector.isDirectCommand(
            "Schedule a launch sync next week and share the agenda."
        ))
        XCTAssertFalse(DirectCommandDetector.isDirectCommand(
            "remind me to buy bread and check the oven"
        ))
        // Multi-line and multi-sentence input is a note, not a command.
        XCTAssertFalse(DirectCommandDetector.isDirectCommand(
            "text from the meeting:\nfollow up with legal"
        ))
        XCTAssertFalse(DirectCommandDetector.isDirectCommand(
            "Email went out this morning. The team still needs the deck."
        ))
        XCTAssertFalse(DirectCommandDetector.isDirectCommand(""))
        XCTAssertFalse(DirectCommandDetector.isDirectCommand(
            "text " + String(repeating: "very long capture ", count: 20)
        ))
    }

    // MARK: - Deterministic router

    func testMessageCommandParsesContactTimeDateAndDraft() {
        let action = DeterministicCommandRouter(calendar: utcCalendar).route(
            "text Priya that Sunday brunch works, 11am at the usual place",
            relativeTo: referenceNow
        )

        XCTAssertEqual(action.actionType, .message)
        XCTAssertEqual(action.contactName, "Priya")
        XCTAssertEqual(action.time, "11:00")
        XCTAssertEqual(action.date, "2026-07-12", "Sunday resolves to the next Sunday")
        XCTAssertEqual(action.draftContent, "Sunday brunch works, 11am at the usual place")
        XCTAssertEqual(action.location, "", "regex location extraction is deliberately skipped")
        XCTAssertTrue(action.summary.hasPrefix("Message Priya:"))
    }

    func testEmailCommandCarriesSubjectAndRecipient() {
        let action = DeterministicCommandRouter(calendar: utcCalendar).route(
            "email HR about leave next week",
            relativeTo: referenceNow
        )

        XCTAssertEqual(action.actionType, .email)
        XCTAssertEqual(action.contactName, "HR")
        XCTAssertEqual(action.draftContent, "Leave next week")
        XCTAssertFalse(action.emailSubject.isEmpty)
    }

    func testMeetingCommandResolvesWeekdayAndClockTime() {
        let action = DeterministicCommandRouter(calendar: utcCalendar).route(
            "meeting with Rahul Thursday 3pm",
            relativeTo: referenceNow
        )

        XCTAssertEqual(action.actionType, .calendarEvent)
        XCTAssertEqual(action.contactName, "Rahul")
        XCTAssertEqual(action.date, "2026-07-09")
        XCTAssertEqual(action.time, "15:00")

        let due = action.resolvedDueDate(calendar: utcCalendar)
        XCTAssertEqual(
            due.map { utcCalendar.component(.hour, from: $0) },
            15,
            "date and time combine into one instant"
        )
    }

    func testReminderCommandStripsPrefixAndRanksFamilyHigh() {
        let action = DeterministicCommandRouter(calendar: utcCalendar).route(
            "remind me to call mom tomorrow",
            relativeTo: referenceNow
        )

        XCTAssertEqual(action.actionType, .reminder)
        XCTAssertEqual(action.priority, .high, "family keywords rank high")
        XCTAssertEqual(action.draftContent, "Call mom tomorrow")
        XCTAssertEqual(action.date, "2026-07-08")
        XCTAssertEqual(action.contactName, "")
    }

    func testUnknownContactStaysAsWritten() {
        let action = DeterministicCommandRouter(calendar: utcCalendar).route(
            "text Zara that I'm on my way",
            relativeTo: referenceNow
        )
        // The router extracts the name as written; Contacts resolution
        // happens downstream and simply finds no match.
        XCTAssertEqual(action.contactName, "Zara")
        XCTAssertEqual(action.actionType, .message)
    }

    // MARK: - Time parsing

    func testCommandTimeParserHandlesClockFormats() {
        XCTAssertEqual(CommandTimeParser.time(in: "brunch at 11am"), "11:00")
        XCTAssertEqual(CommandTimeParser.time(in: "dinner 7 pm"), "19:00")
        XCTAssertEqual(CommandTimeParser.time(in: "call at 11:30pm"), "23:30")
        XCTAssertEqual(CommandTimeParser.time(in: "midnight run 12am"), "00:00")
        XCTAssertEqual(CommandTimeParser.time(in: "lunch 12pm"), "12:00")
        XCTAssertEqual(CommandTimeParser.time(in: "standup 09:15"), "09:15")
        XCTAssertNil(CommandTimeParser.time(in: "no time here"))
        XCTAssertNil(CommandTimeParser.time(in: "due 6/7"))
    }

    func testDueDateParserHonorsExplicitTimes() {
        let parser = DueDateParser(calendar: utcCalendar)

        let withTime = parser.date(from: "tomorrow 3pm", relativeTo: referenceNow)
        XCTAssertEqual(withTime.map { utcCalendar.component(.hour, from: $0) }, 15)

        // Without an explicit time the branch defaults hold.
        let withoutTime = parser.date(from: "tomorrow", relativeTo: referenceNow)
        XCTAssertEqual(withoutTime.map { utcCalendar.component(.hour, from: $0) }, 9)

        // The mapper's editable "date time" string round-trips.
        let roundTrip = parser.date(from: "2026-07-12 11:00", relativeTo: referenceNow)
        XCTAssertEqual(roundTrip.map { utcCalendar.component(.hour, from: $0) }, 11)
        XCTAssertEqual(roundTrip.map { utcCalendar.component(.day, from: $0) }, 12)
    }

}

/// How the service folds routed actions into reviewable summaries on the
/// model and fallback paths, and how the reconciler corrects live model
/// failures (example leaks, unasked-for actions, wrong calendar math).
final class LocalAssistCommandReconciliationTests: XCTestCase {
    // MARK: - Service integration

    func testCommandRoutesThroughModelWhenClientSupportsIt() async throws {
        let routed = [
            RoutedAction(
                actionType: .message,
                priority: .medium,
                contactName: "Priya",
                date: "2026-07-12",
                time: "11:00",
                location: "Café Milano",
                draftContent: "Sunday brunch sounds perfect! See you at 11.",
                emailSubject: "",
                summary: "Message Priya: brunch confirmed"
            ),
            RoutedAction(
                actionType: .reminder,
                priority: .medium,
                contactName: "",
                date: "",
                time: "",
                location: "",
                draftContent: "Book a table for Sunday brunch",
                emailSubject: "",
                summary: "Reminder: book a table"
            ),
        ]
        let service = LocalAssistService(
            model: StaticStructuredModelClient(routedActions: routed)
        )

        let summary = try await service.summarize(
            AssistantRequest(sourceText: "text Priya about brunch and remind me to book a table")
        )

        XCTAssertEqual(summary.source, .foundationModels)
        XCTAssertTrue(summary.keyPoints.isEmpty, "routed commands carry no key points")
        XCTAssertEqual(summary.suggestions.count, 2)
        XCTAssertEqual(summary.suggestions.map(\.action), [.messageDraft, .reminder])

        let messageDraft = try XCTUnwrap(summary.actionDrafts.first)
        XCTAssertEqual(messageDraft.kind, .messageDraft)
        XCTAssertEqual(messageDraft.payload["recipient"], "Priya")
        XCTAssertEqual(messageDraft.payload["channel"], MessageChannel.textMessage.rawValue)
        XCTAssertEqual(messageDraft.payload["body"], "Sunday brunch sounds perfect! See you at 11.")
        XCTAssertEqual(
            messageDraft.payload["composed"], "true",
            "model-drafted bodies must not be recomposed at confirmation"
        )

        let reminderDraft = try XCTUnwrap(summary.actionDrafts.last)
        XCTAssertEqual(reminderDraft.kind, .reminder)
        XCTAssertEqual(reminderDraft.payload["title"], "Book a table for Sunday brunch")
    }

    func testCommandFallsBackToDeterministicRouterWithoutModel() async throws {
        let service = LocalAssistService()

        let summary = try await service.summarize(
            AssistantRequest(sourceText: "text Priya that Sunday brunch works, 11am at the usual place")
        )

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertTrue(summary.keyPoints.isEmpty)
        XCTAssertEqual(summary.suggestions.count, 1)
        XCTAssertEqual(summary.suggestions.first?.action, .messageDraft)

        let draft = try XCTUnwrap(summary.actionDrafts.first)
        XCTAssertEqual(draft.payload["recipient"], "Priya")
        XCTAssertEqual(draft.payload["channel"], MessageChannel.textMessage.rawValue)
        XCTAssertNil(
            draft.payload["composed"],
            "deterministic drafts get the template composition at confirmation"
        )
    }

    func testCommandFallsBackWhenClientDoesNotSupportRouting() async throws {
        // Scripted client with no routedActions: availability says yes,
        // routeCommand answers nil — the deterministic router must cover it.
        let service = LocalAssistService(model: StaticStructuredModelClient())

        let summary = try await service.summarize(
            AssistantRequest(sourceText: "tell mom I landed safely")
        )

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertEqual(summary.suggestions.first?.action, .messageDraft)
        XCTAssertEqual(summary.suggestions.first?.priority, .high)
    }

    func testCommandFallsBackWhenRoutingThrows() async throws {
        let service = LocalAssistService(
            model: StaticStructuredModelClient(
                routingFailure: .decodingFailure(detail: "stream ended early")
            )
        )

        let summary = try await service.summarize(
            AssistantRequest(sourceText: "email HR about leave next week")
        )

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertNotNil(summary.diagnostics.fallbackReason)
        XCTAssertEqual(summary.suggestions.first?.action, .messageDraft)
    }

    func testCapturesStillProduceBriefs() async throws {
        // The README's flagship capture starts with "Call", not a routing
        // verb: it must keep flowing through the brief pipeline untouched.
        let service = LocalAssistService()

        let summary = try await service.summarize(
            AssistantRequest(
                sourceText: "Call Mom tonight, pick up the birthday cake Saturday, and book the dentist for next week."
            )
        )

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertFalse(summary.keyPoints.isEmpty, "captures keep their key points")
        XCTAssertGreaterThanOrEqual(summary.suggestions.count, 2)
    }

    // MARK: - Reconciler

    func testReconcilerDropsExampleLeakedActions() {
        // Reproduces a live run: routing "text Priya…" produced a second
        // action copied from the prompt's own few-shot examples.
        let grounded = RoutedAction(
            actionType: .message,
            priority: .medium,
            contactName: "Priya",
            date: "2026-07-12",
            time: "11:00",
            location: "",
            draftContent: "Sunday brunch sounds perfect! See you at 11.",
            emailSubject: "",
            summary: "Message Priya: brunch confirmed"
        )
        let leaked = RoutedAction(
            actionType: .reminder,
            priority: .medium,
            contactName: "",
            date: "",
            time: "",
            location: "",
            draftContent: "Remind me to pick up groceries.",
            emailSubject: "",
            summary: "Reminder: pick up groceries"
        )

        let reconciled = RoutedActionReconciler.reconciled(
            [grounded, leaked],
            sourceText: "text Priya that Sunday brunch works, 11am at the usual place",
            calendar: utcCalendar,
            now: referenceNow
        )

        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled.first?.actionType, .message)
    }

    func testReconcilerOverridesModelDatesWithDeterministicParses() {
        // Reproduces a live run: the model resolved "Sunday" to a Thursday.
        let action = RoutedAction(
            actionType: .message,
            priority: .medium,
            contactName: "Priya",
            date: "2026-07-09",
            time: "",
            location: "",
            draftContent: "Sunday brunch sounds perfect! See you there.",
            emailSubject: "",
            summary: "Message Priya: brunch"
        )

        let reconciled = RoutedActionReconciler.reconciled(
            [action],
            sourceText: "text Priya that Sunday brunch works, 11am at the usual place",
            calendar: utcCalendar,
            now: referenceNow
        )

        XCTAssertEqual(reconciled.first?.date, "2026-07-12", "the deterministic weekday parse wins")
        XCTAssertEqual(reconciled.first?.time, "11:00", "the command's clock time fills the gap")
    }

    func testReconcilerDropsUnaskedForActionTypes() {
        // Reproduces a live run: "meeting with Rahul Thursday 3pm" grew a
        // second, unasked-for message action ("Excited for the meeting!").
        let event = RoutedAction(
            actionType: .calendarEvent,
            priority: .medium,
            contactName: "Rahul",
            date: "2026-07-14",
            time: "15:00",
            location: "",
            draftContent: "Meeting with Rahul",
            emailSubject: "",
            summary: "Event: meeting with Rahul"
        )
        let volunteeredMessage = RoutedAction(
            actionType: .message,
            priority: .medium,
            contactName: "Rahul",
            date: "",
            time: "",
            location: "",
            draftContent: "Excited for the meeting with Rahul.",
            emailSubject: "",
            summary: "Message Rahul: excited for the meeting"
        )

        let reconciled = RoutedActionReconciler.reconciled(
            [event, volunteeredMessage],
            sourceText: "meeting with Rahul Thursday 3pm",
            calendar: utcCalendar,
            now: referenceNow
        )

        XCTAssertEqual(reconciled.map(\.actionType), [.calendarEvent])
        XCTAssertEqual(
            reconciled.first?.date, "2026-07-09",
            "the model's off-by-a-week Thursday is corrected from the command"
        )
        XCTAssertEqual(reconciled.first?.time, "15:00")
    }

    func testReconcilerClearsDatesTheCommandNeverGave() {
        // "text Priya about brunch and remind me to book a table" names no
        // day; a model draft that invents "Sunday" must not date the card.
        let message = RoutedAction(
            actionType: .message,
            priority: .medium,
            contactName: "Priya",
            date: "2026-07-12",
            time: "11:00",
            location: "",
            draftContent: "Sunday brunch with Priya",
            emailSubject: "",
            summary: "Message Priya: brunch"
        )

        let reconciled = RoutedActionReconciler.reconciled(
            [message],
            sourceText: "text Priya about brunch and remind me to book a table",
            calendar: utcCalendar,
            now: referenceNow
        )

        XCTAssertEqual(reconciled.first?.date, "")
        XCTAssertEqual(reconciled.first?.time, "")
    }

    func testServiceFallsBackWhenNothingSurvivesGrounding() async throws {
        let ungrounded = RoutedAction(
            actionType: .reminder,
            priority: .medium,
            contactName: "",
            date: "",
            time: "",
            location: "",
            draftContent: "Finish the quarterly presentation",
            emailSubject: "",
            summary: "Reminder: finish the presentation"
        )
        let service = LocalAssistService(
            model: StaticStructuredModelClient(routedActions: [ungrounded])
        )

        let summary = try await service.summarize(
            AssistantRequest(sourceText: "tell mom I landed safely")
        )

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertEqual(summary.suggestions.first?.action, .messageDraft)
    }

    // MARK: - Mapper

    func testMapperBuildsEditableDateStringsAndDueDates() {
        let action = RoutedAction(
            actionType: .calendarEvent,
            priority: .medium,
            contactName: "Rahul",
            date: "2026-07-09",
            time: "15:00",
            location: "the office",
            draftContent: "Meeting with Rahul",
            emailSubject: "",
            summary: "Event: meeting with Rahul"
        )

        let summary = RoutedActionMapper.summary(
            from: [action],
            source: .foundationModels,
            diagnostics: GenerationDiagnostics(availability: .available),
            calendar: utcCalendar
        )

        let draft = summary.actionDrafts[0]
        XCTAssertEqual(draft.kind, .calendarHold)
        XCTAssertEqual(draft.payload["date"], "2026-07-09 15:00")
        XCTAssertEqual(draft.payload["title"], "Meeting with Rahul")
        XCTAssertEqual(draft.payload["notes"], "the office")

        let suggestion = summary.suggestions[0]
        XCTAssertEqual(suggestion.action, .calendarHold)
        XCTAssertEqual(
            suggestion.dueDate.map { utcCalendar.component(.hour, from: $0) },
            15
        )
        XCTAssertEqual(summary.overview, "Event: meeting with Rahul")
    }
}
