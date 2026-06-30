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

public struct DraftOnlyToolActionPreparer: ToolActionPreparing {
    public init() {}

    public func prepare(_ draft: ToolActionDraft) async throws -> PreparedToolAction {
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
