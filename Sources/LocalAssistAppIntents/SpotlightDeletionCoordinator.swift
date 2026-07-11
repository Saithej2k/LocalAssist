import AppIntents
import Foundation
import LocalAssistCore
import OSLog

/// Seam over the Spotlight index so deletion logic is testable without
/// CoreSpotlight, and so `RunHistoryStore` never performs index I/O itself:
/// the store owns durable tombstones, this owns the index round trip.
public protocol SpotlightRunIndexing: Sendable {
    /// Removes the entities with these run IDs from the index. Throwing
    /// means "nothing was confirmed deleted" — the coordinator keeps the
    /// tombstones and retries at next launch.
    func deleteEntities(runIDs: [String]) async throws
}

#if canImport(CoreSpotlight)
    import CoreSpotlight

    /// The real index, using the exact entity-identified deletion API so
    /// Spotlight and Siri drop the same records the donation created.
    public struct LiveSpotlightRunIndexer: SpotlightRunIndexing {
        public init() {}

        public func deleteEntities(runIDs: [String]) async throws {
            try await CSSearchableIndex.default().deleteAppEntities(
                identifiedBy: runIDs,
                ofType: AssistantRunEntity.self
            )
        }
    }
#endif

/// Drains the Spotlight tombstone outbox: deletes pending entities from the
/// index and acknowledges the tombstones only on confirmed success. Failure
/// keeps them durable for the next launch — an index entry can outlive the
/// deleted run only until the next successful pass, and entity queries
/// filter tombstoned IDs so it is never *visible* even in that window.
public struct SpotlightDeletionCoordinator: Sendable {
    private static let log = Logger(subsystem: "com.saithej.localassist", category: "Spotlight")

    private let store: RunHistoryStore
    private let indexer: any SpotlightRunIndexing

    public init(store: RunHistoryStore, indexer: any SpotlightRunIndexing) {
        self.store = store
        self.indexer = indexer
    }

    /// Processes every pending deletion. Call at launch (retry path) and
    /// after any local deletion (prompt path). Returns the IDs confirmed
    /// deleted, for tests and logs.
    @discardableResult
    public func processPending() async -> [String] {
        let pending = await store.pendingSpotlightDeletions()
        guard !pending.isEmpty else {
            return []
        }
        let runIDs = pending.map(\.runID)
        do {
            try await indexer.deleteEntities(runIDs: runIDs)
            try await store.acknowledgeSpotlightDeletions(runIDs)
            Self.log.info("spotlight outbox drained: \(runIDs.count) deletions confirmed")
            return runIDs
        } catch {
            // Tombstones stay; next launch retries. IDs only — no content.
            Self.log.error("""
            spotlight deletion failed for \(runIDs.count) runs, will retry at launch: \
            \(String(describing: error), privacy: .public)
            """)
            return []
        }
    }
}

#if canImport(CoreSpotlight)
    public extension SpotlightDeletionCoordinator {
        /// Coordinator over the shared history store and the real index.
        static func live() -> SpotlightDeletionCoordinator? {
            guard let store = RunHistoryStore.sharedOrLocal() else {
                return nil
            }
            return SpotlightDeletionCoordinator(store: store, indexer: LiveSpotlightRunIndexer())
        }
    }
#endif
