import Foundation

/// Splits long input into sentence-aligned chunks so hour-long meeting notes
/// fit the on-device model's context window via map-reduce summarization.
public enum TranscriptChunker {
    /// Greedy sentence packing: each chunk stays under `targetCharacters`
    /// without splitting sentences (oversized sentences are hard-wrapped).
    public static func chunks(from text: String, targetCharacters: Int = 2800) -> [String] {
        let sentences = text
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0 + "." }

        guard !sentences.isEmpty else {
            return text.isEmpty ? [] : [text]
        }

        var chunks: [String] = []
        var current = ""

        for sentence in sentences {
            if sentence.count > targetCharacters {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                var remainder = Substring(sentence)
                while remainder.count > targetCharacters {
                    chunks.append(String(remainder.prefix(targetCharacters)))
                    remainder = remainder.dropFirst(targetCharacters)
                }
                current = String(remainder)
                continue
            }

            if current.count + sentence.count + 1 > targetCharacters, !current.isEmpty {
                chunks.append(current)
                current = sentence
            } else {
                current = current.isEmpty ? sentence : current + " " + sentence
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    /// Compact digest of per-chunk summaries used as the reduce-pass input.
    public static func digest(of parts: [StructuredSummary], maxCharacters: Int = 8000) -> String {
        var lines: [String] = []
        for (index, part) in parts.enumerated() {
            lines.append("Part \(index + 1): \(part.headline)")
            lines.append(contentsOf: part.keyPoints.map { "- \($0)" })
            lines.append(contentsOf: part.tasks.map { task in
                var line = "Task: \(task.title)"
                if let due = task.iso8601DueDate ?? task.dueHint {
                    line += " (due \(due))"
                }
                return line
            })
        }
        return String(lines.joined(separator: "\n").prefix(maxCharacters))
    }
}

public extension SummaryNormalizer {
    /// Deterministic merge of per-chunk summaries — used when no model is
    /// available for a coherent reduce pass.
    func merged(
        parts: [StructuredSummary],
        request: AssistantRequest,
        availability: ModelAvailability,
        generatedAt: Date = Date()
    ) -> StructuredSummary? {
        guard let first = parts.first else {
            return nil
        }

        let partial = StructuredSummaryPartial(
            overview: parts.count > 1
                ? "\(first.headline) (+\(parts.count - 1) more sections)"
                : first.headline,
            keyPoints: parts.flatMap(\.keyPoints),
            suggestions: parts.flatMap(\.tasks).map { task in
                TaskSuggestionPartial(
                    title: task.title,
                    priority: task.priority,
                    dueHint: task.dueHint,
                    dueDate: task.dueDate,
                    action: task.action,
                    rationale: task.rationale,
                    confidence: task.confidence
                )
            },
            isComplete: true
        )

        guard var summary = summary(
            from: partial,
            request: request,
            availability: availability,
            generatedAt: generatedAt
        ) else {
            return nil
        }
        summary.source = first.source
        summary.diagnostics = first.diagnostics
        return summary
    }
}
