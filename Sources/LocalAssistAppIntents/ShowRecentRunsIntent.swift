import AppIntents
import LocalAssistCore

@available(macOS 13.0, iOS 16.0, *)
public struct ShowRecentRunsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show LocalAssist Runs"
    public static let description = IntentDescription(
        "Show recent private LocalAssist summaries and latency metrics saved on this device."
    )

    @Parameter(title: "Limit", default: 3)
    public var limit: Int

    public init() {}

    public init(limit: Int = 3) {
        self.limit = limit
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let store = RunHistoryStore.applicationSupportOrNil(limit: 50) else {
            return .result(value: "Run history is unavailable on this device.")
        }

        let runs = try await store.load()
        guard !runs.isEmpty else {
            return .result(value: "No LocalAssist runs have been saved yet.")
        }

        let safeLimit = min(max(limit, 1), 5)
        let lines = runs.prefix(safeLimit).enumerated().map { index, run in
            let source = run.summary.source == .foundationModels ? "model" : "fallback"
            let latency = run.metrics.durationMilliseconds.formatted(.number.precision(.fractionLength(0)))
            return "\(index + 1). \(run.summary.overview) [\(source), \(latency) ms]"
        }

        return .result(value: lines.joined(separator: "\n"))
    }
}
