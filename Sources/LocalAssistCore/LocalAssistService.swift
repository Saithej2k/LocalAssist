import Foundation
import OSLog

/// Orchestrates a summary run: validation, availability, typed streaming from
/// the on-device model, normalization, and the deterministic offline fallback.
///
/// Long inputs are handled with map-reduce: sentence-aligned chunks are
/// summarized individually, then a reduce pass over the digest produces the
/// final brief — so hour-long meeting notes work within the on-device model's
/// context window instead of failing into the fallback.
///
/// Fallback policy: the deterministic summarizer substitutes whenever the
/// model cannot complete a usable brief. Availability failures, guardrails,
/// context-window errors, refusals, and transient generation failures all keep
/// the app moving offline while diagnostics preserve the exact reason.
public struct LocalAssistService: Sendable {
    private let model: (any StructuredModelClient)?
    private let fallback: DeterministicFallbackGenerator
    private let normalizer: SummaryNormalizer
    private let validator: RequestValidator

    /// Inputs longer than one chunk trigger map-reduce summarization.
    private let chunkTargetCharacters: Int

    /// Bounded deadline for one model streaming pass. A wedged stream —
    /// device suspending mid-generation, model service hung — otherwise
    /// spins forever; on expiry the run falls back deterministically with
    /// `GenerationFailure.timedOut` recorded. Generous on purpose: it must
    /// only fire when something is genuinely stuck, never on a slow-but-
    /// working device.
    private let modelResponseDeadline: Duration

    /// Bounded deadline for routing one direct command.
    private let routingDeadline: Duration

    public init(
        model: (any StructuredModelClient)? = nil,
        fallback: DeterministicFallbackGenerator = DeterministicFallbackGenerator(),
        normalizer: SummaryNormalizer = SummaryNormalizer(),
        validator: RequestValidator = RequestValidator(),
        chunkTargetCharacters: Int = 2800,
        modelResponseDeadline: Duration = .seconds(90),
        routingDeadline: Duration = .seconds(30)
    ) {
        self.model = model
        self.fallback = fallback
        self.normalizer = normalizer
        self.validator = validator
        self.chunkTargetCharacters = chunkTargetCharacters
        self.modelResponseDeadline = modelResponseDeadline
        self.routingDeadline = routingDeadline
    }

    /// Warms up the underlying model so the first request streams sooner.
    public func prewarm() async {
        await model?.prewarm()
    }

    public func availability() async -> ModelAvailability {
        guard let model else {
            return .unavailable(ModelUnavailability(reason: .adapterNotConfigured))
        }
        return await model.availability()
    }

    public func summarize(_ request: AssistantRequest) async throws -> StructuredSummary {
        var finalSummary: StructuredSummary?
        for try await update in streamSummary(request) where update.summary != nil {
            finalSummary = update.summary
        }
        try Task.checkCancellation()

        guard let finalSummary else {
            throw LocalAssistError.generationDidNotFinish
        }

        return finalSummary
    }

    public func streamSummary(_ request: AssistantRequest) -> AsyncThrowingStream<SummaryGenerationUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let emit: @Sendable (SummaryGenerationUpdate) -> Void = { update in
                    continuation.yield(update)
                }

