import AppIntents
import LocalAssistCore
import LocalAssistFoundationModels

@available(macOS 13.0, iOS 16.0, *)
public struct LocalAssistSummaryIntent: AppIntent {
    public static let title: LocalizedStringResource = "Summarize with LocalAssist"
    public static let description = IntentDescription(
        "Generate a private on-device summary with suggested follow-up tasks."
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
        return .result(value: SummaryFormatter.plainText(summary))
    }
}
