import Foundation

// Direct-command routing: "text Priya that Sunday brunch works, 11am" should
// become one addressed, drafted, ready-to-confirm action card — not a brief
// with a headline and key points. The detector decides which inputs qualify,
// the deterministic router covers every device, and the mapper folds routed
// actions into the same `StructuredSummary`/`ToolActionDraft` shapes the
// review UI, history, and executors already consume.

/// The four things a direct command can ask for, named after the system app
/// each routes to (Messages, mail, Calendar, Reminders).
public enum RoutedActionType: String, Codable, Sendable, CaseIterable {
    case message
    case email
    case calendarEvent
    case reminder
}

/// One action parsed out of a direct command. Empty strings mean "not
/// mentioned" — the model contract and the deterministic router share that
/// sentinel, so downstream code never has to guess at nils or filter
/// placeholder values like "TBD".
public struct RoutedAction: Codable, Equatable, Sendable {
    public var actionType: RoutedActionType
    public var priority: TaskPriority
    /// First name as written in the command; resolved against Contacts later.
    public var contactName: String
    /// ISO-8601 calendar date ("2026-07-12") or "".
    public var date: String
    /// 24-hour "HH:mm" or "".
    public var time: String
    public var location: String
    /// Message/email body, event title, or reminder text — ready to hand off.
    public var draftContent: String
    /// Email only; "" for the other action types.
    public var emailSubject: String
    /// One-line description for the review card.
    public var summary: String

    public init(
        actionType: RoutedActionType,
        priority: TaskPriority,
        contactName: String,
        date: String,
        time: String,
        location: String,
        draftContent: String,
        emailSubject: String,
        summary: String
    ) {
        self.actionType = actionType
        self.priority = priority
        self.contactName = contactName
        self.date = date
        self.time = time
        self.location = location
        self.draftContent = draftContent
        self.emailSubject = emailSubject
        self.summary = summary
    }

    /// `date` + `time` as one instant in the user's calendar. A date without
    /// a time stays at midnight so date-only semantics ("that day", not "that
    /// midnight") survive downstream staleness checks.
    public func resolvedDueDate(calendar: Calendar = .current) -> Date? {
        guard !date.isEmpty,
              let day = LocalAssistDates.parse(date, timeZone: calendar.timeZone)
        else {
            return nil
        }
        guard let time = CommandTimeParser.components(in: time) else {
            return day
        }
        return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) ?? day
    }
}

// MARK: - Detector

/// Decides whether an input is a direct command (router path) or a capture
/// (brief pipeline). Deliberately conservative: only short, single-clause
/// inputs that *start* with an explicit routing verb qualify. "Pick up
/// groceries" has no routing verb and stays on the brief path, which already
/// turns it into a reminder — a missed command degrades gracefully, but a
/// meeting transcript misread as a command would lose the whole brief.
public enum DirectCommandDetector {
    /// Ordered so longer prefixes win ("remind me " before "remind ").
    static let commandPrefixes: [(prefix: String, type: RoutedActionType)] = [
        ("text ", .message),
        ("message ", .message),
        ("msg ", .message),
        ("imessage ", .message),
        ("tell ", .message),
        ("email ", .email),
        ("mail ", .email),
        ("remind me ", .reminder),
        ("remind ", .reminder),
        ("schedule ", .calendarEvent),
        ("book ", .calendarEvent),
        ("meeting with ", .calendarEvent),
    ]

    /// Commands are one breath long; anything past this is a capture.
    private static let maximumLength = 220

    public static func isDirectCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength, !trimmed.contains("\n") else {
            return false
        }

        let lowered = trimmed.lowercased()
        if let match = commandPrefixes.first(where: { lowered.hasPrefix($0.prefix) }) {
            // Multi-sentence input is a note. A single trailing period is fine.
            let sentences = trimmed
                .components(separatedBy: CharacterSet(charactersIn: ".!?"))
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if sentences.count <= 1 {
                // Compound scheduling and reminder captures ("schedule the
                // sync and send the agenda") stay on the brief path: it
                // extracts every clause as its own task, while the
                // single-action router would drop all but the first. Message
                // and email commands stay routed even when compound —
                // drafting the message is the whole point.
                switch match.type {
                case .message, .email:
                    return true
                case .calendarEvent, .reminder:
                    if !lowered.contains(" and ") {
                        return true
                    }
                }
            }
        }

