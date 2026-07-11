import Foundation

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
    /// Stable identifiers for the seven reconciler policies. Diagnostics and
    /// tests key on these; never rename a shipped ID.
    public enum RuleID {
        public static let admissibleType = "admissible-type"
        public static let sourceGrounding = "source-grounding"
        public static let clauseEcho = "clause-echo"
        public static let deduplication = "deduplication"
        public static let locationGrounding = "location-grounding"
        public static let priorityFloor = "priority-floor"
        public static let temporalCorrection = "temporal-correction"
    }

    public enum Disposition: String, Codable, Sendable {
        case accepted
        case modified
        case rejected
    }

    /// What the reconciler did to one model proposal — rule IDs and a
    /// disposition only, never the proposal's content.
    public struct Finding: Codable, Equatable, Sendable {
        /// Index of the proposal in the model's output order.
        public var proposalIndex: Int
        public var disposition: Disposition
        /// The rules that fired: the single rejecting rule, or every rule
        /// that modified the proposal. Empty for a clean accept.
        public var ruleIDs: [String]

        public init(proposalIndex: Int, disposition: Disposition, ruleIDs: [String]) {
            self.proposalIndex = proposalIndex
            self.disposition = disposition
            self.ruleIDs = ruleIDs
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var actions: [RoutedAction]
        public var findings: [Finding]
    }

    /// Everything the rules need to know about the command, computed once —
    /// the reconciler runs per model proposal, and re-deriving these per
    /// action was measurable churn.
    private struct CommandContext {
        let sourceContentWords: Set<String>
        let sourceWords: Set<String>
        let admissible: Set<RoutedActionType>
        let commandIsHighPriority: Bool
        let dateParser: DueDateParser
        let sourceDate: String?
        let sourceTime: String?
        let commandDateCues: Set<String>
        let clauseWords: Set<String>?
        let calendar: Calendar
        let now: Date

        init(sourceText: String, calendar: Calendar, now: Date) {
            let lowered = sourceText.lowercased()
            sourceContentWords = RoutedActionReconciler.contentWords(in: sourceText)
            sourceWords = Set(
                lowered
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
            )
            admissible = RoutedActionReconciler.admissibleTypes(in: sourceWords, lowered: lowered)
            commandIsHighPriority = DeterministicCommandRouter.isHighPriority(words: sourceWords)
            dateParser = DueDateParser(calendar: calendar)
            sourceDate = dateParser.date(from: lowered, relativeTo: now)
                .map { LocalAssistDates.dateOnlyString(from: $0, timeZone: calendar.timeZone) }
            sourceTime = CommandTimeParser.time(in: lowered)
            commandDateCues = Set(RoutedActionReconciler.dateCues.filter { lowered.contains($0) })
            // A deferred command's routing clause ("…text this to amma now")
            // is an instruction, not content — a draft that says nothing
            // beyond the clause is the clause echoed back as a second action.
            clauseWords = DirectCommandDetector.deferredCommand(in: sourceText).map { deferred in
                var words = RoutedActionReconciler.contentWords(in: String(sourceText[deferred.clauseRange]))
                if !deferred.recipient.isEmpty {
                    words.insert(deferred.recipient.lowercased())
                }
                return words
            }
            self.calendar = calendar
            self.now = now
        }
    }

    public static func reconciled(
        _ actions: [RoutedAction],
        sourceText: String,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [RoutedAction] {
        reconcile(actions, sourceText: sourceText, calendar: calendar, now: now).actions
    }

    public static func reconcile(
        _ actions: [RoutedAction],
        sourceText: String,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Outcome {
        let context = CommandContext(sourceText: sourceText, calendar: calendar, now: now)

        // Model actions sometimes duplicate on any of three axes: identical
        // content words, identical summary title, or clause-echo variants
        // padded with a greeting. Track all three.
        var seenContent = Set<String>()
        var seenSummary = Set<String>()

        var kept: [RoutedAction] = []
        var findings: [Finding] = []

        for (index, action) in actions.enumerated() {
            if let rejectingRule = rejectionRuleID(
                for: action,
                context: context,
                seenContent: &seenContent,
                seenSummary: &seenSummary
            ) {
                findings.append(Finding(proposalIndex: index, disposition: .rejected, ruleIDs: [rejectingRule]))
                continue
            }

            let (reconciled, firedRules) = corrected(action, context: context)
            findings.append(Finding(
                proposalIndex: index,
                disposition: firedRules.isEmpty ? .accepted : .modified,
                ruleIDs: firedRules
            ))
            kept.append(reconciled)
        }

        return Outcome(actions: kept, findings: findings)
    }

    /// The first rule that rejects the proposal outright, or nil to keep it.
    private static func rejectionRuleID(
        for action: RoutedAction,
        context: CommandContext,
        seenContent: inout Set<String>,
        seenSummary: inout Set<String>
    ) -> String? {
        guard context.admissible.contains(action.actionType) else {
            return RuleID.admissibleType
        }
        guard isGrounded(action, in: context.sourceContentWords) else {
            return RuleID.sourceGrounding
        }
        let draftWords = contentWords(in: action.draftContent)
        // Clause echo: whatever the draft says beyond its greeting
        // ("Hi", "Hello", …) is entirely inside the routing clause.
        // A padded echo like "Hi amma, text this to me now." leaks
        // through a straight isSubset check because "hi" isn't in the
        // clause words; stripping greetings first catches it.
        if let clauseWords = context.clauseWords {
            let padded = draftWords.subtracting(greetingWords)
            if !padded.isEmpty, padded.isSubset(of: clauseWords) {
                return RuleID.clauseEcho
            }
        }
        let contentIdentity = action.actionType.rawValue + "|"
            + action.contactName.lowercased() + "|"
            + draftWords.sorted().joined(separator: " ")
        guard seenContent.insert(contentIdentity).inserted else {
            return RuleID.deduplication
        }
        // Summary-level dedupe covers pairs like ("Text to amma",
        // "Text to amma") whose drafts differ only in punctuation the
        // content-word set already normalizes — the belt-and-braces
        // step catches the runs where two model turns landed on the
        // same headline for two different-looking drafts.
        let summaryKey = action.actionType.rawValue + "|"
            + action.contactName.lowercased() + "|"
            + action.summary.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !action.summary.isEmpty, !seenSummary.insert(summaryKey).inserted {
            return RuleID.deduplication
        }
        return nil
    }

    /// Applies the modifying rules and reports which ones fired.
    private static func corrected(
        _ action: RoutedAction,
        context: CommandContext
    ) -> (RoutedAction, [String]) {
        var reconciled = action
        var firedRules: [String] = []

        // Locations follow the grounding rule too: "Meeting Room" on a
        // command that names no place is a model invention, and a wrong
        // prefilled location is worse than an empty field.
        let locationWords = contentWords(in: action.location)
        if !locationWords.isEmpty, !locationWords.isSubset(of: context.sourceWords) {
            reconciled.location = ""
            firedRules.append(RuleID.locationGrounding)
        }
        // Family and work keywords are a deterministic priority floor —
        // the model may raise priority for its own reasons, never lower
        // it below what the command plainly says.
        if context.commandIsHighPriority, reconciled.priority != .high {
            reconciled.priority = .high
            firedRules.append(RuleID.priorityFloor)
        }

        applyTemporalCorrection(to: &reconciled, original: action, context: context, firedRules: &firedRules)
        return (reconciled, firedRules)
    }

    /// A command without a date cue dates nothing — a model-invented date
    /// on a real reminder is worse than an empty field the user can fill on
    /// the card. With a cue, a cue the draft shares with the command settles
    /// which action it belongs to; drafts with no shared cue take the
    /// command's date. Cues found only in the draft are model inventions
    /// ("3pm today" for a Thursday meeting) and never count. A shape-valid
    /// but calendar-invalid model date ("2026-02-30") also lands here: the
    /// command's deterministic parse replaces it, or it clears.
    private static func applyTemporalCorrection(
        to reconciled: inout RoutedAction,
        original action: RoutedAction,
        context: CommandContext,
        firedRules: inout [String]
    ) {
        let actionText = "\(action.draftContent) \(action.summary)".lowercased()

        if context.sourceDate == nil {
            reconciled.date = ""
        } else if let cue = context.commandDateCues.first(where: { actionText.contains($0) }),
                  let date = context.dateParser.date(from: cue, relativeTo: context.now) {
            reconciled.date = LocalAssistDates.dateOnlyString(from: date, timeZone: context.calendar.timeZone)
        } else {
            reconciled.date = context.sourceDate ?? ""
        }
        // Belt and braces: whatever won above must be a real calendar
        // date. The deterministic parser only emits real dates, so this
        // only fires if a future edit lets a model string through.
        if case .invalid = GeneratedDateTimeValidator.validateDate(reconciled.date, calendar: context.calendar) {
            reconciled.date = ""
        }

        // Same for clock times: the command's time is the only one that
        // counts.
        reconciled.time = context.sourceTime ?? ""
        if case .invalid = GeneratedDateTimeValidator.validateTime(reconciled.time) {
            reconciled.time = ""
        }
        if reconciled.date != action.date || reconciled.time != action.time {
            firedRules.append(RuleID.temporalCorrection)
        }
    }

    /// Salutations the model habitually prepends to a routed draft.
    /// Stripped before the clause-echo comparison so "Hi amma, text this
    /// to me now" is recognized as an instruction echoed back with a
    /// greeting, not a real message.
    private static let greetingWords: Set<String> = [
        "hi", "hey", "hello", "yo", "greetings", "howdy",
    ]

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
        // Grounding reads the contact and the draft — what the action would
        // actually do — not the summary label or the location: "Event:" and
        // an invented "Meeting Room" are the model's own words, and judging
        // them against the command sank legitimate actions.
        let actionWords = contentWords(in: "\(action.contactName) \(action.draftContent)")
        // An action with no content words of its own can't be judged;
        // keep it and let the user's review be the filter.
        guard !actionWords.isEmpty else {
            return true
        }
        // One shared word is not grounding: a fabricated "hi amma how are
        // you" card slipped through on "amma" alone when a capture merely
        // mentioned her. A wordy action must share at least two content
        // words with the command; a one- or two-word action still only
        // needs what it has.
        let required = min(2, actionWords.count)
        return actionWords.intersection(sourceWords).count >= required
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
