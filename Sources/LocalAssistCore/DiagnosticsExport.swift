import Foundation

/// User-initiated, content-free diagnostics export.
///
/// The redaction rule is structural, not filter-based: the export record
/// type simply has no fields for text. Metrics, counts, categories, rule
/// IDs, timings, and environment go in; headlines, key points, task titles,
/// drafts, transcripts, and free-form failure detail never had a place to
/// go. `fallbackReason` is deliberately excluded — framework error strings
/// can embed prompt fragments; `failureCategory` carries the same signal
/// safely.
public enum DiagnosticsExporter {
    /// One run's metrics, stripped to what a performance investigation
    /// needs.
    public struct RunRecord: Codable, Equatable, Sendable {
        public var runID: String
        public var startedAt: Date
        public var durationMilliseconds: Double
        public var source: GenerationSource
        public var inputKind: AssistantInputKind
        public var isRefinement: Bool
        public var suggestionCount: Int
        public var actionDraftCount: Int
        public var keyPointCount: Int
        public var inputCharacterCount: Int
        public var outputByteCount: Int
        public var toolInvocationCount: Int
        public var cancelled: Bool
        public var failureCategory: String?
        public var modelWasAvailable: Bool
        public var unavailabilityReason: ModelUnavailabilityReason?
        public var stageTimings: RunStageTimings?
        public var environment: RunEnvironment?
        public var context: ContextWindowDiagnostics?
        public var reconcilerFindings: [RoutedActionReconciler.Finding]?

        public init(run: AssistantRun) {
            runID = run.id
            startedAt = run.metrics.startedAt
            durationMilliseconds = run.metrics.durationMilliseconds
            source = run.metrics.source
            inputKind = run.request.inputKind
            isRefinement = run.request.isRefinement
            suggestionCount = run.metrics.suggestionCount
            actionDraftCount = run.metrics.actionDraftCount
            keyPointCount = run.metrics.keyPointCount
            inputCharacterCount = run.metrics.inputCharacterCount
            outputByteCount = run.metrics.outputByteCount
            toolInvocationCount = run.summary.diagnostics.toolInvocationCount
            cancelled = run.metrics.cancelled
            failureCategory = run.metrics.failureCategory
                ?? run.summary.diagnostics.failureCategory
            modelWasAvailable = run.summary.diagnostics.availability.isAvailable
            unavailabilityReason = run.summary.diagnostics.availability.unavailability?.reason
            stageTimings = run.metrics.stageTimings
            environment = run.metrics.environment
            context = run.metrics.context
            reconcilerFindings = run.summary.diagnostics.reconcilerFindings
        }
    }

    public struct Export: Codable, Equatable, Sendable {
        public var exportedAt: Date
        public var formatVersion: Int
        public var environment: RunEnvironment
        public var runs: [RunRecord]
        public var aggregate: AggregateRunMetrics
        /// Timing snapshot of the most recent voice capture, when one
        /// happened this session. Milliseconds only.
        public var lastVoiceSessionTimings: [String: Double]?
        /// History-write duration of the most recent run, measured around
        /// the append that saved it.
        public var lastPersistenceMilliseconds: Double?
    }

    public static func export(
        runs: [AssistantRun],
        lastVoiceSessionTimings: [String: Double]? = nil,
        lastPersistenceMilliseconds: Double? = nil,
        exportedAt: Date = Date()
    ) -> Export {
        Export(
            exportedAt: exportedAt,
            formatVersion: 1,
            environment: .current(coldStart: false),
            runs: runs.map(RunRecord.init(run:)),
            aggregate: AggregateRunMetrics(runs: runs),
            lastVoiceSessionTimings: lastVoiceSessionTimings,
            lastPersistenceMilliseconds: lastPersistenceMilliseconds
        )
    }

    public static func jsonData(_ export: Export) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }
}
