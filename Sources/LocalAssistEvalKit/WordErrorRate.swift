import Foundation

/// Word error rate against a reference transcript — the standard ASR
/// accuracy metric: (substitutions + deletions + insertions) over reference
/// words, from a word-level edit-distance alignment.
///
/// Normalization before alignment: lowercased, punctuation stripped,
/// whitespace collapsed — "Friday." and "friday" are the same word.
/// Numerals are deliberately NOT normalized: "eleven" coming back as "11"
/// is a real recognition difference the metric should surface, not paper
/// over — downstream date parsing treats those spellings differently.
/// One alignment operation from the edit-distance backtrace: which
/// reference word maps to which hypothesis word, and how. `.match` carries
/// both, `.substitution` both (different), `.deletion` only the reference
/// word, `.insertion` only the hypothesis word.
public struct WERAlignedWord: Equatable, Sendable {
    public enum Operation: String, Sendable {
        case match
        case substitution
        case deletion
        case insertion
    }

    public var operation: Operation
    public var referenceWord: String?
    public var hypothesisWord: String?

    public init(operation: Operation, referenceWord: String?, hypothesisWord: String?) {
        self.operation = operation
        self.referenceWord = referenceWord
        self.hypothesisWord = hypothesisWord
    }
}

public struct WordErrorRate: Equatable, Sendable {
    /// Kept as a member name so call sites read `WordErrorRate.AlignedWord`.
    public typealias AlignedWord = WERAlignedWord

    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceWordCount: Int
    /// The full alignment in reference order, matches included — the report
    /// can print exactly which words were substituted, dropped, or invented.
    public var alignment: [AlignedWord]

    public init(
        substitutions: Int,
        deletions: Int,
        insertions: Int,
        referenceWordCount: Int,
        alignment: [AlignedWord] = []
    ) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceWordCount = referenceWordCount
        self.alignment = alignment
    }

    public var errorCount: Int {
        substitutions + deletions + insertions
    }

    /// 0.0 is a perfect transcript; values above 1.0 are possible when the
    /// hypothesis inserts more words than the reference contains.
    public var rate: Double {
        guard referenceWordCount > 0 else {
            return errorCount == 0 ? 0 : 1
        }
        return Double(errorCount) / Double(referenceWordCount)
    }

    /// Just the error operations, for compact reports.
    public var errors: [AlignedWord] {
        alignment.filter { $0.operation != .match }
    }

    public static func measure(reference: String, hypothesis: String) -> WordErrorRate {
        let referenceWords = normalizedWords(reference)
        let hypothesisWords = normalizedWords(hypothesis)

        // Word-level Levenshtein with an operation backtrace, so the report
        // can say HOW a transcript was wrong, not just how much.
        let rows = referenceWords.count + 1
        let columns = hypothesisWords.count + 1
        var distance = [[Int]](repeating: [Int](repeating: 0, count: columns), count: rows)
        for row in 0 ..< rows {
            distance[row][0] = row
        }
        for column in 0 ..< columns {
            distance[0][column] = column
        }
        for row in 1 ..< rows {
            for column in 1 ..< columns {
                if referenceWords[row - 1] == hypothesisWords[column - 1] {
                    distance[row][column] = distance[row - 1][column - 1]
                } else {
                    distance[row][column] = 1 + min(
                        distance[row - 1][column - 1], // substitution
                        distance[row - 1][column], // deletion
                        distance[row][column - 1] // insertion
                    )
                }
            }
        }

        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var operations: [AlignedWord] = []
        var row = referenceWords.count
        var column = hypothesisWords.count
        while row > 0 || column > 0 {
            if row > 0, column > 0, referenceWords[row - 1] == hypothesisWords[column - 1] {
                operations.append(AlignedWord(
                    operation: .match,
                    referenceWord: referenceWords[row - 1],
                    hypothesisWord: hypothesisWords[column - 1]
                ))
                row -= 1
                column -= 1
            } else if row > 0, column > 0,
                      distance[row][column] == distance[row - 1][column - 1] + 1 {
                substitutions += 1
                operations.append(AlignedWord(
                    operation: .substitution,
                    referenceWord: referenceWords[row - 1],
                    hypothesisWord: hypothesisWords[column - 1]
                ))
                row -= 1
                column -= 1
            } else if row > 0, distance[row][column] == distance[row - 1][column] + 1 {
                deletions += 1
                operations.append(AlignedWord(
                    operation: .deletion,
                    referenceWord: referenceWords[row - 1],
                    hypothesisWord: nil
                ))
                row -= 1
            } else {
                insertions += 1
                operations.append(AlignedWord(
                    operation: .insertion,
                    referenceWord: nil,
                    hypothesisWord: hypothesisWords[column - 1]
                ))
                column -= 1
            }
        }

        return WordErrorRate(
            substitutions: substitutions,
            deletions: deletions,
            insertions: insertions,
            referenceWordCount: referenceWords.count,
            alignment: operations.reversed()
        )
    }

    static func normalizedWords(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }
}

/// What a text eval case sounds like when spoken: bullet markers and line
/// breaks become sentence pauses, because nobody dictates a hyphen. The
/// spoken form is both what the synthesizer reads and the reference the
/// transcript is scored against — the WER must measure recognition, not the
/// difference between written and spoken layout.
public enum SpokenForm {
    public static func render(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { line in
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                while let first = trimmed.first, "-*•".contains(first) {
                    trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                return trimmed
            }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(".") || $0.hasSuffix("!") || $0.hasSuffix("?") ? $0 : $0 + "." }
            .joined(separator: " ")
    }
}
