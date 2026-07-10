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

/// Deferred commands — the message first, the verb last — and the
/// one-command-per-line batch detector.
final class LocalAssistDeferredCommandTests: XCTestCase {
    func testDetectorAcceptsDeferredCommands() {
        // The message first, the verb last — the shape natural dictation takes.
        XCTAssertTrue(DirectCommandDetector.isDirectCommand(
            "Hi amma how are you doing, text this to amma now"
        ))
        XCTAssertTrue(DirectCommandDetector.isDirectCommand(
            "The report is ready for review, email this to the team"
        ))
        // Multiple sentences are fine here — the content IS the message.
        XCTAssertTrue(DirectCommandDetector.isDirectCommand(
            "Hi amma. Hope the garden is doing well. Send this to amma"
        ))
        // The clause alone has no message to defer to.
        XCTAssertNil(DirectCommandDetector.deferredCommand(in: "send this to mom"))
    }

    func testDeferredCommandKeepsTheUsersWordsAsTheBody() {
        let action = DeterministicCommandRouter(calendar: utcCalendar).route(
            "Hi amma how are you doing, text this to amma now",
            relativeTo: referenceNow
        )

        XCTAssertEqual(action.actionType, .message)
        XCTAssertEqual(action.contactName, "Amma")
        XCTAssertEqual(action.draftContent, "Hi amma how are you doing")
        XCTAssertEqual(action.priority, .high, "amma is a family keyword")
        XCTAssertEqual(action.date, "", "\"now\" is the send urgency, not a due date")
    }

    func testDeferredEmailRoutesToMailWithSubject() {
        let action = DeterministicCommandRouter(calendar: utcCalendar).route(
            "The report is ready for review, email this to the team",
            relativeTo: referenceNow
        )

        XCTAssertEqual(action.actionType, .email)
        XCTAssertEqual(action.contactName, "Team")
        XCTAssertEqual(action.draftContent, "The report is ready for review")
        XCTAssertFalse(action.emailSubject.isEmpty)
    }

    func testDeferredTailCommandTakesRecipientFromGreeting() {
        // Reproduces a live run: "Hi amma how are you? Send this now" names
        // nobody in the clause — the greeting is who the message is for.
        // Under the old pattern this fell to the brief path, which made
        // "Send this now" the card title and mailed it.
        XCTAssertTrue(DirectCommandDetector.isDirectCommand(
            "Hi amma how are you? Send this now"
        ))
        let action = DeterministicCommandRouter(calendar: utcCalendar).route(
            "Hi amma how are you? Send this now",
            relativeTo: referenceNow
        )
        XCTAssertEqual(action.actionType, .message)
        XCTAssertEqual(action.contactName, "Amma")
        XCTAssertEqual(action.draftContent, "Hi amma how are you?")
        XCTAssertEqual(action.priority, .high, "amma is a family keyword")
    }

    func testDeferredTailWithoutGreetingRoutesUnaddressed() {
        // No greeting, no "to X": still a message — the composer opens
        // unaddressed and the user picks the recipient there.
        let action = DeterministicCommandRouter(calendar: utcCalendar).route(
            "Running fifteen minutes late, text this now",
            relativeTo: referenceNow
        )
        XCTAssertEqual(action.actionType, .message)
        XCTAssertEqual(action.contactName, "")
        XCTAssertEqual(action.draftContent, "Running fifteen minutes late")
    }

    func testDeferredTailMustCloseTheInput() {
        // Mid-note "send this" is prose, not a command — only a clause that
        // ends the input routes.
        XCTAssertNil(DirectCommandDetector.deferredCommand(
            in: "Need to send this over after the review wraps"
        ))
        XCTAssertFalse(DirectCommandDetector.isDirectCommand(
            "Need to send this over after the review wraps"
        ))
        // And the clause alone still has no message to defer to.
        XCTAssertNil(DirectCommandDetector.deferredCommand(in: "Send this now"))
    }

