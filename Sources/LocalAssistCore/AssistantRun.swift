import Foundation

public struct AssistantRun: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var request: AssistantRequest
    public var summary: StructuredSummary
    public var metrics: RunMetrics
    /// IDs of task suggestions the user has checked off. Scoped per run, so
    /// identical tasks in different captures track independently.
    public var completedTaskIDs: Set<String>

    public init(
        id: String = UUID().uuidString,
        request: AssistantRequest,
        summary: StructuredSummary,
        metrics: RunMetrics,
        completedTaskIDs: Set<String> = []
    ) {
        self.id = id
        self.request = request
        self.summary = summary
        self.metrics = metrics
        self.completedTaskIDs = completedTaskIDs
    }

    public func isCompleted(_ task: TaskSuggestion) -> Bool {
        completedTaskIDs.contains(task.id)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case request
        case summary
        case metrics
        case completedTaskIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        request = try container.decode(AssistantRequest.self, forKey: .request)
        summary = try container.decode(StructuredSummary.self, forKey: .summary)
        metrics = try container.decode(RunMetrics.self, forKey: .metrics)
        // Pre-identity history entries derive a stable id from their timestamp.
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? "run-\(Int(metrics.startedAt.timeIntervalSince1970 * 1000))"
        completedTaskIDs = try container.decodeIfPresent(Set<String>.self, forKey: .completedTaskIDs) ?? []
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
    // All 2026-07 additions are optional so history saved before them
    // decodes unchanged (synthesized Codable reads missing keys as nil).
    /// Per-stage latency offsets, ContinuousClock-measured.
    public var stageTimings: RunStageTimings?
    /// Device/build/thermal snapshot the numbers were taken under.
    public var environment: RunEnvironment?
    /// Context-window bookkeeping from the model adapter.
    public var context: ContextWindowDiagnostics?
    /// Stable machine-readable failure taxonomy case when the run fell
    /// back (`GenerationFailure.category`) — never free-form detail text.
    public var failureCategory: String?

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
        cancelled: Bool = false,
        stageTimings: RunStageTimings? = nil,
        environment: RunEnvironment? = nil,
        context: ContextWindowDiagnostics? = nil,
        failureCategory: String? = nil
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
        self.stageTimings = stageTimings
        self.environment = environment
        self.context = context
        self.failureCategory = failureCategory
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
