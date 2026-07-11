import Combine
import Foundation
import LocalAssistCore
import OSLog
import LocalAssistFoundationModels
import LocalAssistSystemTools
#if canImport(UIKit)
    import UIKit
#endif

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
    /// Cancels itself when the view model deallocates — no deinit bookkeeping.
    private var memoryWarningSubscription: AnyCancellable?
    private var forceOfflineFallbackForNextRun = false
    /// One prewarm per Smart-mode session — WWDC "Code-Along" pattern: fire
    /// when the user gives a strong hint (starts typing) so time-to-first-
    /// token is spent while they finish composing, not after Generate.
    private var didPrewarmForCurrentSmartSession = false
    private static let defaultMaxSuggestions = 5

    private static let smartModeDefaultsKey = "localassist.usesSmartModel"
    /// Comma-separated names whose messages/emails outrank everything else.
    public static let priorityContactsDefaultsKey = "localassist.priorityContacts"
    public static let defaultPriorityContacts = "mom, dad"

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

        #if canImport(UIKit)
            // Memory pressure sheds idle model sessions; the conversation
            // digest and saved history are untouched. Captures the worker,
            // not self — the closure needs nothing MainActor-isolated.
            let pressureWorker = worker
            memoryWarningSubscription = NotificationCenter.default
                .publisher(for: UIApplication.didReceiveMemoryWarningNotification)
                .sink { _ in
                    Task {
                        await pressureWorker.handleMemoryPressure()
                    }
                }
        #endif
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
        Logger(subsystem: "com.saithej.localassist", category: "Voice")
            .info("prepare capture: base=\(self.voiceCaptureBaseText.count) chars")
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

    /// One-tap ✕ on the capture box. Also forgets the voice-capture base
    /// snapshot: a recording session may still be live, and its next
    /// transcript update must merge onto the now-empty box — merging onto
    /// the old snapshot resurrected everything the user just cleared.
    public func clearCapture() {
        inputText = ""
        inputKind = .note
        voiceCaptureBaseText = ""
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

    /// Composer URL for a confirmed message draft: Messages for personal
    /// texts (`sms:` with the contact's number), the default mail app for
    /// email (`mailto:` with address + subject + body — Gmail when the
    /// user made it their default). The user sends or abandons; the app
    /// never sends anything itself. Drafts from older runs carry no
    /// channel and fall back to the email composer, as before.
    public nonisolated static func draftHandoffURL(for action: PreparedToolAction) -> URL? {
        guard action.draft.kind == .messageDraft else {
            return nil
        }
        let payload = action.draft.payload
        let explicit = MessageChannel(rawValue: payload["channel"] ?? "") ?? .auto
        let channel = MessageChannelRouter.resolve(
            explicit: explicit,
            hasPhone: payload["recipientPhone"] != nil,
            hasEmail: payload["recipientEmail"] != nil
        )
        return MessageChannelRouter.handoffURL(
            channel: channel,
            phone: payload["recipientPhone"],
            email: payload["recipientEmail"],
            subject: payload["subject"] ?? payload["title"] ?? action.draft.title,
            body: payload["body"] ?? payload["notes"] ?? ""
        )
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

    /// Confirmation for communication actions: the model first writes the
    /// actual message (subject + ready-to-send body grounded in the
    /// captured note), then the composer URL for it is returned so the
    /// caller can open Messages or mail. Non-message actions run the plain
    /// confirm path and return nil.
    public func confirmAndHandoff(_ action: PreparedToolAction) async -> URL? {
        guard action.draft.kind == .messageDraft else {
            confirmAction(action)
            return nil
        }
        let capturedNote = run?.request.sourceText ?? inputText
        let composed = await worker.composedMessageAction(
            action,
            capturedNote: capturedNote,
            useModel: usesSmartModel
        )
        do {
            let executed = try await worker.execute(composed)
            executedActions[action.id] = executed
        } catch {
            executedActions[action.id] = ExecutedToolAction(
                id: action.id,
                kind: composed.draft.kind,
                outcome: .skipped(reason: String(describing: error))
            )
        }
        return Self.draftHandoffURL(for: composed)
    }

    public func cancel() {
        generationTask?.cancel()
        isGenerating = false
        generationMessage = "Cancelled"
    }

    public func clearDraft() {
        inputText = ""
        inputKind = .note
        voiceCaptureBaseText = ""
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
            NotificationCenter.default.post(name: .localAssistHistoryDidDelete, object: nil)
        }
    }

    /// Deletes one saved brief from history. The Spotlight entry follows
    /// via the tombstone outbox — it never outlives the local data by more
    /// than the cleanup pass.
    public func deleteRun(id: String) {
        Task { [weak self] in
            guard let self else { return }
            self.history = await worker.deleteRun(id: id)
            if self.run?.id == id {
                self.run = nil
                self.preparedActions = []
                self.executedActions = [:]
            }
            await morningBrief.refresh(history: self.history)
            NotificationCenter.default.post(name: .localAssistHistoryDidDelete, object: nil)
        }
    }

    /// Read-only transcript of the shared model session for the Settings
    /// diagnostics view.
    public func transcriptDiagnostics() async -> [TranscriptEntrySnapshot] {
        await worker.transcriptDiagnostics()
    }

    /// Timing snapshot of the most recent voice capture, mirrored from the
    /// transcriber by the capture UI so the diagnostics export can include
    /// it. Milliseconds only — never transcript content.
    public var latestVoiceTimeline: VoiceSessionTimeline.Snapshot?

    public static let sampleInput = """
    Call Mom tonight to check in, text Priya about Sunday brunch, and pick up the birthday cake \
    Saturday morning. Book a dentist appointment for next week and pay the electricity bill by Friday.
    """
}

// MARK: - Exports