                do {
                    _ = try await summarize(request, emit: emit)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func summarize(
        _ request: AssistantRequest,
        emit: @escaping @Sendable (SummaryGenerationUpdate) -> Void
    ) async throws -> StructuredSummary {
        let signposter = LocalAssistInstrumentation.generationSignposter()
        let summarizeState = signposter.beginInterval("Summarize")
        defer {
            signposter.endInterval("Summarize", summarizeState)
        }

        emit(.init(phase: .validating, message: "Validating local input"))
        let validated: AssistantRequest
        do {
            let validateState = signposter.beginInterval("Validate request")
            defer {
                signposter.endInterval("Validate request", validateState)
            }
            validated = try validator.validate(request)
        }
        try Task.checkCancellation()

        // Direct commands ("text Priya that brunch works") skip the brief
        // entirely: the deliverable is a routed, addressed action card, not
        // a headline with key points. A multi-line dump partitions — command
        // lines route line by line, the remaining lines go once through the
        // brief extractor, and every card lands in the same review list;
        // the whole point of the box is dumping thoughts and getting each
        // one sorted. Refinements stay on the brief path — they are
        // instructions about an existing summary.
        if !validated.isRefinement {
            if let dump = DirectCommandDetector.partitionedDump(in: validated.sourceText) {
                return try await routeCommandBatch(
                    dump,
                    request: validated,
                    emit: emit,
                    signposter: signposter
                )
            }
            if DirectCommandDetector.isDirectCommand(validated.sourceText) {
                return try await routeDirectCommand(validated, emit: emit, signposter: signposter)
            }
        }

        let chunks = TranscriptChunker.chunks(
            from: validated.sourceText,
            targetCharacters: chunkTargetCharacters
        )
        if chunks.count > 1 {
            return try await mapReduceSummary(
                validated,
                chunks: chunks,
                emit: emit,
                signposter: signposter
            )
        }

        return try await singlePass(validated, emit: emit, publishUpdates: true, signposter: signposter)
    }

    // MARK: - Map-reduce for long input

    private func mapReduceSummary(
        _ request: AssistantRequest,
        chunks: [String],
        emit: @escaping @Sendable (SummaryGenerationUpdate) -> Void,
        signposter: OSSignposter
    ) async throws -> StructuredSummary {
        let mapState = signposter.beginInterval("Map-reduce")
        defer {
            signposter.endInterval("Map-reduce", mapState)
        }

        var parts: [StructuredSummary] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            emit(.init(
                phase: .streamingModel,
                message: "Summarizing section \(index + 1) of \(chunks.count)"
            ))

            let chunkRequest = AssistantRequest(
                sourceText: chunk,
                localeIdentifier: request.localeIdentifier,
                maxSuggestions: request.maxSuggestions,
                inputKind: request.inputKind
            )
            let part = try await singlePass(
                chunkRequest,
                emit: emit,
                publishUpdates: false,
                signposter: signposter
            )
            parts.append(part)
        }

        // Reduce: a model pass over the digest yields a coherent overall
        // headline; without a working model, merge deterministically.
        let modelProducedParts = parts.contains { $0.source == .foundationModels }
        if modelProducedParts {
            emit(.init(phase: .streamingModel, message: "Combining \(chunks.count) sections"))
            let reduceRequest = AssistantRequest(
                sourceText: TranscriptChunker.digest(of: parts),
                localeIdentifier: request.localeIdentifier,
                maxSuggestions: request.maxSuggestions,
                inputKind: request.inputKind
            )
            return try await singlePass(
                reduceRequest,
                emit: emit,
                publishUpdates: true,
                signposter: signposter
            )
        }

        let availability = parts.first?.diagnostics.availability
            ?? .unavailable(ModelUnavailability(reason: .adapterNotConfigured))
        guard let merged = normalizer.merged(
            parts: parts,
            request: request,
            availability: availability
        ) else {
            throw GenerationFailure.decodingFailure(
                detail: "Merging chunked summaries produced no usable brief."
            )
        }

        emit(.init(
            phase: .completed,
            summary: merged,
            message: "Combined \(chunks.count) sections offline"
        ))
        return merged
    }

    // MARK: - Single-pass generation

