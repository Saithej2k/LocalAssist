import Foundation

public struct DeterministicFallbackGenerator: Sendable {
    private let planner: ToolActionPlanner

    public init(planner: ToolActionPlanner = ToolActionPlanner()) {
        self.planner = planner
    }

    public func generate(
        for request: AssistantRequest,
        reason: String,
        generatedAt: Date = Date()
    ) async throws -> StructuredSummary {
        try Task.checkCancellation()

        let text = request.sourceText.normalizedWhitespace()
        let clauses = TextSegments.taskClauses(in: text)
        let sentences = TextSegments.sentences(in: text)

        let overview = makeOverview(from: sentences, fallback: text)
        let keyPoints = makeKeyPoints(from: sentences, clauses: clauses, limit: 5)
        let suggestions = try await makeSuggestions(from: clauses, request: request)
        let drafts = suggestions.map(planner.draft(for:))

        return StructuredSummary(
            overview: overview,
            keyPoints: keyPoints,
            suggestions: suggestions,
            actionDrafts: drafts,
            source: .deterministicFallback,
            diagnostics: GenerationDiagnostics(
                availability: .unavailable(reason: reason),
                fallbackReason: reason,
                repairedMalformedModelOutput: false
            ),
            generatedAt: generatedAt
        )
    }

    private func makeOverview(from sentences: [String], fallback: String) -> String {
        let first = sentences.first ?? fallback
        if first.count <= 180 {
            return first
        }
        return String(first.prefix(177)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func makeKeyPoints(from sentences: [String], clauses: [String], limit: Int) -> [String] {
        let candidates = (sentences + clauses)
            .map { $0.cleanedBullet() }
            .filter { !$0.isEmpty }

        return Array(OrderedUnique.values(candidates).prefix(limit))
    }

    private func makeSuggestions(
        from clauses: [String],
        request: AssistantRequest
    ) async throws -> [TaskSuggestion] {
        var suggestions: [TaskSuggestion] = []

        for clause in clauses {
            try Task.checkCancellation()
            guard TaskClassifier.looksActionable(clause) else {
                continue
            }

            let title = TaskClassifier.title(for: clause)
            guard !title.isEmpty else {
                continue
            }

            let dueHint = TaskClassifier.dueHint(in: clause)
            let priority = TaskClassifier.priority(in: clause, dueHint: dueHint)
            let action = TaskClassifier.action(for: clause)

            suggestions.append(
                TaskSuggestion(
                    id: StableID.make(from: title + clause),
                    title: title,
                    priority: priority,
                    dueHint: dueHint,
                    action: action,
                    rationale: TaskClassifier.rationale(for: clause, action: action),
                    confidence: TaskClassifier.confidence(for: clause)
                )
            )

            if suggestions.count == request.maxSuggestions {
                break
            }
        }

        return suggestions
    }
}

private enum TextSegments {
    static func sentences(in text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.cleanedBullet() }
            .filter { !$0.isEmpty }
    }

    static func taskClauses(in text: String) -> [String] {
        var normalized = text
            .replacingOccurrences(of: "\n", with: ". ")
            .replacingOccurrences(of: ";", with: ". ")
            .replacingOccurrences(of: " and ", with: ". ", options: [.caseInsensitive])

        for marker in ["•", "-", "*"] {
            normalized = normalized.replacingOccurrences(of: marker, with: ". ")
        }

        return normalized
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .flatMap { segment in
                segment.components(separatedBy: ",")
            }
            .map { $0.cleanedBullet() }
            .filter { !$0.isEmpty }
    }
}

private enum TaskClassifier {
    private static let actionVerbs = [
        "add", "book", "call", "check", "confirm", "create", "draft", "email",
        "finish", "follow", "prepare", "review", "schedule", "send", "share",
        "ship", "summarize", "update", "write"
    ]

    static func looksActionable(_ clause: String) -> Bool {
        let lowercased = clause.lowercased()
        if actionVerbs.contains(where: { lowercased.hasPrefix($0 + " ") }) {
            return true
        }
        return actionVerbs.contains(where: { lowercased.contains(" \($0) ") })
    }

    static func title(for clause: String) -> String {
        clause
            .cleanedBullet()
            .removingLeadingTaskMarker()
            .sentenceCapitalized()
    }

    static func dueHint(in clause: String) -> String? {
        let lowercased = clause.lowercased()
        let explicitHints = [
            "today", "tomorrow", "tonight", "this week", "next week",
            "monday", "tuesday", "wednesday", "thursday", "friday",
            "saturday", "sunday"
        ]

        if let hint = explicitHints.first(where: { lowercased.contains($0) }) {
            return hint
        }

        if lowercased.contains("asap") || lowercased.contains("urgent") {
            return "as soon as possible"
        }

        return nil
    }

    static func priority(in clause: String, dueHint: String?) -> TaskPriority {
        let lowercased = clause.lowercased()
        if lowercased.contains("urgent")
            || lowercased.contains("asap")
            || lowercased.contains("blocker")
            || lowercased.contains("deadline") {
            return .high
        }

        if dueHint != nil || lowercased.contains("follow up") {
            return .medium
        }

        return .low
    }

    static func action(for clause: String) -> SuggestedAction {
        let lowercased = clause.lowercased()
        if lowercased.contains("schedule") || lowercased.contains("book") || lowercased.contains("sync") {
            return .calendarHold
        }
        if lowercased.contains("send") || lowercased.contains("email") || lowercased.contains("message") {
            return .messageDraft
        }
        if lowercased.contains("review") || lowercased.contains("finish") || lowercased.contains("follow") {
            return .reminder
        }
        if lowercased.contains("add") || lowercased.contains("check") || lowercased.contains("update") {
            return .checklistItem
        }
        return .reminder
    }

    static func rationale(for clause: String, action: SuggestedAction) -> String {
        switch action {
        case .calendarHold:
            return "The note references scheduling or coordination work."
        case .messageDraft:
            return "The note includes communication that can be drafted before sending."
        case .reminder:
            return "The note describes a follow-up task that should not be lost."
        case .checklistItem:
            return "The note can be tracked as a checklist item."
        case .none:
            return "No safe system action was inferred."
        }
    }

    static func confidence(for clause: String) -> Double {
        let lowercased = clause.lowercased()
        var score = 0.62
        if actionVerbs.contains(where: { lowercased.hasPrefix($0 + " ") }) {
            score += 0.16
        }
        if dueHint(in: clause) != nil {
            score += 0.12
        }
        if clause.count > 24 {
            score += 0.06
        }
        return min(score, 0.96)
    }
}
