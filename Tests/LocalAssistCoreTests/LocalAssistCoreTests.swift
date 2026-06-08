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
        XCTAssertTrue(await cancellationPropagates())
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
