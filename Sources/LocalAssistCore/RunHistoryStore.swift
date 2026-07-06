import Foundation

public actor RunHistoryStore {
    public nonisolated let fileURL: URL
    public nonisolated let limit: Int

    public init(fileURL: URL, limit: Int = 50) {
        self.fileURL = fileURL
        self.limit = limit
    }

    public static func applicationSupport(limit: Int = 50) throws -> RunHistoryStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("LocalAssist", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        return RunHistoryStore(
            fileURL: directory.appendingPathComponent("run-history.json"),
            limit: limit
        )
    }

    public static func applicationSupportOrNil(limit: Int = 50) -> RunHistoryStore? {
        try? applicationSupport(limit: limit)
    }

    /// App-group identifier shared with the widget and share extensions.
    public static let appGroupIdentifier = "group.com.saithej.localassist"

    /// Whether the app-group container is actually provisioned for this
    /// build. Free personal teams often fail to provision the group;
    /// callers use this to skip group-scoped APIs that would otherwise
    /// log cfprefsd complaints and silently no-op.
    public static var isSharedContainerAvailable: Bool {
        SharedContainerCache.resolvedFileURL() != nil
    }

    /// Share-extension handoff file inside the app-group container, next to
    /// the history store. A plain file instead of group `UserDefaults`:
    /// merely touching a group preferences suite makes cfprefsd log a
    /// kCFPreferencesAnyUser complaint on device, provisioned or not.
    /// The name must match what `ShareViewController` writes.
    public static var pendingCaptureFileURL: URL? {
        SharedContainerCache.resolvedFileURL()?
            .deletingLastPathComponent()
            .appendingPathComponent("pending-capture.txt")
    }

    /// Preferred store: the app-group container so widgets and extensions can
    /// read the same history. Falls back to Application Support when the
    /// group container is unavailable (tests, CLI, unsigned builds), with a
    /// one-time migration of legacy history into the shared container.
    ///
    /// The app-group container lookup is an XPC call into containermanagerd
    /// that takes ~1 second to time out on unsigned/unprovisioned builds.
    /// The result is cached so we pay that cost at most once per process.
    public static func sharedOrLocal(limit: Int = 50) -> RunHistoryStore? {
        if let cachedURL = SharedContainerCache.resolvedFileURL() {
            return RunHistoryStore(fileURL: cachedURL, limit: limit)
        }
        return applicationSupportOrNil(limit: limit)
    }

    public func load() throws -> [AssistantRun] {
        let signposter = LocalAssistInstrumentation.historySignposter()
        let state = signposter.beginInterval("Load run history")
        defer {
            signposter.endInterval("Load run history", state)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AssistantRun].self, from: data)
    }

    @discardableResult
    public func append(_ run: AssistantRun) throws -> [AssistantRun] {
        var runs = try load()
        runs.insert(run, at: 0)
        if runs.count > limit {
            runs = Array(runs.prefix(limit))
        }
        try save(runs)
        return runs
    }

    public func save(_ runs: [AssistantRun]) throws {
        let signposter = LocalAssistInstrumentation.historySignposter()
        let state = signposter.beginInterval("Save run history")
        defer {
            signposter.endInterval("Save run history", state)
        }

        let trimmed = Array(runs.prefix(limit))
        let data = try exportData(trimmed)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Toggles a task's done-state inside a stored run and persists it.
    /// Returns the updated history (newest first).
    @discardableResult
    public func setTask(
        _ taskID: String,
        completed: Bool,
        inRun runID: String
    ) throws -> [AssistantRun] {
        var runs = try load()
        guard let index = runs.firstIndex(where: { $0.id == runID }) else {
            return runs
        }
        if completed {
            runs[index].completedTaskIDs.insert(taskID)
        } else {
            runs[index].completedTaskIDs.remove(taskID)
        }
        try save(runs)
        return runs
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public func aggregate() throws -> AggregateRunMetrics {
        AggregateRunMetrics(runs: try load())
    }

    public func exportData(_ runs: [AssistantRun]? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(runs ?? load())
    }
}
