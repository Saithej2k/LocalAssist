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

/// Reconciler findings: every proposal gets a rule-ID + disposition record,
/// and the record never carries user content.
final class LocalAssistReconcilerFindingTests: XCTestCase {
    private func action(
        type: RoutedActionType = .message,
        priority: TaskPriority = .medium,
        contact: String = "Priya",
        date: String = "",
        time: String = "",
        location: String = "",
        draft: String = "Sunday brunch sounds perfect!",
        summary: String = "Message Priya: brunch"
    ) -> RoutedAction {
        RoutedAction(
            actionType: type,
            priority: priority,
            contactName: contact,
            date: date,
            time: time,
            location: location,
            draftContent: draft,
            emailSubject: "",
            summary: summary
        )
    }

    func testCleanAcceptRecordsAcceptedWithNoRules() {
        let outcome = RoutedActionReconciler.reconcile(
            [action()],
            sourceText: "text Priya that Sunday brunch works",
            calendar: utcCalendar,
            now: referenceNow
        )

        // "Sunday" in the command dates the action, so temporal correction
        // fires; use a command without cues for a clean accept.
        let noCue = RoutedActionReconciler.reconcile(
            [action(draft: "Brunch sounds perfect!", summary: "Message Priya: brunch")],
            sourceText: "text Priya that brunch works",
            calendar: utcCalendar,
            now: referenceNow
        )
        XCTAssertEqual(noCue.findings, [
            .init(proposalIndex: 0, disposition: .accepted, ruleIDs: [])
        ])
        XCTAssertEqual(outcome.actions.count, 1)
    }

    func testInadmissibleTypeRecordsRejection() {
        let outcome = RoutedActionReconciler.reconcile(
            [action(type: .reminder, contact: "", draft: "Pick up groceries", summary: "Reminder: groceries")],
            sourceText: "text Priya that brunch works",
            calendar: utcCalendar,
            now: referenceNow
        )

        XCTAssertTrue(outcome.actions.isEmpty)
        XCTAssertEqual(outcome.findings, [
            .init(
                proposalIndex: 0,
                disposition: .rejected,
                ruleIDs: [RoutedActionReconciler.RuleID.admissibleType]
            )
        ])
    }

    func testUngroundedActionRecordsSourceGroundingRejection() {
        let outcome = RoutedActionReconciler.reconcile(
            [action(draft: "Excited about the quarterly numbers dashboard")],
            sourceText: "text Priya that brunch works",
            calendar: utcCalendar,
            now: referenceNow
        )

        XCTAssertTrue(outcome.actions.isEmpty)
        XCTAssertEqual(
            outcome.findings.first?.ruleIDs,
            [RoutedActionReconciler.RuleID.sourceGrounding]
        )
    }

    func testDuplicateRecordsDeduplicationRejection() {
        let duplicate = action(draft: "Brunch sounds perfect!", summary: "Message Priya: brunch")
        let outcome = RoutedActionReconciler.reconcile(
            [duplicate, duplicate],
            sourceText: "text Priya that brunch works",
            calendar: utcCalendar,
            now: referenceNow
        )

        XCTAssertEqual(outcome.actions.count, 1)
        XCTAssertEqual(outcome.findings.count, 2)
        XCTAssertEqual(outcome.findings[0].disposition, .accepted)
        XCTAssertEqual(outcome.findings[1].disposition, .rejected)
        XCTAssertEqual(outcome.findings[1].ruleIDs, [RoutedActionReconciler.RuleID.deduplication])
    }

    func testClauseEchoRecordsRejection() {
        let echo = action(
            contact: "Amma",
            draft: "Text this to amma now.",
            summary: "Message Amma"
        )
        let real = action(
            contact: "Amma",
            draft: "Hi amma how are you doing?",
            summary: "Message Amma: checking in"
        )
        let outcome = RoutedActionReconciler.reconcile(
            [real, echo],
            sourceText: "Hi amma how are you doing, text this to amma now",
            calendar: utcCalendar,
            now: referenceNow
        )

        XCTAssertEqual(outcome.actions.count, 1)
        XCTAssertEqual(outcome.findings[1].disposition, .rejected)
        XCTAssertEqual(outcome.findings[1].ruleIDs, [RoutedActionReconciler.RuleID.clauseEcho])
    }

