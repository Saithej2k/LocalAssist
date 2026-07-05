import Foundation
import LocalAssistCore

/// One fixed input with machine-checkable expectations about the summary.
public struct EvalCase: Identifiable, Sendable {
    /// Keywords that must all appear (case-insensitive) in a single
    /// suggestion title for the expected task to count as recalled.
    public struct ExpectedTask: Sendable {
        public var keywords: [String]
        public var dueHintContains: String?
        public var action: SuggestedAction?

        public init(keywords: [String], dueHintContains: String? = nil, action: SuggestedAction? = nil) {
            self.keywords = keywords
            self.dueHintContains = dueHintContains
            self.action = action
        }
    }

    public var id: String
    public var input: String
    public var maxSuggestions: Int
    public var expectedTasks: [ExpectedTask]
    /// Phrases that must NOT appear anywhere in the output — hallucination probes.
    public var forbiddenPhrases: [String]

    public init(
        id: String,
        input: String,
        maxSuggestions: Int = 5,
        expectedTasks: [ExpectedTask],
        forbiddenPhrases: [String] = []
    ) {
        self.id = id
        self.input = input
        self.maxSuggestions = maxSuggestions
        self.expectedTasks = expectedTasks
        self.forbiddenPhrases = forbiddenPhrases
    }
}

public enum EvalDataset {
    /// Fixed, versioned dataset. Add cases; never mutate existing ones, so
    /// score history in docs/evals stays comparable across runs.
    public static let standard: [EvalCase] = [
        EvalCase(
            id: "blockers-message",
            input: "Review the onboarding doc, send Mira the blockers by Friday, and schedule a design sync next week.",
            expectedTasks: [
                .init(keywords: ["send", "mira"], dueHintContains: "friday", action: .messageDraft),
                .init(keywords: ["schedule", "design", "sync"], dueHintContains: "next week", action: .calendarHold),
                .init(keywords: ["review", "onboarding"]),
            ]
        ),
        EvalCase(
            id: "urgent-deadline",
            input: "Finish the quarterly report asap. Email finance the draft numbers tomorrow.",
            expectedTasks: [
                .init(keywords: ["finish", "report"]),
                .init(keywords: ["email", "finance"], dueHintContains: "tomorrow", action: .messageDraft),
            ]
        ),
        EvalCase(
            id: "checklist-update",
            input: "Update the launch checklist before the beta ships. Add the new QA steps and check the crash dashboards.",
            expectedTasks: [
                .init(keywords: ["update", "checklist"]),
                .init(keywords: ["add", "qa"]),
                .init(keywords: ["check", "crash"]),
            ]
        ),
        EvalCase(
            id: "meeting-notes",
            input: """
            Standup notes: infra migration is blocked on the auth token rollout. \
            Priya will share the runbook. Book a war room for Thursday and follow up with the platform team.
            """,
            expectedTasks: [
                .init(keywords: ["book", "war room"], dueHintContains: "thursday", action: .calendarHold),
                .init(keywords: ["follow", "platform"]),
            ],
            forbiddenPhrases: ["Mira"]
        ),
        EvalCase(
            id: "single-task",
            input: "Call the vendor about the renewed contract terms today.",
            maxSuggestions: 3,
            expectedTasks: [
                .init(keywords: ["call", "vendor"], dueHintContains: "today"),
            ]
        ),
        EvalCase(
            id: "bullet-list",
            input: """
            - draft release notes for 2.4
            - send the beta invite email on Monday
            - review open crash reports
            """,
            expectedTasks: [
                .init(keywords: ["draft", "release notes"]),
                .init(keywords: ["send", "invite"], dueHintContains: "monday", action: .messageDraft),
                .init(keywords: ["review", "crash"]),
            ]
        ),
        EvalCase(
            id: "no-deadline",
            input: "Prepare interview questions for the platform engineer role and share them with the panel.",
            expectedTasks: [
                .init(keywords: ["prepare", "interview"]),
                .init(keywords: ["share", "panel"]),
            ]
        ),
        EvalCase(
            id: "mixed-noise",
            input: """
            Lunch was great. Weather is nice. Ship the hotfix build tonight and confirm the rollout with Dana. \
            Maybe we should think about the offsite sometime.
            """,
            expectedTasks: [
                .init(keywords: ["ship", "hotfix"], dueHintContains: "tonight"),
                .init(keywords: ["confirm", "dana"]),
            ]
        ),
    ]
}
