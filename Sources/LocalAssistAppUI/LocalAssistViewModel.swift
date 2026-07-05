import Foundation
import LocalAssistCore
import LocalAssistFoundationModels
import LocalAssistSystemTools

@MainActor
public final class LocalAssistViewModel: ObservableObject {
    @Published public var inputText: String
    @Published public var inputKind: AssistantInputKind
    @Published public var refineInstruction: String
    /// Smart mode runs the on-device Foundation Models pipeline; Instant mode
    /// runs the deterministic rule-based summarizer. Both are 100% on-device.
    @Published public var usesSmartModel: Bool
    @Published public private(set) var morningBriefEnabled: Bool
    @Published public private(set) var run: AssistantRun?
    @Published public private(set) var preparedActions: [PreparedToolAction]
    @Published public private(set) var executedActions: [String: ExecutedToolAction]
    @Published public private(set) var availability: ModelAvailability?
    @Published public private(set) var history: [AssistantRun]
    @Published public private(set) var isGenerating: Bool
    @Published public private(set) var generationPhase: SummaryGenerationPhase?
    @Published public private(set) var generationMessage: String?
    @Published public private(set) var streamingPartial: StructuredSummaryPartial?
    @Published public private(set) var errorMessage: String?

    private let worker: LocalAssistWorker
    private let morningBrief: MorningBriefScheduler
    private var generationTask: Task<Void, Never>?
    private var forceOfflineFallbackForNextRun = false
    private static let defaultMaxSuggestions = 5

    public init(
        inputText: String = "",
        inputKind: AssistantInputKind = .note,
        usesSmartModel: Bool = false,
        worker: LocalAssistWorker = LocalAssistWorker(),
        morningBrief: MorningBriefScheduler = MorningBriefScheduler()
    ) {
        self.inputText = inputText
        self.inputKind = inputKind
        self.usesSmartModel = usesSmartModel
        refineInstruction = ""
        self.worker = worker
        self.morningBrief = morningBrief
        morningBriefEnabled = morningBrief.isEnabled
        run = nil
        preparedActions = []
        executedActions = [:]
        availability = nil
        history = []
        isGenerating = false
        generationPhase = nil
        generationMessage = nil
        streamingPartial = nil
        errorMessage = nil
    }

    deinit {
        generationTask?.cancel()
    }

