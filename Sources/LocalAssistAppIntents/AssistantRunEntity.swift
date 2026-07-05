import AppIntents
import Foundation
import LocalAssistCore

/// Exposes saved runs as App Entities so Shortcuts can chain LocalAssist
/// output into other apps ("Summarize My Notes" → "Send Message"),
/// and Spotlight/Siri can reference specific summaries.
public struct AssistantRunEntity: AppEntity, Identifiable, Sendable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "LocalAssist Brief"
    public static let defaultQuery = AssistantRunQuery()

    public var id: String

    @Property(title: "Overview")
    public var overview: String

    @Property(title: "Key Points")
    public var keyPoints: [String]

    @Property(title: "Task Titles")
    public var taskTitles: [String]

    @Property(title: "Task Count")
    public var taskCount: Int

    @Property(title: "Generated With")
    public var source: String

    @Property(title: "Latency (ms)")
    public var latencyMilliseconds: Double

    @Property(title: "Plain Text")
    public var plainText: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(overview)",
            subtitle: "\(taskCount) tasks · \(source)"
        )
    }

    public init(run: AssistantRun) {
        id = run.id
        overview = run.summary.headline
        keyPoints = run.summary.keyPoints
        taskTitles = run.summary.suggestions.map(\.title)
        taskCount = run.summary.suggestions.count
        source = run.summary.source == .foundationModels ? "On-device model" : "Offline fallback"
        latencyMilliseconds = run.metrics.durationMilliseconds
        plainText = SummaryFormatter.plainText(run.summary)
    }
}

public struct AssistantRunQuery: EntityQuery, Sendable {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [AssistantRunEntity] {
        try await loadRuns()
            .filter { identifiers.contains($0.id) }
            .map(AssistantRunEntity.init(run:))
    }

    public func suggestedEntities() async throws -> [AssistantRunEntity] {
        try await loadRuns()
            .prefix(5)
            .map(AssistantRunEntity.init(run:))
    }

    private func loadRuns() async throws -> [AssistantRun] {
        guard let store = RunHistoryStore.applicationSupportOrNil() else {
            return []
        }
        return try await store.load()
    }
}
