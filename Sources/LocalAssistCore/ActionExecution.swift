import Foundation

public enum PreparedActionState: String, Codable, Sendable {
    case readyForConfirmation
    case noActionRequired
}

public struct PreparedToolAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var draft: ToolActionDraft
    public var state: PreparedActionState
    public var confirmationTitle: String
    public var confirmationMessage: String

    public init(
        id: String,
        draft: ToolActionDraft,
        state: PreparedActionState,
        confirmationTitle: String,
        confirmationMessage: String
    ) {
        self.id = id
        self.draft = draft
        self.state = state
        self.confirmationTitle = confirmationTitle
        self.confirmationMessage = confirmationMessage
    }
}

public protocol ToolActionPreparing: Sendable {
    func prepare(_ draft: ToolActionDraft) async throws -> PreparedToolAction
}

/// Result of executing a confirmed action against a system store.
public struct ExecutedToolAction: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: Codable, Equatable, Sendable {
        /// A real system write happened (Reminders/Calendar item created).
        case executed(detail: String, systemIdentifier: String?)
        /// No system write is possible or needed; the result is informational.
        case simulated(detail: String)
        case skipped(reason: String)
    }

    public var id: String
    public var kind: SuggestedAction
    public var outcome: Outcome
    public var executedAt: Date

    public init(id: String, kind: SuggestedAction, outcome: Outcome, executedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.outcome = outcome
        self.executedAt = executedAt
    }

    public var detail: String {
        switch outcome {
        case .executed(let detail, _), .simulated(let detail):
            detail
        case .skipped(let reason):
            reason
        }
    }

    public var didWriteToSystem: Bool {
        if case .executed = outcome {
            return true
        }
        return false
    }
}

/// Executes a user-confirmed action. The system implementation writes to
/// EventKit; this package-level default only simulates so CLI runs, tests,
/// and previews never touch real stores.
public protocol ToolActionExecuting: Sendable {
    func execute(_ action: PreparedToolAction) async throws -> ExecutedToolAction
}

public struct SimulatedActionExecutor: ToolActionExecuting {
    public init() {}

    public func execute(_ action: PreparedToolAction) async throws -> ExecutedToolAction {
        try Task.checkCancellation()

        let detail: String
        switch action.draft.kind {
        case .reminder, .checklistItem:
            detail = "Simulated a Reminders entry for “\(action.draft.payload["title"] ?? action.draft.title)”."
        case .calendarHold:
            detail = "Simulated a 30-minute calendar hold for “\(action.draft.payload["title"] ?? action.draft.title)”."
        case .messageDraft:
            detail = "Prepared message draft: \(action.draft.payload["subject"] ?? action.draft.title)."
        case .none:
            return ExecutedToolAction(
                id: action.id,
                kind: .none,
                outcome: .skipped(reason: "No system action was required.")
            )
        }

        return ExecutedToolAction(
            id: action.id,
            kind: action.draft.kind,
            outcome: .simulated(detail: detail)
        )
    }
}

public struct DraftOnlyToolActionPreparer: ToolActionPreparing {
    public init() {}

    public func prepare(_ draft: ToolActionDraft) async throws -> PreparedToolAction {
        let signposter = LocalAssistInstrumentation.actionSignposter()
        let state = signposter.beginInterval("Prepare action draft")
        defer {
            signposter.endInterval("Prepare action draft", state)
        }

        try Task.checkCancellation()

        let message: String
        switch draft.kind {
        case .reminder:
            message = "A reminder is staged locally and still needs user confirmation before it writes to Reminders."
        case .calendarHold:
            message = "A calendar hold is staged locally and still needs user confirmation before it writes to Calendar."
        case .messageDraft:
            message = "A message draft is staged locally and still needs user confirmation before it opens a composer."
        case .checklistItem:
            message = "A checklist item is staged locally for review."
        case .none:
            message = "No system write is needed for this suggestion."
        }

        return PreparedToolAction(
            id: StableID.make(from: draft.kind.rawValue + draft.title + draft.payload.description),
            draft: draft,
            state: draft.requiresConfirmation ? .readyForConfirmation : .noActionRequired,
            confirmationTitle: draft.title,
            confirmationMessage: message
        )
    }
}
