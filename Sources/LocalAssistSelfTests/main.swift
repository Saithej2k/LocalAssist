import Darwin
import Foundation
import LocalAssistCore

@main
struct LocalAssistSelfTests {
    static func main() async {
        var suite = SelfTestSuite()
        await suite.run()

        if suite.failures.isEmpty {
            print("LocalAssist self-tests passed (\(suite.passed) checks).")
        } else {
            for failure in suite.failures {
                FileHandle.standardError.write(Data("FAILED: \(failure)\n".utf8))
            }
            exit(1)
        }
    }
}

private struct SelfTestSuite {
    var passed = 0
    var failures: [String] = []

    mutating func run() async {
        malformedInputsThrow()
        await unavailableModelFallsBack()
        await malformedModelOutputUsesFallback()
        await guidedModelOutputUsesFoundationSource()
        await streamingUpdatesExposePartialTextAndFinalSummary()
        await concurrentRequestsComplete()
        await cancellationPropagates()
        await streamingCancellationPropagates()
        await offlineExecutionUsesDeterministicFallback()
        await deterministicFallbackIsStable()
        await summarizeWithMetricsCapturesRun()
        await actionDraftsPrepareForConfirmation()
        metricDistributionComputesPercentiles()
        await runHistoryStorePersistsAndAggregates()
    }

    mutating func malformedInputsThrow() {
        let validator = RequestValidator(maxCharacters: 20)
        expectThrows(.emptyInput, "empty input") {
            _ = try validator.validate(AssistantRequest(sourceText: "   "))
        }
        expectThrows(.inputTooLong(actual: 21, maximum: 20), "input length") {
            _ = try validator.validate(AssistantRequest(sourceText: String(repeating: "a", count: 21)))
        }
        expectThrows(.invalidSuggestionLimit(0), "suggestion limit") {
            _ = try validator.validate(AssistantRequest(sourceText: "Review notes", maxSuggestions: 0))
        }
    }

    mutating func unavailableModelFallsBack() async {
        do {
            let model = StaticLanguageModelClient(
                state: .unavailable(reason: "device not eligible"),
                response: "{}"
            )
            let service = LocalAssistService(primaryModel: model)
            let summary = try await service.summarize(
                AssistantRequest(sourceText: "Review the launch checklist by Friday.")
            )
            expect(summary.source == .deterministicFallback, "unavailable model falls back")
            expect(summary.diagnostics.fallbackReason == "device not eligible", "availability reason is preserved")
            expect(summary.suggestions.first?.action == .reminder, "fallback proposes reminder")
        } catch {
            fail("unavailable model scenario threw \(error)")
        }
    }

    mutating func malformedModelOutputUsesFallback() async {
        do {
            let model = StaticLanguageModelClient(
                state: .available,
                response: "Here is a summary, but not JSON."
            )
            let service = LocalAssistService(primaryModel: model)
            let summary = try await service.summarize(
                AssistantRequest(sourceText: "Send Mira blockers by Friday.")
            )
            expect(summary.source == .deterministicFallback, "malformed model output falls back")
            expect(summary.suggestions.first?.action == .messageDraft, "send task becomes message draft")
        } catch {
            fail("malformed model scenario threw \(error)")
        }
    }

    mutating func guidedModelOutputUsesFoundationSource() async {
        do {
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
            let summary = try await service.summarize(
                AssistantRequest(sourceText: "Send Mira blockers by Friday.")
            )
            expect(summary.source == .foundationModels, "guided JSON uses model source")
            expect(summary.suggestions.first?.priority == .high, "guided priority is preserved")
            expect(summary.actionDrafts.first?.kind == .messageDraft, "guided action draft is built")
        } catch {
            fail("guided model scenario threw \(error)")
        }
    }

    mutating func streamingUpdatesExposePartialTextAndFinalSummary() async {
        do {
            let result = try await streamedSummaryResult()
            expect(result.partials.count >= 2, "streaming partial count")
            expect(result.partials.contains { $0.contains("\"overview\"") }, "streaming partial text")
            expect(result.summary?.source == .foundationModels, "streaming final source")
            expect(result.summary?.suggestions.first?.action == .calendarHold, "streaming final action")
        } catch {
            fail("streaming model scenario threw \(error)")
        }
    }