/// Share-sheet exports, kept out of the class body: pure functions of
/// published state.
public extension LocalAssistViewModel {
    /// Writes both history exports to temporary files for the share sheet:
    /// JSON is the app's exact history format, Markdown is human-readable.
    /// Files share far better than raw strings — AirDrop, Save to Files,
    /// and Mail all treat them as documents.
    func exportFileURLs() -> (markdown: URL?, json: URL?) {
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

    /// Redacted diagnostics export: metrics, stage timings, environment,
    /// context bookkeeping, rule IDs — structurally content-free (see
    /// `DiagnosticsExporter`). User-initiated from Settings only; nothing
    /// on a normal screen surfaces these numbers.
    func exportDiagnosticsURL() async -> URL? {
        guard !history.isEmpty else {
            return nil
        }
        let voiceTimings = latestVoiceTimeline.map { snapshot in
            var timings: [String: Double] = [:]
            timings["audioReadyMilliseconds"] = snapshot.audioReadyMilliseconds
            timings["firstFrameMilliseconds"] = snapshot.firstFrameMilliseconds
            timings["analyzerStartMilliseconds"] = snapshot.analyzerStartMilliseconds
            timings["firstPartialMilliseconds"] = snapshot.firstPartialMilliseconds
            timings["lastFrameMilliseconds"] = snapshot.lastFrameMilliseconds
            timings["finalResultMilliseconds"] = snapshot.finalResultMilliseconds
            timings["drainCompletedMilliseconds"] = snapshot.drainCompletedMilliseconds
            return timings.compactMapValues { $0 }
        }
        let export = DiagnosticsExporter.export(
            runs: history,
            lastVoiceSessionTimings: voiceTimings,
            lastPersistenceMilliseconds: await worker.lastPersistenceMilliseconds
        )
        let stamp = LocalAssistDates.dateOnlyString(from: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalAssist-diagnostics-\(stamp).json")
        guard let data = try? DiagnosticsExporter.jsonData(export),
              (try? data.write(to: url, options: .atomic)) != nil
        else {
            return nil
        }
        return url
    }

    /// Markdown export of the entire local history — the data is the user's.
    func exportMarkdown() -> String {
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
}

// MARK: - Generation run

private extension LocalAssistViewModel {
    func start(request: AssistantRequest) {
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
            var collector = StageTimingCollector()

            do {
                var finalSummary = try await drain(
                    await worker.streamSummary(request, forceFallback: useFallback),
                    collector: &collector
                )

                // The service always ends a run with a summary or a typed
                // failure, so an empty ending means the stream itself died —
                // seen on device when the app is suspended mid-generation
                // and the model connection is torn down. Same policy as
                // every other failure: the deterministic engine answers.
                if finalSummary == nil, !useFallback, !Task.isCancelled {
                    finalSummary = try await drain(
                        await worker.streamSummary(request, forceFallback: true),
                        collector: &collector
                    )
                }
                guard !Task.isCancelled else { return }

                guard let finalSummary else {
                    throw LocalAssistError.generationDidNotFinish
                }

                let clock = ContinuousClock()
                let prepareStarted = clock.now
                let prepared = try await worker.prepareActions(finalSummary.actionDrafts)
                collector.recordActionPreparation(prepareStarted.duration(to: clock.now))
                collector.recordActionReviewReady()

                let run = await worker.makeRun(
                    request: request,
                    summary: finalSummary,
                    startedAt: startedAt,
                    stageTimings: collector.collected
                )
                let history = await worker.record(run)
                guard !Task.isCancelled else { return }
                self.run = run
                // Messages/emails to the user's priority people (Settings →
                // Priority contacts) surface above everything else.
                self.preparedActions = MessageChannelRouter.prioritized(
                    prepared,
                    priorityContacts: MessageChannelRouter.priorityContacts(
                        fromSetting: UserDefaults.standard.string(forKey: Self.priorityContactsDefaultsKey)
                            ?? Self.defaultPriorityContacts
                    )
                )
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

    /// Minimum interval between published streaming-partial snapshots.
    /// The model can emit partials far faster than a human can read them;
    /// coalescing to a stable cadence keeps SwiftUI diffing bounded instead
    /// of re-rendering the card for every token. Terminal updates (summary
    /// or a complete partial) always publish immediately.
    private static let partialPublishInterval: Duration = .milliseconds(80)

    /// Drains one generation stream into the UI state, returning the final
    /// summary if the stream produced one. Stops quietly on cancellation —
    /// the caller decides whether a nil summary is an error. Feeds every
    /// update into the stage-timing collector.
    func drain(
        _ stream: AsyncThrowingStream<SummaryGenerationUpdate, Error>,
        collector: inout StageTimingCollector
    ) async throws -> StructuredSummary? {
        var finalSummary: StructuredSummary?
        let clock = ContinuousClock()
        var lastPartialPublishedAt: ContinuousClock.Instant?

        for try await update in stream {
            guard !Task.isCancelled else { return finalSummary }
            collector.record(
                phase: update.phase,
                hasPartial: update.partial != nil,
                hasSummary: update.summary != nil
            )
            generationPhase = update.phase
            generationMessage = update.message
            if let partial = update.partial {
                let now = clock.now
                let isTerminal = partial.isComplete || update.summary != nil
                let cadenceElapsed = lastPartialPublishedAt.map {
                    $0.duration(to: now) >= Self.partialPublishInterval
                } ?? true
                if isTerminal || cadenceElapsed {
                    streamingPartial = partial
                    lastPartialPublishedAt = now
                }
            }
            if let summary = update.summary {
                finalSummary = summary
                // Deliberately not overwriting `availability` here: it
                // tracks the underlying Smart-mode model state (for the
                // header pill), not the fallback reason of the run.
            }
        }
        return finalSummary
    }
}