        // Deferred commands put the message first and the verb last:
        // "Hi amma how are you doing, text this to amma now". The "this"
        // makes the shape precise, so multiple sentences are fine — the
        // content IS the message.
        return deferredCommand(in: trimmed) != nil
    }

    /// The routed order for a deferred command: the message body is the
    /// user's own words with the routing clause removed.
    public struct DeferredCommand: Equatable, Sendable {
        public var type: RoutedActionType
        public var recipient: String
        /// The command clause's range within the input it was matched in.
        public var clauseRange: Range<String.Index>
    }

    /// "text this to amma now", "send that to mom", "email it to HR".
    /// Compiled once; the literal is valid by construction.
    private static let deferredPattern = try? NSRegularExpression(
        pattern: #"(?:,\s*)?(?:and\s+)?\b(text|send|message|imessage|sms|email|mail)"#
            + #"\s+(?:this|that|it)\s+to\s+(?:(?:the|my|our)\s+)?(\w+)"#
            + #"(?:\s+(?:now|please|asap|today|tonight))*[.!?]?"#,
        options: [.caseInsensitive]
    )

    public static func deferredCommand(in text: String) -> DeferredCommand? {
        guard let deferredPattern else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = deferredPattern.firstMatch(in: text, range: range),
              let clauseRange = Range(match.range, in: text),
              let verbRange = Range(match.range(at: 1), in: text),
              let recipientRange = Range(match.range(at: 2), in: text)
        else {
            return nil
        }
        // A deferred command needs content to defer to — the clause alone
        // ("send this to mom") has no message and stays a prefix command.
        let remainder = text.replacingCharacters(in: clauseRange, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return nil
        }
        let verb = text[verbRange].lowercased()
        return DeferredCommand(
            type: verb == "email" || verb == "mail" ? .email : .message,
            recipient: String(text[recipientRange]),
            clauseRange: clauseRange
        )
    }
}

// MARK: - Deterministic router

