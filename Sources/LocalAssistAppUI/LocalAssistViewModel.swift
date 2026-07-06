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
    /// One prewarm per Smart-mode session — WWDC "Code-Along" pattern: fire
    /// when the user gives a strong hint (starts typing) so time-to-first-
    /// token is spent while they finish composing, not after Generate.
    private var didPrewarmForCurrentSmartSession = false
    private static let defaultMaxSuggestions = 5

    private static let smartModeDefaultsKey = "localassist.usesSmartModel"

    public init(
        inputText: String = "",
        inputKind: AssistantInputKind = .note,
        usesSmartModel: Bool? = nil,
        worker: LocalAssistWorker = LocalAssistWorker(),
        morningBrief: MorningBriefScheduler = MorningBriefScheduler()
    ) {
        self.inputText = inputText
        self.inputKind = inputKind
        // Smart mode persists across launches so the model prewarms at
        // startup instead of after the first toggle — the difference
        // between a warm and a cold first generation.
        self.usesSmartModel = usesSmartModel
            ?? UserDefaults.standard.bool(forKey: Self.smartModeDefaultsKey)
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
        guard usesSmartModel, !didPrewarmForCurrentSmartSession else {
            return
        }
        didPrewarmForCurrentSmartSession = true
        Task { [weak self] in
            await self?.worker.prewarm()
        }
    }

    /// Called when the input field or a chip changes. In Smart mode a
    /// non-empty draft is the strongest hint the user will hit Generate soon,
    /// so we prewarm now — matching the WWDC "text-field-triggered prewarm"
    /// recipe. In Instant mode there is nothing to warm up.
    public func inputChanged() {
        guard usesSmartModel else {
            return
        }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        prewarm()
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

    /// Snapshot of the capture box taken synchronously before a recording
    /// starts, so dictation appends to it. Owned here — snapshotting via a
    /// SwiftUI onChange raced the first transcript update, and losing that
    /// race replaced everything previously in the box.
    private var voiceCaptureBaseText = ""

    /// Call synchronously before starting any voice capture (mic button,
    /// App Shortcut, Lock Screen widget).
    public func prepareVoiceCapture() {
        voiceCaptureBaseText = inputText
    }

    /// Live transcript updates merge onto the snapshot; the box never loses
    /// what was there before the recording began.
    public func mergeVoiceTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        inputKind = .voiceNote
        inputText = voiceCaptureBaseText.isEmpty
            ? transcript
            : voiceCaptureBaseText + "\n" + transcript
    }

    public func summarize() {
        // The user never picks a capture kind: voice input keeps its kind,
        // typed or scanned text is classified from its own content.
        if inputKind != .voiceNote {
            inputKind = AssistantInputKind.inferred(from: inputText)
        }
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
        UserDefaults.standard.set(usesSmartModel, forKey: Self.smartModeDefaultsKey)
        didPrewarmForCurrentSmartSession = false
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
                        // Deliberately not overwriting `availability` here:
                        // it tracks the underlying Smart-mode model state
                        // (for the header pill), not the fallback reason of
                        // the just-completed run.
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
                self.isGenerating = false
                await morningBrief.refresh(history: history)
                // Re-query the true model state so the header pill and
                // Settings sheet stay accurate after each run.
                refreshAvailability()
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

    /// Flips a task's done-state and persists it into history.
    public func toggleTask(runID: String, task: TaskSuggestion) {
        Task { [weak self] in
            guard let self else { return }
            let currentlyDone = history.first(where: { $0.id == runID })?.isCompleted(task)
                ?? (run?.id == runID ? run?.isCompleted(task) : nil)
                ?? false

            let updated = await worker.setTask(task.id, completed: !currentlyDone, inRun: runID)
            self.history = updated
            if var current = self.run, current.id == runID {
                if currentlyDone {
                    current.completedTaskIDs.remove(task.id)
                } else {
                    current.completedTaskIDs.insert(task.id)
                }
                self.run = current
            }
            await morningBrief.refresh(history: updated)
        }
    }

    /// Mail composer URL for a confirmed message draft, so the handoff opens
    /// a real composer instead of ending at a simulated result.
    public nonisolated static func draftHandoffURL(for action: PreparedToolAction) -> URL? {
        guard action.draft.kind == .messageDraft else {
            return nil
        }
        let subject = action.draft.payload["subject"] ?? action.draft.payload["title"] ?? action.draft.title
        let body = action.draft.payload["body"] ?? action.draft.payload["notes"] ?? ""

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
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

    /// Writes both history exports to temporary files for the share sheet:
    /// JSON is the app's exact history format, Markdown is human-readable.
    /// Files share far better than raw strings — AirDrop, Save to Files,
    /// and Mail all treat them as documents.
    public func exportFileURLs() -> (markdown: URL?, json: URL?) {
        guard !history.isEmpty else {
            return (nil, nil)
        }

        let stamp = LocalAssistDates.dateOnlyString(from: Date())
        let directory = FileManager.default.temporaryDirectory

        var markdownURL: URL?
        let markdownCandidate = directory.appendingPathComponent("LocalAssist-history-\(stamp).md")
        if let data = exportMarkdown().data(using: .utf8),
           (try? data.write(to: markdownCandidate, options: .atomic)) != nil {
            markdownURL = markdownCandidate
        }

        var jsonURL: URL?
        let jsonCandidate = directory.appendingPathComponent("LocalAssist-history-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(history),
           (try? data.write(to: jsonCandidate, options: .atomic)) != nil {
            jsonURL = jsonCandidate
        }

        return (markdownURL, jsonURL)
    }

    /// Markdown export of the entire local history — the data is the user's.
    public func exportMarkdown() -> String {
        var lines = ["# LocalAssist history", ""]
        let formatter = ISO8601DateFormatter()
        for run in history {
            lines.append("## \(run.summary.headline)")
            let sourceLabel = run.summary.source == .foundationModels ? "on-device model" : "rules engine"
            lines.append("*\(formatter.string(from: run.summary.generatedAt)) · \(run.request.inputKind.rawValue) · \(sourceLabel)*")
            lines.append("")
            for point in run.summary.keyPoints {
                lines.append("- \(point)")
            }
            if !run.summary.tasks.isEmpty {
                lines.append("")
                for task in run.summary.tasks {
                    let done = run.isCompleted(task) ? "x" : " "
                    var line = "- [\(done)] \(task.title)"
                    if let due = task.iso8601DueDate ?? task.dueHint {
                        line += " (due \(due))"
                    }
                    lines.append(line)
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static let sampleInput = """
    Call Mom tonight to check in, text Priya about Sunday brunch, and pick up the birthday cake \
    Saturday morning. Book a dentist appointment for next week and pay the electricity bill by Friday.
    """
}

public actor LocalAssistWorker {
    private let liveService: LocalAssistService
    private let fallbackService: LocalAssistService
    private let summarizer: FoundationModelsSummarizer
    private let actionPreparer: any ToolActionPreparing
    private let actionExecutor: any ToolActionExecuting
    private let toolCounter: ToolInvocationCounter
    private var historyStore: RunHistoryStore?
    private var historyStoreResolved: Bool

    public init(
        actionPreparer: any ToolActionPreparing = DraftOnlyToolActionPreparer(),
        actionExecutor: (any ToolActionExecuting)? = nil,
        historyStore: RunHistoryStore? = nil
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
        // A nil store means "resolve the shared container on first use" —
        // that lookup is an XPC call that can block for seconds on builds
        // without a provisioned app group, and this initializer runs on the
        // MainActor at launch. Deferring it into the actor keeps startup
        // hang-free.
        historyStoreResolved = historyStore != nil
    }

    private func store() -> RunHistoryStore? {
        if !historyStoreResolved {
            historyStoreResolved = true
            historyStore = RunHistoryStore.sharedOrLocal()
        }
        return historyStore
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
        guard let historyStore = store() else {
            return []
        }
        return (try? await historyStore.load()) ?? []
    }

    public func setTask(_ taskID: String, completed: Bool, inRun runID: String) async -> [AssistantRun] {
        guard let historyStore = store() else {
            return []
        }
        if let updated = try? await historyStore.setTask(taskID, completed: completed, inRun: runID) {
            LocalAssistWidgetRefresher.refresh()
            return updated
        }
        return (try? await historyStore.load()) ?? []
    }

    public func record(_ run: AssistantRun) async -> [AssistantRun] {
        guard let historyStore = store() else {
            return [run]
        }
        let updated = (try? await historyStore.append(run)) ?? [run]
        LocalAssistWidgetRefresher.refresh()
        return updated
    }

    public func clearHistory() async {
        try? await store()?.clear()
        await summarizer.resetConversation()
    }
}