    private func singlePass(
        _ request: AssistantRequest,
        emit: @escaping @Sendable (SummaryGenerationUpdate) -> Void,
        publishUpdates: Bool,
        signposter: OSSignposter
    ) async throws -> StructuredSummary {
        let sink = UpdateSink(emit: emit, publishUpdates: publishUpdates, signposter: signposter)
        guard let model else {
            return try await fallbackSummary(
                for: request,
                unavailability: ModelUnavailability(reason: .adapterNotConfigured),
                sink: sink
            )
        }

        if publishUpdates {
            emit(.init(phase: .checkingAvailability, message: "Checking Foundation Models availability"))
        }
        let availabilityState = signposter.beginInterval("Model availability")
        let availability = await model.availability()
        signposter.endInterval("Model availability", availabilityState)
        try Task.checkCancellation()

        guard availability.isAvailable else {
            let unavailability = availability.unavailability
                ?? ModelUnavailability(reason: .other)
            return try await fallbackSummary(for: request, unavailability: unavailability, sink: sink)
        }

        do {
            return try await modelSummary(
                for: request,
                model: model,
                availability: availability,
                sink: sink
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as GenerationFailure {
            if case .modelUnavailable(let unavailability) = failure {
                return try await fallbackSummary(for: request, unavailability: unavailability, sink: sink)
            }
            return try await fallbackSummary(
                for: request,
                availability: availability,
                context: FallbackContext(
                    reason: String(describing: failure),
                    guidance: failure.userMessage,
                    failureCategory: failure.category
                ),
                sink: sink
            )
        } catch {
            throw GenerationFailure.unknown(detail: String(describing: error))
        }
    }

    /// One deadline-bounded model streaming pass plus normalization. Throws
    /// typed `GenerationFailure`s; `singlePass` owns the fallback policy.
    private func modelSummary(
        for request: AssistantRequest,
        model: any StructuredModelClient,
        availability: ModelAvailability,
        sink: UpdateSink
    ) async throws -> StructuredSummary {
        let emit = sink.emit
        let publishUpdates = sink.publishUpdates
        let signposter = sink.signposter
        let responseState = signposter.beginInterval("Model response")
        if publishUpdates {
            emit(.init(phase: .streamingModel, message: "Streaming on-device model response"))
        }

        // The whole streaming pass runs under a deadline: a wedged
        // stream (app suspended mid-generation, hung model service)
        // otherwise never finishes and never errors. On expiry the
        // stream task is cancelled and the run falls back with a typed
        // `timedOut` failure like any other generation failure.
        let latest = try await Self.boundedModelPass(
            deadline: modelResponseDeadline
        ) { () -> StructuredSummaryPartial? in
            var latest: StructuredSummaryPartial?
            for try await partial in model.streamSummary(for: request) {
                try Task.checkCancellation()
                latest = partial
                if publishUpdates {
                    emit(.init(
                        phase: .streamingModel,
                        partial: partial,
                        message: partial.isComplete
                            ? "Model response complete"
                            : "Streaming on-device model response"
                    ))
                }
            }
            return latest
        }
        signposter.endInterval("Model response", responseState)
        try Task.checkCancellation()

        guard let latest, latest.isComplete else {
            throw GenerationFailure.decodingFailure(
                detail: "The model stream ended before producing a complete summary."
            )
        }

        if publishUpdates {
            emit(.init(phase: .normalizing, partial: latest, message: "Normalizing structured output"))
        }
        let normalizeState = signposter.beginInterval("Normalize summary")
        let summary = normalizer.summary(
            from: latest,
            request: request,
            availability: availability
        )
        signposter.endInterval("Normalize summary", normalizeState)

        guard let summary else {
            throw GenerationFailure.decodingFailure(
                detail: "The model produced an empty overview or no key points."
            )
        }

        if publishUpdates {
            emit(.init(
                phase: .completed,
                partial: latest,
                summary: summary,
                message: "Completed with Foundation Models"
            ))
        }
        return summary
    }

}

// MARK: - Fallback

/// How generation updates leave the service: the emit closure, whether this
/// pass publishes to the UI, and the signposter — they travel together
/// through every stage.
private struct UpdateSink: Sendable {
    let emit: @Sendable (SummaryGenerationUpdate) -> Void
    let publishUpdates: Bool
    let signposter: OSSignposter
}

/// Why a run is falling back: prose reason for diagnostics, user-facing
/// guidance, and the stable machine-readable category.
private struct FallbackContext: Sendable {
    let reason: String
    let guidance: String
    let failureCategory: String?
}

private extension LocalAssistService {
    func fallbackSummary(
        for request: AssistantRequest,
        unavailability: ModelUnavailability,
        sink: UpdateSink
    ) async throws -> StructuredSummary {
        try await fallbackSummary(
            for: request,
            availability: .unavailable(unavailability),
            context: FallbackContext(
                reason: unavailability.detail,
                guidance: unavailability.userGuidance,
                failureCategory: GenerationFailure.modelUnavailable(unavailability).category
            ),
            sink: sink
        )
    }

    func fallbackSummary(
        for request: AssistantRequest,
        availability: ModelAvailability,
        context: FallbackContext,
        sink: UpdateSink
    ) async throws -> StructuredSummary {
        if sink.publishUpdates {
            sink.emit(.init(phase: .fallback, message: context.guidance))
        }
        let fallbackState = sink.signposter.beginInterval("Fallback generation")
        defer {
            sink.signposter.endInterval("Fallback generation", fallbackState)
        }

        var summary = try await fallback.generate(
            for: request,
            availability: availability,
            fallbackReason: context.reason
        )
        summary.diagnostics.failureCategory = context.failureCategory
        if sink.publishUpdates {
            emitFallbackPartials(for: summary, message: context.guidance, emit: sink.emit)
            sink.emit(.init(
                phase: .completed,
                summary: summary,
                message: "Completed with deterministic fallback"
            ))
        }
        return summary
    }

    /// One model streaming pass under a deadline, with `DeadlineExceeded`
    /// mapped into the typed failure taxonomy so every caller's existing
    /// `GenerationFailure` policy (fall back, record reason) applies.
    static func boundedModelPass<T: Sendable>(
        deadline: Duration,
        stage: String = "model-response",
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await LocalAssistDeadline.run(deadline, stage: stage, operation: operation)
        } catch let exceeded as DeadlineExceeded {
            throw GenerationFailure.timedOut(stage: exceeded.stage)
        }
    }

    func emitFallbackPartials(
        for summary: StructuredSummary,
        message: String,
        emit: @escaping @Sendable (SummaryGenerationUpdate) -> Void
    ) {
        var partial = StructuredSummaryPartial(overview: summary.headline)
        emit(.init(phase: .fallback, partial: partial, message: message))

        partial.keyPoints = summary.keyPoints
        emit(.init(phase: .fallback, partial: partial, message: message))

        partial.suggestions = summary.tasks.map {
            TaskSuggestionPartial(
                title: $0.title,
                priority: $0.priority,
                dueHint: $0.dueHint,
                dueDate: $0.dueDate,
                action: $0.action,
                rationale: $0.rationale,
                confidence: $0.confidence
            )
        }
        partial.isComplete = true
        emit(.init(phase: .fallback, partial: partial, message: message))
    }
}

// MARK: - Direct command routing

private extension LocalAssistService {
    func routeDirectCommand(
        _ request: AssistantRequest,
        emit: @escaping @Sendable (SummaryGenerationUpdate) -> Void,
        signposter: OSSignposter
    ) async throws -> StructuredSummary {
        let routeState = signposter.beginInterval("Route command")
        defer {
            signposter.endInterval("Route command", routeState)
        }

        emit(.init(phase: .checkingAvailability, message: "Checking Foundation Models availability"))
        let availability: ModelAvailability
        if let model {
            availability = await model.availability()
        } else {
            availability = .unavailable(ModelUnavailability(reason: .adapterNotConfigured))
        }
        try Task.checkCancellation()

        var fallbackReason = availability.unavailability?.detail

        if let model, availability.isAvailable {
            emit(.init(phase: .streamingModel, message: "Routing command with the on-device model"))
            do {
                let routingModel = model
                if let routed = try await Self.boundedModelPass(
                    deadline: routingDeadline,
                    stage: "route-command",
                    operation: { try await routingModel.routeCommand(for: request) }
                ) {
                    try Task.checkCancellation()
                    // Drop example-leaked actions and let the deterministic
                    // parser win on dates and clock times before anything
                    // reaches the review cards.
                    let outcome = RoutedActionReconciler.reconcile(
                        routed,
                        sourceText: request.sourceText
                    )
                    let grounded = outcome.actions
                    if !grounded.isEmpty {
                        let summary = RoutedActionMapper.summary(
                            from: Array(grounded.prefix(request.maxSuggestions)),
                            source: .foundationModels,
                            diagnostics: GenerationDiagnostics(
                                availability: availability,
                                reconcilerFindings: outcome.findings
                            )
                        )
                        emit(.init(
                            phase: .completed,
                            summary: summary,
                            message: "Routed with Foundation Models"
                        ))
                        return summary
                    }
                    fallbackReason = "The model produced no actions grounded in the command."
                } else {
                    fallbackReason = "The model client does not support command routing."
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as GenerationFailure {
                fallbackReason = String(describing: failure)
            } catch {
                fallbackReason = String(describing: error)
            }
        }

        emit(.init(phase: .fallback, message: "Routing command with the offline rules engine"))
        let action = DeterministicCommandRouter().route(request.sourceText)
        let summary = RoutedActionMapper.summary(
            from: [action],
            source: .deterministicFallback,
            diagnostics: GenerationDiagnostics(
                availability: availability,
                fallbackReason: fallbackReason ?? "Deterministic command routing."
            )
        )
        emit(.init(
            phase: .completed,
            summary: summary,
            message: "Routed with deterministic rules"
        ))
        return summary
    }

    /// One command per line, one card per command — and one brief-extractor
    /// pass over whatever lines were not commands, so a dump can mix "text
    /// Priya…" with "Call Mom tonight, pick up the cake Saturday" and lose
    /// nothing. Each command line routes exactly like a single command —
    /// model when available, reconciled against that line, deterministic
    /// router on any failure — so a line can never vanish: the rules engine
    /// is the floor for every line individually. Cards accumulate into the
    /// streaming partial as lines finish, so a four-command dump shows its
    /// first card while the fourth still routes.
    func routeCommandBatch(
        _ dump: DirectCommandDetector.PartitionedDump,
        request: AssistantRequest,
        emit: @escaping @Sendable (SummaryGenerationUpdate) -> Void,
        signposter: OSSignposter
    ) async throws -> StructuredSummary {
        let lines = dump.commandLines
        let batchState = signposter.beginInterval("Route command batch")
        defer {
            signposter.endInterval("Route command batch", batchState)
        }

        emit(.init(phase: .checkingAvailability, message: "Checking Foundation Models availability"))
        let availability: ModelAvailability
        if let model {
            availability = await model.availability()
        } else {
            availability = .unavailable(ModelUnavailability(reason: .adapterNotConfigured))
        }
        try Task.checkCancellation()

        let routed = try await routeLines(
            lines,
            request: request,
            availability: availability,
            emit: emit
        )
        let actions = routed.actions
        let anyModelRouted = routed.usedModel
        var fallbackReasons = routed.failureNotes

        if !dump.captureText.isEmpty {
            emit(.init(
                phase: availability.isAvailable ? .streamingModel : .fallback,
                partial: Self.routedPartial(from: actions),
                message: "Sorting the rest of the note"
            ))
        }
        let capture = try await extractCaptureLines(
            from: dump,
            request: request,
            emit: emit,
            signposter: signposter
        )
        if let failureNote = capture.failureNote {
            fallbackReasons.append(failureNote)
        }

        var summary = RoutedActionMapper.summary(
            from: Array(actions.prefix(max(request.maxSuggestions, lines.count))),
            source: (anyModelRouted || capture.usedModel) ? .foundationModels : .deterministicFallback,
            diagnostics: GenerationDiagnostics(
                availability: availability,
                fallbackReason: fallbackReasons.isEmpty ? nil : fallbackReasons.joined(separator: " | "),
                reconcilerFindings: routed.findings.isEmpty ? nil : routed.findings
            )
        )
        summary.suggestions.append(contentsOf: capture.suggestions)
        summary.actionDrafts.append(contentsOf: capture.drafts)
        if summary.suggestions.count > 1 {
            summary.overview = "\(summary.suggestions.count) actions ready to review"
        }
        emit(.init(
            phase: .completed,
            summary: summary,
            message: anyModelRouted || capture.usedModel
                ? "Sorted \(summary.suggestions.count) actions with Foundation Models"
                : "Sorted \(summary.suggestions.count) actions with deterministic rules"
        ))
        return summary
    }

    struct RoutedLines {
        var actions: [RoutedAction] = []
        var usedModel = false
        var failureNotes: [String] = []
        var findings: [RoutedActionReconciler.Finding] = []
    }

    /// Each command line routes like a single command — model when
    /// available, reconciled against that line, deterministic router on
    /// any failure — so a line can never vanish.
    func routeLines(
        _ lines: [String],
        request: AssistantRequest,
        availability: ModelAvailability,
        emit: @escaping @Sendable (SummaryGenerationUpdate) -> Void
    ) async throws -> RoutedLines {
        var routed = RoutedLines()
        for (index, line) in lines.enumerated() {
            try Task.checkCancellation()
            emit(.init(
                phase: availability.isAvailable ? .streamingModel : .fallback,
                partial: Self.routedPartial(from: routed.actions),
                message: "Routing command \(index + 1) of \(lines.count)"
            ))

            let lineRequest = AssistantRequest(
                sourceText: line,
                localeIdentifier: request.localeIdentifier,
                maxSuggestions: request.maxSuggestions,
                inputKind: request.inputKind
            )

            var lineActions: [RoutedAction] = []
            if let model, availability.isAvailable {
                do {
                    let routingModel = model
                    if let modelActions = try await Self.boundedModelPass(
                        deadline: routingDeadline,
                        stage: "route-command",
                        operation: { try await routingModel.routeCommand(for: lineRequest) }
                    ) {
                        let outcome = RoutedActionReconciler.reconcile(modelActions, sourceText: line)
                        lineActions = outcome.actions
                        routed.findings.append(contentsOf: outcome.findings)
                        routed.usedModel = routed.usedModel || !lineActions.isEmpty
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    routed.failureNotes.append("Line \(index + 1): \(String(describing: error))")
                }
            }
            if lineActions.isEmpty {
                lineActions = [DeterministicCommandRouter().route(line)]
            }
            routed.actions.append(contentsOf: lineActions)
        }
        return routed
    }

    struct CaptureExtraction {
        var suggestions: [TaskSuggestion] = []
        var drafts: [ToolActionDraft] = []
        var usedModel = false
        var failureNote: String?
    }

    /// The lines that were not commands get one brief-extraction pass — the
    /// same engine a plain capture would hit — and their cards join the
    /// routed ones. A failure here must not sink the commands that already
    /// routed, so it degrades to a diagnostic note.
    func extractCaptureLines(
        from dump: DirectCommandDetector.PartitionedDump,
        request: AssistantRequest,
        emit: @escaping @Sendable (SummaryGenerationUpdate) -> Void,
        signposter: OSSignposter
    ) async throws -> CaptureExtraction {
        guard !dump.captureText.isEmpty else {
            return CaptureExtraction()
        }
        do {
            let captureSummary = try await singlePass(
                AssistantRequest(
                    sourceText: dump.captureText,
                    localeIdentifier: request.localeIdentifier,
                    maxSuggestions: request.maxSuggestions,
                    inputKind: request.inputKind
                ),
                emit: emit,
                publishUpdates: false,
                signposter: signposter
            )
            return CaptureExtraction(
                suggestions: captureSummary.suggestions,
                drafts: captureSummary.actionDrafts,
                usedModel: captureSummary.source == .foundationModels
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return CaptureExtraction(failureNote: "Capture lines: \(String(describing: error))")
        }
    }

    /// The accumulated cards as a streaming partial, so the progress panel
    /// renders each routed command the moment it lands.
    private static func routedPartial(from actions: [RoutedAction]) -> StructuredSummaryPartial? {
        guard !actions.isEmpty else {
            return nil
        }
        return StructuredSummaryPartial(
            suggestions: actions.map { action in
                let suggestion = RoutedActionMapper.taskSuggestion(from: action, source: .foundationModels)
                return TaskSuggestionPartial(
                    title: suggestion.title,
                    priority: suggestion.priority,
                    dueHint: suggestion.dueHint,
                    dueDate: suggestion.dueDate,
                    action: suggestion.action,
                    rationale: suggestion.rationale,
                    confidence: suggestion.confidence
                )
            },
            isComplete: false
        )
    }
}