/// Regex-and-keyword router for devices without the model. Routes the action
/// type, recipient, date, and time correctly; what it cannot do is write a
/// natural message draft, so it passes the user's own words through after
/// stripping the command verb. Always returns exactly one action — splitting
/// compound sentences on "and" produces false positives ("remind me to buy
/// bread and milk" is one errand), so the conservative path is a single
/// action the user can follow with a second command.
public struct DeterministicCommandRouter: Sendable {
    private let calendar: Calendar
    private let dateParser: DueDateParser

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
        self.dateParser = DueDateParser(calendar: calendar)
    }

    public func route(_ input: String, relativeTo now: Date = Date()) -> RoutedAction {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        // Deferred shape ("Hi amma how are you doing, text this to amma"):
        // the message is the user's own words with the routing clause
        // removed. A leading verb wins — "remind me to text this to amma"
        // is a reminder about texting, not a text.
        if !DirectCommandDetector.commandPrefixes.contains(where: { lowered.hasPrefix($0.prefix) }),
           let deferred = DirectCommandDetector.deferredCommand(in: trimmed) {
            return deferredAction(deferred, in: trimmed, relativeTo: now)
        }

        let actionType = Self.actionType(for: lowered)
        let time = CommandTimeParser.time(in: lowered) ?? ""
        let date = dateParser.date(from: lowered, relativeTo: now)
            .map { LocalAssistDates.dateOnlyString(from: $0, timeZone: calendar.timeZone) } ?? ""
        let contact = contactName(in: trimmed, actionType: actionType)
        let draft = Self.draftContent(from: trimmed, actionType: actionType, contact: contact)

        return RoutedAction(
            actionType: actionType,
            priority: Self.isHighPriority(lowered) ? .high : .medium,
            contactName: contact,
            date: date,
            time: time,
            // Regex location extraction confuses "at the office" with
            // "at 3pm" too often to prefill safely; only the model path
            // extracts locations.
            location: "",
            draftContent: draft,
            emailSubject: actionType == .email ? String(draft.prefix(50)) : "",
            summary: Self.summaryLine(for: actionType, contact: contact, draft: draft)
        )
    }

    // MARK: Deferred commands

    private func deferredAction(
        _ deferred: DirectCommandDetector.DeferredCommand,
        in input: String,
        relativeTo now: Date
    ) -> RoutedAction {
        // The body is exactly what the user wrote, minus the routing clause
        // and any comma it dangled from — never a paraphrase.
        var body = input
        body.removeSubrange(deferred.clauseRange)
        body = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;: "))
            .sentenceCapitalized()

        let lowered = body.lowercased()
        let contact = deferred.recipient.sentenceCapitalized()
        return RoutedAction(
            actionType: deferred.type,
            priority: Self.isHighPriority(input.lowercased()) ? .high : .medium,
            contactName: contact,
            date: dateParser.date(from: lowered, relativeTo: now)
                .map { LocalAssistDates.dateOnlyString(from: $0, timeZone: calendar.timeZone) } ?? "",
            time: CommandTimeParser.time(in: lowered) ?? "",
            location: "",
            draftContent: body,
            emailSubject: deferred.type == .email ? String(body.prefix(50)) : "",
            summary: Self.summaryLine(for: deferred.type, contact: contact, draft: body)
        )
    }

    // MARK: Action type

    private static func actionType(for lowered: String) -> RoutedActionType {
        // The command verb wins over any date/time content in the body:
        // "text Priya that Sunday brunch works, 11am" is a message.
        if let match = DirectCommandDetector.commandPrefixes.first(where: { lowered.hasPrefix($0.prefix) }) {
            return match.type
        }
        if lowered.contains("email") || lowered.contains("mail") {
            return .email
        }
        return .reminder
    }

    // MARK: Recipient

    private static let nameStopwords: Set<String> = [
        "today", "tomorrow", "tonight", "next", "this", "at", "on", "in",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "about", "regarding", "that", "to", "for", "and",
    ]

    private func contactName(in input: String, actionType: RoutedActionType) -> String {
        switch actionType {
        case .message, .email:
            return MessageChannelRouter.recipientName(fromTitle: input) ?? ""
        case .calendarEvent:
            // "meeting with Rahul Thursday 3pm" → "Rahul"
            let words = input.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            guard let withIndex = words.firstIndex(where: { $0.lowercased() == "with" }) else {
                return ""
            }
            var collected: [String] = []
            for word in words.dropFirst(withIndex + 1) {
                let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if Self.nameStopwords.contains(bare)
                    || bare.contains(where: \.isNumber)
                    || collected.count == 2 {
                    break
                }
                collected.append(word.trimmingCharacters(in: .punctuationCharacters))
            }
            return collected.joined(separator: " ")
        case .reminder:
            return ""
        }
    }

    // MARK: Draft content

    private static let connectorPrefixes = ["that ", "to say ", "saying ", "about "]

    private static func draftContent(
        from input: String,
        actionType: RoutedActionType,
        contact: String
    ) -> String {
        var draft = input
        if let match = DirectCommandDetector.commandPrefixes.first(where: {
            input.lowercased().hasPrefix($0.prefix)
        }) {
            // "remind me to X" sheds the whole "remind me to";
            // "meeting with Rahul" keeps its natural title.
            if match.prefix == "remind me ", draft.lowercased().hasPrefix("remind me to ") {
                draft = String(draft.dropFirst("remind me to ".count))
            } else if match.prefix == "meeting with " {
                return draft.sentenceCapitalized()
            } else {
                draft = String(draft.dropFirst(match.prefix.count))
            }
        }

        guard actionType == .message || actionType == .email else {
            return draft.trimmingCharacters(in: .whitespacesAndNewlines).sentenceCapitalized()
        }

        if !contact.isEmpty, let range = draft.range(of: contact, options: .caseInsensitive) {
            draft.removeSubrange(range)
        }
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        for connector in connectorPrefixes where draft.lowercased().hasPrefix(connector) {
            draft = String(draft.dropFirst(connector.count))
            break
        }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).sentenceCapitalized()
    }

    // MARK: Priority

    /// People and stakes the user always treats as urgent. Whole-word match
    /// so "mom" never fires on "moment" or "dad" on "deadline"… which is
    /// its own keyword.
    private static let highPriorityWords: Set<String> = [
        "mom", "dad", "amma", "appa", "mother", "father", "parents",
        "office", "boss", "client", "deadline", "urgent", "asap",
    ]

    /// Shared with the reconciler so model-routed actions get the same
    /// priority floor the deterministic router applies.
    static func isHighPriority(_ lowered: String) -> Bool {
        isHighPriority(words: Set(
            lowered
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        ))
    }

    /// Overload for callers that already have the word set — the reconciler
    /// hits this on every action and would otherwise re-tokenize each time.
    static func isHighPriority(words: Set<String>) -> Bool {
        !words.isDisjoint(with: highPriorityWords)
    }

    // MARK: Summary

    private static func summaryLine(
        for actionType: RoutedActionType,
        contact: String,
        draft: String
    ) -> String {
        let prefix = switch actionType {
        case .message: contact.isEmpty ? "Message" : "Message \(contact)"
        case .email: contact.isEmpty ? "Email" : "Email \(contact)"
        case .calendarEvent: "Event"
        case .reminder: "Reminder"
        }
        return "\(prefix): \(draft.prefix(40))"
    }
}

