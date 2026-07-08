import Foundation
import NaturalLanguage

/// Splits long input into sentence-aligned chunks so hour-long meeting notes
/// fit the on-device model's context window via map-reduce summarization.
public enum TranscriptChunker {
    /// Greedy sentence packing: each chunk stays under `targetCharacters`
    /// without splitting sentences (oversized sentences are hard-wrapped).
    ///
    /// Sentences come from `NLTokenizer` rather than a punctuation split —
    /// "Dr. Smith mentioned Q3 revenue of $3.14M." stays one sentence
    /// instead of five fragments, which is what map-reduce chunks need to
    /// carry coherent meaning between the model's turns.
    public static func chunks(from text: String, targetCharacters: Int = 2800) -> [String] {
        let sentences = detectedSentences(in: text)

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

    private static func detectedSentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        return sentences
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
