import Foundation

public enum SummaryFormatter {
    public static func plainText(_ summary: StructuredSummary) -> String {
        var lines: [String] = []
        lines.append(summary.overview)

        if !summary.keyPoints.isEmpty {
            lines.append("")
            lines.append("Key points")
            lines.append(contentsOf: summary.keyPoints.map { "- \($0)" })
        }

        if !summary.suggestions.isEmpty {
            lines.append("")
            lines.append("Suggested tasks")
            lines.append(
                contentsOf: summary.suggestions.map { suggestion in
                    let due = suggestion.iso8601DueDate
                        .map { " due \($0)" }
                        ?? suggestion.dueHint.map { " due \($0)" }
                        ?? ""
                    return "- [\(suggestion.priority.rawValue)] \(suggestion.title)\(due)"
                }
            )
        }

        if !summary.actionDrafts.isEmpty {
            lines.append("")
            lines.append("Draft actions")
            lines.append(
                contentsOf: summary.actionDrafts.map { draft in
                    "- \(draft.kind.rawValue): \(draft.title)"
                }
            )
        }

        return lines.joined(separator: "\n")
    }

    public static func jsonData(_ summary: StructuredSummary, prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if prettyPrinted {
            encoder.outputFormatting.insert(.prettyPrinted)
        }
        return try encoder.encode(summary)
    }
}
