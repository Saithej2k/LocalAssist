import Foundation
#if canImport(MetricKit) && os(iOS)
    import MetricKit
#endif

/// Privacy-preserving crash and hang diagnostics: MetricKit payloads are
/// written to local JSON files in the app's container and go nowhere else.
/// The same rule as everything in LocalAssist — even diagnostics never
/// leave the device. Inspect them via Xcode's container download, or delete
/// the folder to discard them.
public enum LocalDiagnostics {
    static let maxStoredPayloads = 20

    #if canImport(MetricKit) && os(iOS)
        private static let subscriber = Subscriber()

        public static func start() {
            MXMetricManager.shared.add(subscriber)
        }

        // Stateless — safe to share across the metric manager's queues.
        private final class Subscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
            func didReceive(_ payloads: [MXDiagnosticPayload]) {
                for payload in payloads {
                    LocalDiagnostics.store(payload.jsonRepresentation(), prefix: "diagnostic")
                }
            }

            func didReceive(_ payloads: [MXMetricPayload]) {
                for payload in payloads {
                    LocalDiagnostics.store(payload.jsonRepresentation(), prefix: "metrics")
                }
            }
        }
    #else
        public static func start() {}
    #endif

    static func store(_ data: Data, prefix: String, now: Date = Date()) {
        guard let directory = diagnosticsDirectory() else {
            return
        }
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = directory.appendingPathComponent("\(prefix)-\(stamp).json")
        try? data.write(to: fileURL, options: [.atomic])
        trim(directory: directory)
    }

    /// Application Support/LocalAssist/diagnostics — local, backed up with
    /// the device backup, never transmitted.
    static func diagnosticsDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let directory = base
            .appendingPathComponent("LocalAssist", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Oldest files beyond the cap are deleted so diagnostics can never
    /// grow unbounded.
    static func trim(directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
            files.count > maxStoredPayloads
        else {
            return
        }
        for stale in files.prefix(files.count - maxStoredPayloads) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
