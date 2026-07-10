import Foundation

/// One entry of the model session's transcript, flattened for display:
/// which role it played and a truncated, whitespace-normalized preview.
/// The Foundation Models transcript types stop at the adapter boundary —
/// the UI only ever sees this value type, same rule as the failure
/// taxonomy and the streaming partials.
public struct TranscriptEntrySnapshot: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case instructions
        case prompt
        case toolCalls
        case toolOutput
        case response

        public var displayTitle: String {
            switch self {
            case .instructions:
                "Instructions"
            case .prompt:
                "Prompt"
            case .toolCalls:
                "Tool call"
            case .toolOutput:
                "Tool output"
            case .response:
                "Response"
            }
        }
    }

    /// Position in the transcript — entries never reorder, so the index is
    /// the identity.
    public let id: Int
    public let kind: Kind
    public let text: String

    /// Normalizes runs of whitespace (transcript text carries the prompt's
    /// own line breaks) and truncates to a display budget, marking the cut
    /// with an ellipsis so a clipped entry never reads as a complete one.
    public init(id: Int, kind: Kind, rawText: String, maxCharacters: Int = 220) {
        self.id = id
        self.kind = kind
        let normalized = rawText.normalizedWhitespace()
        if normalized.count > maxCharacters {
            text = String(normalized.prefix(maxCharacters)) + "…"
        } else {
            text = normalized
        }
    }
}
