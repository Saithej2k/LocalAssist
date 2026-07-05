import AppIntents
import Foundation
import LocalAssistCore
import LocalAssistFoundationModels
import LocalAssistSystemTools
import SwiftUI

/// Summarizes text, picks the best reminder candidate, shows an interactive
/// snippet for confirmation right in Siri/Spotlight/Shortcuts, and — only
/// after the user confirms — writes a real reminder through EventKit.
public struct CreateReminderIntent: AppIntent {
    public static let title: LocalizedStringResource = "Create Reminder with LocalAssist"
    public static let description = IntentDescription(
        "Find the most important task in your text and add it to Reminders after confirmation.",
        categoryName: "Actions"
    )

    @Parameter(title: "Text")
    public var text: String

    @Parameter(title: "Maximum Suggestions", default: 5)
    public var maxSuggestions: Int

    public init() {}

    public init(text: String, maxSuggestions: Int = 5) {
        self.text = text
        self.maxSuggestions = maxSuggestions
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let service = LocalAssistLiveFactory.makeService()
        let summary = try await service.summarize(
            AssistantRequest(sourceText: text, maxSuggestions: maxSuggestions)
        )

        guard let draft = summary.actionDrafts.first(where: { $0.kind == .reminder })
            ?? summary.actionDrafts.first(where: { $0.requiresConfirmation })
        else {
            return .result(
                value: "No reminder-worthy task was found.",
                dialog: "I didn't find a task worth reminding you about."
            )
        }

        let reminderTitle = draft.payload["title"] ?? draft.title
        let dueText = draft.payload["dueDate"] ?? draft.payload["dueHint"]

        // Confirmation happens where the intent runs — Siri, Spotlight, or
        // Shortcuts — with an interactive snippet card. Cancelling throws and
        // nothing is written.
        try await requestConfirmation(
            dialog: IntentDialog("Add “\(reminderTitle)” to Reminders?"),
            snippetIntent: ReminderPreviewSnippetIntent(
                reminderTitle: reminderTitle,
                dueText: dueText
            )
        )

        let prepared = try await DraftOnlyToolActionPreparer().prepare(draft)
        let executor: any ToolActionExecuting
        #if canImport(EventKit)
            executor = SystemActionExecutor.live()
        #else
            executor = SimulatedActionExecutor()
        #endif

        let executed = try await executor.execute(prepared)
        return .result(
            value: executed.detail,
            dialog: IntentDialog("\(executed.detail)")
        )
    }
}

/// Interactive snippet card rendered inside Siri/Spotlight during
/// confirmation. Snippet intents re-run to refresh their view, so all state
/// arrives through parameters.
public struct ReminderPreviewSnippetIntent: SnippetIntent {
    public static let title: LocalizedStringResource = "Reminder Preview"
    public static let description = IntentDescription("Shows the reminder that is about to be created.")

    @Parameter(title: "Reminder Title")
    public var reminderTitle: String

    @Parameter(title: "Due")
    public var dueText: String?

    public init() {}

    public init(reminderTitle: String, dueText: String?) {
        self.reminderTitle = reminderTitle
        self.dueText = dueText
    }

    public func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: ReminderPreviewSnippetView(title: reminderTitle, dueText: dueText))
    }
}

struct ReminderPreviewSnippetView: View {
    var title: String
    var dueText: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let dueText, !dueText.isEmpty {
                    Label(dueText, systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("Created privately on device")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}
