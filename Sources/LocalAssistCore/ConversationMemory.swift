import Foundation

/// One completed model exchange, compressed to what future turns need.
public struct ConversationExchange: Codable, Equatable, Sendable {
    public var inputExcerpt: String
    public var overview: String
    public var taskTitles: [String]
    public var generatedAt: Date

    public init(inputExcerpt: String, overview: String, taskTitles: [String], generatedAt: Date = Date()) {
        self.inputExcerpt = inputExcerpt
        self.overview = overview
        self.taskTitles = taskTitles
        self.generatedAt = generatedAt
    }
}

/// Rolling-window transcript compression for multi-turn sessions.
///
/// A `LanguageModelSession` transcript grows with every turn and eventually
/// throws `exceededContextWindowSize`. Instead of dropping context entirely,
/// the adapter records a compressed exchange per turn here and, when a session
/// must be rebuilt, seeds the new session's instructions with
/// `condensedContext()` — the rolling-window + summarization strategy from
/// Apple's foundation-models-utilities patterns.
public struct ConversationMemory: Equatable, Sendable {
    public private(set) var exchanges: [ConversationExchange]
    public let maxExchanges: Int

    /// Rough character budget for prompt-side context (~4 chars per token).
    public let condensedCharacterBudget: Int

    public init(maxExchanges: Int = 6, condensedCharacterBudget: Int = 1200) {
        exchanges = []
        self.maxExchanges = maxExchanges
        self.condensedCharacterBudget = condensedCharacterBudget
    }

    public mutating func record(request: AssistantRequest, summary: StructuredSummary) {
        let exchange = ConversationExchange(
            inputExcerpt: String(request.sourceText.prefix(120)),
            overview: summary.overview,
            taskTitles: summary.suggestions.map(\.title),
            generatedAt: summary.generatedAt
        )
        exchanges.append(exchange)
        if exchanges.count > maxExchanges {
            exchanges.removeFirst(exchanges.count - maxExchanges)
        }
    }

    public mutating func clear() {
        exchanges.removeAll()
    }

    /// A compact, oldest-first digest of prior turns for session rebuilds.
    /// Returns nil when there is no history worth carrying forward.
    public func condensedContext() -> String? {
        guard !exchanges.isEmpty else {
            return nil
        }

        var lines: [String] = ["Earlier in this conversation the user processed these notes:"]
        var budget = condensedCharacterBudget

        // Most recent exchanges matter most; walk backwards until the budget
        // is spent, then restore chronological order.
        var kept: [String] = []
        for exchange in exchanges.reversed() {
            var line = "- \(exchange.overview)"
            if !exchange.taskTitles.isEmpty {
                line += " Tasks: \(exchange.taskTitles.joined(separator: "; "))."
            }
            guard budget - line.count > 0 else {
                break
            }
            budget -= line.count
            kept.append(line)
        }

        lines.append(contentsOf: kept.reversed())
        return lines.joined(separator: "\n")
    }

    /// Approximate prompt-token estimate for overflow forecasting.
    public static func estimatedTokenCount(for text: String) -> Int {
        max(1, text.count / 4)
    }
}
