import Foundation

public protocol LanguageModelClient: Sendable {
    func availability() async -> ModelAvailability
    func generateResponse(for prompt: String) async throws -> String
    func streamResponse(for prompt: String) -> AsyncThrowingStream<PartialGeneration, Error>
}

public extension LanguageModelClient {
    func streamResponse(for prompt: String) -> AsyncThrowingStream<PartialGeneration, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await generateResponse(for: prompt)
                    try Task.checkCancellation()
                    continuation.yield(PartialGeneration(text: response, isComplete: true))
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
}

public struct LocalAssistService: Sendable {
    private let primaryModel: (any LanguageModelClient)?
    private let fallback: DeterministicFallbackGenerator
    private let guide: GenerationGuide
    private let validator: RequestValidator

    public init(
        primaryModel: (any LanguageModelClient)? = nil,
        fallback: DeterministicFallbackGenerator = DeterministicFallbackGenerator(),
        guide: GenerationGuide = GenerationGuide(),
        validator: RequestValidator = RequestValidator()
    ) {
        self.primaryModel = primaryModel
        self.fallback = fallback
        self.guide = guide
        self.validator = validator
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

        guard let primaryModel else {
            emit(.init(phase: .fallback, message: "No on-device model adapter was configured"))
            let fallbackState = signposter.beginInterval("Fallback generation")
            defer {
                signposter.endInterval("Fallback generation", fallbackState)
            }
            let summary = try await fallback.generate(
                for: validated,
                reason: "No on-device model adapter was configured."
            )
            emit(.init(phase: .completed, summary: summary, message: "Completed with deterministic fallback"))
            return summary
        }

        emit(.init(phase: .checkingAvailability, message: "Checking Foundation Models availability"))
        let availabilityState = signposter.beginInterval("Model availability")
        let availability = await primaryModel.availability()
        signposter.endInterval("Model availability", availabilityState)
        try Task.checkCancellation()

        guard availability.isAvailable else {
            emit(.init(phase: .fallback, message: availability.reason ?? "The on-device model is unavailable"))
            let fallbackState = signposter.beginInterval("Fallback generation")
            defer {
                signposter.endInterval("Fallback generation", fallbackState)
            }
            let summary = try await fallback.generate(
                for: validated,
                reason: availability.reason ?? "The on-device model is unavailable."
            )
            emit(.init(phase: .completed, summary: summary, message: "Completed with deterministic fallback"))
            return summary
        }

        emit(.init(phase: .buildingPrompt, message: "Building guided JSON prompt"))
        let promptState = signposter.beginInterval("Build guided prompt")
        let prompt = guide.prompt(for: validated)
        signposter.endInterval("Build guided prompt", promptState)

        do {
            let rawResponse: String
            do {
                let responseState = signposter.beginInterval("Model response")
                defer {
                    signposter.endInterval("Model response", responseState)
                }
                emit(.init(phase: .streamingModel, message: "Streaming on-device model response"))
                rawResponse = try await collectStreamingResponse(
                    prompt: prompt,
                    model: primaryModel,
                    emit: emit
                )
            }
            try Task.checkCancellation()

            emit(.init(phase: .decoding, partialText: rawResponse, message: "Validating guided JSON"))
            let decodeState = signposter.beginInterval("Decode guided JSON")
            let decodedSummary = guide.decode(
                rawResponse: rawResponse,
                request: validated,
                availability: availability
            )
            signposter.endInterval("Decode guided JSON", decodeState)

            if let summary = decodedSummary {
                emit(.init(phase: .completed, partialText: rawResponse, summary: summary, message: "Completed with Foundation Models"))
                return summary
            }

            emit(.init(phase: .fallback, partialText: rawResponse, message: "Malformed guided JSON; using deterministic fallback"))
            let fallbackState = signposter.beginInterval("Fallback generation")
            defer {
                signposter.endInterval("Fallback generation", fallbackState)
            }
            let summary = try await fallback.generate(
                for: validated,
                reason: "The on-device model returned malformed guided JSON."
            )
            emit(.init(phase: .completed, summary: summary, message: "Completed with deterministic fallback"))
            return summary
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            emit(.init(phase: .fallback, message: "Model failed; using deterministic fallback"))
            let fallbackState = signposter.beginInterval("Fallback generation")
            defer {
                signposter.endInterval("Fallback generation", fallbackState)
            }
            let summary = try await fallback.generate(
                for: validated,
                reason: "The on-device model failed: \(error.localizedDescription)"
            )
            emit(.init(phase: .completed, summary: summary, message: "Completed with deterministic fallback"))
            return summary
        }
    }

    private func collectStreamingResponse(
        prompt: String,
        model: any LanguageModelClient,
        emit: @Sendable (SummaryGenerationUpdate) -> Void
    ) async throws -> String {
        var rawResponse = ""

        for try await partial in model.streamResponse(for: prompt) {
            try Task.checkCancellation()
            rawResponse = partial.text
            emit(.init(
                phase: .streamingModel,
                partialText: rawResponse,
                message: partial.isComplete ? "Model response complete" : "Streaming on-device model response"
            ))
        }

        try Task.checkCancellation()
        return rawResponse
    }
}

public struct StaticLanguageModelClient: LanguageModelClient {
    private let state: ModelAvailability
    private let response: String
    private let delayNanoseconds: UInt64
    private let streamChunks: [String]?
    private let chunkDelayNanoseconds: UInt64

    public init(
        state: ModelAvailability = .available,
        response: String,
        delayNanoseconds: UInt64 = 0,
        streamChunks: [String]? = nil,
        chunkDelayNanoseconds: UInt64 = 0
    ) {
        self.state = state
        self.response = response
        self.delayNanoseconds = delayNanoseconds
        self.streamChunks = streamChunks
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }

    public func availability() async -> ModelAvailability {
        state
    }

    public func generateResponse(for _: String) async throws -> String {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        try Task.checkCancellation()
        return response
    }

    public func streamResponse(for _: String) -> AsyncThrowingStream<PartialGeneration, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if delayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: delayNanoseconds)
                    }

                    let chunks = streamChunks ?? [response]
                    for (index, chunk) in chunks.enumerated() {
                        if chunkDelayNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: chunkDelayNanoseconds)
                        }
                        try Task.checkCancellation()
                        continuation.yield(PartialGeneration(
                            text: chunk,
                            isComplete: index == chunks.count - 1
                        ))
                    }

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
}
