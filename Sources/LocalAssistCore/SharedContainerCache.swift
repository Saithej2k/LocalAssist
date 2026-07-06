import Foundation

/// Caches the outcome of the App Group container lookup.
///
/// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` makes
/// an XPC call into containermanagerd. On builds without the App Group
/// entitlement (unsigned Xcode runs, tests, the CLI) the call takes about
/// one second to time out before returning nil. Calling it on every history
/// read, record, and Spotlight donation stacked those timeouts into the UI
/// as a multi-second hang; this cache resolves the lookup once and hands
/// out the memoized answer forever after.
enum SharedContainerCache {
    private static let lock = NSLock()
    // Serialized behind `lock`; the nonisolated(unsafe) escape hatch is
    // Swift 6's supported pattern for lock-guarded mutable statics.
    private nonisolated(unsafe) static var didResolve = false
    private nonisolated(unsafe) static var resolvedURL: URL?

    /// The full run-history file URL inside the app-group container, or nil
    /// if the container is unavailable to this build.
    static func resolvedFileURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        if !didResolve {
            didResolve = true
            resolvedURL = resolveContainer()
        }
        return resolvedURL
    }

    private static func resolveContainer() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: RunHistoryStore.appGroupIdentifier
        ) else {
            return nil
        }

        let directory = container.appendingPathComponent("LocalAssist", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("run-history.json")

        // First run inside a signed app: seed the shared store with any
        // previously-collected local history so the widget sees it too.
        if !FileManager.default.fileExists(atPath: fileURL.path),
           let legacy = RunHistoryStore.applicationSupportOrNil(),
           FileManager.default.fileExists(atPath: legacy.fileURL.path) {
            try? FileManager.default.copyItem(at: legacy.fileURL, to: fileURL)
        }

        return fileURL
    }
}
