import Foundation

public enum LocalAssistError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyInput
    case inputTooLong(actual: Int, maximum: Int)
    case invalidSuggestionLimit(Int)

    public var description: String {
        switch self {
        case .emptyInput:
            "Input text is empty."
        case .inputTooLong(let actual, let maximum):
            "Input text is too long (\(actual) characters, maximum \(maximum))."
        case .invalidSuggestionLimit(let limit):
            "Suggestion limit must be between 1 and 8, received \(limit)."
        }
    }
}

public struct RequestValidator: Sendable {
    public var maxCharacters: Int
    public var suggestionRange: ClosedRange<Int>

    public init(maxCharacters: Int = 12_000, suggestionRange: ClosedRange<Int> = 1...8) {
        self.maxCharacters = maxCharacters
        self.suggestionRange = suggestionRange
    }

    public func validate(_ request: AssistantRequest) throws -> AssistantRequest {
        let trimmedText = request.sourceText.normalizedWhitespace()

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
            maxSuggestions: request.maxSuggestions
        )
    }
}
