import Foundation
import FoundationModels
import LocalAssistCore

// Guided-generation contract for direct commands. Same constrained-decoding
// guarantee as `DailyBrief`: the enum cases below are the only action types
// the decoder can emit, so classification can't produce a fifth category.
//
// The @Guide strings use few-shot examples rather than conditional rules —
// validated on-device: rule prompts ("if input starts with text → message")
// misrouted "text Priya that Sunday brunch works, 11am" to calendarEvent
// or reminder, while the same input classified correctly the first time
// once each case carried four literal examples. The 3B model is a pattern
// matcher, not a logic engine.

@Generable(description: "Discrete actions parsed from one direct command.")
struct RoutedCommandPlan: Sendable {
    @Guide(description: """
    Every discrete action the command asks for. Most commands are one action. \
    "text Priya about brunch and remind me to book a table" is two: one \
    message, one reminder.
    """, .count(1 ... 3))
    var actions: [RoutedCommandAction]
}

@Generable(description: "One action routed to a system app.")
struct RoutedCommandAction: Sendable {
    @Guide(description: """
    message examples: "text Priya that dinner works", "msg Arjun I'll be late", \
    "tell mom I landed", "message dad happy birthday"
    email examples: "email HR about leave", "mail the report to the team", \
    "send mail to the client"
    calendarEvent examples: "meeting with Rahul Thursday 3pm", \
    "schedule dentist Tuesday 2pm", "book lunch with the team Friday noon"
    reminder examples: "remind me to pick up groceries", \
    "remind me to finish the presentation", "remind me to call the plumber"
    """)
    var actionType: RoutedCommandType

    @Guide(description: """
    high examples: "call mom", "text dad", "message amma", "office meeting", \
    "deadline Friday", "client presentation"
    normal examples: "pick up groceries", "text Priya about brunch", \
    "schedule dentist", "buy flowers"
    """)
    var priority: RoutedCommandPriority

    @Guide(description: """
    First name of the person mentioned, exactly as written in the command. \
    Empty string if no person is mentioned.
    """)
    var contactName: String

    @Guide(description: """
    Calendar date in ISO 8601 format (YYYY-MM-DD) resolved relative to \
    today's date. Empty string if no date is mentioned.
    """)
    var date: String

    @Guide(description: "Time in HH:mm 24-hour format. Empty string if no time is mentioned.")
    var time: String

    @Guide(description: "Physical location or place name if mentioned. Empty string if none.")
    var location: String

    @Guide(description: """
    For message: a casual 1-2 sentence draft written as the user, using only \
    facts from the command. Input "text Priya that Sunday brunch works, 11am" \
    → "Sunday brunch sounds perfect! See you at 11".
    For email: a brief professional body.
    For calendarEvent: a short event title, like "Brunch with Priya".
    For reminder: the task description, like "Pick up groceries".
    """)
    var draftContent: String

    @Guide(description: """
    For email only: a concise subject line under 8 words naming the topic. \
    Empty string for every other action type.
    """)
    var emailSubject: String

    @Guide(description: "One-line human-readable summary under 60 characters for the review card.")
    var summary: String
}

@Generable(description: "Which system app the action routes to.")
enum RoutedCommandType: Sendable {
    case message
    case email
    case calendarEvent
    case reminder
}

@Generable(description: "How urgent the action is.")
enum RoutedCommandPriority: Sendable {
    case high
    case normal
}

// MARK: - Mapping into engine-agnostic core values

extension RoutedCommandAction {
    var coreAction: RoutedAction {
        RoutedAction(
            actionType: actionType.coreType,
            priority: priority == .high ? .high : .medium,
            contactName: contactName.trimmingCharacters(in: .whitespacesAndNewlines),
            date: date.trimmingCharacters(in: .whitespacesAndNewlines),
            time: time.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            draftContent: draftContent.trimmingCharacters(in: .whitespacesAndNewlines),
            emailSubject: emailSubject.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

extension RoutedCommandType {
    var coreType: RoutedActionType {
        switch self {
        case .message: .message
        case .email: .email
        case .calendarEvent: .calendarEvent
        case .reminder: .reminder
        }
    }
}
