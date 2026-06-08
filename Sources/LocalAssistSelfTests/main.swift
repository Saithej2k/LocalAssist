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
        await concurrentRequestsComplete()
        await cancellationPropagates()
        await offlineExecutionUsesDeterministicFallback()
        await deterministicFallbackIsStable()
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

    mutating func concurrentRequestsComplete() async {
        do {
            let service = LocalAssistService()
            let summaries = try await withThrowingTaskGroup(of: StructuredSummary.self) { group in
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
