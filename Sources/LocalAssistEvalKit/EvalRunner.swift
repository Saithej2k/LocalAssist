import Foundation
import LocalAssistCore

public struct EvalReport: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var completedAt: Date
    public var configurationLabel: String
    public var caseResults: [EvalCaseResult]
    public var meanComposite: Double
    public var minComposite: Double
    public var meanLatencyMilliseconds: Double

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func renderedMarkdown() -> String {
        var lines: [String] = [
            "# LocalAssist Eval Report",
            "",
            "- Configuration: \(configurationLabel)",
            "- Completed: \(ISO8601DateFormatter().string(from: completedAt))",
            "- Mean composite score: \(meanComposite.scoreString)",
            "- Minimum case score: \(minComposite.scoreString)",
            "- Mean latency: \(meanLatencyMilliseconds.formatted2) ms",
            "",
            "| Case | Composite | Recall | Due hints | Actions | Structure | Halluc.-free | Latency (ms) | Source |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]

        for result in caseResults {
            lines.append(
                "| \(result.caseID) | \(result.composite.scoreString) | \(result.taskRecall.scoreString) "
                    + "| \(result.dueHintAccuracy.scoreString) | \(result.actionAccuracy.scoreString) "
                    + "| \(result.structureScore.scoreString) | \(result.hallucinationFree.scoreString) "
                    + "| \(result.latencyMilliseconds.formatted2) | \(result.source.rawValue) |"
            )
        }

        let allNotes = caseResults.flatMap { result in
            result.notes.map { "- \(result.caseID): \($0)" }
        }
        if !allNotes.isEmpty {
            lines.append("")
            lines.append("## Notes")
            lines.append(contentsOf: allNotes)
        }

        return lines.joined(separator: "\n") + "\n"
    }
}

public enum EvalRunner {
    /// Runs every case through the service and scores the results.
    public static func run(
        cases: [EvalCase] = EvalDataset.standard,
        service: LocalAssistService,
        configurationLabel: String
    ) async throws -> EvalReport {
        let startedAt = Date()
        var results: [EvalCaseResult] = []

        for evalCase in cases {
            let clock = ContinuousClock.now
            let summary = try await service.summarize(
                AssistantRequest(sourceText: evalCase.input, maxSuggestions: evalCase.maxSuggestions)
            )
            let elapsed = clock.duration(to: ContinuousClock.now)
            let latency = Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

            results.append(EvalScorer.score(
                summary: summary,
                against: evalCase,
                latencyMilliseconds: latency
            ))
        }

        let composites = results.map(\.composite)
        return EvalReport(
            startedAt: startedAt,
            completedAt: Date(),
            configurationLabel: configurationLabel,
            caseResults: results,
            meanComposite: composites.reduce(0, +) / Double(max(composites.count, 1)),
            minComposite: composites.min() ?? 0,
            meanLatencyMilliseconds: results.map(\.latencyMilliseconds).reduce(0, +)
                / Double(max(results.count, 1))
        )
    }
}

public extension Double {
    var scoreString: String {
        String(format: "%.2f", self)
    }

    var formatted2: String {
        String(format: "%.2f", self)
    }
}