    mutating func concurrentRequestsComplete() async {
        do {
            let service = LocalAssistService()
            let summaries = try await withThrowingTaskGroup(of: StructuredSummary.self) { group in
                for index in 0 ..< 20 {
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

            expect(summaries.count == 20, "concurrent request count")
            expect(summaries.allSatisfy { $0.source == .deterministicFallback }, "concurrent fallback source")
            expect(summaries.allSatisfy { !$0.suggestions.isEmpty }, "concurrent suggestions")
        } catch {
            fail("concurrent requests threw \(error)")
        }
    }

    mutating func cancellationPropagates() async {
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
            fail("cancellation did not propagate")
        } catch is CancellationError {
            pass()
        } catch {
            fail("expected CancellationError, received \(error)")
        }
    }

    mutating func streamingCancellationPropagates() async {
        let response = """
        {
          "overview": "Cancellation should interrupt streaming.",
          "keyPoints": ["Cancel streaming"],
          "suggestions": []
        }
        """
        let model = StaticLanguageModelClient(
            state: .available,
            response: response,
            streamChunks: [response],
            chunkDelayNanoseconds: 2_000_000_000
        )
        let service = LocalAssistService(primaryModel: model)
        let task = Task {
            var updateCount = 0
            for try await _ in service.streamSummary(
                AssistantRequest(sourceText: "Review streaming cancellation tomorrow.")
            ) {
                updateCount += 1
            }
            try Task.checkCancellation()
            return updateCount
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            fail("streaming cancellation did not propagate")
        } catch is CancellationError {
            pass()
        } catch {
            fail("expected streaming CancellationError, received \(error)")
        }
    }

    mutating func offlineExecutionUsesDeterministicFallback() async {
        do {
            let service = LocalAssistService()
            let summary = try await service.summarize(
                AssistantRequest(
                    sourceText: "Prepare release notes, update the checklist, and follow up tomorrow.",
                    maxSuggestions: 4
                )
            )
            expect(summary.source == .deterministicFallback, "offline fallback source")
            expect(summary.diagnostics.availability.isAvailable == false, "offline availability diagnostic")
            expect(summary.actionDrafts.count >= 2, "offline drafts are created")
        } catch {
            fail("offline fallback threw \(error)")
        }
    }

    mutating func deterministicFallbackIsStable() async {
        do {
            let service = LocalAssistService()
            let request = AssistantRequest(
                sourceText: "Schedule a launch sync next week and send the agenda to Mira.",
                maxSuggestions: 3
            )
            let first = try await service.summarize(request)
            let second = try await service.summarize(request)
            expect(first.overview == second.overview, "stable overview")
            expect(first.keyPoints == second.keyPoints, "stable key points")
            expect(first.suggestions == second.suggestions, "stable suggestions")
            expect(first.actionDrafts == second.actionDrafts, "stable action drafts")
        } catch {
            fail("stable fallback threw \(error)")
        }
    }

    mutating func summarizeWithMetricsCapturesRun() async {
        do {
            let run = try await measuredFallbackRun()
            expect(run.summary.source == .deterministicFallback, "measured fallback source")
            expect(run.metrics.source == .deterministicFallback, "metrics source")
            expect(run.metrics.durationMilliseconds >= 0, "metrics duration")
            expect(run.metrics.suggestionCount == run.summary.suggestions.count, "metrics suggestion count")
            expect(run.metrics.actionDraftCount == run.summary.actionDrafts.count, "metrics draft count")
        } catch {
            fail("measured run threw \(error)")
        }
    }

    mutating func actionDraftsPrepareForConfirmation() async {
        do {
            let run = try await measuredFallbackRun()
            let preparer = DraftOnlyToolActionPreparer()
            var prepared: [PreparedToolAction] = []

            for draft in run.summary.actionDrafts {
                try prepared.append(await preparer.prepare(draft))
            }

            expect(!prepared.isEmpty, "prepared actions are present")
            expect(prepared.contains { $0.state == .readyForConfirmation }, "prepared actions require confirmation")
            expect(prepared.allSatisfy { !$0.confirmationMessage.isEmpty }, "prepared action messages")
        } catch {
            fail("action preparation threw \(error)")
        }
    }

    mutating func metricDistributionComputesPercentiles() {
        let distribution = MetricDistribution(samples: [1, 3, 5, 7, 9])
        expect(distribution.count == 5, "distribution count")
        expect(distribution.minimum == 1, "distribution minimum")
        expect(distribution.maximum == 9, "distribution maximum")
        expect(distribution.p50 == 5, "distribution p50")
        expect(distribution.p95 == 9, "distribution p95")
    }

    mutating func runHistoryStorePersistsAndAggregates() async {
        do {
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

            expect(runs.count == 3, "history limit")
            expect(runs.first?.summary.overview == "Run 4", "history newest first")
            expect(aggregate.runCount == 3, "history aggregate count")
            expect(aggregate.fallbackRuns == 3, "history fallback count")
            expect(aggregate.latencyMilliseconds.p50 == 5, "history p50")
        } catch {
            fail("history store threw \(error)")
        }
    }

    mutating func expectThrows(
        _ expected: LocalAssistError,
        _ label: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            fail("\(label) did not throw")
        } catch let error as LocalAssistError {
            expect(error == expected, label)
        } catch {
            fail("\(label) threw unexpected error \(error)")
        }
    }

    mutating func expect(_ condition: Bool, _ label: String) {
        condition ? pass() : fail(label)
    }

    mutating func pass() {
        passed += 1
    }

    mutating func fail(_ label: String) {
        failures.append(label)
    }
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

private func streamedSummaryResult() async throws -> (
    partials: [String],
    summary: StructuredSummary?
) {
    let response = """
    {
      "overview": "A launch sync needs a calendar hold.",
      "keyPoints": ["Schedule the launch sync", "Share the agenda"],
      "suggestions": [
        {
          "title": "Schedule launch sync",
          "priority": "medium",
          "dueHint": "next week",
          "action": "calendarHold",
          "rationale": "The team needs time reserved for launch coordination.",
          "confidence": 0.84
        }
      ]
    }
    """
    let chunks = [
        "{",
        """
        {
          "overview": "A launch sync needs a calendar hold.",
          "keyPoints": ["Schedule the launch sync"],
          "suggestions": []
        }
        """,
        response,
    ]
    let model = StaticLanguageModelClient(
        state: .available,
        response: response,
        streamChunks: chunks
    )
    let service = LocalAssistService(primaryModel: model)

    var partials: [String] = []
    var summary: StructuredSummary?

    for try await update in service.streamSummary(
        AssistantRequest(sourceText: "Schedule a launch sync next week and share the agenda.")
    ) {
        if update.phase == .streamingModel, !update.partialText.isEmpty {
            partials.append(update.partialText)
        }
        if let final = update.summary {
            summary = final
        }
    }

    return (partials, summary)
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
            finishedAt: Date(timeIntervalSince1970: Double(index) + latency / 1000),
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
