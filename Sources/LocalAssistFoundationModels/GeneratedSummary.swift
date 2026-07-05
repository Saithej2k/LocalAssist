import Foundation
import FoundationModels
import LocalAssistCore

// Guided-generation contract. Constrained decoding guarantees the model can
// only emit values that satisfy these types and guides, so there is no
// malformed-JSON repair path anywhere in the app.
//
// Property order is deliberate: `headline` first so streaming UI can render
// immediately, key points next, and task rows last.

@Generable(description: "A structured, privacy-preserving daily brief from the user's local notes.")
struct DailyBrief: Sendable {
    @Guide(description: "One-line headline for the brief, under 180 characters.")
    var headline: String

    @Guide(description: "Concise, concrete key points taken only from the note.", .count(3...5))
    var keyPoints: [String]

    @Guide(description: "Prioritized follow-up tasks found in the note.", .maximumCount(5))
    var tasks: [BriefTaskSuggestion]
}

@Generable(description: "One actionable follow-up task extracted from the note.")
struct BriefTaskSuggestion: Sendable {
    @Guide(description: "Short action-oriented task title starting with a verb.")
    var title: String

    @Guide(description: "How urgent the task is.")
    var priority: BriefTaskPriority

    @Guide(description: "ISO-8601 calendar date for the task deadline, such as 2026-07-03. Use nil when no deadline is in the note.")
    var dueDate: String?
}

@Generable(description: "Task urgency.")
enum BriefTaskPriority: Sendable {
    case low
    case medium
    case high
}

// MARK: - Mapping into engine-agnostic core snapshots

extension BriefTaskPriority {
    var corePriority: LocalAssistCore.TaskPriority {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}

extension DailyBrief.PartiallyGenerated {
    var corePartial: StructuredSummaryPartial {
        StructuredSummaryPartial(
            overview: headline,
            keyPoints: keyPoints ?? [],
            suggestions: (tasks ?? []).map(\.corePartial),
            isComplete: false
        )
    }
}

extension BriefTaskSuggestion.PartiallyGenerated {
    var corePartial: TaskSuggestionPartial {
        let cleanedDueDate = dueDate?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskSuggestionPartial(
            title: title,
            priority: priority?.corePriority,
            dueHint: cleanedDueDate?.isEmpty == false ? cleanedDueDate : nil,
            dueDate: cleanedDueDate.flatMap(Self.isoDate),
            action: nil,
            rationale: nil,
            confidence: nil
        )
    }

    private static func isoDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: value)
    }
}

extension DailyBrief {
    var corePartial: StructuredSummaryPartial {
        StructuredSummaryPartial(
            overview: headline,
            keyPoints: keyPoints,
            suggestions: tasks.map { suggestion in
                let cleanedDueDate = suggestion.dueDate?.trimmingCharacters(in: .whitespacesAndNewlines)
                return TaskSuggestionPartial(
                    title: suggestion.title,
                    priority: suggestion.priority.corePriority,
                    dueHint: cleanedDueDate?.isEmpty == false ? cleanedDueDate : nil,
                    dueDate: cleanedDueDate.flatMap(Self.isoDate),
                    action: nil,
                    rationale: nil,
                    confidence: nil
                )
            },
            isComplete: true
        )
    }

    private static func isoDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: value)
    }
}
