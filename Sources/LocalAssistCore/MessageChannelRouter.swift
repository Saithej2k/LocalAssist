import Foundation

/// Which app a communication draft hands off to.
public enum MessageChannel: String, Codable, Sendable {
    /// Messages (SMS/iMessage) — the personal channel.
    case textMessage = "sms"
    /// The user's default mail app (Mail, or Gmail when set as default).
    case email = "email"
    /// No explicit verb; contacts decide (personal number → Messages,
    /// email-only → mail).
    case auto = "auto"
}

/// Pure routing rules for communication drafts: which channel a title
/// implies, who it's addressed to, how a contact's reachability settles an
/// ambiguous channel, which URL opens the right composer, and which drafts
/// outrank the rest because the person matters to the user.
///
/// Everything here is deterministic string/URL logic — the Contacts lookup
/// that feeds it lives behind `ContactResolving` in the system layer.
public enum MessageChannelRouter {
    // MARK: - Channel from the title verb

    private static let textCues: Set<String> = ["text", "message", "imessage", "sms"]
    private static let emailCues: Set<String> = ["email", "mail"]

    /// Explicit verbs win: "text Priya" is Messages no matter what her
    /// contact card says; "email the landlord" is mail. Everything else
    /// ("send", "share") is `.auto` and resolves from the contact.
    /// Whole-word matching — "context" must not read as a text verb.
    public static func explicitChannel(forTitle title: String) -> MessageChannel {
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        if words.contains(where: textCues.contains) {
            return .textMessage
        }
        if words.contains(where: emailCues.contains) {
            return .email
        }
        return .auto
    }

    // MARK: - Recipient from the title

    private static let recipientVerbs: Set<String> = [
        "text", "message", "msg", "imessage", "sms", "tell",
        "email", "e-mail", "mail", "send", "share", "ping",
    ]
    private static let recipientArticles: Set<String> = ["the", "a", "an", "my", "our"]
    private static let recipientStopwords: Set<String> = [
        "about", "regarding", "re", "that", "to", "for", "by", "before", "after",
        "with", "on", "at", "in", "when", "if", "and", "tomorrow", "today", "tonight",
    ]

    /// "Text Priya about Sunday brunch" → "Priya"; "Email the landlord
    /// about the heater" → "landlord". Up to three words after the verb,
    /// skipping leading articles, stopping at connective words. Nil when
    /// the title has no recognizable verb → addressee shape.
    public static func recipientName(fromTitle title: String) -> String? {
        let words = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard let verbIndex = words.firstIndex(where: { recipientVerbs.contains(normalized($0)) }) else {
            return nil
        }

        var collected: [String] = []
        for word in words.dropFirst(verbIndex + 1) {
            let bare = normalized(word)
            if recipientArticles.contains(bare) {
                // Leading article: the name follows ("email the landlord").
                // Mid-stream article: the name is over ("send Mira the
                // blockers" — nobody is called "Mira the blockers").
                if collected.isEmpty {
                    continue
                }
                break
            }
            if recipientStopwords.contains(bare) || collected.count == 3 {
                break
            }
            collected.append(word.trimmingCharacters(in: .punctuationCharacters))
        }
        let name = collected.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    // MARK: - Settling `.auto` from the contact card

    /// The user's rule: mail only when the note says mail. Explicit verbs
    /// win outright; for everyone else a phone number means Messages, an
    /// email-only contact means mail (the only way to reach them), and an
    /// unresolved person means Messages too — a live run sent "Hi amma" to
    /// a Gmail composer because the old default was email, and nobody
    /// texts their mother by mail. Both composers open unaddressed when
    /// nobody resolved, so the default costs nothing and matches how
    /// people actually reach each other.
    public static func resolve(explicit: MessageChannel, hasPhone: Bool, hasEmail: Bool) -> MessageChannel {
        switch explicit {
        case .textMessage, .email:
            return explicit
        case .auto:
            if hasPhone {
                return .textMessage
            }
            if hasEmail {
                return .email
            }
            return .textMessage
        }
    }

    // MARK: - Composer URLs

    /// Prefilled composer the user can send or abandon — the app never
    /// sends anything itself. `sms:` opens Messages; `mailto:` opens the
    /// default mail app (Gmail when the user has set it as default).
    public static func handoffURL(
        channel: MessageChannel,
        phone: String?,
        email: String?,
        subject: String,
        body: String
    ) -> URL? {
        switch channel {
        case .textMessage:
            let digits = phone.map { $0.filter { "+0123456789".contains($0) } } ?? ""
            // A text is just the message: leading with the subject line
            // duplicated the content in the composer ("Sunday brunch with
            // Priya at 11 am." above "Sunday brunch sounds perfect!…").
            // The subject only substitutes when there is no body at all.
            let text = body.isEmpty ? subject : body
            // `.urlQueryAllowed` already encodes `%`, `#`, and whitespace,
            // but leaves three characters intact that corrupt an sms: URL:
            // `&` terminates the recipient part, `?` opens a query string,
            // and `+` decodes as a space on the receiver. Encoding `%` or
            // `#` a second time here would double-escape ("%25" → "%2525").
            let encoded = (text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
                .replacingOccurrences(of: "&", with: "%26")
                .replacingOccurrences(of: "?", with: "%3F")
                .replacingOccurrences(of: "+", with: "%2B")
            return URL(string: "sms:\(digits)&body=\(encoded)")
        case .email, .auto:
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = email ?? ""
            components.queryItems = [
                URLQueryItem(name: "subject", value: subject),
                URLQueryItem(name: "body", value: body),
            ]
            return components.url
        }
    }

    // MARK: - Urgency

    /// Splits the Settings string ("mom, dad, Anika") into match terms.
    public static func priorityContacts(fromSetting setting: String) -> [String] {
        setting
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Whole-word match so "dad" doesn't fire on "deadline" and "mom"
    /// doesn't fire on "moment".
    public static func isUrgent(text: String, priorityContacts: [String]) -> Bool {
        guard !priorityContacts.isEmpty else {
            return false
        }
        let words = Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        return priorityContacts.contains { contact in
            let contactWords = contact.components(separatedBy: " ").filter { !$0.isEmpty }
            return !contactWords.isEmpty && contactWords.allSatisfy(words.contains)
        }
    }

    /// Stable partition: urgent communications first, everything else in
    /// its original order — the model's own ordering still matters within
    /// each band.
    public static func prioritized(
        _ actions: [PreparedToolAction],
        priorityContacts: [String]
    ) -> [PreparedToolAction] {
        guard !priorityContacts.isEmpty else {
            return actions
        }
        var urgent: [PreparedToolAction] = []
        var rest: [PreparedToolAction] = []
        for action in actions {
            let haystack = [
                action.draft.title,
                action.draft.payload["title"] ?? "",
                action.draft.payload["subject"] ?? "",
                action.draft.payload["recipient"] ?? "",
            ].joined(separator: " ")
            if action.draft.kind == .messageDraft, isUrgent(text: haystack, priorityContacts: priorityContacts) {
                var flagged = action
                flagged.draft.payload["priority"] = "urgent"
                urgent.append(flagged)
            } else {
                rest.append(action)
            }
        }
        return urgent + rest
    }
}