    /// Loads the on-device model before the first smart request so
    /// time-to-first-token is spent while the user is still composing.
    public func prewarm() {
        guard usesSmartModel else {
            return
        }
        Task { [weak self] in
            await self?.worker.prewarm()
        }
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
            await morningBrief.refresh(history: history)
        }
    }

    /// Enables or disables the morning brief notification; enabling asks for
    /// notification permission the first time.
    public func setMorningBrief(enabled: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let result = await morningBrief.setEnabled(enabled, history: history)
            self.morningBriefEnabled = result
        }
    }

    /// Starts (or stops) a voice capture initiated from outside the view —
    /// the "Capture a thought" App Shortcut or the Lock Screen widget.
    public func markExternalCaptureRequested() {
        inputKind = .voiceNote
    }

    public func summarize() {
        start(request: AssistantRequest(
            sourceText: inputText,
            maxSuggestions: Self.defaultMaxSuggestions,
            inputKind: inputKind
        ))
    }

    /// Follow-up turn on the same model session: the transcript still holds
    /// the note and previous summary, so a short instruction is enough.
    public func refine() {
        let instruction = refineInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            return
        }
        refineInstruction = ""
        start(request: AssistantRequest(
            sourceText: instruction,
            maxSuggestions: Self.defaultMaxSuggestions,
            inputKind: inputKind,
            isRefinement: true
        ))
    }

    public func forceOfflineFallbackForAutomation() {
        forceOfflineFallbackForNextRun = true
    }

    public func toggleSmartMode() {
        usesSmartModel.toggle()
        if usesSmartModel {
            prewarm()
            refreshAvailability()
        }
    }

    private func start(request: AssistantRequest) {
        generationTask?.cancel()
        errorMessage = nil
        isGenerating = true
        preparedActions = []
        executedActions = [:]
        generationPhase = .validating
        generationMessage = "Starting local generation"
        streamingPartial = nil

        let useFallback = !usesSmartModel || forceOfflineFallbackForNextRun
        forceOfflineFallbackForNextRun = false

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
                    if let partial = update.partial {
                        self.streamingPartial = partial
                    }
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
                self.availability = run.summary.diagnostics.availability
                self.isGenerating = false
                await morningBrief.refresh(history: history)
            } catch is CancellationError {
                self.isGenerating = false
                self.generationMessage = "Cancelled"
            } catch let failure as GenerationFailure {
                self.errorMessage = failure.userMessage
                self.isGenerating = false
            } catch let error as LocalAssistError {
                self.errorMessage = error.description
                self.isGenerating = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isGenerating = false
            }
        }
    }

    /// Executes a staged action after the user's explicit confirmation tap.
    public func confirmAction(_ action: PreparedToolAction) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let executed = try await worker.execute(action)
                self.executedActions[action.id] = executed
            } catch {
                self.executedActions[action.id] = ExecutedToolAction(
                    id: action.id,
                    kind: action.draft.kind,
                    outcome: .skipped(reason: String(describing: error))
                )
            }
        }
    }

    public func cancel() {
        generationTask?.cancel()
        isGenerating = false
        generationMessage = "Cancelled"
    }

    public func clearDraft() {
        inputText = ""
        inputKind = .note
        refineInstruction = ""
        run = nil
        preparedActions = []
        executedActions = [:]
        generationPhase = nil
        generationMessage = nil
        streamingPartial = nil
        errorMessage = nil
    }

    public func clearHistory() {
        Task { [weak self] in
            guard let self else { return }
            await worker.clearHistory()
            self.history = []
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
    private let summarizer: FoundationModelsSummarizer
    private let actionPreparer: any ToolActionPreparing
    private let actionExecutor: any ToolActionExecuting
    private let toolCounter: ToolInvocationCounter
    private let historyStore: RunHistoryStore?

    public init(
        actionPreparer: any ToolActionPreparing = DraftOnlyToolActionPreparer(),
        actionExecutor: (any ToolActionExecuting)? = nil,
        historyStore: RunHistoryStore? = RunHistoryStore.applicationSupportOrNil()
    ) {
        let counter = ToolInvocationCounter()
        let summarizer = LocalAssistLiveFactory.makeSummarizer(
            tools: LocalAssistToolkit.liveTools(counter: counter)
        )
        toolCounter = counter
        self.summarizer = summarizer
        liveService = LocalAssistService(model: summarizer)
        fallbackService = LocalAssistService(
            model: StaticStructuredModelClient(
                state: .unavailable(ModelUnavailability(reason: .forcedOffline))
            )
        )
        self.actionPreparer = actionPreparer
        #if canImport(EventKit)
            self.actionExecutor = actionExecutor ?? SystemActionExecutor.live()
        #else
            self.actionExecutor = actionExecutor ?? SimulatedActionExecutor()
        #endif
        self.historyStore = historyStore
    }

    public func prewarm() async {
        await liveService.prewarm()
    }

    public func availability() async -> ModelAvailability {
        await summarizer.availability()
    }

    public func streamSummary(
        _ request: AssistantRequest,
        forceFallback: Bool
    ) async -> AsyncThrowingStream<SummaryGenerationUpdate, Error> {
        await toolCounter.reset()
        let service = forceFallback ? fallbackService : liveService
        return service.streamSummary(request)
    }

    public func makeRun(
        request: AssistantRequest,
        summary: StructuredSummary,
        startedAt: Date
    ) async -> AssistantRun {
        var summary = summary
        summary.diagnostics.toolInvocationCount = await toolCounter.count

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

    public func execute(_ action: PreparedToolAction) async throws -> ExecutedToolAction {
        try await actionExecutor.execute(action)
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
        await summarizer.resetConversation()
    }
}