// MARK: - Time extraction

/// Parses explicit clock times ("11am", "3 pm", "11:30", "11:30pm") into
/// 24-hour components. Shared by the deterministic router and by
/// `DueDateParser`, so a hint like "tomorrow 3pm" resolves to 15:00 instead
/// of the default reminder hour.
public enum CommandTimeParser {
    /// Compiled once. The literal is valid by construction; a nil pattern
    /// would just mean no time is ever extracted, never a crash.
    private static let pattern = try? NSRegularExpression(
        pattern: #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b|\b(\d{1,2}):(\d{2})\b"#,
        options: [.caseInsensitive]
    )

    public static func time(in text: String) -> String? {
        components(in: text).map { String(format: "%02d:%02d", $0.hour, $0.minute) }
    }

    public static func components(in text: String) -> (hour: Int, minute: Int)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let pattern, let match = pattern.firstMatch(in: text, range: range) else {
            return nil
        }

        func group(_ index: Int) -> String? {
            guard let groupRange = Range(match.range(at: index), in: text) else {
                return nil
            }
            return String(text[groupRange])
        }

        // "11am", "11:30pm"
        if let hourText = group(1), var hour = Int(hourText), let period = group(3) {
            let minute = group(2).flatMap(Int.init) ?? 0
            guard (1 ... 12).contains(hour), (0 ... 59).contains(minute) else {
                return nil
            }
            if period.lowercased() == "pm", hour != 12 {
                hour += 12
            }
            if period.lowercased() == "am", hour == 12 {
                hour = 0
            }
            return (hour, minute)
        }

        // "15:00"
        if let hourText = group(4), let minuteText = group(5),
           let hour = Int(hourText), let minute = Int(minuteText),
           (0 ... 23).contains(hour), (0 ... 59).contains(minute) {
            return (hour, minute)
        }

        return nil
    }
}

// MARK: - Reconciling model output against the command

