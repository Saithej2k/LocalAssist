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

public enum AssistantInputKind: String, Codable, Sendable, CaseIterable {
    case note
    case voiceNote
    case meeting
    case personalAdmin
}

public extension AssistantInputKind {
    /// Classifies raw capture text so the user never has to pick a kind.
    /// Deterministic cue scoring keeps the Instant path and tests stable;
    /// the Smart prompt additionally asks the model to infer the type itself.
    static func inferred(from text: String) -> AssistantInputKind {
        let lowercased = text.lowercased()

        let meetingCues = [
            "standup", "stand-up", "meeting", "sync", "agenda", "attendees",
            "action items", "decisions", "retro", "1:1", "war room",
            "minutes", "follow-ups", "postmortem", "notes:",
        ]
        let adminCues = [
            "bill", "renew", "appointment", "dentist", "doctor", "pay ",
            "insurance", "groceries", "pharmacy", "vet ", "license",
            "errand", "subscription", "utility", "rent", "landlord", "dmv",
        ]

        let meetingScore = meetingCues.filter { lowercased.contains($0) }.count
        let adminScore = adminCues.filter { lowercased.contains($0) }.count

        if meetingScore == 0, adminScore == 0 {
            return .note
        }
        return meetingScore >= adminScore ? .meeting : .personalAdmin
    }
}

/// Why the on-device model cannot serve requests right now.
///
/// Mirrors `SystemLanguageModel.Availability.UnavailableReason` so UI and
/// diagnostics can react to each state distinctly instead of pattern-matching
/// on strings.
public enum ModelUnavailabilityReason: String, Codable, Sendable, CaseIterable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case adapterNotConfigured
    case forcedOffline
    case other
}

public struct ModelUnavailability: Codable, Equatable, Sendable {
    public var reason: ModelUnavailabilityReason
    public var detail: String

    public init(reason: ModelUnavailabilityReason, detail: String? = nil) {
        self.reason = reason
        self.detail = detail ?? Self.defaultDetail(for: reason)
    }

    /// Actionable guidance the UI can surface for each unavailability state.
    public var userGuidance: String {
        switch reason {
        case .deviceNotEligible:
            "This device does not support Apple Intelligence. LocalAssist keeps working with its deterministic offline summarizer."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to use the on-device model. Until then LocalAssist uses its offline summarizer."
        case .modelNotReady:
            "The on-device model is still downloading or preparing. Try again shortly; the offline summarizer covers the gap."
        case .adapterNotConfigured:
            "No on-device model adapter is configured, so the deterministic offline summarizer is used."
        case .forcedOffline:
            "Offline fallback is forced on, so the deterministic summarizer is used."
        case .other:
            detail
        }
    }

    private static func defaultDetail(for reason: ModelUnavailabilityReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "The device is not eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is not enabled on this device."
        case .modelNotReady:
            "The on-device model assets are not ready yet."
        case .adapterNotConfigured:
            "No on-device model adapter was configured."
        case .forcedOffline:
            "Offline fallback was requested explicitly."
        case .other:
            "The on-device model is unavailable."
        }
    }

    private enum CodingKeys: String, CodingKey {
        case reason
        case detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let typed = try? container.decode(ModelUnavailabilityReason.self, forKey: .reason) {
            reason = typed
            detail = try container.decodeIfPresent(String.self, forKey: .detail)
                ?? Self.defaultDetail(for: typed)
        } else {
            // Pre-taxonomy history entries stored a free-form reason string.
            let legacy = try container.decodeIfPresent(String.self, forKey: .reason)
            reason = .other
            detail = legacy ?? Self.defaultDetail(for: .other)
        }
    }
}

public enum ModelAvailability: Equatable, Sendable {
    case available
    case unavailable(ModelUnavailability)

    /// Bridge for call sites that only have a human-readable reason.
    public static func unavailable(reason: String) -> ModelAvailability {
        .unavailable(ModelUnavailability(reason: .other, detail: reason))
    }

    public var isAvailable: Bool {
        switch self {
        case .available:
            true
        case .unavailable:
            false
        }
    }

    public var unavailability: ModelUnavailability? {
        switch self {
        case .available:
            nil
        case .unavailable(let unavailability):
            unavailability
        }
    }

    public var reason: String? {
        unavailability?.detail
    }
}

extension ModelAvailability: Codable {
    private enum CodingKeys: String, CodingKey {
        case available
        case unavailable
    }

    private struct Empty: Codable {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.available) {
            self = .available
        } else {
            self = .unavailable(try container.decode(ModelUnavailability.self, forKey: .unavailable))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available:
            try container.encode(Empty(), forKey: .available)
        case .unavailable(let unavailability):
            try container.encode(unavailability, forKey: .unavailable)
        }
    }
}

public struct AssistantRequest: Codable, Equatable, Sendable {
    public var sourceText: String
    public var localeIdentifier: String
    public var maxSuggestions: Int
    public var inputKind: AssistantInputKind
    /// Follow-up turn on an existing session: `sourceText` is an instruction
    /// ("only keep high priority") rather than a fresh note.
    public var isRefinement: Bool

