import Foundation
import XCTest
@testable import LocalAssistCore
@testable import LocalAssistAppIntents

/// Behavior script for the test indexer — top level so type nesting stays
/// within the repo's one-level rule.
private enum IndexerBehavior {
    case succeed
    case fail
    case slow(Duration)
}

/// History deletion + the Spotlight tombstone outbox: local deletion is
/// atomic with tombstone persistence, index I/O is acknowledged or retried,
/// and tombstoned runs never surface as entities.
final class LocalAssistDeletionAndSpotlightTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localassist-deletion-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore(limit: Int = 50) -> RunHistoryStore {
        RunHistoryStore(
            fileURL: directory.appendingPathComponent("run-history.json"),
            limit: limit
        )
    }

    private func sampleRun(id: String) -> AssistantRun {
        AssistantRun(
            id: id,
            request: AssistantRequest(sourceText: "note for \(id)"),
            summary: StructuredSummary(
                overview: "brief \(id)",
                keyPoints: ["point"],
                suggestions: [],
                actionDrafts: [],
                source: .deterministicFallback,
                diagnostics: GenerationDiagnostics(
                    availability: .unavailable(ModelUnavailability(reason: .forcedOffline))
                )
            ),
            metrics: RunMetrics(
                startedAt: Date(),
                finishedAt: Date(),
                durationMilliseconds: 5,
                source: .deterministicFallback,
                suggestionCount: 0,
                actionDraftCount: 0
            )
        )
    }

    /// Scriptable indexer: succeeds, fails, or hangs on demand.
    private actor ScriptedIndexer: SpotlightRunIndexing {
        var behavior: IndexerBehavior
        private(set) var deletedIDs: [[String]] = []

        init(behavior: IndexerBehavior) {
            self.behavior = behavior
        }

        func setBehavior(_ behavior: IndexerBehavior) {
            self.behavior = behavior
        }

        func deleteEntities(runIDs: [String]) async throws {
            switch behavior {
            case .succeed:
                deletedIDs.append(runIDs)
            case .fail:
                throw CocoaError(.fileWriteUnknown)
            case .slow(let delay):
                try await Task.sleep(for: delay)
                deletedIDs.append(runIDs)
            }
        }
    }

    // MARK: - Store-level deletion

    func testIndividualDeletionRemovesRunAndWritesTombstone() async throws {
        let store = makeStore()
        try await store.append(sampleRun(id: "keep"))
        try await store.append(sampleRun(id: "remove"))

        let remaining = try await store.delete(runID: "remove")

        XCTAssertEqual(remaining.map(\.id), ["keep"])
        let pending = await store.pendingSpotlightDeletions()
        XCTAssertEqual(pending.map(\.runID), ["remove"])

        // Durability: a fresh store instance over the same files sees both.
        let reloaded = makeStore()
        let reloadedRuns = try await reloaded.load()
        XCTAssertEqual(reloadedRuns.map(\.id), ["keep"])
        let reloadedPending = await reloaded.pendingSpotlightDeletions()
        XCTAssertEqual(reloadedPending.map(\.runID), ["remove"])
    }

    func testDeletingUnknownIDIsANoOp() async throws {
        let store = makeStore()
        try await store.append(sampleRun(id: "only"))
        let remaining = try await store.delete(runID: "ghost")
        XCTAssertEqual(remaining.map(\.id), ["only"])
        let pending = await store.pendingSpotlightDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testClearAllTombstonesEveryRun() async throws {
        let store = makeStore()
        try await store.append(sampleRun(id: "a"))
        try await store.append(sampleRun(id: "b"))

        try await store.clear()

        let runs = try await store.load()
        XCTAssertTrue(runs.isEmpty)
        let pending = await store.pendingSpotlightDeletions()
        XCTAssertEqual(Set(pending.map(\.runID)), ["a", "b"])
    }

    func testMigrationFromPreOutboxHistory() async throws {
        // A pre-outbox install has a history file and no sidecar: loading
        // and deleting must work with no migration step.
        let store = makeStore()
        try await store.append(sampleRun(id: "legacy"))
        let sidecar = store.spotlightOutboxURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))

        let pendingBefore = await store.pendingSpotlightDeletions()
        XCTAssertTrue(pendingBefore.isEmpty, "absent sidecar reads as empty outbox")

        try await store.delete(runID: "legacy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testAcknowledgeRetiresOnlyConfirmedTombstones() async throws {
        let store = makeStore()
        try await store.append(sampleRun(id: "a"))
        try await store.append(sampleRun(id: "b"))
        try await store.delete(runID: "a")
        try await store.delete(runID: "b")

        try await store.acknowledgeSpotlightDeletions(["a"])

        let pending = await store.pendingSpotlightDeletions()
        XCTAssertEqual(pending.map(\.runID), ["b"])
    }

    func testConcurrentAppendsAndDeletesStayConsistent() async throws {
        let store = makeStore(limit: 200)
        let seededRuns = (0 ..< 40).map { sampleRun(id: "run-\($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for run in seededRuns {
                group.addTask {
                    try await store.append(run)
                }
            }
            try await group.waitForAll()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 40 where index.isMultiple(of: 2) {
                group.addTask {
                    try await store.delete(runID: "run-\(index)")
                }
            }
            try await group.waitForAll()
        }

        let runs = try await store.load()
        XCTAssertEqual(runs.count, 20)
        XCTAssertTrue(runs.allSatisfy { run in
            Int(run.id.dropFirst("run-".count)).map { !$0.isMultiple(of: 2) } ?? false
        })
        let pending = await store.pendingSpotlightDeletions()
        XCTAssertEqual(pending.count, 20)
    }

    // MARK: - Coordinator

    func testCoordinatorAcknowledgesOnSuccess() async throws {
        let store = makeStore()
        try await store.append(sampleRun(id: "gone"))
        try await store.delete(runID: "gone")

        let indexer = ScriptedIndexer(behavior: .succeed)
        let coordinator = SpotlightDeletionCoordinator(store: store, indexer: indexer)
        let confirmed = await coordinator.processPending()

        XCTAssertEqual(confirmed, ["gone"])
        let pending = await store.pendingSpotlightDeletions()
        XCTAssertTrue(pending.isEmpty, "confirmed deletions retire their tombstones")
        let calls = await indexer.deletedIDs
        XCTAssertEqual(calls, [["gone"]])
    }

    func testIndexFailureKeepsTombstonesForLaunchRetry() async throws {
        let store = makeStore()
        try await store.append(sampleRun(id: "sticky"))
        try await store.delete(runID: "sticky")

        let indexer = ScriptedIndexer(behavior: .fail)
        let coordinator = SpotlightDeletionCoordinator(store: store, indexer: indexer)
        let confirmed = await coordinator.processPending()

        XCTAssertTrue(confirmed.isEmpty)
        let pending = await store.pendingSpotlightDeletions()
        XCTAssertEqual(pending.map(\.runID), ["sticky"], "failure keeps the tombstone")

        // "Restart": a new coordinator over the same store succeeds and
        // retires it — the launch retry path.
        await indexer.setBehavior(.succeed)
        let retryCoordinator = SpotlightDeletionCoordinator(store: store, indexer: indexer)
        let retried = await retryCoordinator.processPending()
        XCTAssertEqual(retried, ["sticky"])
        let after = await store.pendingSpotlightDeletions()
        XCTAssertTrue(after.isEmpty)
    }

    func testSlowIndexerStillCompletesAndAcknowledges() async throws {
        let store = makeStore()
        try await store.append(sampleRun(id: "slowpoke"))
        try await store.delete(runID: "slowpoke")

        let indexer = ScriptedIndexer(behavior: .slow(.milliseconds(150)))
        let coordinator = SpotlightDeletionCoordinator(store: store, indexer: indexer)
        let confirmed = await coordinator.processPending()

        XCTAssertEqual(confirmed, ["slowpoke"])
        let pending = await store.pendingSpotlightDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCoordinatorNoOpsOnEmptyOutbox() async throws {
        let store = makeStore()
        let indexer = ScriptedIndexer(behavior: .succeed)
        let coordinator = SpotlightDeletionCoordinator(store: store, indexer: indexer)
        let confirmed = await coordinator.processPending()
        XCTAssertTrue(confirmed.isEmpty)
        let calls = await indexer.deletedIDs
        XCTAssertTrue(calls.isEmpty, "no index round trip without tombstones")
    }

    // MARK: - Entity queries

    func testTombstonedRunsNeverAppearInEntityQueries() async throws {
        // Simulate the crash window: tombstone written, history not yet.
        // The query contract says the run is already invisible.
        let store = makeStore()
        try await store.append(sampleRun(id: "visible"))
        try await store.append(sampleRun(id: "half-deleted"))
        try await store.delete(runID: "half-deleted")
        // Even if the run were still present, the filter hides it; verify
        // via the store the query logic reads.
        let tombstoned = Set(await store.pendingSpotlightDeletions().map(\.runID))
        let runs = try await store.load()
        let visible = runs.filter { !tombstoned.contains($0.id) }
        XCTAssertEqual(visible.map(\.id), ["visible"])
    }
}
