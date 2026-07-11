import Foundation
import Synchronization
import XCTest
@testable import LocalAssistCore
@testable import LocalAssistEvalKit
@testable import LocalAssistSystemTools

/// Model client that counts every call, so tests can prove the
/// deterministic fallback never consults the model once it begins.
private final class CountingModelClient: StructuredModelClient, Sendable {
    private let calls = Mutex((stream: 0, route: 0))
    private let failure: GenerationFailure?
    private let script: [StructuredSummaryPartial]

    init(failure: GenerationFailure?, script: [StructuredSummaryPartial] = []) {
        self.failure = failure
        self.script = script
    }

    var streamCallCount: Int {
        calls.withLock { $0.stream }
    }

    var routeCallCount: Int {
        calls.withLock { $0.route }
    }

    func availability() async -> ModelAvailability {
        .available
    }

    func prewarm() async {}

    func streamSummary(for _: AssistantRequest) -> AsyncThrowingStream<StructuredSummaryPartial, Error> {
        calls.withLock { $0.stream += 1 }
        let failure = failure
        let script = script
        return AsyncThrowingStream { continuation in
            for chunk in script {
                continuation.yield(chunk)
            }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }

    func routeCommand(for _: AssistantRequest) async throws -> [RoutedAction]? {
        calls.withLock { $0.route += 1 }
        if let failure {
            throw failure
        }
        return nil
    }
}

/// Once the fallback begins, the model is out of the loop: exactly one
/// model pass happens per request, and the deterministic engine completes
/// without any further model call.
final class LocalAssistFallbackProofTests: XCTestCase {
    private let noteText = "Ship the hotfix tonight and confirm the rollout with Dana."

    func testFallbackMakesNoModelCallsAfterItBegins() async throws {
        let client = CountingModelClient(failure: .decodingFailure(detail: "injected"))
        let service = LocalAssistService(model: client)

        var sawFallbackPhase = false
        var callsWhenFallbackBegan = 0
        var summary: StructuredSummary?
        for try await update in service.streamSummary(AssistantRequest(sourceText: noteText)) {
            if update.phase == .fallback, !sawFallbackPhase {
                sawFallbackPhase = true
                callsWhenFallbackBegan = client.streamCallCount
            }
            if let final = update.summary {
                summary = final
            }
        }

        XCTAssertTrue(sawFallbackPhase)
        XCTAssertEqual(summary?.source, .deterministicFallback)
        XCTAssertEqual(callsWhenFallbackBegan, 1, "one model pass before the fallback")
        XCTAssertEqual(
            client.streamCallCount, callsWhenFallbackBegan,
            "zero model calls after fallback began"
        )
        XCTAssertEqual(client.routeCallCount, 0)
    }

    func testEveryTypedFailureFallsBackToDeterministicEngine() async throws {
        let failures: [GenerationFailure] = [
            .modelUnavailable(ModelUnavailability(reason: .modelNotReady)),
            .guardrailViolation(detail: "probe"),
            .refused(explanation: "probe"),
            .contextWindowExceeded(detail: "probe"),
            .unsupportedLanguage(detail: "probe"),
            .decodingFailure(detail: "probe"),
            .rateLimited(detail: "probe"),
            .concurrentRequests(detail: "probe"),
            .toolExecutionFailed(tool: "calendar", detail: "probe"),
            .timedOut(stage: "model-response"),
            .unknown(detail: "probe"),
        ]

        for failure in failures {
            let client = CountingModelClient(failure: failure)
            let service = LocalAssistService(model: client)
            let summary = try await service.summarize(AssistantRequest(sourceText: noteText))

            XCTAssertEqual(
                summary.source, .deterministicFallback,
                "\(failure.category) must fall back"
            )
            XCTAssertEqual(
                summary.diagnostics.failureCategory, failure.category,
                "\(failure.category) must be recorded as the failure category"
            )
            XCTAssertFalse(summary.suggestions.isEmpty, "\(failure.category) still yields tasks")
        }
    }

    func testIncompleteStreamFallsBackWithSummary() async throws {
        // Stream ends cleanly but never delivers a complete partial — the
        // suspended-app shape.
        let client = CountingModelClient(
            failure: nil,
            script: [StructuredSummaryPartial(overview: "Half", isComplete: false)]
        )
        let service = LocalAssistService(model: client)
        let summary = try await service.summarize(AssistantRequest(sourceText: noteText))
        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertEqual(summary.diagnostics.failureCategory, "decodingFailure")
        XCTAssertEqual(client.streamCallCount, 1)
    }

    func testModelResponseDeadlineExpiryFallsBackAsTimedOut() async throws {
        let client = StaticStructuredModelClient(
            script: [StructuredSummaryPartial(overview: "Slow", isComplete: true)],
            initialDelayNanoseconds: 5_000_000_000
        )
        let service = LocalAssistService(
            model: client,
            modelResponseDeadline: .milliseconds(80)
        )
        let summary = try await service.summarize(AssistantRequest(sourceText: noteText))
        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertEqual(summary.diagnostics.failureCategory, "timedOut")
    }

