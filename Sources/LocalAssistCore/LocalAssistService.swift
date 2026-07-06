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

    public init(
        model: (any StructuredModelClient)? = nil,
        fallback: DeterministicFallbackGenerator = DeterministicFallbackGenerator(),
        normalizer: SummaryNormalizer = SummaryNormalizer(),
        validator: RequestValidator = RequestValidator(),
        chunkTargetCharacters: Int = 2800
    ) {
        self.model = model
        self.fallback = fallback
        self.normalizer = normalizer
        self.validator = validator
        self.chunkTargetCharacters = chunkTargetCharacters
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
        emit: @Sendable (SummaryGenerationUpdate) -> Void
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
        emit: @Sendable (SummaryGenerationUpdate) -> Void,
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
        emit: @Sendable (SummaryGenerationUpdate) -> Void,
        publishUpdates: Bool,
        signposter: OSSignposter
    ) async throws -> StructuredSummary {
        guard let model else {
            return try await fallbackSummary(
                for: request,
                unavailability: ModelUnavailability(reason: .adapterNotConfigured),
                emit: emit,
                publishUpdates: publishUpdates,
                signposter: signposter
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
            return try await fallbackSummary(
                for: request,
                unavailability: unavailability,
                emit: emit,
                publishUpdates: publishUpdates,
                signposter: signposter
            )
        }

        do {
            let responseState = signposter.beginInterval("Model response")
            if publishUpdates {
                emit(.init(phase: .streamingModel, message: "Streaming on-device model response"))
            }

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
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as GenerationFailure {
            if case .modelUnavailable(let unavailability) = failure {
                return try await fallbackSummary(
                    for: request,
                    unavailability: unavailability,
                    emit: emit,
                    publishUpdates: publishUpdates,
                    signposter: signposter
                )
            }
            return try await fallbackSummary(
                for: request,
                availability: availability,
                fallbackReason: String(describing: failure),
                guidance: failure.userMessage,
                emit: emit,
                publishUpdates: publishUpdates,
                signposter: signposter
            )
        } catch {
            throw GenerationFailure.unknown(detail: String(describing: error))
        }
    }

    // MARK: - Fallback

    private func fallbackSummary(
        for request: AssistantRequest,
        unavailability: ModelUnavailability,
        emit: @Sendable (SummaryGenerationUpdate) -> Void,
        publishUpdates: Bool,
        signposter: OSSignposter
    ) async throws -> StructuredSummary {
        try await fallbackSummary(
            for: request,
            availability: .unavailable(unavailability),
            fallbackReason: unavailability.detail,
            guidance: unavailability.userGuidance,
            emit: emit,
            publishUpdates: publishUpdates,
            signposter: signposter
        )
    }

    private func fallbackSummary(
        for request: AssistantRequest,
        availability: ModelAvailability,
        fallbackReason: String,
        guidance: String,
        emit: @Sendable (SummaryGenerationUpdate) -> Void,
        publishUpdates: Bool,
        signposter: OSSignposter
    ) async throws -> StructuredSummary {
        if publishUpdates {
            emit(.init(phase: .fallback, message: guidance))
        }
        let fallbackState = signposter.beginInterval("Fallback generation")
        defer {
            signposter.endInterval("Fallback generation", fallbackState)
        }

        let summary = try await fallback.generate(
            for: request,
            availability: availability,
            fallbackReason: fallbackReason
        )
        if publishUpdates {
            emitFallbackPartials(for: summary, message: guidance, emit: emit)
            emit(.init(
                phase: .completed,
                summary: summary,
                message: "Completed with deterministic fallback"
            ))
        }
        return summary
    }

    private func emitFallbackPartials(
        for summary: StructuredSummary,
        message: String,
        emit: @Sendable (SummaryGenerationUpdate) -> Void
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
