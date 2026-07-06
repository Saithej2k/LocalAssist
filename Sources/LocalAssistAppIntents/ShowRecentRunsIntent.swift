import AppIntents
import LocalAssistCore

public struct ShowRecentRunsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show LocalAssist Runs"
    public static let description = IntentDescription(
        "Show recent private LocalAssist summaries and latency metrics saved on this device.",
        categoryName: "Summaries",
        resultValueName: "Recent Summaries"
    )

    @Parameter(title: "Limit", default: 3)
    public var limit: Int

    public init() {}

    public init(limit: Int = 3) {
        self.limit = limit
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[AssistantRunEntity]> & ProvidesDialog {
        guard let store = RunHistoryStore.sharedOrLocal(limit: 50) else {
            return .result(value: [], dialog: "Run history is unavailable on this device.")
        }

        let runs = try await store.load()
        guard !runs.isEmpty else {
            return .result(value: [], dialog: "No LocalAssist runs have been saved yet.")
        }

        let safeLimit = min(max(limit, 1), 5)
        let entities = runs.prefix(safeLimit).map(AssistantRunEntity.init(run:))
        let latency = runs.prefix(safeLimit)
            .map { $0.metrics.durationMilliseconds }
            .reduce(0, +) / Double(min(safeLimit, runs.count))
        let latencyText = latency.formatted(.number.precision(.fractionLength(0)))

        return .result(
            value: Array(entities),
            dialog: IntentDialog(
                full: "Here are your last \(entities.count) summaries. Average latency was \(latencyText) milliseconds.",
                supporting: "All processing stayed on this device."
            )
        )
    }
}
