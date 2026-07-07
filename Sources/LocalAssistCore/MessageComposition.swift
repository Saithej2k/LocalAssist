import Foundation

/// A ready-to-send message: what actually lands in the composer when the
/// user confirms a communication action. The on-device model writes it from
/// the captured note; this deterministic composer is the same-shape fallback
/// for Instant mode and unavailable-model devices.
public struct ComposedMessageDraft: Equatable, Sendable {
    public var subject: String
    public var body: String

    public init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }
}

/// LocalAssist's mark on the artifacts it creates — visible, deletable, and
/// branded with the app, not the model.
public enum MessageBranding {
    /// Appended to composed message bodies. One short line the user can
    /// remove in the composer before sending.
    public static func signature(for channel: MessageChannel) -> String {
        switch channel {
        case .textMessage:
            return "\n— via LocalAssist"
        case .email, .auto:
            return "\n\n— Sent with LocalAssist"
        }
    }

    /// Notes line for reminders, calendar holds, and suggestion rationale.
    public static let artifactNote = "Added by LocalAssist"
}

/// Template composer: readable, first person, no placeholders. Derives the
/// topic from the task title ("Text Priya about Sunday brunch" → "Sunday
/// brunch") and greets the recipient when one is known.
public enum DeterministicMessageComposer {
    public static func compose(
        recipient: String?,
        title: String,
        channel: MessageChannel
    ) -> ComposedMessageDraft {
        let topic = Self.topic(fromTitle: title)
        let greeting = recipient.map { "Hi \(Self.capitalized($0))," } ?? "Hi,"

        switch channel {
        case .textMessage:
            return ComposedMessageDraft(
                subject: Self.capitalized(topic),
                body: "\(greeting) I wanted to check in about \(topic). Let me know what works!"
            )
        case .email, .auto:
            return ComposedMessageDraft(
                subject: Self.capitalized(topic),
                body: "\(greeting)\n\nI wanted to follow up about \(topic). "
                    + "Could you let me know where this stands?\n\nThanks!"
            )
        }
    }

    /// "Text Priya about Sunday brunch" → "Sunday brunch";
    /// "Email the landlord about the broken heater" → "the broken heater";
    /// titles without "about" fall back to the title minus the verb clause.
    static func topic(fromTitle title: String) -> String {
        let lowercased = title.lowercased()
        if let range = lowercased.range(of: " about ") {
            let topic = String(title[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !topic.isEmpty {
                return topic
            }
        }
        // No "about" clause: drop the verb and recipient if we can name
        // them, otherwise use the whole title.
        if let recipient = MessageChannelRouter.recipientName(fromTitle: title),
           let range = title.range(of: recipient) {
            let remainder = String(title[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                return remainder
            }
        }
        return title
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else {
            return text
        }
        return first.uppercased() + text.dropFirst()
    }
}