    func testModificationsRecordEveryFiredRule() {
        let embellished = action(
            contact: "Amma",
            date: "2026-07-09",
            time: "15:00",
            location: "Meeting Room",
            draft: "Hi amma how are you doing?",
            summary: "Message Amma: checking in"
        )
        let outcome = RoutedActionReconciler.reconcile(
            [embellished],
            sourceText: "Hi amma how are you doing, text this to amma now",
            calendar: utcCalendar,
            now: referenceNow
        )

        XCTAssertEqual(outcome.actions.count, 1)
        let finding = try? XCTUnwrap(outcome.findings.first)
        XCTAssertEqual(finding?.disposition, .modified)
        XCTAssertEqual(Set(finding?.ruleIDs ?? []), [
            RoutedActionReconciler.RuleID.locationGrounding,
            RoutedActionReconciler.RuleID.priorityFloor,
            RoutedActionReconciler.RuleID.temporalCorrection,
        ])
        XCTAssertEqual(outcome.actions.first?.location, "")
        XCTAssertEqual(outcome.actions.first?.priority, .high)
        XCTAssertEqual(outcome.actions.first?.date, "")
        XCTAssertEqual(outcome.actions.first?.time, "")
    }

    func testFindingsCarryNoContent() throws {
        let outcome = RoutedActionReconciler.reconcile(
            [action(draft: "SECRET-PHRASE brunch works perfectly today")],
            sourceText: "text Priya that SECRET-PHRASE brunch works perfectly today",
            calendar: utcCalendar,
            now: referenceNow
        )

        let encoded = try JSONEncoder().encode(outcome.findings)
        let json = try XCTUnwrap(String(bytes: encoded, encoding: .utf8))
        XCTAssertFalse(json.lowercased().contains("secret"), "findings must never embed user content")
        XCTAssertFalse(json.contains("Priya"))
    }

    func testFindingsSurviveDiagnosticsRoundTripAndLegacyDecode() throws {
        var diagnostics = GenerationDiagnostics(availability: .available)
        diagnostics.reconcilerFindings = [
            .init(proposalIndex: 0, disposition: .modified, ruleIDs: ["temporal-correction"])
        ]
        let data = try JSONEncoder().encode(diagnostics)
        let decoded = try JSONDecoder().decode(GenerationDiagnostics.self, from: data)
        XCTAssertEqual(decoded.reconcilerFindings, diagnostics.reconcilerFindings)

        // Diagnostics saved before the findings field existed still decode.
        let legacy = #"{"availability":{"available":{}},"toolInvocationCount":2}"#
        let legacyDecoded = try JSONDecoder().decode(
            GenerationDiagnostics.self,
            from: Data(legacy.utf8)
        )
        XCTAssertNil(legacyDecoded.reconcilerFindings)
        XCTAssertEqual(legacyDecoded.toolInvocationCount, 2)
    }
}

/// Calendar-semantics validation for generated dates — the shape guide can't
/// know February's length; this can.
final class LocalAssistDateValidatorTests: XCTestCase {
    func testValidDateParses() {
        guard case .valid(let date) = GeneratedDateTimeValidator.validateDate(
            "2026-07-12",
            calendar: utcCalendar
        ) else {
            return XCTFail("expected valid")
        }
        XCTAssertEqual(utcCalendar.component(.day, from: date), 12)
    }

    func testEmptyIsEmpty() {
        XCTAssertEqual(GeneratedDateTimeValidator.validateDate("", calendar: utcCalendar), .empty)
        XCTAssertEqual(GeneratedDateTimeValidator.validateTime("  "), .empty)
    }

    func testImpossibleCalendarDatesAreInvalid() {
        for value in ["2026-02-30", "2026-13-01", "2025-02-29", "2026-04-31", "2026-00-10"] {
            if case .valid = GeneratedDateTimeValidator.validateDate(value, calendar: utcCalendar) {
                XCTFail("\(value) must be invalid")
            }
        }
        // 2024 was a leap year: Feb 29 is real.
        if case .valid = GeneratedDateTimeValidator.validateDate("2024-02-29", calendar: utcCalendar) {
        } else {
            XCTFail("2024-02-29 is a real date")
        }
    }

    func testMalformedShapesAreInvalid() {
        for value in ["tomorrow", "07/12/2026", "2026-7-12", "20260712"] {
            if case .invalid = GeneratedDateTimeValidator.validateDate(value, calendar: utcCalendar) {
            } else {
                XCTFail("\(value) must be invalid")
            }
        }
    }

    func testTimeRanges() {
        if case .valid(let hour, let minute) = GeneratedDateTimeValidator.validateTime("23:59") {
            XCTAssertEqual(hour, 23)
            XCTAssertEqual(minute, 59)
        } else {
            XCTFail("23:59 is valid")
        }
        for value in ["24:00", "12:60", "3pm", "12", "12:5x"] {
            if case .invalid = GeneratedDateTimeValidator.validateTime(value) {
            } else {
                XCTFail("\(value) must be invalid")
            }
        }
    }

