import Foundation

public struct AssistantRun: Codable, Equatable, Sendable {
    public var request: AssistantRequest
    public var summary: StructuredSummary
    public var metrics: RunMetrics

    public init(
        request: AssistantRequest,
        summary: StructuredSummary,
        metrics: RunMetrics
    ) {
        self.request = request
        self.summary = summary
        self.metrics = metrics
    }
}

public struct RunMetrics: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date
    public var durationMilliseconds: Double
    public var source: GenerationSource
    public var suggestionCount: Int
    public var actionDraftCount: Int
    public var keyPointCount: Int
    public var inputCharacterCount: Int
    public var outputByteCount: Int
    public var fallbackReason: String?
    public var cancelled: Bool

    public init(
        startedAt: Date,
        finishedAt: Date,
        durationMilliseconds: Double,
        source: GenerationSource,
        suggestionCount: Int,
        actionDraftCount: Int,
        keyPointCount: Int = 0,
        inputCharacterCount: Int = 0,
        outputByteCount: Int = 0,
        fallbackReason: String? = nil,
        cancelled: Bool = false
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMilliseconds = durationMilliseconds
        self.source = source
        self.suggestionCount = suggestionCount
        self.actionDraftCount = actionDraftCount
        self.keyPointCount = keyPointCount
        self.inputCharacterCount = inputCharacterCount
        self.outputByteCount = outputByteCount
        self.fallbackReason = fallbackReason
        self.cancelled = cancelled
    }
}

public extension LocalAssistService {
    func summarizeWithMetrics(_ request: AssistantRequest) async throws -> AssistantRun {
        let startedAt = Date()
        let started = ContinuousClock.now

        do {
            let summary = try await summarize(request)
            let finishedAt = Date()
            let duration = started.duration(to: ContinuousClock.now)

            return AssistantRun(
                request: request,
                summary: summary,
                metrics: RunMetrics(
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    durationMilliseconds: duration.milliseconds,
                    source: summary.source,
                    suggestionCount: summary.suggestions.count,
                    actionDraftCount: summary.actionDrafts.count,
                    keyPointCount: summary.keyPoints.count,
                    inputCharacterCount: request.sourceText.count,
                    outputByteCount: (try? SummaryFormatter.jsonData(summary, prettyPrinted: false).count) ?? 0,
                    fallbackReason: summary.diagnostics.fallbackReason
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        let components = components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
