import Foundation
@testable import LocalAssistCore

#if canImport(XCTest)
import XCTest

final class LocalAssistCoreTests: XCTestCase {
    func testMalformedInputsThrow() throws {
        let validator = RequestValidator(maxCharacters: 20)

        XCTAssertThrowsError(try validator.validate(AssistantRequest(sourceText: "   "))) { error in
            XCTAssertEqual(error as? LocalAssistError, .emptyInput)
        }
        XCTAssertThrowsError(
            try validator.validate(AssistantRequest(sourceText: String(repeating: "a", count: 21)))
        ) { error in
            XCTAssertEqual(error as? LocalAssistError, .inputTooLong(actual: 21, maximum: 20))
        }
        XCTAssertThrowsError(
            try validator.validate(AssistantRequest(sourceText: "Review notes", maxSuggestions: 0))
        ) { error in
            XCTAssertEqual(error as? LocalAssistError, .invalidSuggestionLimit(0))
        }
    }

    func testUnavailableModelFallsBack() async throws {
        let summary = try await unavailableModelSummary()
        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertEqual(summary.diagnostics.fallbackReason, "device not eligible")
        XCTAssertEqual(summary.suggestions.first?.action, .reminder)
    }

    func testMalformedModelOutputUsesFallback() async throws {
        let summary = try await malformedModelSummary()
        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertEqual(summary.diagnostics.fallbackReason, "The on-device model returned malformed guided JSON.")
        XCTAssertEqual(summary.suggestions.first?.action, .messageDraft)
    }

    func testGuidedModelOutputUsesFoundationSource() async throws {
        let summary = try await guidedModelSummary()
        XCTAssertEqual(summary.source, .foundationModels)
        XCTAssertEqual(summary.suggestions.first?.priority, .high)
        XCTAssertEqual(summary.actionDrafts.first?.kind, .messageDraft)
    }

    func testConcurrentRequestsComplete() async throws {
        let summaries = try await concurrentSummaries()
        XCTAssertEqual(summaries.count, 20)
        XCTAssertTrue(summaries.allSatisfy { $0.source == .deterministicFallback })
        XCTAssertTrue(summaries.allSatisfy { !$0.suggestions.isEmpty })
    }

    func testCancellationPropagates() async {
        let didPropagate = await cancellationPropagates()
        XCTAssertTrue(didPropagate)
    }

    func testOfflineExecutionUsesDeterministicFallback() async throws {
        let summary = try await offlineSummary()
        XCTAssertEqual(summary.source, .deterministicFallback)
        XCTAssertEqual(summary.diagnostics.availability.isAvailable, false)
        XCTAssertGreaterThanOrEqual(summary.actionDrafts.count, 2)
    }

    func testDeterministicFallbackIsStable() async throws {
        let summaries = try await stableFallbackSummaries()
        XCTAssertEqual(summaries.first.overview, summaries.second.overview)
        XCTAssertEqual(summaries.first.keyPoints, summaries.second.keyPoints)
        XCTAssertEqual(summaries.first.suggestions, summaries.second.suggestions)
        XCTAssertEqual(summaries.first.actionDrafts, summaries.second.actionDrafts)
    }

    func testSummarizeWithMetricsCapturesRun() async throws {
        let run = try await measuredFallbackRun()
        XCTAssertEqual(run.summary.source, .deterministicFallback)
        XCTAssertEqual(run.metrics.source, .deterministicFallback)
        XCTAssertGreaterThanOrEqual(run.metrics.durationMilliseconds, 0)
        XCTAssertEqual(run.metrics.suggestionCount, run.summary.suggestions.count)
        XCTAssertEqual(run.metrics.actionDraftCount, run.summary.actionDrafts.count)
    }

    func testActionDraftsPrepareForConfirmation() async throws {
        let actions = try await preparedFallbackActions()
        XCTAssertFalse(actions.isEmpty)
        XCTAssertTrue(actions.contains { $0.state == .readyForConfirmation })
        XCTAssertTrue(actions.allSatisfy { !$0.confirmationMessage.isEmpty })
    }

    func testMetricDistributionComputesPercentiles() {
        let distribution = sampleDistribution()
        XCTAssertEqual(distribution.count, 5)
        XCTAssertEqual(distribution.minimum, 1)
        XCTAssertEqual(distribution.maximum, 9)
        XCTAssertEqual(distribution.p50, 5)
        XCTAssertEqual(distribution.p95, 9)
    }

    func testRunHistoryStorePersistsAndAggregates() async throws {
        let result = try await persistedHistoryResult()
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.latestOverview, "Run 4")
        XCTAssertEqual(result.aggregate.runCount, 3)
        XCTAssertEqual(result.aggregate.fallbackRuns, 3)
        XCTAssertEqual(result.aggregate.latencyMilliseconds.p50, 5)
    }
}

#else
import Testing