/// Deterministic corrections for the on-device model's routed actions, every
/// one earned from a live run. Few-shot examples can leak ("text Priya about
/// brunch" once grew a "remind me to pick up groceries" copied from the
/// prompt) — so an action sharing no content words with the command is
/// dropped. The model volunteers unasked-for actions (the Rahul meeting grew
/// a cheerful message to Rahul) — so an action's type must be asked for by a
/// verb in the command. It echoes a deferred command's routing clause back
/// as its own action ("Text this to amma now" as a second message) — so
/// clause-only drafts are dropped. It duplicates actions — so identical
/// type+content pairs collapse. It invents dates, times, and places
/// ("3pm today" for a Thursday meeting; "Meeting Room" from thin air) — so
/// dates, times, and locations exist only when the command itself carries
/// them, the same policy `SummaryNormalizer` applies to brief titles.
public enum RoutedActionReconciler {
    public static func reconciled(
        _ actions: [RoutedAction],
        sourceText: String,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [RoutedAction] {
        let lowered = sourceText.lowercased()
        let sourceContentWords = contentWords(in: sourceText)
        let sourceWords = Set(
            lowered
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        let admissible = admissibleTypes(in: sourceWords, lowered: lowered)
        // Both are properties of the command; the previous version tokenized
        // `lowered` again inside `isHighPriority` and inside every action's
        // date branch. Compute them once at the top.
        let commandIsHighPriority = DeterministicCommandRouter.isHighPriority(words: sourceWords)

        let dateParser = DueDateParser(calendar: calendar)
        let sourceDate = dateParser.date(from: lowered, relativeTo: now)
            .map { LocalAssistDates.dateOnlyString(from: $0, timeZone: calendar.timeZone) }
        let sourceTime = CommandTimeParser.time(in: lowered)
        let commandDateCues = Set(dateCues.filter { lowered.contains($0) })

        // A deferred command's routing clause ("…text this to amma now") is
        // an instruction, not content — a draft that says nothing beyond the
        // clause is the clause echoed back as a second action.
        let clauseWords = DirectCommandDetector.deferredCommand(in: sourceText).map { deferred in
            contentWords(in: String(sourceText[deferred.clauseRange]))
                .union([deferred.recipient.lowercased()])
        }

        // The model sometimes emits the same action twice ("Hi amma…" once
        // routed as two identical messages); the first of each type+content
        // pair wins.
        var seen = Set<String>()

        return actions.compactMap { action in
            guard admissible.contains(action.actionType),
                  isGrounded(action, in: sourceContentWords)
            else {
                return nil
            }
            let draftWords = contentWords(in: action.draftContent)
            if let clauseWords, !draftWords.isEmpty, draftWords.isSubset(of: clauseWords) {
                return nil
            }
            let identity = action.actionType.rawValue + "|" + action.contactName.lowercased() + "|"
                + draftWords.sorted().joined(separator: " ")
            guard seen.insert(identity).inserted else {
                return nil
            }
            var reconciled = action

            // Locations follow the grounding rule too: "Meeting Room" on a
            // command that names no place is a model invention, and a wrong
            // prefilled location is worse than an empty field.
            let locationWords = contentWords(in: action.location)
            if !locationWords.isEmpty, !locationWords.isSubset(of: sourceWords) {
                reconciled.location = ""
            }
            // Family and work keywords are a deterministic priority floor —
            // the model may raise priority for its own reasons, never lower
            // it below what the command plainly says.
            if commandIsHighPriority {
                reconciled.priority = .high
            }
            let actionText = "\(action.draftContent) \(action.summary)".lowercased()

            // A command without a date cue dates nothing — a model-invented
            // date on a real reminder is worse than an empty field the user
            // can fill on the card. With a cue, a cue the draft shares with
            // the command settles which action it belongs to; drafts with no
            // shared cue take the command's date. Cues found only in the
            // draft are model inventions ("3pm today" for a Thursday
            // meeting) and never count.
            if sourceDate == nil {
                reconciled.date = ""
            } else if let cue = commandDateCues.first(where: { actionText.contains($0) }),
                      let date = dateParser.date(from: cue, relativeTo: now) {
                reconciled.date = LocalAssistDates.dateOnlyString(from: date, timeZone: calendar.timeZone)
            } else {
                reconciled.date = sourceDate ?? ""
            }

            // Same for clock times: the command's time is the only one that
            // counts.
            reconciled.time = sourceTime ?? ""
            return reconciled
        }
    }

    /// Cue words a draft can share with the command to claim a date.
    /// Mirrors what `DueDateParser` resolves.
    private static let dateCues = [
        "today", "tomorrow", "tonight", "next week", "this week",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    /// An action type is admissible when the command asks for it: the
    /// routing verb that opened the command, plus any communication or
    /// scheduling verbs mentioned later ("…and remind me to book a table").
    private static func admissibleTypes(
        in sourceWords: Set<String>,
        lowered: String
    ) -> Set<RoutedActionType> {
        var types: Set<RoutedActionType> = []
        if let match = DirectCommandDetector.commandPrefixes.first(where: { lowered.hasPrefix($0.prefix) }) {
            types.insert(match.type)
        }
        if !sourceWords.isDisjoint(with: ["text", "tell", "message", "msg", "imessage", "sms", "send", "share", "ping"]) {
            types.insert(.message)
        }
        if !sourceWords.isDisjoint(with: ["email", "mail"]) {
            types.insert(.email)
        }
        if !sourceWords.isDisjoint(with: ["remind", "reminder", "remember"]) {
            types.insert(.reminder)
        }
        if !sourceWords.isDisjoint(with: ["schedule", "book", "meeting", "appointment", "event", "calendar"]) {
            types.insert(.calendarEvent)
        }
        return types
    }

    /// Words that carry no grounding signal on their own.
    private static let structuralWords: Set<String> = [
        "a", "an", "the", "to", "that", "this", "at", "on", "in", "for",
        "about", "and", "or", "of", "with", "by", "is", "are", "be",
        "i", "me", "my", "you", "your", "we", "our", "it", "its",
        "text", "message", "msg", "imessage", "tell", "email", "mail",
        "remind", "reminder", "schedule", "book", "meeting",
        "please", "will", "would", "can", "could",
    ]

    private static func isGrounded(_ action: RoutedAction, in sourceWords: Set<String>) -> Bool {
        let actionWords = contentWords(
            in: "\(action.contactName) \(action.draftContent) \(action.summary) \(action.location)"
        )
        // An action with no content words of its own can't be judged;
        // keep it and let the user's review be the filter.
        guard !actionWords.isEmpty else {
            return true
        }
        return !actionWords.isDisjoint(with: sourceWords)
    }

    private static func contentWords(in text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 && !structuralWords.contains($0) }
        )
    }
}

// MARK: - Mapping into the review pipeline

/// Folds routed actions into the shapes the rest of the app already speaks:
/// `TaskSuggestion` rows for Today/history/widgets and fully-addressed
/// `ToolActionDraft`s for the review cards and executors. Drafts are built
/// directly — not through `ToolActionPlanner` — because a routed action
/// already knows its recipient, channel, and body; re-deriving them from a
/// title would only lose information.
public enum RoutedActionMapper {
    public static func summary(
        from actions: [RoutedAction],
        source: GenerationSource,
        diagnostics: GenerationDiagnostics,
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) -> StructuredSummary {
        let suggestions = actions.map { taskSuggestion(from: $0, source: source, calendar: calendar) }
        let drafts = actions.map { actionDraft(from: $0, source: source) }
        return StructuredSummary(
            overview: overview(for: actions),
            // A routed command has no key points by design: the action card
            // is the whole story.
            keyPoints: [],
            suggestions: suggestions,
            actionDrafts: drafts,
            source: source,
            diagnostics: diagnostics,
            generatedAt: generatedAt
        )
    }