    public init(
        sourceText: String,
        localeIdentifier: String = Locale.current.identifier,
        maxSuggestions: Int = 5,
        inputKind: AssistantInputKind = .note,
        isRefinement: Bool = false
    ) {
        self.sourceText = sourceText
        self.localeIdentifier = localeIdentifier
        self.maxSuggestions = maxSuggestions
        self.inputKind = inputKind
        self.isRefinement = isRefinement
    }

    private enum CodingKeys: String, CodingKey {
        case sourceText
        case localeIdentifier
        case maxSuggestions
        case inputKind
        case isRefinement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceText = try container.decode(String.self, forKey: .sourceText)
        localeIdentifier = try container.decode(String.self, forKey: .localeIdentifier)
        maxSuggestions = try container.decode(Int.self, forKey: .maxSuggestions)
        inputKind = try container.decodeIfPresent(AssistantInputKind.self, forKey: .inputKind) ?? .note
        isRefinement = try container.decodeIfPresent(Bool.self, forKey: .isRefinement) ?? false
    }
}

public struct TaskSuggestion: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var priority: TaskPriority
    public var dueHint: String?
    /// Resolved due date for the task when the source text names a concrete
    /// or relative deadline. Encoded as ISO-8601 by the app's formatters.
    public var dueDate: Date?
    public var action: SuggestedAction
    public var rationale: String
    public var confidence: Double

    public init(
        id: String,
        title: String,
        priority: TaskPriority,
        dueHint: String?,
        dueDate: Date? = nil,
        action: SuggestedAction,
        rationale: String,
        confidence: Double
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.dueHint = dueHint
        self.dueDate = dueDate
        self.action = action
        self.rationale = rationale
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case priority
        case dueHint
        case dueDate
        case action
        case rationale
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        priority = try container.decode(TaskPriority.self, forKey: .priority)
        dueHint = try container.decodeIfPresent(String.self, forKey: .dueHint)
        if let dueDateString = try container.decodeIfPresent(String.self, forKey: .dueDate) {
            dueDate = LocalAssistDates.parse(dueDateString)
        } else {
            dueDate = nil
        }
        action = try container.decode(SuggestedAction.self, forKey: .action)
        rationale = try container.decode(String.self, forKey: .rationale)
        confidence = try container.decode(Double.self, forKey: .confidence)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(priority, forKey: .priority)
        try container.encodeIfPresent(dueHint, forKey: .dueHint)
        try container.encodeIfPresent(iso8601DueDate, forKey: .dueDate)
        try container.encode(action, forKey: .action)
        try container.encode(rationale, forKey: .rationale)
        try container.encode(confidence, forKey: .confidence)
    }

}

public struct GenerationDiagnostics: Codable, Equatable, Sendable {
    public var availability: ModelAvailability
    public var fallbackReason: String?
    /// Number of tools the model invoked while producing the summary.
    public var toolInvocationCount: Int

    public init(
        availability: ModelAvailability,
        fallbackReason: String? = nil,
        toolInvocationCount: Int = 0
    ) {
        self.availability = availability
        self.fallbackReason = fallbackReason
        self.toolInvocationCount = toolInvocationCount
    }

    private enum CodingKeys: String, CodingKey {
        case availability
        case fallbackReason
        case toolInvocationCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availability = try container.decode(ModelAvailability.self, forKey: .availability)
        fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
        toolInvocationCount = try container.decodeIfPresent(Int.self, forKey: .toolInvocationCount) ?? 0
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

    private enum CodingKeys: String, CodingKey {
        case headline
        case keyPoints
        case tasks
        case actionDrafts
        case source
        case diagnostics
        case generatedAt
        case overview
        case suggestions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overview = try container.decodeIfPresent(String.self, forKey: .headline)
            ?? container.decode(String.self, forKey: .overview)
        keyPoints = try container.decode([String].self, forKey: .keyPoints)
        suggestions = try container.decodeIfPresent([TaskSuggestion].self, forKey: .tasks)
            ?? container.decode([TaskSuggestion].self, forKey: .suggestions)
        actionDrafts = try container.decode([ToolActionDraft].self, forKey: .actionDrafts)
        source = try container.decode(GenerationSource.self, forKey: .source)
        diagnostics = try container.decode(GenerationDiagnostics.self, forKey: .diagnostics)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(headline, forKey: .headline)
        try container.encode(keyPoints, forKey: .keyPoints)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(actionDrafts, forKey: .actionDrafts)
        try container.encode(source, forKey: .source)
        try container.encode(diagnostics, forKey: .diagnostics)
        try container.encode(generatedAt, forKey: .generatedAt)
    }
}

public extension StructuredSummary {
    /// Product-facing name for the one-line brief headline. Kept as an alias
    /// so older saved history with `overview` still decodes.
    var headline: String {
        get { overview }
        set { overview = newValue }
    }

    /// Product-facing task collection alias.
    var tasks: [TaskSuggestion] {
        get { suggestions }
        set { suggestions = newValue }
    }
}

public extension TaskSuggestion {
    var iso8601DueDate: String? {
        dueDate.map { LocalAssistDates.dateOnlyString(from: $0) }
    }
}
