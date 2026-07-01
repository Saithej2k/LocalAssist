import Foundation
import LocalAssistCore
import LocalAssistFoundationModels

@MainActor
public final class LocalAssistViewModel: ObservableObject {
    @Published public var inputText: String
    @Published public var maxSuggestions: Double
    @Published public var forceOfflineFallback: Bool
    @Published public private(set) var run: AssistantRun?
    @Published public private(set) var preparedActions: [PreparedToolAction]
    @Published public private(set) var availability: ModelAvailability?
    @Published public private(set) var history: [AssistantRun]
    @Published public private(set) var aggregateMetrics: AggregateRunMetrics
    @Published public private(set) var isGenerating: Bool
    @Published public private(set) var generationPhase: SummaryGenerationPhase?
    @Published public private(set) var generationMessage: String?
    @Published public private(set) var streamingPartialText: String
    @Published public private(set) var errorMessage: String?

    private let worker: LocalAssistWorker
    private var generationTask: Task<Void, Never>?

    public init(
        inputText: String = LocalAssistViewModel.sampleInput,
        maxSuggestions: Double = 5,
        forceOfflineFallback: Bool = false,
        worker: LocalAssistWorker = LocalAssistWorker()
    ) {
        self.inputText = inputText
        self.maxSuggestions = maxSuggestions
        self.forceOfflineFallback = forceOfflineFallback
        self.worker = worker
        run = nil
        preparedActions = []
        availability = nil
        history = []
        aggregateMetrics = AggregateRunMetrics(runs: [])
        isGenerating = false
        generationPhase = nil
        generationMessage = nil
        streamingPartialText = ""
        errorMessage = nil
    }

    deinit {
        generationTask?.cancel()
    }

    public func refreshAvailability() {
        Task { [weak self] in
            guard let self else { return }
            self.availability = await worker.availability()
        }
    }

    public func loadHistory() {
        Task { [weak self] in
            guard let self else { return }
            let history = await worker.loadHistory()
            self.history = history
            self.aggregateMetrics = AggregateRunMetrics(runs: history)
        }
    }

    public func summarize() {
        generationTask?.cancel()
        errorMessage = nil
        isGenerating = true
        preparedActions = []
        generationPhase = .validating
        generationMessage = "Starting local generation"
        streamingPartialText = ""

        let request = AssistantRequest(
            sourceText: inputText,
            maxSuggestions: Int(maxSuggestions.rounded())
        )
        let useFallback = forceOfflineFallback

        generationTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var finalSummary: StructuredSummary?

            do {
                let stream = await worker.streamSummary(request, forceFallback: useFallback)
                for try await update in stream {
                    guard !Task.isCancelled else { return }
                    self.generationPhase = update.phase
                    self.generationMessage = update.message
                    self.streamingPartialText = update.partialText
                    if let summary = update.summary {
                        finalSummary = summary
                        self.availability = summary.diagnostics.availability
                    }
                }

                guard let finalSummary else {
                    throw LocalAssistError.generationDidNotFinish
                }

                let run = await worker.makeRun(
                    request: request,
                    summary: finalSummary,
                    startedAt: startedAt
                )
                let prepared = try await worker.prepareActions(run.summary.actionDrafts)
                let history = await worker.record(run)
                guard !Task.isCancelled else { return }
                self.run = run
                self.preparedActions = prepared
                self.history = history
                self.aggregateMetrics = AggregateRunMetrics(runs: history)
                self.availability = run.summary.diagnostics.availability
                self.isGenerating = false
            } catch is CancellationError {
                self.isGenerating = false
                self.generationMessage = "Cancelled"
            } catch {
                self.errorMessage = error.localizedDescription
                self.isGenerating = false
            }
        }
    }

    public func cancel() {
        generationTask?.cancel()
        isGenerating = false
        generationMessage = "Cancelled"
    }

    public func resetSample() {
        inputText = Self.sampleInput
        run = nil
        preparedActions = []
        generationPhase = nil
        generationMessage = nil
        streamingPartialText = ""
        errorMessage = nil
    }

    public func clearHistory() {
        Task { [weak self] in
            guard let self else { return }
            await worker.clearHistory()
            self.history = []
            self.aggregateMetrics = AggregateRunMetrics(runs: [])
        }
    }

    public static let sampleInput = """
    Review the onboarding doc, send Mira the blockers by Friday, and schedule a design sync next week. \
    Update the launch checklist before the beta build ships.
    """
}

public actor LocalAssistWorker {
    private let liveService: LocalAssistService
    private let fallbackService: LocalAssistService
    private let modelClient: FoundationModelsLanguageModelClient
    private let actionPreparer: any ToolActionPreparing
    private let historyStore: RunHistoryStore?

    public init(
        liveService: LocalAssistService = LocalAssistLiveFactory.makeService(),
        fallbackService: LocalAssistService = LocalAssistService(),
        modelClient: FoundationModelsLanguageModelClient = FoundationModelsLanguageModelClient(),
        actionPreparer: any ToolActionPreparing = DraftOnlyToolActionPreparer(),
        historyStore: RunHistoryStore? = RunHistoryStore.applicationSupportOrNil()
    ) {
        self.liveService = liveService
        self.fallbackService = fallbackService
        self.modelClient = modelClient
        self.actionPreparer = actionPreparer
        self.historyStore = historyStore
    }

    public func availability() async -> ModelAvailability {
        await modelClient.availability()
    }

    public func summarize(_ request: AssistantRequest, forceFallback: Bool) async throws -> AssistantRun {
        try Task.checkCancellation()
        let service = forceFallback ? fallbackService : liveService
        return try await service.summarizeWithMetrics(request)
    }

    public func streamSummary(
        _ request: AssistantRequest,
        forceFallback: Bool
    ) -> AsyncThrowingStream<SummaryGenerationUpdate, Error> {
        let service = forceFallback ? fallbackService : liveService
        return service.streamSummary(request)
    }

    public func makeRun(
        request: AssistantRequest,
        summary: StructuredSummary,
        startedAt: Date
    ) -> AssistantRun {
        let finishedAt = Date()
        return AssistantRun(
            request: request,
            summary: summary,
            metrics: RunMetrics(
                startedAt: startedAt,
                finishedAt: finishedAt,
                durationMilliseconds: max(0, finishedAt.timeIntervalSince(startedAt) * 1000),
                source: summary.source,
                suggestionCount: summary.suggestions.count,
                actionDraftCount: summary.actionDrafts.count,
                keyPointCount: summary.keyPoints.count,
                inputCharacterCount: request.sourceText.count,
                outputByteCount: (try? SummaryFormatter.jsonData(summary, prettyPrinted: false).count) ?? 0,
                fallbackReason: summary.diagnostics.fallbackReason
            )
        )
    }

    public func prepareActions(_ drafts: [ToolActionDraft]) async throws -> [PreparedToolAction] {
        var prepared: [PreparedToolAction] = []
        for draft in drafts {
            try Task.checkCancellation()
            try prepared.append(await actionPreparer.prepare(draft))
        }
        return prepared
    }

    public func loadHistory() async -> [AssistantRun] {
        guard let historyStore else {
            return []
        }
        return (try? await historyStore.load()) ?? []
    }

    public func record(_ run: AssistantRun) async -> [AssistantRun] {
        guard let historyStore else {
            return [run]
        }
        return (try? await historyStore.append(run)) ?? [run]
    }

    public func clearHistory() async {
        try? await historyStore?.clear()
    }
}
