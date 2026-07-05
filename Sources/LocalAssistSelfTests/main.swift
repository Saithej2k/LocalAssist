import Darwin
import Foundation
import LocalAssistCore
import LocalAssistEvalKit
import LocalAssistSystemTools

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
        await guardrailViolationFallsBack()
        await typedModelOutputUsesFoundationSource()
        await streamingExposesTypedPartials()
        await concurrentRequestsComplete()
        await cancellationPropagates()
        await streamingCancellationPropagates()
        await offlineExecutionUsesDeterministicFallback()
        await deterministicFallbackIsStable()
        await summarizeWithMetricsCapturesRun()
        await executorWritesThroughRecordingStore()
        metricDistributionComputesPercentiles()
        await runHistoryStorePersistsAndAggregates()
        await evalHarnessScoresFallback()
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
            let model = StaticStructuredModelClient(
                state: .unavailable(ModelUnavailability(reason: .deviceNotEligible))
            )
            let service = LocalAssistService(model: model)
            let summary = try await service.summarize(
                AssistantRequest(sourceText: "Review the launch checklist by Friday.")
            )
            expect(summary.source == .deterministicFallback, "unavailable model falls back")
            expect(
                summary.diagnostics.availability.unavailability?.reason == .deviceNotEligible,
                "typed unavailability reason is preserved"
            )
            expect(summary.suggestions.first?.action == .reminder, "fallback proposes reminder")
        } catch {
            fail("unavailable model scenario threw \(error)")
        }
    }

    mutating func guardrailViolationFallsBack() async {
        let model = StaticStructuredModelClient(failure: .guardrailViolation(detail: "sensitive"))
        let service = LocalAssistService(model: model)

        do {
            let summary = try await service.summarize(AssistantRequest(sourceText: "Review notes tomorrow."))
            expect(summary.source == .deterministicFallback, "guardrail violation falls back")
            expect(summary.diagnostics.fallbackReason?.contains("guardrailViolation") == true, "guardrail fallback reason")
        } catch {
            fail("guardrail scenario threw unexpected \(error)")
        }
    }

    mutating func typedModelOutputUsesFoundationSource() async {
        do {
            let service = LocalAssistService(model: StaticStructuredModelClient.completing(with: .mira))
            let summary = try await service.summarize(
                AssistantRequest(sourceText: "Send Mira blockers by Friday.")
            )
            expect(summary.source == .foundationModels, "typed output uses model source")
            expect(summary.suggestions.first?.priority == .high, "typed priority is preserved")
            expect(summary.actionDrafts.first?.kind == .messageDraft, "typed action draft is built")
        } catch {
            fail("typed model scenario threw \(error)")
        }
    }

    mutating func streamingExposesTypedPartials() async {
        do {
            let script = [
                StructuredSummaryPartial(overview: "A launch sync needs a calendar hold."),
                StructuredSummaryPartial.launchSync,
            ]
            let service = LocalAssistService(model: StaticStructuredModelClient(script: script))

            var sawStreamingOverview = false
            var summary: StructuredSummary?
            for try await update in service.streamSummary(
                AssistantRequest(sourceText: "Schedule a launch sync next week and share the agenda.")
            ) {
                if update.phase == .streamingModel, update.partial?.overview != nil {
                    sawStreamingOverview = true
                }
                if let final = update.summary {
                    summary = final
                }
            }

            expect(sawStreamingOverview, "typed overview streams before completion")
            expect(summary?.source == .foundationModels, "streaming final source")
            expect(summary?.suggestions.first?.action == .calendarHold, "streaming final action")
        } catch {
            fail("streaming scenario threw \(error)")
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
        let model = StaticStructuredModelClient(
            script: [.launchSync],
            initialDelayNanoseconds: 2_000_000_000
        )
        let service = LocalAssistService(model: model)
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
        let model = StaticStructuredModelClient(
            script: [.launchSync],
            chunkDelayNanoseconds: 2_000_000_000
        )
        let service = LocalAssistService(model: model)
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
            let service = LocalAssistService(fallback: DeterministicFallbackGenerator(clock: .frozen))
            let request = AssistantRequest(
                sourceText: "Schedule a launch sync next week and send the agenda to Mira.",
                maxSuggestions: 3
            )
            let first = try await service.summarize(request)
            let second = try await service.summarize(request)
            let firstData = try SummaryFormatter.jsonData(first, prettyPrinted: false)
            let secondData = try SummaryFormatter.jsonData(second, prettyPrinted: false)
            expect(first.overview == second.overview, "stable overview")
            expect(first.keyPoints == second.keyPoints, "stable key points")
            expect(first.suggestions == second.suggestions, "stable suggestions")
            expect(first.actionDrafts == second.actionDrafts, "stable action drafts")
            expect(firstData == secondData, "stable encoded fallback output")
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

    mutating func executorWritesThroughRecordingStore() async {
        do {
            let store = RecordingWriteStore()
            let executor = SystemActionExecutor(store: store)
            let draft = ToolActionDraft(
                kind: .reminder,
                title: "Create reminder",
                payload: ["title": "Send Mira the blockers", "dueHint": "Friday"]
            )
            let prepared = try await DraftOnlyToolActionPreparer().prepare(draft)
            let executed = try await executor.execute(prepared)

            expect(executed.didWriteToSystem, "executor reports a system write")
            let reminders = await store.reminders
            expect(reminders.count == 1, "executor writes one reminder")
            expect(reminders.first?.due != nil, "executor resolves the due hint")
        } catch {
            fail("executor scenario threw \(error)")
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

    mutating func evalHarnessScoresFallback() async {
        do {
            let report = try await EvalRunner.run(
                service: LocalAssistService(),
                configurationLabel: "selftest"
            )
            expect(report.caseResults.count == EvalDataset.standard.count, "eval case count")
            expect(report.meanComposite >= 0.75, "eval mean composite >= 0.75 (was \(report.meanComposite))")
        } catch {
            fail("eval harness threw \(error)")
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

private extension StructuredSummaryPartial {
    static let mira = StructuredSummaryPartial(
        overview: "Mira needs launch blockers and a design sync.",
        keyPoints: ["Send Mira blockers", "Schedule a design sync"],
        suggestions: [
            TaskSuggestionPartial(
                title: "Send Mira blockers",
                priority: .high,
                dueHint: "Friday",
                action: .messageDraft,
                rationale: "A direct follow-up message is needed.",
                confidence: 0.91
            ),
        ],
        isComplete: true
    )

    static let launchSync = StructuredSummaryPartial(
        overview: "A launch sync needs a calendar hold.",
        keyPoints: ["Schedule the launch sync", "Share the agenda"],
        suggestions: [
            TaskSuggestionPartial(
                title: "Schedule launch sync",
                priority: .medium,
                dueHint: "next week",
                action: .calendarHold,
                rationale: "The team needs time reserved for launch coordination.",
                confidence: 0.84
            ),
        ],
        isComplete: true
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
            availability: .unavailable(ModelUnavailability(reason: .forcedOffline, detail: "test")),
            fallbackReason: "test"
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
