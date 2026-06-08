import Foundation

public enum TaskPriority: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

public enum GenerationSource: String, Codable, Sendable {
    case foundationModels
    case deterministicFallback
}

public enum ModelAvailability: Codable, Equatable, Sendable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        switch self {
        case .available:
            true
        case .unavailable:
            false
        }
    }

    public var reason: String? {
        switch self {
        case .available:
            nil
        case .unavailable(let reason):
            reason
        }
    }
}

public struct AssistantRequest: Codable, Equatable, Sendable {
    public var sourceText: String
    public var localeIdentifier: String
    public var maxSuggestions: Int

    public init(
        sourceText: String,
        localeIdentifier: String = Locale.current.identifier,
        maxSuggestions: Int = 5
    ) {
        self.sourceText = sourceText
        self.localeIdentifier = localeIdentifier
        self.maxSuggestions = maxSuggestions
    }
}

public struct TaskSuggestion: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var priority: TaskPriority
    public var dueHint: String?
    public var action: SuggestedAction
    public var rationale: String
    public var confidence: Double

    public init(
        id: String,
        title: String,
        priority: TaskPriority,
        dueHint: String?,
        action: SuggestedAction,
        rationale: String,
        confidence: Double
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.dueHint = dueHint
        self.action = action
        self.rationale = rationale
        self.confidence = confidence
    }
}

public struct GenerationDiagnostics: Codable, Equatable, Sendable {
    public var availability: ModelAvailability
    public var fallbackReason: String?
    public var repairedMalformedModelOutput: Bool

    public init(
        availability: ModelAvailability,
        fallbackReason: String?,
        repairedMalformedModelOutput: Bool
    ) {
        self.availability = availability
        self.fallbackReason = fallbackReason
        self.repairedMalformedModelOutput = repairedMalformedModelOutput
    }
}

public struct StructuredSummary: Codable, Equatable, Sendable {
    public var overview: String
    public var keyPoints: [String]
    public var suggestions: [TaskSuggestion]
    public var actionDrafts: [ToolActionDraft]
    public var source: GenerationSource
    public var diagnostics: GenerationDiagnostics
    public var generatedAt: Date

    public init(
        overview: String,
        keyPoints: [String],
        suggestions: [TaskSuggestion],
        actionDrafts: [ToolActionDraft],
        source: GenerationSource,
        diagnostics: GenerationDiagnostics,
        generatedAt: Date = Date()
    ) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.suggestions = suggestions
        self.actionDrafts = actionDrafts
        self.source = source
        self.diagnostics = diagnostics
        self.generatedAt = generatedAt
    }
}