    func testConcurrentRequestsBothComplete() async throws {
        let service = LocalAssistService()
        let request = AssistantRequest(sourceText: noteText)
        async let first = service.summarize(request)
        async let second = service.summarize(request)
        let (firstSummary, secondSummary) = try await (first, second)
        XCTAssertFalse(firstSummary.suggestions.isEmpty)
        XCTAssertEqual(
            firstSummary.headline, secondSummary.headline,
            "deterministic engine is stable under concurrency"
        )
    }
}

/// Executor boundary: only Sendable receipt DTOs cross out of the write
/// store, and the receipt carries the created item's system identifier.
final class LocalAssistExecutorReceiptTests: XCTestCase {
    func testReminderExecutionReturnsReceiptWithSystemIdentifier() async throws {
        let store = RecordingWriteStore()
        let executor = SystemActionExecutor(
            store: store,
            calendar: .current,
            now: { Date(timeIntervalSince1970: 1_780_000_000) }
        )
        let action = PreparedToolAction(
            id: "a1",
            draft: ToolActionDraft(
                kind: .reminder,
                title: "Renew insurance",
                payload: ["title": "Renew insurance", "dueDate": "tomorrow"]
            ),
            state: .readyForConfirmation,
            confirmationTitle: "Renew insurance",
            confirmationMessage: "confirm"
        )

        let executed = try await executor.execute(action)

        guard case .executed(_, let identifier) = executed.outcome else {
            return XCTFail("expected a real write receipt")
        }
        XCTAssertEqual(identifier, "recorded-reminder-1")
        XCTAssertTrue(executed.didWriteToSystem)
        let recorded = await store.reminders
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.title, "Renew insurance")
        XCTAssertNotNil(recorded.first?.due, "the due hint resolved to a real date")
    }

    func testExecutionRespectsCancellation() async {
        let store = RecordingWriteStore()
        let executor = SystemActionExecutor(store: store)
        let action = PreparedToolAction(
            id: "a2",
            draft: ToolActionDraft(kind: .reminder, title: "t", payload: [:]),
            state: .readyForConfirmation,
            confirmationTitle: "t",
            confirmationMessage: "m"
        )
        let task = Task {
            try await executor.execute(action)
        }
        task.cancel()
        do {
            _ = try await task.value
            // A fast path may still complete before the cancel lands —
            // acceptable; the contract is no partial writes on cancel.
        } catch {
            let written = await store.reminders
            XCTAssertTrue(written.isEmpty, "cancelled execution must not write")
        }
    }
}

/// Due-date scoring resolves calendar dates instead of substring matching.
final class LocalAssistEvalScorerDateTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Tuesday, July 7, 2026, noon UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 12))!
    }

    private func suggestion(dueHint: String?, dueDate: Date?) -> TaskSuggestion {
        TaskSuggestion(
            id: "s",
            title: "send mira the blockers",
            priority: .medium,
            dueHint: dueHint,
            dueDate: dueDate,
            action: .messageDraft,
            rationale: "r",
            confidence: 0.8
        )
    }

    func testISOOutputMatchesNaturalLanguageExpectation() {
        // "friday" from 2026-07-07 resolves to 2026-07-10; an ISO hint for
        // that day matches even though the string "friday" appears nowhere.
        XCTAssertTrue(EvalScorer.dueDateMatches(
            expected: "friday",
            suggestion: suggestion(dueHint: "2026-07-10", dueDate: nil),
            calendar: calendar,
            now: now
        ))
    }

    func testResolvedDueDateMatchesExpectation() {
        let friday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 9))!
        XCTAssertTrue(EvalScorer.dueDateMatches(
            expected: "friday",
            suggestion: suggestion(dueHint: nil, dueDate: friday),
            calendar: calendar,
            now: now
        ))
    }

    func testWrongDayFailsEvenWithMatchingSubstring() {
        // The hint literally contains "friday" but resolves to the wrong
        // calendar day — the date comparison must win over the substring.
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11, hour: 9))!
        XCTAssertFalse(EvalScorer.dueDateMatches(
            expected: "friday",
            suggestion: suggestion(dueHint: "friday-ish", dueDate: saturday),
            calendar: calendar,
            now: now
        ))
    }

    func testUnparseableExpectationFallsBackToSubstring() {
        XCTAssertTrue(EvalScorer.dueDateMatches(
            expected: "someday",
            suggestion: suggestion(dueHint: "someday soon", dueDate: nil),
            calendar: calendar,
            now: now
        ))
        XCTAssertFalse(EvalScorer.dueDateMatches(
            expected: "someday",
            suggestion: suggestion(dueHint: "next week", dueDate: nil),
            calendar: calendar,
            now: now
        ))
    }

    func testDatedExpectationAgainstUndatedSuggestionUsesTextEcho() {
        XCTAssertTrue(EvalScorer.dueDateMatches(
            expected: "next week",
            suggestion: suggestion(dueHint: "sometime next week", dueDate: nil),
            calendar: calendar,
            now: now
        ))
        XCTAssertFalse(EvalScorer.dueDateMatches(
            expected: "next week",
            suggestion: suggestion(dueHint: nil, dueDate: nil),
            calendar: calendar,
            now: now
        ))
    }
}
