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
        let validated = try validator.validate(request)
        try Task.checkCancellation()

        guard let primaryModel else {
            return try await fallback.generate(
                for: validated,
                reason: "No on-device model adapter was configured."
            )
        }

        let availability = await primaryModel.availability()
        try Task.checkCancellation()

        guard availability.isAvailable else {
            return try await fallback.generate(
                for: validated,
                reason: availability.reason ?? "The on-device model is unavailable."
            )
        }

        let prompt = guide.prompt(for: validated)

        do {
            let rawResponse = try await primaryModel.generateResponse(for: prompt)
            try Task.checkCancellation()

            if let summary = guide.decode(
                rawResponse: rawResponse,
                request: validated,
                availability: availability
            ) {
                return summary
            }

            return try await fallback.generate(
                for: validated,
                reason: "The on-device model returned malformed guided JSON."
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
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
