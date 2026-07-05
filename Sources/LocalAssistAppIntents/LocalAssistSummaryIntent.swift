import AppIntents
import LocalAssistCore
import LocalAssistFoundationModels

public struct LocalAssistSummaryIntent: AppIntent {
    public static let title: LocalizedStringResource = "Summarize My Notes"
    public static let description = IntentDescription(
        "Generate a private on-device summary with suggested follow-up tasks.",
        categoryName: "Summaries",
        resultValueName: "Summary"
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

    public func perform() async throws -> some IntentResult & ReturnsValue<AssistantRunEntity> & ProvidesDialog {
        let service = LocalAssistLiveFactory.makeService()
        let run = try await service.summarizeWithMetrics(
            AssistantRequest(sourceText: text, maxSuggestions: maxSuggestions)
        )

        // Persist so the entity is queryable later and shows up in history.
        if let store = RunHistoryStore.applicationSupportOrNil() {
            _ = try? await store.append(run)
        }

        let entity = AssistantRunEntity(run: run)
        return .result(
            value: entity,
            dialog: IntentDialog(
                full: "\(run.summary.headline) I found \(run.summary.tasks.count) follow-up tasks.",
                supporting: "Summarized privately on device."
            )
        )
    }
}
