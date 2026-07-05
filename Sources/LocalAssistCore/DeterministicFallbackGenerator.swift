import Foundation

public struct DeterministicFallbackGenerator: Sendable {
    private let planner: ToolActionPlanner
    private let clock: GenerationClock
    private let dateParser: DueDateParser
    private let calendar: Calendar

    public init(
        planner: ToolActionPlanner = ToolActionPlanner(),
        clock: GenerationClock = .system,
        calendar: Calendar = .current
    ) {
        self.planner = planner
        self.clock = clock
        self.calendar = calendar
        dateParser = DueDateParser(calendar: calendar)
    }

    public func generate(
        for request: AssistantRequest,
        reason: String,
        generatedAt: Date? = nil
    ) async throws -> StructuredSummary {
        try await generate(
            for: request,
            unavailability: ModelUnavailability(reason: .other, detail: reason),
            generatedAt: generatedAt
        )
    }

    public func generate(
        for request: AssistantRequest,
        unavailability: ModelUnavailability,
        generatedAt: Date? = nil
    ) async throws -> StructuredSummary {
        try await generate(
            for: request,
            availability: .unavailable(unavailability),
            fallbackReason: unavailability.detail,
            generatedAt: generatedAt
        )
    }

    public func generate(
        for request: AssistantRequest,
        availability: ModelAvailability,
        fallbackReason: String,
        generatedAt: Date? = nil
    ) async throws -> StructuredSummary {
        try Task.checkCancellation()
        let referenceDate = generatedAt ?? clock.now()

        let text = request.sourceText.normalizedWhitespace()
        let clauses = TextSegments.taskClauses(in: text)
        let sentences = TextSegments.sentences(in: text)

        let overview = makeOverview(from: sentences, clauses: clauses, fallback: text)
        let keyPoints = makeKeyPoints(from: sentences, clauses: clauses, limit: 5)
        let suggestions = try await makeSuggestions(
            from: clauses,
            request: request,
            relativeTo: referenceDate
        )
        let drafts = suggestions.map(planner.draft(for:))

        return StructuredSummary(
            overview: overview,
            keyPoints: keyPoints,
            suggestions: suggestions,
            actionDrafts: drafts,
            source: .deterministicFallback,
            diagnostics: GenerationDiagnostics(
                availability: availability,
                fallbackReason: fallbackReason
            ),
            generatedAt: referenceDate
        )
    }

    private func makeOverview(from sentences: [String], clauses: [String], fallback: String) -> String {
        let candidates = sentences.isEmpty ? clauses : sentences
        let selected = scored(candidates).first?.text ?? fallback
        if selected.count <= 180 {
            return selected
        }
        return String(selected.prefix(177)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func makeKeyPoints(from sentences: [String], clauses: [String], limit: Int) -> [String] {
        let preferredSegments = clauses.count > 1 ? clauses : sentences + clauses
        let candidates = scored(preferredSegments)
            .map { $0.text.cleanedBullet().sentenceCapitalized() }
            .filter { !$0.isEmpty }

        return Array(OrderedUnique.values(candidates).prefix(limit))
    }

    private func scored(_ segments: [String]) -> [ScoredSegment] {
        segments
            .enumerated()
            .map { index, text in
                ScoredSegment(
                    text: text.cleanedBullet().sentenceCapitalized(),
                    score: TaskClassifier.salienceScore(for: text),
                    index: index
                )
            }
            .filter { !$0.text.isEmpty }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.index < rhs.index
                }
                return lhs.score > rhs.score
            }
    }

    private func makeSuggestions(
        from clauses: [String],
        request: AssistantRequest,
        relativeTo referenceDate: Date
    ) async throws -> [TaskSuggestion] {
        var suggestions: [TaskSuggestion] = []

        for clause in scored(clauses).map(\.text) {
            try Task.checkCancellation()
            guard TaskClassifier.looksActionable(clause) else {
                continue
            }

            let title = TaskClassifier.title(for: clause)
            guard !title.isEmpty else {
                continue
            }

            var dueHint = TaskClassifier.dueHint(in: clause)
            let dueDate = dateParser.date(from: dueHint ?? clause, relativeTo: referenceDate)
            if dueHint == nil, let dueDate {
                dueHint = Self.isoDate(dueDate)
            }
            let priority = TaskClassifier.priority(in: clause, dueHint: dueHint)
            let action = TaskClassifier.action(for: clause)

            suggestions.append(
                TaskSuggestion(
                    id: StableID.make(from: title + clause),
                    title: title,
                    priority: priority,
                    dueHint: dueHint,
                    dueDate: dueDate,
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

    private static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}

private struct ScoredSegment: Sendable {
    var text: String
    var score: Int
    var index: Int
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
        "add", "ask", "assign", "book", "buy", "call", "cancel", "check",
        "confirm", "create", "decide", "draft", "email", "finish", "follow",
        "invite", "order", "pay", "prepare", "renew", "reschedule", "return",
        "review", "schedule", "send", "share", "ship", "submit", "summarize",
        "update", "write"
    ]
    private static let urgencyCues = [
        "urgent", "asap", "today", "tomorrow", "tonight", "deadline",
        "blocker", "blocked", "by ", "before", "this week", "next week"
    ]

    static func salienceScore(for clause: String) -> Int {
        let lowercased = clause.lowercased()
        var score = 0
        if looksActionable(clause) {
            score += 8
        }
        for cue in urgencyCues where lowercased.contains(cue) {
            score += 4
        }
        for verb in actionVerbs where lowercased.contains(verb) {
            score += 2
        }
        if clause.count > 24 {
            score += 1
        }
        return score
    }

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
        let weekdayHints = [
            "monday", "tuesday", "wednesday", "thursday", "friday",
            "saturday", "sunday"
        ]
        let explicitHints = [
            "today", "tomorrow", "tonight", "this week", "next week",
        ] + weekdayHints

        if let hint = explicitHints.first(where: { lowercased.contains($0) }) {
            if weekdayHints.contains(hint) {
                return hint.sentenceCapitalized()
            }
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
        if lowercased.contains("add")
            || lowercased.contains("check")
            || lowercased.contains("update")
            || lowercased.contains("prepare")
            || lowercased.contains("write") {
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
