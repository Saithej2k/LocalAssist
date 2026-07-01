import Foundation

public protocol LanguageModelClient: Sendable {
    func availability() async -> ModelAvailability
    func generateResponse(for prompt: String) async throws -> String
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
        let signposter = LocalAssistInstrumentation.generationSignposter()
        let summarizeState = signposter.beginInterval("Summarize")
        defer {
            signposter.endInterval("Summarize", summarizeState)
        }

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
            let fallbackState = signposter.beginInterval("Fallback generation")
            defer {
                signposter.endInterval("Fallback generation", fallbackState)
            }
            return try await fallback.generate(
                for: validated,
                reason: "No on-device model adapter was configured."
            )
        }

        let availabilityState = signposter.beginInterval("Model availability")
        let availability = await primaryModel.availability()
        signposter.endInterval("Model availability", availabilityState)
        try Task.checkCancellation()

        guard availability.isAvailable else {
            let fallbackState = signposter.beginInterval("Fallback generation")
            defer {
                signposter.endInterval("Fallback generation", fallbackState)
            }
            return try await fallback.generate(
                for: validated,
                reason: availability.reason ?? "The on-device model is unavailable."
            )
        }

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
                rawResponse = try await primaryModel.generateResponse(for: prompt)
            }
            try Task.checkCancellation()

            let decodeState = signposter.beginInterval("Decode guided JSON")
            let decodedSummary = guide.decode(
                rawResponse: rawResponse,
                request: validated,
                availability: availability
            )
            signposter.endInterval("Decode guided JSON", decodeState)

            if let summary = decodedSummary {
                return summary
            }

            let fallbackState = signposter.beginInterval("Fallback generation")
            defer {
                signposter.endInterval("Fallback generation", fallbackState)
            }
            return try await fallback.generate(
                for: validated,
                reason: "The on-device model returned malformed guided JSON."
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fallbackState = signposter.beginInterval("Fallback generation")
            defer {
                signposter.endInterval("Fallback generation", fallbackState)
            }
            return try await fallback.generate(
                for: validated,
                reason: "The on-device model failed: \(error.localizedDescription)"
            )
        }
    }
}

public struct StaticLanguageModelClient: LanguageModelClient {
    private let state: ModelAvailability
    private let response: String
    private let delayNanoseconds: UInt64

    public init(
        state: ModelAvailability = .available,
        response: String,
        delayNanoseconds: UInt64 = 0
    ) {
        self.state = state
        self.response = response
        self.delayNanoseconds = delayNanoseconds
    }

    public func availability() async -> ModelAvailability {
        state
    }

    public func generateResponse(for prompt: String) async throws -> String {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        try Task.checkCancellation()
        return response
    }
}
