import Foundation

public struct PartialGeneration: Equatable, Sendable {
    public var text: String
    public var isComplete: Bool

    public init(text: String, isComplete: Bool = false) {
        self.text = text
        self.isComplete = isComplete
    }
}

public enum SummaryGenerationPhase: String, Codable, Equatable, Sendable {
    case validating
    case checkingAvailability
    case fallback
    case buildingPrompt
    case streamingModel
    case decoding
    case completed
}

public struct SummaryGenerationUpdate: Equatable, Sendable {
    public var phase: SummaryGenerationPhase
    public var partialText: String
    public var summary: StructuredSummary?
    public var message: String?

    public init(
        phase: SummaryGenerationPhase,
        partialText: String = "",
        summary: StructuredSummary? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.partialText = partialText
        self.summary = summary
        self.message = message
    }
}