@Test
func malformedInputsThrow() throws {
    let validator = RequestValidator(maxCharacters: 20)

    expectLocalAssistError(.emptyInput) {
        _ = try validator.validate(AssistantRequest(sourceText: "   "))
    }
    expectLocalAssistError(.inputTooLong(actual: 21, maximum: 20)) {
        _ = try validator.validate(AssistantRequest(sourceText: String(repeating: "a", count: 21)))
    }
    expectLocalAssistError(.invalidSuggestionLimit(0)) {
        _ = try validator.validate(AssistantRequest(sourceText: "Review notes", maxSuggestions: 0))
    }
}

@Test
func unavailableModelFallsBack() async throws {
    let summary = try await unavailableModelSummary()
    #expect(summary.source == .deterministicFallback)
    #expect(summary.diagnostics.fallbackReason == "device not eligible")
    #expect(summary.suggestions.first?.action == .reminder)
}

@Test
func malformedModelOutputUsesFallback() async throws {
    let summary = try await malformedModelSummary()
    #expect(summary.source == .deterministicFallback)
    #expect(summary.diagnostics.fallbackReason == "The on-device model returned malformed guided JSON.")
    #expect(summary.suggestions.first?.action == .messageDraft)
}

@Test
func guidedModelOutputUsesFoundationSource() async throws {
    let summary = try await guidedModelSummary()
    #expect(summary.source == .foundationModels)
    #expect(summary.suggestions.first?.priority == .high)
    #expect(summary.actionDrafts.first?.kind == .messageDraft)
}

@Test
func concurrentRequestsComplete() async throws {
    let summaries = try await concurrentSummaries()
    #expect(summaries.count == 20)
    #expect(summaries.allSatisfy { $0.source == .deterministicFallback })
    #expect(summaries.allSatisfy { !$0.suggestions.isEmpty })
}

@Test
func cancellationPropagatesFromModelClient() async {
    #expect(await cancellationPropagates())
}

@Test
func offlineExecutionUsesDeterministicFallback() async throws {
    let summary = try await offlineSummary()
    #expect(summary.source == .deterministicFallback)
    #expect(summary.diagnostics.availability.isAvailable == false)
    #expect(summary.actionDrafts.count >= 2)
}

@Test
func deterministicFallbackIsStable() async throws {
    let summaries = try await stableFallbackSummaries()
    #expect(summaries.first.overview == summaries.second.overview)
    #expect(summaries.first.keyPoints == summaries.second.keyPoints)
    #expect(summaries.first.suggestions == summaries.second.suggestions)
    #expect(summaries.first.actionDrafts == summaries.second.actionDrafts)
}

@Test
func summarizeWithMetricsCapturesRun() async throws {
    let run = try await measuredFallbackRun()
    #expect(run.summary.source == .deterministicFallback)
    #expect(run.metrics.source == .deterministicFallback)
    #expect(run.metrics.durationMilliseconds >= 0)
    #expect(run.metrics.suggestionCount == run.summary.suggestions.count)
    #expect(run.metrics.actionDraftCount == run.summary.actionDrafts.count)
}

@Test
func actionDraftsPrepareForConfirmation() async throws {
    let actions = try await preparedFallbackActions()
    #expect(!actions.isEmpty)
    #expect(actions.contains { $0.state == .readyForConfirmation })
    #expect(actions.allSatisfy { !$0.confirmationMessage.isEmpty })
}

@Test
func metricDistributionComputesPercentiles() {
    let distribution = sampleDistribution()
    #expect(distribution.count == 5)
    #expect(distribution.minimum == 1)
    #expect(distribution.maximum == 9)
    #expect(distribution.p50 == 5)
    #expect(distribution.p95 == 9)
}

@Test
func runHistoryStorePersistsAndAggregates() async throws {
    let result = try await persistedHistoryResult()
    #expect(result.count == 3)
    #expect(result.latestOverview == "Run 4")
    #expect(result.aggregate.runCount == 3)
    #expect(result.aggregate.fallbackRuns == 3)
    #expect(result.aggregate.latencyMilliseconds.p50 == 5)
}

private func expectLocalAssistError(_ expected: LocalAssistError, operation: () throws -> Void) {
    do {
        try operation()
        #expect(Bool(false))
    } catch let error as LocalAssistError {
        #expect(error == expected)
    } catch {
        #expect(Bool(false))
    }
}
#endif

private func unavailableModelSummary() async throws -> StructuredSummary {
    let model = StaticLanguageModelClient(
        state: .unavailable(reason: "device not eligible"),
        response: "{}"
    )
    let service = LocalAssistService(primaryModel: model)
    return try await service.summarize(
        AssistantRequest(sourceText: "Review the launch checklist by Friday.")
    )
}

private func malformedModelSummary() async throws -> StructuredSummary {
    let model = StaticLanguageModelClient(
        state: .available,
        response: "Here is a summary, but not JSON."
    )
    let service = LocalAssistService(primaryModel: model)
    return try await service.summarize(
        AssistantRequest(sourceText: "Send Mira blockers by Friday.")
    )
}

