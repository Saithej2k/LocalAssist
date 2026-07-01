import AppIntents
import LocalAssistCore
import LocalAssistFoundationModels

@available(macOS 13.0, iOS 16.0, *)
public struct CreateReminderDraftIntent: AppIntent {
    public static let title: LocalizedStringResource = "Draft Reminder with LocalAssist"
    public static let description = IntentDescription(
        "Summarize local text and stage the best reminder draft for confirmation."
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

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = LocalAssistLiveFactory.makeService()
        let summary = try await service.summarize(
            AssistantRequest(sourceText: text, maxSuggestions: maxSuggestions)
        )

        guard let reminderDraft = summary.actionDrafts.first(where: { $0.kind == .reminder })
            ?? summary.actionDrafts.first(where: { $0.requiresConfirmation })
        else {
            return .result(value: "No reminder-worthy task was found.")
        }

        let prepared = try await DraftOnlyToolActionPreparer().prepare(reminderDraft)
        let title = reminderDraft.payload["title"] ?? reminderDraft.title
        let dueHint = reminderDraft.payload["dueHint"].map { "\nDue: \($0)" } ?? ""
        return .result(value: "\(prepared.confirmationTitle)\n\(title)\(dueHint)\n\(prepared.confirmationMessage)")
    }
}
