import Combine
import Foundation
import LocalAssistCore
import LocalAssistFoundationModels
import LocalAssistSystemTools

public actor LocalAssistWorker {
    private let liveService: LocalAssistService
    private let fallbackService: LocalAssistService
    private let summarizer: FoundationModelsSummarizer
    private let actionPreparer: any ToolActionPreparing
    private let actionExecutor: any ToolActionExecuting
    private let contactResolver: (any ContactResolving)?
    private let toolCounter: ToolInvocationCounter
    private var historyStore: RunHistoryStore?
    private var historyStoreResolved: Bool

    public init(
        actionPreparer: any ToolActionPreparing = DraftOnlyToolActionPreparer(),
        actionExecutor: (any ToolActionExecuting)? = nil,
        contactResolver: (any ContactResolving)? = nil,
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
        #if canImport(Contacts)
            // Contact enrichment can prompt for Contacts access; automation
            // runs (UI tests, screenshots) must stay dialog-free, same as
            // the onboarding sheet.
            let isAutomationRun = ProcessInfo.processInfo.environment["LOCALASSIST_AUTO_RUN"] == "1"
            self.contactResolver = contactResolver ?? (isAutomationRun ? nil : ContactsFrameworkResolver())
        #else
            self.contactResolver = contactResolver
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

    /// True until the first run completes in this process — the cold/warm
    /// classification recorded into each run's environment.
    private var hasCompletedARun = false

    public func makeRun(
        request: AssistantRequest,
        summary: StructuredSummary,
        startedAt: Date,
        stageTimings: RunStageTimings? = nil
    ) async -> AssistantRun {
        var summary = summary
        summary.diagnostics.toolInvocationCount = await toolCounter.count

        let coldStart = !hasCompletedARun
        hasCompletedARun = true

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
                fallbackReason: summary.diagnostics.fallbackReason,
                stageTimings: stageTimings,
                environment: RunEnvironment.current(coldStart: coldStart),
                context: await summarizer.contextDiagnostics(),
                failureCategory: summary.diagnostics.failureCategory
            )
        )
    }

    public func prepareActions(_ drafts: [ToolActionDraft]) async throws -> [PreparedToolAction] {
        var prepared: [PreparedToolAction] = []
        for draft in drafts {
            try Task.checkCancellation()
            try prepared.append(await actionPreparer.prepare(enrichedWithContact(draft)))
        }
        return prepared
    }

    /// Fills a message draft's recipient phone/email from Contacts so the
    /// composer opens already addressed, and settles an `auto` channel with
    /// the personal-vs-work rule (saved with a phone number → Messages,
    /// email-only → mail). Any lookup failure — access denied, no match —
    /// leaves the draft untouched and the composer opens unaddressed.
    private func enrichedWithContact(_ draft: ToolActionDraft) async -> ToolActionDraft {
        guard draft.kind == .messageDraft,
              let contactResolver,
              let recipient = draft.payload["recipient"],
              // Bounded: a hung Contacts lookup (busy contactsd, first-run
              // permission service stall) must not hold the review cards
              // hostage — past the deadline the draft ships unenriched and
              // the composer opens unaddressed, same as a failed lookup.
              let match = try? await LocalAssistDeadline.run(
                  .seconds(5),
                  stage: "contact-enrichment",
                  operation: { try await contactResolver.contacts(matching: recipient).first }
              )
        else {
            return draft
        }
        var enriched = draft
        if let phone = match.phoneNumber {
            enriched.payload["recipientPhone"] = phone
        }
        if let email = match.emailAddress {
            enriched.payload["recipientEmail"] = email
        }
        let explicit = MessageChannel(rawValue: draft.payload["channel"] ?? "") ?? .auto
        enriched.payload["channel"] = MessageChannelRouter.resolve(
            explicit: explicit,
            hasPhone: match.hasPhone,
            hasEmail: match.hasEmail
        ).rawValue
        return enriched
    }

    public func execute(_ action: PreparedToolAction) async throws -> ExecutedToolAction {
        try await actionExecutor.execute(action)
    }

    /// Composes the actual message for a confirmed communication action:
    /// the on-device model writes a ready-to-send subject + body from the
    /// captured note (Smart mode), with the deterministic template as the
    /// always-works fallback. The LocalAssist signature lands at the end of
    /// the body — visible and deletable in the composer.
    public func composedMessageAction(
        _ action: PreparedToolAction,
        capturedNote: String,
        useModel: Bool
    ) async -> PreparedToolAction {
        guard action.draft.kind == .messageDraft else {
            return action
        }
        let payload = action.draft.payload
        let task = payload["subject"] ?? action.draft.title
        let recipient = payload["recipient"]
        let channel = MessageChannelRouter.resolve(
            explicit: MessageChannel(rawValue: payload["channel"] ?? "") ?? .auto,
            hasPhone: payload["recipientPhone"] != nil,
            hasEmail: payload["recipientEmail"] != nil
        )

        // Routed commands arrive with the message already written (the
        // router drafts at parse time), and the user just reviewed exactly
        // that text on the card — recomposing here would replace what they
        // approved. Only the signature is appended.
        if payload["composed"] == "true", let body = payload["body"], !body.isEmpty {
            var updated = action
            updated.draft.payload["body"] = body + MessageBranding.signature(for: channel)
            return updated
        }

        var composed: ComposedMessageDraft?
        if useModel, let modelDraft = await summarizer.composeMessage(
            recipient: recipient,
            task: task,
            channelDescription: channel == .textMessage ? "text message" : "email",
            capturedNote: capturedNote
        ) {
            composed = ComposedMessageDraft(subject: modelDraft.subject, body: modelDraft.body)
        }
        let final = composed ?? DeterministicMessageComposer.compose(
            recipient: recipient,
            title: task,
            channel: channel
        )

        var updated = action
        updated.draft.payload["subject"] = final.subject
        updated.draft.payload["body"] = final.body + MessageBranding.signature(for: channel)
        return updated
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

    /// History-write duration of the most recent `record`, for the
    /// diagnostics export. A run cannot carry its own persistence cost —
    /// it is measured around the write that saves it.
    public private(set) var lastPersistenceMilliseconds: Double?

    public func record(_ run: AssistantRun) async -> [AssistantRun] {
        guard let historyStore = store() else {
            return [run]
        }
        // Bounded persistence: a blocked container write (unprovisioned
        // app group, containermanagerd stall) already degrades to the
        // in-memory run; the deadline turns "blocked forever" into that
        // same degradation.
        let clock = ContinuousClock()
        let started = clock.now
        let updated = (try? await LocalAssistDeadline.run(
            .seconds(10),
            stage: "history-persistence",
            operation: { try await historyStore.append(run) }
        )) ?? [run]
        let elapsed = started.duration(to: clock.now)
        lastPersistenceMilliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        LocalAssistWidgetRefresher.refresh()
        return updated
    }

    /// Deletes one saved run. Local deletion is atomic with its Spotlight
    /// tombstone inside the store; the index cleanup itself runs in the app
    /// layer (`SpotlightDeletionCoordinator`), triggered by the
    /// `.localAssistHistoryDidDelete` notification the view model posts.
    public func deleteRun(id: String) async -> [AssistantRun] {
        guard let historyStore = store() else {
            return []
        }
        let updated: [AssistantRun]
        if let afterDelete = try? await historyStore.delete(runID: id) {
            updated = afterDelete
        } else {
            updated = (try? await historyStore.load()) ?? []
        }
        LocalAssistWidgetRefresher.refresh()
        return updated
    }

    public func clearHistory() async {
        try? await store()?.clear()
        await summarizer.resetConversation()
        LocalAssistWidgetRefresher.refresh()
    }

    /// Memory-warning response: drop idle model sessions and transient
    /// caches. Saved history and the conversation digest survive — only
    /// rebuildable state goes.
    public func handleMemoryPressure() async {
        await summarizer.releaseInactiveSessions()
    }

    /// Read-only transcript of the shared model session for the Settings
    /// diagnostics view — value types only, mapped at the adapter boundary.
    public func transcriptDiagnostics() async -> [TranscriptEntrySnapshot] {
        await summarizer.transcriptSnapshot()
    }
}