    func testReconcilerClearsCalendarInvalidModelDates() {
        // Pattern-valid, calendar-invalid: the model can emit "2026-02-30"
        // through the shape guide; the reconciler must not let it reach a
        // review card. The command carries a cue so the date branch engages.
        let action = RoutedAction(
            actionType: .reminder,
            priority: .medium,
            contactName: "",
            date: "2026-02-30",
            time: "99:99",
            location: "",
            draftContent: "Renew the car insurance",
            emailSubject: "",
            summary: "Reminder: renew car insurance"
        )
        let outcome = RoutedActionReconciler.reconcile(
            [action],
            sourceText: "remind me to renew the car insurance tomorrow",
            calendar: utcCalendar,
            now: referenceNow
        )
        XCTAssertEqual(outcome.actions.first?.date, "2026-07-08", "the command's own cue wins")
        XCTAssertEqual(outcome.actions.first?.time, "")
    }
}

/// Bounded deadlines: the losing side is cancelled, cancellation propagates,
/// and the thrown error names the stage without content.
final class LocalAssistDeadlineTests: XCTestCase {
    func testFastOperationWins() async throws {
        let value = try await LocalAssistDeadline.run(.seconds(5), stage: "test") {
            42
        }
        XCTAssertEqual(value, 42)
    }

    func testSlowOperationThrowsDeadlineExceeded() async {
        do {
            _ = try await LocalAssistDeadline.run(.milliseconds(50), stage: "generation") {
                try await Task.sleep(for: .seconds(10))
                return 0
            }
            XCTFail("expected DeadlineExceeded")
        } catch let deadline as DeadlineExceeded {
            XCTAssertEqual(deadline.stage, "generation")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDeadlineReleasesCallerWhenOperationCannotCancel() async {
        // The reason the race is unstructured: a synchronous XPC call
        // blocked inside a system daemon never checks Task.isCancelled. The
        // caller must still get its DeadlineExceeded at the budget instead
        // of waiting for the wedged call — the operation is abandoned.
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await LocalAssistDeadline.run(.milliseconds(100), stage: "wedged-service") {
                // Non-cooperative blocking work: ignores cancellation
                // entirely and would hold a structured group for 30s.
                var spun = 0
                let blockUntil = ContinuousClock.now.advanced(by: .seconds(30))
                while ContinuousClock.now < blockUntil {
                    spun += 1
                    if spun.isMultiple(of: 1_000_000) {
                        // No cancellation check on purpose.
                        await Task.yield()
                    }
                }
                return spun
            }
            XCTFail("expected DeadlineExceeded")
        } catch let deadline as DeadlineExceeded {
            XCTAssertEqual(deadline.stage, "wedged-service")
            let elapsed = started.duration(to: clock.now)
            XCTAssertLessThan(
                elapsed, .seconds(5),
                "caller must be released at the budget, not when the wedged work ends"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOuterCancellationReleasesUncooperativeOperationImmediately() async {
        // The gate must resume with CancellationError from the cancellation
        // handler itself — not wait for the operation to notice (it never
        // will) and not wait for the budget (30 s away).
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await LocalAssistDeadline.run(.seconds(30), stage: "uncooperative") { () -> Int in
                var spun = 0
                let blockUntil = ContinuousClock.now.advanced(by: .seconds(30))
                while ContinuousClock.now < blockUntil {
                    spun += 1
                    if spun.isMultiple(of: 1_000_000) {
                        // Yields without ever checking Task.isCancelled.
                        await Task.yield()
                    }
                }
                return spun
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(
                started.duration(to: clock.now), .seconds(5),
                "outer cancel must release the caller now, not at the budget"
            )
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testOuterCancellationPropagates() async {
        let task = Task {
            try await LocalAssistDeadline.run(.seconds(30), stage: "test") {
                try await Task.sleep(for: .seconds(30))
                return 0
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "outer cancel must surface as CancellationError, got \(error)"
            )
        }
    }

    func testTimedOutFailureCategory() {
        XCTAssertEqual(GenerationFailure.timedOut(stage: "generation").category, "timedOut")
        XCTAssertEqual(
            GenerationFailure.timedOut(stage: "generation").description,
            "timedOut: generation"
        )
        XCTAssertFalse(GenerationFailure.timedOut(stage: "generation").userMessage.isEmpty)
    }

    func testEveryFailureHasStableCategory() {
        let failures: [GenerationFailure] = [
            .modelUnavailable(ModelUnavailability(reason: .modelNotReady)),
            .guardrailViolation(detail: "x"),
            .refused(explanation: "x"),
            .contextWindowExceeded(detail: "x"),
            .unsupportedLanguage(detail: "x"),
            .decodingFailure(detail: "x"),
            .rateLimited(detail: "x"),
            .concurrentRequests(detail: "x"),
            .toolExecutionFailed(tool: "calendar", detail: "x"),
            .timedOut(stage: "x"),
            .unknown(detail: "x"),
        ]
        let categories = failures.map(\.category)
        XCTAssertEqual(Set(categories).count, failures.count, "categories must be distinct")
        for category in categories {
            XCTAssertFalse(category.contains(" "))
        }
    }
}
