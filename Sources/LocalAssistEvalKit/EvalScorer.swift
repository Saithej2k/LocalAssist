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
        latencyMilliseconds: Double
    ) -> EvalCaseResult {
        var notes: [String] = []

        // Structure: the contract the app promises downstream consumers.
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
        let structureScore = structureChecks > 0 ? structurePassed / structureChecks : 1

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
                if let dueHint = match.dueHint, dueHint.lowercased().contains(expectedDue.lowercased()) {
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
}
