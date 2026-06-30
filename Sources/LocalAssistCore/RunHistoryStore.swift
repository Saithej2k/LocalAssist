import Foundation

public actor RunHistoryStore {
    public let fileURL: URL
    public let limit: Int

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

    public func load() throws -> [AssistantRun] {
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
        let trimmed = Array(runs.prefix(limit))
        let data = try exportData(trimmed)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
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
