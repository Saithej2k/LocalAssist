import Foundation
import XCTest
import LocalAssistAppUI
@testable import LocalAssistCore

/// Capture-behavior regressions: local-day due dates, dictation
/// accumulation, capture-kind inference, and degenerate inputs. Split
/// from the engine suite by topic.
final class LocalAssistCaptureBehaviorTests: XCTestCase {
    func testBareDueDatesUseTheLocalCalendarDay() throws {
        // A bare model date like "2026-07-06" means that day where the user
        // is. Parsing it as GMT midnight shifted it into the previous local
        // day everywhere west of GMT.
        let parsed = try XCTUnwrap(LocalAssistDates.parse("2026-07-06"))
        let components = Calendar.current.dateComponents([.year, .month, .day], from: parsed)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 6)
        XCTAssertEqual(LocalAssistDates.dateOnlyString(from: parsed), "2026-07-06")

        // Full timestamps still parse as instants.
        XCTAssertEqual(
            LocalAssistDates.parse("2026-07-01T12:00:00Z"),
            Date(timeIntervalSince1970: 1_782_907_200)
        )

        // Injectable-calendar call sites can pin an explicit zone.
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let tokyoParsed = try XCTUnwrap(LocalAssistDates.parse("2026-07-06", timeZone: tokyo))
        XCTAssertEqual(LocalAssistDates.dateOnlyString(from: tokyoParsed, timeZone: tokyo), "2026-07-06")
    }

    func testModelDueTodayTaskSurvivesNormalizationAndRoundtrip() throws {
        let today = LocalAssistDates.dateOnlyString(from: Date())
        let partial = StructuredSummaryPartial(
            overview: "Blockers are due today.",
            keyPoints: ["Send the blockers today"],
            suggestions: [
                TaskSuggestionPartial(
                    title: "Send Mira the blockers",
                    priority: .high,
                    dueHint: today,
                    action: .messageDraft,
                    rationale: "The deadline is explicit.",
                    confidence: 0.9
                ),
            ],
            isComplete: true
        )

        let summary = try XCTUnwrap(SummaryNormalizer().summary(
            from: partial,
            request: AssistantRequest(sourceText: "Send Mira the blockers today."),
            availability: .available
        ))

        let dueDate = try XCTUnwrap(summary.suggestions.first?.dueDate)
        XCTAssertTrue(
            Calendar.current.isDateInToday(dueDate),
            "a due-today model date must not be dropped as stale or shifted a day"
        )

        // Codable roundtrip through saved history keeps the calendar day.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            StructuredSummary.self,
            from: SummaryFormatter.jsonData(summary)
        )
        let decodedDue = try XCTUnwrap(decoded.suggestions.first?.dueDate)
        XCTAssertTrue(Calendar.current.isDateInToday(decodedDue))
    }

    func testNormalizerPrefersDeterministicDayNamesOverModelDates() throws {
        // The model resolved "by Wednesday" to a Tuesday; the title still
        // names the day, so the deterministic parser must correct it.
        let wrongModelDate = Calendar.current.date(byAdding: .day, value: 8, to: Date())
        let partial = StructuredSummaryPartial(
            overview: "Tax paperwork is due midweek.",
            keyPoints: ["The tax paperwork is due by Wednesday"],
            suggestions: [
                TaskSuggestionPartial(
                    title: "Finish the tax paperwork by Wednesday",
                    priority: .high,
                    dueDate: wrongModelDate
                ),
            ],
            isComplete: true
        )

        let summary = try XCTUnwrap(SummaryNormalizer().summary(
            from: partial,
            request: AssistantRequest(sourceText: "Finish the tax paperwork by Wednesday."),
            availability: .available
        ))

        let dueDate = try XCTUnwrap(summary.suggestions.first?.dueDate)
        XCTAssertEqual(
            Calendar.current.component(.weekday, from: dueDate), 4,
            "a title naming Wednesday must resolve to an actual Wednesday"
        )
    }

    @MainActor
    func testVoiceMergeAppendsAcrossRecordingSessions() {
        // Second recording sessions must append to what earlier sessions
        // (or typing) put in the box — the snapshot happens synchronously
        // in prepareVoiceCapture, so no UI-observation race can lose it.
        let viewModel = LocalAssistViewModel(worker: LocalAssistWorker(historyStore: nil))

        viewModel.prepareVoiceCapture()
        viewModel.mergeVoiceTranscript("Call Mom tonight")
        viewModel.mergeVoiceTranscript("Call Mom tonight, grab the birthday cake Saturday")
        XCTAssertEqual(viewModel.inputText, "Call Mom tonight, grab the birthday cake Saturday")

        // User stops, then taps the mic again for a second session.
        viewModel.prepareVoiceCapture()
        viewModel.mergeVoiceTranscript("And also text Priya")
        XCTAssertEqual(
            viewModel.inputText,
            "Call Mom tonight, grab the birthday cake Saturday\nAnd also text Priya"
        )

        // Empty partials never wipe anything.
        viewModel.mergeVoiceTranscript("   ")
        XCTAssertEqual(
            viewModel.inputText,
            "Call Mom tonight, grab the birthday cake Saturday\nAnd also text Priya"
        )
    }

    func testDictationSurvivesPausesEndedByErrorNotFinal() {
        // The exact reported flow: speak, pause (the on-device recognizer
        // ends the segment with "no speech detected" instead of a final),
        // keep speaking. Earlier words must never disappear.
        var dictation = DictationAccumulator()

        dictation.updatePartial("Call Mom tonight")
        dictation.updatePartial("Call Mom tonight, grab the birthday cake Saturday")
        dictation.endSegmentWithoutFinal()
        XCTAssertEqual(dictation.transcript, "Call Mom tonight, grab the birthday cake Saturday")

        dictation.updatePartial("text Priya")
        XCTAssertEqual(
            dictation.transcript,
            "Call Mom tonight, grab the birthday cake Saturday text Priya"
        )

        dictation.finalizeSegment("text Priya about brunch")
        XCTAssertTrue(dictation.transcript.hasPrefix("Call Mom tonight, grab the birthday cake Saturday"))
        XCTAssertTrue(dictation.transcript.hasSuffix("text Priya about brunch"))
    }

    func testDictationSurvivesHypothesisResetsWithoutFinalsOrErrors() {
        // The exact pattern from the 2026-07-06 screen recording on device:
        // one recognition runs the whole time, never sending finals or
        // errors — after each pause its partial hypothesis resets and the
        // next phrase starts overwriting the previous one. New utterances
        // stream word by word, so their first partial is short.
        var dictation = DictationAccumulator()

        dictation.updatePartial("Call")
        dictation.updatePartial("Call mom")
        dictation.updatePartial("Call mom tonight")

        // Pause. Hypothesis resets; the next phrase arrives incrementally.
        dictation.updatePartial("And")
        XCTAssertEqual(dictation.finalizedText, "Call mom tonight")
        dictation.updatePartial("And grab the birthday")
        dictation.updatePartial("And grab the birthday cake Saturday")
        XCTAssertEqual(dictation.transcript, "Call mom tonight And grab the birthday cake Saturday")

        // Second pause, third phrase.
        dictation.updatePartial("And also")
        dictation.updatePartial("And also text Priya")
        XCTAssertEqual(
            dictation.transcript,
            "Call mom tonight And grab the birthday cake Saturday And also text Priya"
        )

        // In-utterance revisions that shrink but remain prefixes must NOT fold.
        var revising = DictationAccumulator()
        revising.updatePartial("Call mommy")
        revising.updatePartial("Call mom")
        XCTAssertEqual(revising.finalizedText, "")
        XCTAssertEqual(revising.transcript, "Call mom")
    }

    func testDictationFoldsLateFinalsFromSupersededSegments() {
        // The on-device recognizer can withhold partials entirely and send
        // the pause error BEFORE the utterance's final text. That late
        // final is the only carrier of the words — it must fold in even
        // though the pipeline already chained to the next segment.
        var dictation = DictationAccumulator()

        dictation.endSegmentWithoutFinal() // pause error arrived first; nothing live to fold
        dictation.foldCompletedSegment("Call Mom tonight, grab the birthday cake Saturday")
        XCTAssertEqual(dictation.transcript, "Call Mom tonight, grab the birthday cake Saturday")

        // The same final delivered twice must not duplicate.
        dictation.foldCompletedSegment("Call Mom tonight, grab the birthday cake Saturday")
        XCTAssertEqual(dictation.transcript, "Call Mom tonight, grab the birthday cake Saturday")

        // The next utterance finalizes on the live segment as usual.
        dictation.finalizeSegment("and also text Priya")
        XCTAssertEqual(
            dictation.transcript,
            "Call Mom tonight, grab the birthday cake Saturday and also text Priya"
        )
    }

    func testDictationKeepsLongerHypothesisWhenFinalCollapses() {
        // Mixed-language finals can re-score to something shorter than the
        // partial the user watched appear; the longer text must win — this
        // was the "stop cleared everything" report.
        var dictation = DictationAccumulator()
        dictation.updatePartial("Call Mom tonight and pay the electricity bill")
        dictation.finalizeSegment("hi")
        XCTAssertEqual(dictation.transcript, "Call Mom tonight and pay the electricity bill")

        // A richer final (the usual case) is preferred over the partial.
        dictation.updatePartial("book the dentist")
        dictation.finalizeSegment("Book the dentist for next week.")
        XCTAssertTrue(dictation.transcript.hasSuffix("Book the dentist for next week."))
    }

    func testSmartPathInfersActionsForTextAndCallVerbs() throws {
        // The model's schema carries no action field, so actions are always
        // inferred from titles — the Smart path must route the same verbs
        // as the rules engine ("Text Priya" is a message, not a reminder).
        let partial = StructuredSummaryPartial(
            overview: "Family errands for the week.",
            keyPoints: ["Several follow-ups today"],
            suggestions: [
                TaskSuggestionPartial(title: "Text Priya about Sunday brunch", priority: .low),
                TaskSuggestionPartial(title: "Call the pharmacy to check on refills", priority: .medium),
                TaskSuggestionPartial(title: "Email the landlord about the heater", priority: .high),
                TaskSuggestionPartial(title: "Update the packing checklist", priority: .low),
            ],
            isComplete: true
        )

        let summary = try XCTUnwrap(SummaryNormalizer().summary(
            from: partial,
            request: AssistantRequest(sourceText: "irrelevant"),
            availability: .available
        ))

        let actions = summary.suggestions.map(\.action)
        XCTAssertEqual(actions, [.messageDraft, .reminder, .messageDraft, .checklistItem])
    }

    func testInputKindInferenceClassifiesWithoutUserChoice() {
        XCTAssertEqual(
            AssistantInputKind.inferred(from: "Standup notes: infra is blocked, Priya shares the runbook, book a war room Thursday."),
            .meeting
        )
        XCTAssertEqual(
            AssistantInputKind.inferred(from: "Pay the electricity bill and book a dentist appointment tomorrow."),
            .personalAdmin
        )
        XCTAssertEqual(
            AssistantInputKind.inferred(from: "Ship the hotfix build tonight and confirm the rollout with Dana."),
            .note
        )
    }

    func testChunkerHandlesDegenerateInput() {
        XCTAssertEqual(TranscriptChunker.chunks(from: ""), [])
        XCTAssertFalse(TranscriptChunker.chunks(from: "   \n  ").isEmpty)
        XCTAssertEqual(TranscriptChunker.digest(of: []), "")
    }

    func testNormalizerRejectsEmptyPartial() {
        XCTAssertNil(SummaryNormalizer().summary(
            from: StructuredSummaryPartial(),
            request: AssistantRequest(sourceText: "anything"),
            availability: .available
        ))
    }
}
