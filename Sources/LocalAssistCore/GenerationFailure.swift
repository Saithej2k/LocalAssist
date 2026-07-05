import Foundation

/// Typed taxonomy for on-device generation failures.
///
/// Mirrors `LanguageModelSession.GenerationError` so the rest of the app can
/// make policy decisions (fall back, retry, or surface guidance) without
/// depending on the FoundationModels framework. Only `modelUnavailable` is
/// eligible for the deterministic fallback; every other case carries a
/// user-facing message that can explain why LocalAssist switched to the
/// deterministic offline engine.
public enum GenerationFailure: Error, Equatable, Sendable {
    case modelUnavailable(ModelUnavailability)
    case guardrailViolation(detail: String)
    case refused(explanation: String)
    case contextWindowExceeded(detail: String)
    case unsupportedLanguage(detail: String)
    case decodingFailure(detail: String)
    case rateLimited(detail: String)
    case concurrentRequests(detail: String)
    case toolExecutionFailed(tool: String, detail: String)
    case unknown(detail: String)

    /// The app never dead-ends on generation failures; it switches to the
    /// deterministic local engine and records this failure as the reason.
    public var allowsDeterministicFallback: Bool {
        true
    }

    public var userMessage: String {
        switch self {
        case .modelUnavailable(let unavailability):
            unavailability.userGuidance
        case .guardrailViolation:
            "LocalAssist can't help with that content. Try rephrasing or removing sensitive material."
        case .refused:
            "The on-device model declined this request. Try rewording the note."
        case .contextWindowExceeded:
            "That note is too long for a single pass. Split it up or shorten it and try again."
        case .unsupportedLanguage:
            "The on-device model doesn't support this language yet. English input works best."
        case .decodingFailure:
            "The model response couldn't be decoded. Please try again."
        case .rateLimited:
            "The on-device model is briefly rate limited. Wait a moment and retry."
        case .concurrentRequests:
            "Another generation is still running. Wait for it to finish or cancel it first."
        case .toolExecutionFailed(let tool, _):
            "The \(tool) tool failed while grounding the summary. The result may be less specific."
        case .unknown:
            "Generation failed unexpectedly. Please try again."
        }
    }
}

extension GenerationFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .modelUnavailable(let unavailability):
            "modelUnavailable(\(unavailability.reason.rawValue)): \(unavailability.detail)"
        case .guardrailViolation(let detail):
            "guardrailViolation: \(detail)"
        case .refused(let explanation):
            "refused: \(explanation)"
        case .contextWindowExceeded(let detail):
            "contextWindowExceeded: \(detail)"
        case .unsupportedLanguage(let detail):
            "unsupportedLanguage: \(detail)"
        case .decodingFailure(let detail):
            "decodingFailure: \(detail)"
        case .rateLimited(let detail):
            "rateLimited: \(detail)"
        case .concurrentRequests(let detail):
            "concurrentRequests: \(detail)"
        case .toolExecutionFailed(let tool, let detail):
            "toolExecutionFailed(\(tool)): \(detail)"
        case .unknown(let detail):
            "unknown: \(detail)"
        }
    }
}
