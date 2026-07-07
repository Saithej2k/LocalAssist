import Foundation

public enum SuggestedAction: String, Codable, Sendable, CaseIterable {
    case reminder
    case calendarHold
    case messageDraft
    case checklistItem
    case none
}

public struct ToolActionDraft: Codable, Equatable, Sendable {
    public var kind: SuggestedAction
    public var title: String
    public var payload: [String: String]
    public var requiresConfirmation: Bool

    public init(
        kind: SuggestedAction,
        title: String,
        payload: [String: String],
        requiresConfirmation: Bool = true
    ) {
        self.kind = kind
        self.title = title
        self.payload = payload
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct ToolActionPlanner: Sendable {
    public init() {}

    public func draft(for suggestion: TaskSuggestion) -> ToolActionDraft {
        switch suggestion.action {
        case .reminder:
            var payload = [
                "title": suggestion.title,
                "notes": suggestion.rationale
            ]
            if let dueHint = suggestion.dueHint {
                payload["dueHint"] = dueHint
            }
            if let dueDate = suggestion.iso8601DueDate {
                payload["dueDate"] = dueDate
            }
            return ToolActionDraft(
                kind: .reminder,
                title: "Create reminder",
                payload: payload
            )

        case .calendarHold:
            var payload = [
                "title": suggestion.title,
                "duration": "30m"
            ]
            if let dueHint = suggestion.dueHint {
                payload["dateHint"] = dueHint
            }
            if let dueDate = suggestion.iso8601DueDate {
                payload["date"] = dueDate
            }
            return ToolActionDraft(
                kind: .calendarHold,
                title: "Draft calendar hold",
                payload: payload
            )

        case .messageDraft:
            // The title's verb picks the channel ("text" → Messages,
            // "email" → mail, otherwise the contact card decides at
            // preparation time) and names the recipient for lookup.
            let channel = MessageChannelRouter.explicitChannel(forTitle: suggestion.title)
            var payload = [
                "subject": suggestion.title,
                "body": suggestion.rationale,
                "channel": channel.rawValue
            ]
            if let recipient = MessageChannelRouter.recipientName(fromTitle: suggestion.title) {
                payload["recipient"] = recipient
            }
            return ToolActionDraft(
                kind: .messageDraft,
                title: channel == .textMessage ? "Draft text message" : "Draft follow-up message",
                payload: payload
            )

        case .checklistItem:
            return ToolActionDraft(
                kind: .checklistItem,
                title: "Add checklist item",
                payload: ["title": suggestion.title]
            )

        case .none:
            return ToolActionDraft(
                kind: .none,
                title: "No system action",
                payload: ["title": suggestion.title],
                requiresConfirmation: false
            )
        }
    }
}