private func guidedModelSummary() async throws -> StructuredSummary {
    let response = """
    {
      "overview": "Mira needs launch blockers and a design sync.",
      "keyPoints": ["Send Mira blockers", "Schedule a design sync"],
      "suggestions": [
        {
          "title": "Send Mira blockers",
          "priority": "high",
          "dueHint": "Friday",
          "action": "messageDraft",
          "rationale": "A direct follow-up message is needed.",
          "confidence": 0.91
        }
      ]
    }
    """
    let model = StaticLanguageModelClient(state: .available, response: response)
    let service = LocalAssistService(primaryModel: model)
    return try await service.summarize(
        AssistantRequest(sourceText: "Send Mira blockers by Friday.")
    )
}

private func concurrentSummaries() async throws -> [StructuredSummary] {
    let service = LocalAssistService()

    return try await withThrowingTaskGroup(of: StructuredSummary.self) { group in
        for index in 0..<20 {
            group.addTask {
                try await service.summarize(
                    AssistantRequest(
                        sourceText: "Review item \(index) and schedule a design sync next week.",
                        maxSuggestions: 3
                    )
                )
            }
        }

        var output: [StructuredSummary] = []
        for try await summary in group {
            output.append(summary)
        }
        return output
    }
}

private func cancellationPropagates() async -> Bool {
    let model = StaticLanguageModelClient(
        state: .available,
        response: "{}",
        delayNanoseconds: 2_000_000_000
    )
    let service = LocalAssistService(primaryModel: model)
    let task = Task {
        try await service.summarize(
            AssistantRequest(sourceText: "Review cancellation behavior tomorrow.")
        )
    }

    try? await Task.sleep(nanoseconds: 20_000_000)
    task.cancel()

    do {
        _ = try await task.value
        return false
    } catch is CancellationError {
        return true
    } catch {
        return false
    }
}

private func offlineSummary() async throws -> StructuredSummary {
    let service = LocalAssistService()
    return try await service.summarize(
        AssistantRequest(
            sourceText: "Prepare release notes, update the checklist, and follow up tomorrow.",
            maxSuggestions: 4
        )
    )
}

private func stableFallbackSummaries() async throws -> (first: StructuredSummary, second: StructuredSummary) {
    let service = LocalAssistService()
    let request = AssistantRequest(
        sourceText: "Schedule a launch sync next week and send the agenda to Mira.",
        maxSuggestions: 3
    )

    return (
        first: try await service.summarize(request),
        second: try await service.summarize(request)
    )
}

private func measuredFallbackRun() async throws -> AssistantRun {
    let service = LocalAssistService()
    return try await service.summarizeWithMetrics(
        AssistantRequest(
            sourceText: "Review the launch checklist and send blockers by Friday.",
            maxSuggestions: 3
        )
    )
}

private func preparedFallbackActions() async throws -> [PreparedToolAction] {
    let run = try await measuredFallbackRun()
    let preparer = DraftOnlyToolActionPreparer()
    var prepared: [PreparedToolAction] = []

    for draft in run.summary.actionDrafts {
        prepared.append(try await preparer.prepare(draft))
    }

    return prepared
}

private func sampleDistribution() -> MetricDistribution {
    MetricDistribution(samples: [1, 3, 5, 7, 9])
}

private func persistedHistoryResult() async throws -> (
    count: Int,
    latestOverview: String,
    aggregate: AggregateRunMetrics
) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalAssist-\(UUID().uuidString)")
        .appendingPathComponent("history.json")
    let store = RunHistoryStore(fileURL: url, limit: 3)

    try await store.append(sampleRun(index: 1, latency: 1))
    try await store.append(sampleRun(index: 2, latency: 3))
    try await store.append(sampleRun(index: 3, latency: 5))
    try await store.append(sampleRun(index: 4, latency: 9))

    let runs = try await store.load()
    let aggregate = try await store.aggregate()
    try await store.clear()

    return (
        count: runs.count,
        latestOverview: runs.first?.summary.overview ?? "",
        aggregate: aggregate
    )
}

private func sampleRun(index: Int, latency: Double) -> AssistantRun {
    let suggestion = TaskSuggestion(
        id: "task-\(index)",
        title: "Run \(index)",
        priority: .medium,
        dueHint: nil,
        action: .reminder,
        rationale: "Test run",
        confidence: 0.8
    )
    let draft = ToolActionPlanner().draft(for: suggestion)
    let summary = StructuredSummary(
        overview: "Run \(index)",
        keyPoints: ["Point \(index)"],
        suggestions: [suggestion],
        actionDrafts: [draft],
        source: .deterministicFallback,
        diagnostics: GenerationDiagnostics(
            availability: .unavailable(reason: "test"),
            fallbackReason: "test",
            repairedMalformedModelOutput: false
        )
    )
    return AssistantRun(
        request: AssistantRequest(sourceText: "Run \(index)"),
        summary: summary,
        metrics: RunMetrics(
            startedAt: Date(timeIntervalSince1970: Double(index)),
            finishedAt: Date(timeIntervalSince1970: Double(index) + latency / 1_000),
            durationMilliseconds: latency,
            source: .deterministicFallback,
            suggestionCount: 1,
            actionDraftCount: 1,
            keyPointCount: 1,
            inputCharacterCount: 8,
            outputByteCount: 64,
            fallbackReason: "test"
        )
    )
}