    private static func overview(for actions: [RoutedAction]) -> String {
        if actions.count == 1, let only = actions.first {
            return only.summary.nilIfEmpty ?? only.draftContent
        }
        return "\(actions.count) actions ready to review"
    }

    static func taskSuggestion(
        from action: RoutedAction,
        source: GenerationSource,
        calendar: Calendar = .current
    ) -> TaskSuggestion {
        let title = action.summary.nilIfEmpty ?? action.draftContent
        let dueDate = action.resolvedDueDate(calendar: calendar)
        return TaskSuggestion(
            id: StableID.make(from: action.actionType.rawValue + title + action.date + action.time),
            title: title,
            priority: action.priority,
            dueHint: dueHintText(for: action),
            dueDate: dueDate,
            action: suggestedAction(for: action.actionType),
            rationale: action.draftContent.nilIfEmpty ?? MessageBranding.artifactNote,
            confidence: source == .foundationModels ? 0.9 : 0.74
        )
    }

    static func actionDraft(from action: RoutedAction, source: GenerationSource) -> ToolActionDraft {
        var payload: [String: String] = [:]
        if let dateText = dueHintText(for: action) {
            payload["date"] = dateText
            payload["dueDate"] = dateText
        }

        switch action.actionType {
        case .message, .email:
            payload["title"] = action.summary.nilIfEmpty ?? action.draftContent
            payload["body"] = action.draftContent
            payload["channel"] = action.actionType == .email
                ? MessageChannel.email.rawValue
                : MessageChannel.textMessage.rawValue
            // Texts carry no subject line — the composer prepends one into
            // the message body when present.
            payload["subject"] = action.actionType == .email ? action.emailSubject : ""
            if !action.contactName.isEmpty {
                payload["recipient"] = action.contactName
            }
            // The model path drafts the actual message at routing time, so
            // confirmation opens the composer with it instead of writing a
            // second draft. Deterministic drafts stay uncomposed: the
            // template pass at confirm reads better than stripped raw input.
            if source == .foundationModels {
                payload["composed"] = "true"
            }
            return ToolActionDraft(
                kind: .messageDraft,
                title: action.actionType == .email ? "Draft email" : "Draft text message",
                payload: payload
            )

        case .calendarEvent:
            payload["title"] = action.draftContent
            payload["duration"] = "30m"
            if !action.location.isEmpty {
                payload["location"] = action.location
                payload["notes"] = action.location
            }
            return ToolActionDraft(kind: .calendarHold, title: "Draft calendar hold", payload: payload)

        case .reminder:
            payload["title"] = action.draftContent
            return ToolActionDraft(kind: .reminder, title: "Create reminder", payload: payload)
        }
    }

    /// "2026-07-12 15:00" when a time was parsed, "2026-07-12" otherwise —
    /// one editable string the review card can show and `DueDateParser` can
    /// read back after the user changes it.
    private static func dueHintText(for action: RoutedAction) -> String? {
        guard !action.date.isEmpty else {
            return nil
        }
        return action.time.isEmpty ? action.date : "\(action.date) \(action.time)"
    }

    private static func suggestedAction(for type: RoutedActionType) -> SuggestedAction {
        switch type {
        case .message, .email: .messageDraft
        case .calendarEvent: .calendarHold
        case .reminder: .reminder
        }
    }
}
