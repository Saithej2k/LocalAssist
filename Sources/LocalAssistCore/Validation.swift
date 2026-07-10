import Foundation

public enum LocalAssistError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyInput
    case inputTooLong(actual: Int, maximum: Int)
    case invalidSuggestionLimit(Int)
    case generationDidNotFinish

    public var description: String {
        switch self {
        case .emptyInput:
            "Input text is empty."
        case let .inputTooLong(actual, maximum):
            "Input text is too long (\(actual) characters, maximum \(maximum))."
        case let .invalidSuggestionLimit(limit):
            "Suggestion limit must be between 1 and 8, received \(limit)."
        case .generationDidNotFinish:
            "Generation ended without a validated summary."
        }
    }
}

public struct RequestValidator: Sendable {
    public var maxCharacters: Int
    public var suggestionRange: ClosedRange<Int>

    public init(maxCharacters: Int = 12000, suggestionRange: ClosedRange<Int> = 1 ... 8) {
        self.maxCharacters = maxCharacters
        self.suggestionRange = suggestionRange
    }

    public func validate(_ request: AssistantRequest) throws -> AssistantRequest {
        // Whitespace collapses within lines, never across them: line breaks
        // are meaning. A dump of one command per line reached the router as
        // a single mushed line because this used to run
        // `normalizedWhitespace()` over the whole text — the batch detector
        // never saw the lines that were plainly there.
        let trimmedText = request.sourceText
            .components(separatedBy: .newlines)
            .map { $0.normalizedWhitespace() }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else {
            throw LocalAssistError.emptyInput
        }

        guard trimmedText.count <= maxCharacters else {
            throw LocalAssistError.inputTooLong(actual: trimmedText.count, maximum: maxCharacters)
        }

        guard suggestionRange.contains(request.maxSuggestions) else {
            throw LocalAssistError.invalidSuggestionLimit(request.maxSuggestions)
        }

        return AssistantRequest(
            sourceText: trimmedText,
            localeIdentifier: request.localeIdentifier,
            maxSuggestions: request.maxSuggestions,
            inputKind: request.inputKind,
            isRefinement: request.isRefinement
        )
    }
}