    func testPartitionedDumpSeparatesCommandsFromCapture() {
        // Reproduces two live runs: four commands dumped one per line came
        // back as a brief that dropped two of them, and later one capture
        // sentence in the dump sank all four commands under the old
        // all-or-nothing rule.
        let allCommands = """
        text amma that Sunday brunch works, 11am at the usual place

        email HR about leave next week

        meeting with Rahul Thursday 3pm

        remind me to call mom tomorrow
        """
        let pure = DirectCommandDetector.partitionedDump(in: allCommands)
        XCTAssertEqual(pure?.commandLines.count, 4)
        XCTAssertEqual(pure?.captureText, "")

        let mixed = DirectCommandDetector.partitionedDump(in: """
        text amma that brunch works
        Call Mom tonight, pick up the birthday cake Saturday, and book the dentist for next week.
        """)
        XCTAssertEqual(mixed?.commandLines, ["text amma that brunch works"])
        XCTAssertEqual(
            mixed?.captureText,
            "Call Mom tonight, pick up the birthday cake Saturday, and book the dentist for next week."
        )

        // No command lines at all → a plain note for the brief path.
        XCTAssertNil(DirectCommandDetector.partitionedDump(in: """
        the quarterly numbers came in better than expected
        marketing wants a follow-up deck
        """))
        // A single command is the single-command path, not a batch.
        XCTAssertNil(DirectCommandDetector.partitionedDump(in: "text amma that brunch works"))
    }

    func testMixedDumpKeepsEveryCommandAndExtractsTheCapture() async throws {
        // The screenshot case: four commands plus one errand sentence must
        // produce the four routed cards AND the errand tasks — nothing
        // vanishes because a capture line rode along.
        let service = LocalAssistService()
        let summary = try await service.summarize(AssistantRequest(sourceText: """
        text Priya that Sunday brunch works, 11am at the usual place

        email HR about leave next week

        meeting with Rahul Thursday 3pm

        remind me to call mom tomorrow

        Call Mom tonight, pick up the birthday cake Saturday, and book the dentist for next week.
        """))

        XCTAssertEqual(summary.source, .deterministicFallback)
        let kinds = summary.actionDrafts.map(\.kind)
        XCTAssertEqual(
            Array(kinds.prefix(4)),
            [.messageDraft, .messageDraft, .calendarHold, .reminder],
            "the four command cards come first, in dump order"
        )
        XCTAssertGreaterThanOrEqual(
            summary.suggestions.count, 6,
            "the capture sentence contributes its own extracted tasks"
        )
        let titles = summary.suggestions.map(\.title).joined(separator: " | ").lowercased()
        XCTAssertTrue(titles.contains("priya"), titles)
        XCTAssertTrue(titles.contains("cake"), titles)
    }

    func testDeferredCommandSurvivesAbbreviationsInBody() {
        // A message body with mid-sentence periods ("Dr. Smith", decimals)
        // trips the naive sentence counter's "one sentence only" rule, so
        // the deferred pattern still has to catch it — otherwise this input
        // falls onto the brief path.
        XCTAssertTrue(DirectCommandDetector.isDirectCommand(
            "Dr. Smith said the results look good. Text this to mom"
        ))
        XCTAssertNotNil(DirectCommandDetector.deferredCommand(
            in: "Dr. Smith said the results look good. Text this to mom"
        ))
        let action = DeterministicCommandRouter(calendar: utcCalendar).route(
            "Dr. Smith said the results look good. Text this to mom",
            relativeTo: referenceNow
        )
        XCTAssertEqual(action.actionType, .message)
        XCTAssertEqual(action.contactName, "Mom")
        XCTAssertTrue(action.draftContent.contains("Dr. Smith"), "the abbreviation stays whole in the message body")
    }

    func testLeadingVerbOutranksDeferredClause() {
        // "remind me to text this to amma" is a reminder about texting,
        // not a text.
        let action = DeterministicCommandRouter(calendar: utcCalendar).route(
            "remind me to text this to amma",
            relativeTo: referenceNow
        )
        XCTAssertEqual(action.actionType, .reminder)
    }

    func testCommandDumpRoutesEveryLineToItsOwnCard() async throws {
        // Four commands in, four cards out — the rules engine is the floor
        // for every line individually, so no line can vanish the way the
        // brief path dropped two of them in the live run.
        let service = LocalAssistService()
        let dump = """
        text amma that Sunday brunch works, 11am at the usual place

        email HR about leave next week

        meeting with Rahul Thursday 3pm

        remind me to call mom tomorrow
        """

        let summary = try await service.summarize(AssistantRequest(sourceText: dump))

        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertTrue(summary.keyPoints.isEmpty, "routed batches carry no key points")
        XCTAssertEqual(summary.suggestions.count, 4)
        XCTAssertEqual(
            summary.actionDrafts.map(\.kind),
            [.messageDraft, .messageDraft, .calendarHold, .reminder]
        )
        XCTAssertEqual(summary.actionDrafts[0].payload["channel"], MessageChannel.textMessage.rawValue)
        XCTAssertEqual(summary.actionDrafts[1].payload["channel"], MessageChannel.email.rawValue)
        XCTAssertEqual(
            summary.actionDrafts[0].payload["recipient"], "amma",
            "recipient as written — Contacts matching is case-insensitive downstream"
        )
    }
}
