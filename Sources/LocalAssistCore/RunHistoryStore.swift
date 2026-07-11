import Foundation

public actor RunHistoryStore {
    public nonisolated let fileURL: URL
    public nonisolated let limit: Int
    /// Decoded runs, newest first. Populated on the first `load` and kept
    /// in sync by every mutation on this actor. A full brief carries ~2 KB
    /// of JSON; decoding 50 of them on every append/setTask/aggregate was
    /// the whole cost of the disk round trip. Actor isolation makes the
    /// single-writer invariant free.
    private var cache: [AssistantRun]?

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
        if let cache {
            return cache
        }
        let runs = try loadFromDisk()
        cache = runs
        return runs
    }

    private func loadFromDisk() throws -> [AssistantRun] {
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
        cache = trimmed
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

    // MARK: - Deletion + Spotlight tombstones

    /// The Spotlight-deletion outbox lives in a sidecar file next to the
    /// history, so the history format itself is untouched — pre-outbox
    /// installs "migrate" by the sidecar simply not existing yet.
    public nonisolated var spotlightOutboxURL: URL {
        fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("spotlight-outbox.json")
    }

    /// A run the user deleted whose Spotlight entry has not been confirmed
    /// gone yet. IDs only, never content.
    public struct SpotlightTombstone: Codable, Equatable, Sendable {
        public var runID: String
        public var deletedAt: Date

        public init(runID: String, deletedAt: Date = Date()) {
            self.runID = runID
            self.deletedAt = deletedAt
        }
    }

    /// Deletes one run. Ordering is the crash-safety contract: the
    /// tombstone is durable BEFORE the run leaves the history file, so no
    /// crash window exists where a run is gone locally but its Spotlight
    /// entry has no record demanding cleanup. Spotlight I/O itself happens
    /// outside this actor (see `SpotlightDeletionCoordinator`); entity
    /// queries filter tombstoned IDs so a pending deletion is already
    /// invisible.
    @discardableResult
    public func delete(runID: String) throws -> [AssistantRun] {
        var runs = try load()
        guard runs.contains(where: { $0.id == runID }) else {
            return runs
        }
        var outbox = loadOutbox()
        if !outbox.contains(where: { $0.runID == runID }) {
            outbox.append(SpotlightTombstone(runID: runID))
        }
        try saveOutbox(outbox)
        runs.removeAll { $0.id == runID }
        try save(runs)
        return runs
    }

    /// Clear-all follows the same contract: every current run is
    /// tombstoned durably first, then the history file goes.
    public func clear() throws {
        let runs = (try? load()) ?? []
        if !runs.isEmpty {
            var outbox = loadOutbox()
            let known = Set(outbox.map(\.runID))
            for run in runs where !known.contains(run.id) {
                outbox.append(SpotlightTombstone(runID: run.id))
            }
            try saveOutbox(outbox)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        cache = []
    }

    /// Run IDs whose Spotlight entries still need deletion.
    public func pendingSpotlightDeletions() -> [SpotlightTombstone] {
        loadOutbox()
    }

    /// Acknowledges that Spotlight confirmed these deletions; their
    /// tombstones are retired. Failed IDs stay for the next launch retry.
    public func acknowledgeSpotlightDeletions(_ runIDs: [String]) throws {
        let acknowledged = Set(runIDs)
        let remaining = loadOutbox().filter { !acknowledged.contains($0.runID) }
        try saveOutbox(remaining)
    }

    private func loadOutbox() -> [SpotlightTombstone] {
        guard FileManager.default.fileExists(atPath: spotlightOutboxURL.path),
              let data = try? Data(contentsOf: spotlightOutboxURL),
              !data.isEmpty
        else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SpotlightTombstone].self, from: data)) ?? []
    }

    private func saveOutbox(_ outbox: [SpotlightTombstone]) throws {
        guard !outbox.isEmpty else {
            if FileManager.default.fileExists(atPath: spotlightOutboxURL.path) {
                try FileManager.default.removeItem(at: spotlightOutboxURL)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(outbox)
        try FileManager.default.createDirectory(
            at: spotlightOutboxURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: spotlightOutboxURL, options: [.atomic])
    }

    public func aggregate() throws -> AggregateRunMetrics {
        AggregateRunMetrics(runs: try load())
    }

    public func exportData(_ runs: [AssistantRun]? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = try runs ?? load()
        return try encoder.encode(payload)
    }
}
