import Foundation
import LocalAssistCore

public struct EvalCaseResult: Codable, Equatable, Sendable {
    public var caseID: String
    public var structureScore: Double
    public var taskRecall: Double
    public var dueHintAccuracy: Double
    public var actionAccuracy: Double
    public var hallucinationFree: Double
    public var composite: Double
    public var latencyMilliseconds: Double
    public var source: GenerationSource
    public var notes: [String]
}

/// Deterministic, reference-based scoring — no LLM judge, so scores are
/// reproducible run-over-run and safe to gate CI on.
public enum EvalScorer {
    public static func score(
        summary: StructuredSummary,
        against evalCase: EvalCase,
        latencyMilliseconds: Double,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> EvalCaseResult {
        var notes: [String] = []
        let structureScore = structureScore(of: summary, against: evalCase, notes: &notes)

        // Task recall + attribute accuracy against the reference tasks.
        var recalled = 0
        var dueHintChecks = 0
        var dueHintHits = 0
        var actionChecks = 0
        var actionHits = 0

        for expected in evalCase.expectedTasks {
            let match = summary.suggestions.first { suggestion in
                let title = suggestion.title.lowercased()
                return expected.keywords.allSatisfy { title.contains($0.lowercased()) }
            }

            guard let match else {
                notes.append("missed task: \(expected.keywords.joined(separator: "+"))")
                continue
            }
            recalled += 1

            if let expectedDue = expected.dueHintContains {
                dueHintChecks += 1
                if dueDateMatches(expected: expectedDue, suggestion: match, calendar: calendar, now: now) {
                    dueHintHits += 1
                } else {
                    notes.append("due hint mismatch for \(match.title): \(match.dueHint ?? "nil")")
                }
            }

            if let expectedAction = expected.action {
                actionChecks += 1
                if match.action == expectedAction {
                    actionHits += 1
                } else {
                    notes.append("action mismatch for \(match.title): \(match.action.rawValue)")
                }
            }
        }

        let taskRecall = evalCase.expectedTasks.isEmpty
            ? 1
            : Double(recalled) / Double(evalCase.expectedTasks.count)
        let dueHintAccuracy = dueHintChecks == 0 ? 1 : Double(dueHintHits) / Double(dueHintChecks)
        let actionAccuracy = actionChecks == 0 ? 1 : Double(actionHits) / Double(actionChecks)

        // Hallucination probes: forbidden phrases must not leak into output.
        let haystack = (
            [summary.overview]
                + summary.keyPoints
                + summary.suggestions.flatMap { [$0.title, $0.rationale, $0.dueHint ?? ""] }
        ).joined(separator: " ").lowercased()
        let violations = evalCase.forbiddenPhrases.filter { haystack.contains($0.lowercased()) }
        for violation in violations {
            notes.append("hallucination probe tripped: \(violation)")
        }
        let hallucinationFree = evalCase.forbiddenPhrases.isEmpty
            ? 1
            : Double(evalCase.forbiddenPhrases.count - violations.count) / Double(evalCase.forbiddenPhrases.count)

        let composite = 0.25 * structureScore
            + 0.35 * taskRecall
            + 0.15 * dueHintAccuracy
            + 0.10 * actionAccuracy
            + 0.15 * hallucinationFree

        return EvalCaseResult(
            caseID: evalCase.id,
            structureScore: structureScore,
            taskRecall: taskRecall,
            dueHintAccuracy: dueHintAccuracy,
            actionAccuracy: actionAccuracy,
            hallucinationFree: hallucinationFree,
            composite: composite,
            latencyMilliseconds: latencyMilliseconds,
            source: summary.source,
            notes: notes
        )
    }

    /// Structure: the contract the app promises downstream consumers.
    private static func structureScore(
        of summary: StructuredSummary,
        against evalCase: EvalCase,
        notes: inout [String]
    ) -> Double {
        var structureChecks = 0.0
        var structurePassed = 0.0
        func check(_ name: String, _ passed: Bool) {
            structureChecks += 1
            if passed {
                structurePassed += 1
            } else {
                notes.append("structure: \(name) failed")
            }
        }
        check("overview non-empty", !summary.overview.isEmpty)
        check("overview <= 200 chars", summary.overview.count <= 200)
        check("1-5 key points", (1 ... 5).contains(summary.keyPoints.count))
        check("suggestion cap", summary.suggestions.count <= evalCase.maxSuggestions)
        check("unique suggestion ids", Set(summary.suggestions.map(\.id)).count == summary.suggestions.count)
        check("drafts match suggestions", summary.actionDrafts.count == summary.suggestions.count)
        check(
            "confidence in range",
            summary.suggestions.allSatisfy { (0.0 ... 1.0).contains($0.confidence) }
        )
        return structureChecks > 0 ? structurePassed / structureChecks : 1
    }

    /// Due dates compare as resolved local calendar dates, not substrings:
    /// an expectation of "friday" matches a suggestion whose `dueDate` is
    /// next Friday's date or whose hint is the ISO string "2026-07-10" —
    /// both resolve to the same calendar day. Substring matching is only
    /// the fallback for expectations that don't parse to a date at all
    /// ("someday", "eventually"), where a textual echo is all there is to
    /// check.
    static func dueDateMatches(
        expected: String,
        suggestion: TaskSuggestion,
        calendar: Calendar,
        now: Date
    ) -> Bool {
        let parser = DueDateParser(calendar: calendar)
        guard let expectedDate = parser.date(from: expected, relativeTo: now) else {
            return suggestion.dueHint?.lowercased().contains(expected.lowercased()) ?? false
        }

        // The suggestion's resolved date wins; a hint that itself parses
        // (natural language or ISO) is the fallback.
        let actualDate = suggestion.dueDate
            ?? suggestion.dueHint.flatMap { parser.date(from: $0, relativeTo: now) }
        guard let actualDate else {
            // The expectation names a real day and the suggestion resolved
            // none — a textual echo of the phrase still counts, matching
            // the deterministic engine's hint-preserving behavior.
            return suggestion.dueHint?.lowercased().contains(expected.lowercased()) ?? false
        }
        return calendar.isDate(actualDate, inSameDayAs: expectedDate)
    }
}
