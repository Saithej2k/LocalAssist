import Foundation

public struct GenerationGuide: Sendable {
    public init() {}

    public var schemaDescription: String {
        """
        {
          "overview": "Short executive summary",
          "keyPoints": ["3 to 5 concrete bullets"],
          "suggestions": [
            {
              "title": "Action-oriented title",
              "priority": "low | medium | high",
              "dueHint": "Optional natural language deadline",
              "action": "reminder | calendarHold | messageDraft | checklistItem | none",
              "rationale": "Why this task was suggested",
              "confidence": 0.0
            }
          ]
        }
        """
    }

    public func prompt(for request: AssistantRequest) -> String {
        """
        You are LocalAssist, an on-device task assistant. Return only valid JSON.
        Preserve privacy and infer only from the user's local text.

        Schema:
        \(schemaDescription)

        Rules:
        - overview must be under 180 characters.
        - keyPoints must contain concise factual statements.
        - suggestions must contain at most \(request.maxSuggestions) items.
        - confidence must be between 0 and 1.
        - prefer action values that can become safe draft actions.

        User text:
        \(request.sourceText)
        """
    }

    public func decode(
        rawResponse: String,
        request: AssistantRequest,
        availability: ModelAvailability,
        generatedAt: Date = Date()
    ) -> StructuredSummary? {
        guard let data = JSONExtractor.objectData(from: rawResponse) else {
            return nil
        }

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(GuidedPayload.self, from: data) else {
            return nil
        }

        let overview = payload.overview.cleanedBullet()
        let keyPoints = OrderedUnique.values(
            payload.keyPoints
                .map { $0.cleanedBullet() }
                .filter { !$0.isEmpty }
        )

        guard !overview.isEmpty, !keyPoints.isEmpty else {
            return nil
        }

        let suggestions = payload.suggestions
            .prefix(request.maxSuggestions)
            .compactMap(TaskSuggestion.init)

        let planner = ToolActionPlanner()
        return StructuredSummary(
            overview: overview,
            keyPoints: Array(keyPoints.prefix(5)),
            suggestions: suggestions,
            actionDrafts: suggestions.map(planner.draft(for:)),
            source: .foundationModels,
            diagnostics: GenerationDiagnostics(
                availability: availability,
                fallbackReason: nil,
                repairedMalformedModelOutput: false
            ),
            generatedAt: generatedAt
        )
    }
}

private struct GuidedPayload: Decodable {
    var overview: String
    var keyPoints: [String]
    var suggestions: [GuidedSuggestion]
}

private struct GuidedSuggestion: Decodable {
    var title: String
    var priority: String
    var dueHint: String?
    var action: String
    var rationale: String
    var confidence: Double?
}

private extension TaskSuggestion {
    init?(_ suggestion: GuidedSuggestion) {
        let title = suggestion.title.cleanedBullet()
        guard !title.isEmpty else {
            return nil
        }

        let priority = TaskPriority(rawValue: suggestion.priority.lowercased()) ?? .medium
        let action = SuggestedAction(rawValue: suggestion.action) ?? .reminder
        let dueHint = suggestion.dueHint?.cleanedBullet().withoutSchemaPlaceholder.nilIfEmpty
        let rationale = suggestion.rationale.cleanedBullet()

        self.init(
            id: StableID.make(from: title + (dueHint ?? "")),
            title: title,
            priority: priority,
            dueHint: dueHint,
            action: action,
            rationale: rationale.isEmpty ? "Suggested by the on-device model." : rationale,
            confidence: min(max(suggestion.confidence ?? 0.72, 0), 1)
        )
    }
}

private extension String {
    var withoutSchemaPlaceholder: String {
        let lowercasedValue = lowercased()
        let placeholders = [
            "optional natural language deadline",
            "optional natural language due date",
            "optional deadline",
        ]

        if placeholders.contains(lowercasedValue) {
            return ""
        }
        return self
    }
}

private enum JSONExtractor {
    static func objectData(from text: String) -> Data? {
        let characters = Array(text)
        guard let start = characters.firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var inString = false
        var isEscaped = false

        for index in start ..< characters.count {
            let character = characters[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
                continue
            }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let object = String(characters[start ... index])
                    return object.data(using: .utf8)
                }
            }
        }

        return nil
    }
}
