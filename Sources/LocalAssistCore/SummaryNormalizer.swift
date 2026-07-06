import Foundation

/// Converts a completed typed partial into the app's canonical
/// `StructuredSummary`. Guided generation guarantees the shape; this layer
/// enforces app-level semantics: trimming, deduplication, caps, stable IDs,
/// and placeholder removal.
public struct SummaryNormalizer: Sendable {
    private let planner: ToolActionPlanner

    public init(planner: ToolActionPlanner = ToolActionPlanner()) {
        self.planner = planner
    }

    public func summary(
        from partial: StructuredSummaryPartial,
        request: AssistantRequest,
        availability: ModelAvailability,
        toolInvocationCount: Int = 0,
        generatedAt: Date = Date()
    ) -> StructuredSummary? {
        let overview = (partial.overview ?? "").cleanedBullet()
        let keyPoints = OrderedUnique.values(
            partial.keyPoints
                .map { $0.cleanedBullet() }
                .filter { !$0.isEmpty }
        )

        guard !overview.isEmpty, !keyPoints.isEmpty else {
            return nil
        }

        let suggestions = partial.suggestions
            .compactMap { normalizedSuggestion(from: $0, generatedAt: generatedAt) }
            .prefix(request.maxSuggestions)

        return StructuredSummary(
            overview: String(overview.prefix(200)),
            keyPoints: Array(keyPoints.prefix(5)),
            suggestions: Array(suggestions),
            actionDrafts: suggestions.map(planner.draft(for:)),
            source: .foundationModels,
            diagnostics: GenerationDiagnostics(
                availability: availability,
                fallbackReason: nil,
                toolInvocationCount: toolInvocationCount
            ),
            generatedAt: generatedAt
        )
    }

    private func normalizedSuggestion(from partial: TaskSuggestionPartial, generatedAt: Date) -> TaskSuggestion? {
        let title = (partial.title ?? "").cleanedBullet()
        guard !title.isEmpty else {
            return nil
        }

        let dueHint = partial.dueHint?
            .cleanedBullet()
            .withoutSchemaPlaceholder
            .nilIfEmpty
        // The on-device model's calendar arithmetic is unreliable — "by
        // Wednesday" sometimes lands on a Tuesday. When the task title
        // itself names a relative day, the deterministic parser wins;
        // the model's date only stands when the title carries no signal.
        let titleResolvedDate = Self.dateParser.date(from: title, relativeTo: generatedAt)
        let parsedDueDate = titleResolvedDate
            ?? partial.dueDate
            ?? dueHint.flatMap { LocalAssistDates.parse($0) }
        let dueDate = parsedDueDate.flatMap {
            Self.isStale($0, relativeTo: generatedAt) ? nil : $0
        }
        let displayDueHint = dueDate == nil && dueHint.flatMap({ LocalAssistDates.parse($0) }) != nil ? nil : dueHint
        let rationale = (partial.rationale ?? "").cleanedBullet()
        let action = partial.action ?? Self.inferAction(from: title)

        return TaskSuggestion(
            id: StableID.make(from: title + (displayDueHint ?? "") + (dueDate.map { LocalAssistDates.dateOnlyString(from: $0) } ?? "")),
            title: title,
            priority: partial.priority ?? .medium,
            dueHint: displayDueHint,
            dueDate: dueDate,
            action: action,
            rationale: rationale.isEmpty ? "Suggested by the on-device model." : rationale,
            confidence: min(max(partial.confidence ?? 0.72, 0), 1)
        )
    }

    private static let dateParser = DueDateParser()

    private static func isStale(_ date: Date, relativeTo generatedAt: Date) -> Bool {
        Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: generatedAt)
    }

    /// Mirrors the rules engine's verb routing so both paths agree on what
    /// a title means. "text " keeps its trailing space so words like
    /// "context" don't become message drafts.
    private static func inferAction(from title: String) -> SuggestedAction {
        let lowercased = title.lowercased()
        let calendarCues = ["schedule", "book", "sync"]
        if calendarCues.contains(where: lowercased.contains) {
            return .calendarHold
        }
        let messageCues = ["send", "email", "message", "share", "text "]
        if messageCues.contains(where: lowercased.contains) {
            return .messageDraft
        }
        // Call/pick up/pay outrank checklist cues: "Call the pharmacy to
        // check on refills" is a reminder, not a checklist item.
        let reminderCues = ["call", "pick up", "pay"]
        if reminderCues.contains(where: lowercased.contains) {
            return .reminder
        }
        let checklistCues = ["add", "check", "update"]
        if checklistCues.contains(where: lowercased.contains) {
            return .checklistItem
        }
        return .reminder
    }
}

extension String {
    var withoutSchemaPlaceholder: String {
        let lowercasedValue = lowercased()
        let placeholders = [
            "optional natural language deadline",
            "optional natural language due date",
            "optional deadline",
            "none",
            "n/a",
        ]

        if placeholders.contains(lowercasedValue) {
            return ""
        }
        return self
    }
}
