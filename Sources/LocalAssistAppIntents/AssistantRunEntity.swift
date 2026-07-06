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

#if canImport(CoreSpotlight)
    import CoreSpotlight

    /// Briefs surface in Spotlight search today, and this is the exact
    /// integration Apple named for Siri personal context — third-party
    /// content joins via the Spotlight index.
    extension AssistantRunEntity: IndexedEntity {
        public var attributeSet: CSSearchableItemAttributeSet {
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = overview
            attributes.contentDescription = plainText
            attributes.keywords = taskTitles + ["LocalAssist", "brief", "tasks"]
            return attributes
        }
    }

    public enum LocalAssistSpotlight {
        /// Re-donates all saved briefs. Cheap (history is capped) and safe to
        /// call on every launch and after every new capture.
        public static func donateAll() async {
            guard let store = RunHistoryStore.sharedOrLocal(),
                  let runs = try? await store.load()
            else {
                return
            }
            let entities = runs.map(AssistantRunEntity.init(run:))
            try? await CSSearchableIndex.default().indexAppEntities(entities)
        }
    }
#endif

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
        guard let store = RunHistoryStore.sharedOrLocal() else {
            return []
        }
        return try await store.load()
    }
}
