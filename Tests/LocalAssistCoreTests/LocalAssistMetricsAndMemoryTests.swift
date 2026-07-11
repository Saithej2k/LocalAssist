import Foundation
import XCTest
@testable import LocalAssistCore

/// Stage-timing collection from generation-stream events: TTFT exactly
/// once, phase durations from transitions, fallback handoff/completion.
final class LocalAssistStageTimingCollectorTests: XCTestCase {
    private var start: ContinuousClock.Instant {
        ContinuousClock().now
    }

    func testHappyModelPathTimings() {
        let base = start
        var collector = StageTimingCollector(startedAt: base)
        collector.record(
            phase: .validating, hasPartial: false, hasSummary: false,
            at: base
        )
        collector.record(
            phase: .checkingAvailability, hasPartial: false, hasSummary: false,
            at: base.advanced(by: .milliseconds(5))
        )
        collector.record(
            phase: .streamingModel, hasPartial: false, hasSummary: false,
            at: base.advanced(by: .milliseconds(45))
        )
        collector.record(
            phase: .streamingModel, hasPartial: true, hasSummary: false,
            at: base.advanced(by: .milliseconds(400))
        )
        collector.record(
            phase: .normalizing, hasPartial: true, hasSummary: false,
            at: base.advanced(by: .milliseconds(2_000))
        )
        collector.record(
            phase: .completed, hasPartial: true, hasSummary: true,
            at: base.advanced(by: .milliseconds(2_050))
        )

        let timings = collector.collected
        XCTAssertEqual(timings.validationMilliseconds ?? 0, 5, accuracy: 0.01)
        XCTAssertEqual(timings.availabilityMilliseconds ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(timings.timeToFirstPartialMilliseconds ?? 0, 400, accuracy: 0.01)
        XCTAssertEqual(timings.normalizationMilliseconds ?? 0, 50, accuracy: 0.01)
        XCTAssertEqual(timings.generationCompletedMilliseconds ?? 0, 2_050, accuracy: 0.01)
        XCTAssertEqual(timings.modelResponseMilliseconds ?? 0, 2_005, accuracy: 0.01)
        XCTAssertNil(timings.fallbackHandoffMilliseconds, "no fallback ran")
        XCTAssertNil(timings.fallbackCompletionMilliseconds)
    }

    func testFirstPartialRecordsExactlyOnce() {
        let base = start
        var collector = StageTimingCollector(startedAt: base)
        collector.record(
            phase: .streamingModel, hasPartial: true, hasSummary: false,
            at: base.advanced(by: .milliseconds(300))
        )
        collector.record(
            phase: .streamingModel, hasPartial: true, hasSummary: false,
            at: base.advanced(by: .milliseconds(900))
        )
        XCTAssertEqual(
            collector.collected.timeToFirstPartialMilliseconds ?? 0, 300, accuracy: 0.01
        )
    }

    func testFallbackHandoffAndCompletion() {
        let base = start
        var collector = StageTimingCollector(startedAt: base)
        collector.record(
            phase: .validating, hasPartial: false, hasSummary: false, at: base
        )
        collector.record(
            phase: .fallback, hasPartial: false, hasSummary: false,
            at: base.advanced(by: .milliseconds(100))
        )
        collector.record(
            phase: .completed, hasPartial: true, hasSummary: true,
            at: base.advanced(by: .milliseconds(130))
        )

        let timings = collector.collected
        XCTAssertEqual(timings.fallbackHandoffMilliseconds ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(timings.fallbackCompletionMilliseconds ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(timings.timeToFirstPartialMilliseconds ?? 0, 130, accuracy: 0.01)
    }

    func testActionStagesRecord() {
        var collector = StageTimingCollector()
        collector.recordActionPreparation(.milliseconds(12))
        collector.recordActionReviewReady()
        XCTAssertEqual(collector.collected.actionPreparationMilliseconds ?? 0, 12, accuracy: 0.01)
        XCTAssertNotNil(collector.collected.actionReviewReadyMilliseconds)
    }
}

/// RunMetrics backward compatibility: history saved before the 2026-07
/// fields decodes, and the new fields round-trip.
final class LocalAssistRunMetricsCompatibilityTests: XCTestCase {
    func testLegacyMetricsJSONStillDecodes() throws {
        let legacy = """
        {
            "startedAt": "2026-07-01T12:00:00Z",
            "finishedAt": "2026-07-01T12:00:01Z",
            "durationMilliseconds": 1000,
            "source": "deterministicFallback",
            "suggestionCount": 3,
            "actionDraftCount": 3,
            "keyPointCount": 2,
            "inputCharacterCount": 120,
            "outputByteCount": 900,
            "cancelled": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metrics = try decoder.decode(RunMetrics.self, from: Data(legacy.utf8))
        XCTAssertNil(metrics.stageTimings)
        XCTAssertNil(metrics.environment)
        XCTAssertNil(metrics.context)
        XCTAssertNil(metrics.failureCategory)
        XCTAssertEqual(metrics.suggestionCount, 3)
    }

    func testExtendedMetricsRoundTrip() throws {
        var timings = RunStageTimings()
        timings.timeToFirstPartialMilliseconds = 410.5
        timings.persistenceMilliseconds = 4.2
        let metrics = RunMetrics(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_002),
            durationMilliseconds: 2_000,
            source: .foundationModels,
            suggestionCount: 2,
            actionDraftCount: 2,
            stageTimings: timings,
            environment: RunEnvironment.current(coldStart: true),
            context: ContextWindowDiagnostics(
                estimatedPromptCharacters: 800,
                estimatedTranscriptCharacters: 2_000,
                retainedExchanges: 2,
                proactiveRebuildCount: 1,
                overflowCount: 0
            ),
            failureCategory: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RunMetrics.self, from: encoder.encode(metrics))
        XCTAssertEqual(decoded.stageTimings, timings)
        XCTAssertEqual(decoded.context?.proactiveRebuildCount, 1)
        XCTAssertEqual(decoded.environment?.coldStart, true)
    }
}

/// Redacted diagnostics export: structurally content-free.
final class LocalAssistDiagnosticsExportTests: XCTestCase {
    private func sampleRun(text: String, headline: String, taskTitle: String) -> AssistantRun {
        let suggestion = TaskSuggestion(
            id: "t1",
            title: taskTitle,
            priority: .high,
            dueHint: "friday",
            action: .reminder,
            rationale: "from the note",
            confidence: 0.8
        )
        let summary = StructuredSummary(
            overview: headline,
            keyPoints: ["a key point with SECRET-CONTENT"],
            suggestions: [suggestion],
            actionDrafts: [ToolActionDraft(kind: .reminder, title: taskTitle, payload: ["title": taskTitle])],
            source: .deterministicFallback,
            diagnostics: GenerationDiagnostics(
                availability: .unavailable(ModelUnavailability(reason: .forcedOffline)),
                fallbackReason: "refused: model saw SECRET-CONTENT and stopped",
                failureCategory: "refused"
            )
        )
        return AssistantRun(
            request: AssistantRequest(sourceText: text),
            summary: summary,
            metrics: RunMetrics(
                startedAt: Date(),
                finishedAt: Date(),
                durationMilliseconds: 42,
                source: .deterministicFallback,
                suggestionCount: 1,
                actionDraftCount: 1,
                fallbackReason: "refused: model saw SECRET-CONTENT and stopped",
                failureCategory: "refused"
            )
        )
    }

    func testExportCarriesNoContent() throws {
        let run = sampleRun(
            text: "SECRET-CONTENT call mom about the SECRET-CONTENT",
            headline: "SECRET-CONTENT headline",
            taskTitle: "Call mom about SECRET-CONTENT"
        )
        let export = DiagnosticsExporter.export(runs: [run])
        let json = try XCTUnwrap(
            String(bytes: DiagnosticsExporter.jsonData(export), encoding: .utf8)
        )

        XCTAssertFalse(json.contains("SECRET-CONTENT"), "no note, headline, task, or failure detail text")
        XCTAssertFalse(json.contains("call mom"))
        XCTAssertTrue(json.contains("refused"), "the stable category survives")
        XCTAssertTrue(json.contains("\"formatVersion\" : 1"))
    }

    func testExportKeepsInvestigationSignal() throws {
        let run = sampleRun(text: "note", headline: "h", taskTitle: "t")
        let export = DiagnosticsExporter.export(
            runs: [run],
            lastVoiceSessionTimings: ["firstPartialMilliseconds": 812],
            lastPersistenceMilliseconds: 3.4
        )
        XCTAssertEqual(export.runs.count, 1)
        XCTAssertEqual(export.runs.first?.failureCategory, "refused")
        XCTAssertEqual(export.runs.first?.unavailabilityReason, .forcedOffline)
        XCTAssertEqual(export.lastVoiceSessionTimings?["firstPartialMilliseconds"], 812)
        XCTAssertEqual(export.lastPersistenceMilliseconds, 3.4)
        XCTAssertEqual(export.aggregate.runCount, 1)
    }
}

/// ConversationMemory under pressure: tiny budgets and a 30-turn
/// refinement conversation.
final class LocalAssistConversationMemoryStressTests: XCTestCase {
    private func summary(headline: String, tasks: [String]) -> StructuredSummary {
        StructuredSummary(
            overview: headline,
            keyPoints: ["point"],
            suggestions: tasks.map {
                TaskSuggestion(
                    id: $0, title: $0, priority: .medium, dueHint: nil,
                    action: .reminder, rationale: "r", confidence: 0.7
                )
            },
            actionDrafts: [],
            source: .foundationModels,
            diagnostics: GenerationDiagnostics(availability: .available)
        )
    }

    func testForcedSmallBudgetStillProducesUsableContext() {
        var memory = ConversationMemory(maxExchanges: 6, condensedCharacterBudget: 80)
        for turn in 1 ... 6 {
            memory.record(
                request: AssistantRequest(sourceText: "note \(turn) with plenty of words"),
                summary: summary(headline: "Headline for turn \(turn)", tasks: ["Task \(turn)"])
            )
        }
        let context = memory.condensedContext()
        XCTAssertNotNil(context)
        // Header line plus whatever exchanges fit the 80-character budget —
        // newest first, so the last turn always survives.
        XCTAssertTrue(context?.contains("turn 6") ?? false)
        XCTAssertLessThan(context?.count ?? .max, 80 + 80, "budget bounds the digest")
    }

    func testBudgetTooSmallForAnyExchangeStillReturnsHeader() {
        var memory = ConversationMemory(maxExchanges: 3, condensedCharacterBudget: 1)
        memory.record(
            request: AssistantRequest(sourceText: "note"),
            summary: summary(headline: "A very long headline that cannot fit", tasks: [])
        )
        XCTAssertNotNil(memory.condensedContext(), "non-empty history always yields a digest")
    }

    func testThirtyTurnRefinementConversationStaysBounded() {
        var memory = ConversationMemory(maxExchanges: 6, condensedCharacterBudget: 1_200)
        for turn in 1 ... 30 {
            memory.record(
                request: AssistantRequest(
                    sourceText: "refinement instruction number \(turn): tighten the tasks",
                    isRefinement: turn > 1
                ),
                summary: summary(
                    headline: "Brief after refinement \(turn)",
                    tasks: (0 ..< 5).map { "Task \(turn)-\($0)" }
                )
            )
        }

        XCTAssertEqual(memory.exchanges.count, 6, "rolling window holds")
        XCTAssertEqual(memory.exchanges.last?.overview, "Brief after refinement 30")
        XCTAssertEqual(memory.exchanges.first?.overview, "Brief after refinement 25")
        let context = memory.condensedContext()
        XCTAssertNotNil(context)
        XCTAssertLessThan(
            context?.count ?? .max,
            1_200 + 100,
            "digest respects the character budget across 30 turns"
        )
        XCTAssertTrue(context?.contains("refinement 30") ?? false, "newest turn always present")
    }

    func testClearDropsEverything() {
        var memory = ConversationMemory()
        memory.record(
            request: AssistantRequest(sourceText: "note"),
            summary: summary(headline: "h", tasks: ["t"])
        )
        memory.clear()
        XCTAssertNil(memory.condensedContext())
        XCTAssertTrue(memory.exchanges.isEmpty)
    }
}
