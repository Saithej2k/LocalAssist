import Foundation

/// A partially generated task suggestion, mirroring the shape of a
/// `PartiallyGenerated` snapshot from guided generation. Fields become
/// non-nil in declaration order as the model streams.
public struct TaskSuggestionPartial: Equatable, Sendable {
    public var title: String?
    public var priority: TaskPriority?
    public var dueHint: String?
    public var dueDate: Date?
    public var action: SuggestedAction?
    public var rationale: String?
    public var confidence: Double?

    public init(
        title: String? = nil,
        priority: TaskPriority? = nil,
        dueHint: String? = nil,
        dueDate: Date? = nil,
        action: SuggestedAction? = nil,
        rationale: String? = nil,
        confidence: Double? = nil
    ) {
        self.title = title
        self.priority = priority
        self.dueHint = dueHint
        self.dueDate = dueDate
        self.action = action
        self.rationale = rationale
        self.confidence = confidence
    }
}

/// Typed streaming snapshot of a structured summary. The UI can render the
/// overview the moment it arrives instead of waiting for the whole payload.
public struct StructuredSummaryPartial: Equatable, Sendable {
    public var overview: String?
    public var keyPoints: [String]
    public var suggestions: [TaskSuggestionPartial]
    public var isComplete: Bool

    public init(
        overview: String? = nil,
        keyPoints: [String] = [],
        suggestions: [TaskSuggestionPartial] = [],
        isComplete: Bool = false
    ) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.suggestions = suggestions
        self.isComplete = isComplete
    }

    /// Plain-text rendering for logs and accessibility while streaming.
    public var renderedText: String {
        var lines: [String] = []
        if let overview, !overview.isEmpty {
            lines.append(overview)
        }
        for point in keyPoints where !point.isEmpty {
            lines.append("• \(point)")
        }
        for suggestion in suggestions {
            guard let title = suggestion.title, !title.isEmpty else {
                continue
            }
            var line = "→ \(title)"
            if let dueHint = suggestion.dueHint, !dueHint.isEmpty {
                line += " (\(dueHint))"
            } else if let dueDate = suggestion.dueDate {
                line += " (\(ISO8601DateFormatter().string(from: dueDate)))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

public enum SummaryGenerationPhase: String, Codable, Equatable, Sendable {
    case validating
    case checkingAvailability
    case fallback
    case streamingModel
    case normalizing
    case completed
}

public struct SummaryGenerationUpdate: Equatable, Sendable {
    public var phase: SummaryGenerationPhase
    public var partial: StructuredSummaryPartial?
    public var summary: StructuredSummary?
    public var message: String?

    public init(
        phase: SummaryGenerationPhase,
        partial: StructuredSummaryPartial? = nil,
        summary: StructuredSummary? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.partial = partial
        self.summary = summary
        self.message = message
    }
}
