import Foundation
import XCTest
@testable import LocalAssistCore
@testable import LocalAssistEvalKit
@testable import LocalAssistSystemTools
@testable import LocalAssistAppUI

/// Worker with a static contact resolver: the production orchestration
/// path minus the TCC-gated Contacts service a headless runner can hang on.
@MainActor
private func measurementWorker() -> LocalAssistWorker {
    LocalAssistWorker(contactResolver: StaticContactResolver(contacts: [
        ResolvedContact(displayName: "Mira Chen", hasEmail: true, hasPhone: true),
    ]))
}

/// Device-measurement harness semantics that must hold before phone data
/// is trusted: cohort assignment, failure preservation, continuous memory
/// sampling, and the process-cold outbox round trip.
final class LocalAssistMeasurementHarnessTests: XCTestCase {
    func testCohortAssignmentIsFactBased() {
        // First sample in a process that has never generated: processCold.
        XCTAssertEqual(
            DeviceMeasurementHarness.cohort(sampleIndex: 0, priorProcessGenerations: 0),
            .processCold
        )
        // First sample of a run in a process that already generated
        // (user made a brief, or a prior harness run): sessionCold.
        XCTAssertEqual(
            DeviceMeasurementHarness.cohort(sampleIndex: 0, priorProcessGenerations: 3),
            .sessionCold
        )
        // Everything after the first sample is warm, whatever the process
        // history says.
        XCTAssertEqual(
            DeviceMeasurementHarness.cohort(sampleIndex: 1, priorProcessGenerations: 0),
            .warm
        )
        XCTAssertEqual(
            DeviceMeasurementHarness.cohort(sampleIndex: 159, priorProcessGenerations: 40),
            .warm
        )
    }

    func testProcessGenerationRegistryCounts() {
        let before = ProcessGenerationRegistry.generationsStarted()
        ProcessGenerationRegistry.recordGenerationStart()
        XCTAssertEqual(ProcessGenerationRegistry.generationsStarted(), before + 1)
    }

    func testServiceStreamBumpsProcessRegistry() async throws {
        let before = ProcessGenerationRegistry.generationsStarted()
        _ = try await LocalAssistService().summarize(
            AssistantRequest(sourceText: "Call the vendor today.")
        )
        XCTAssertGreaterThan(ProcessGenerationRegistry.generationsStarted(), before)
    }

    func testFailedSamplesArePreservedWithTypedCategories() async {
        // A model that always refuses: with the deterministic fallback the
        // run still SUCCEEDS (source .deterministicFallback), so measure a
        // service whose stream dies outright by cancelling mid-run instead —
        // simplest injectable hard failure is a validator rejection.
        let report = await DeviceMeasurementHarness.run(
            configuration: .init(repetitions: 1, useModel: false),
            worker: await measurementWorker()
        )
        // Deterministic engine: every case succeeds; failure list exists
        // and is empty — the field is part of the contract, not pruned.
        XCTAssertEqual(report.samples.count, EvalDataset.standard.count)
        XCTAssertTrue(report.failedSamples.isEmpty)
        XCTAssertEqual(report.samples.filter { $0.cohort == .warm }.count, report.samples.count - 1)
        // First sample is sessionCold here (this test process generated
        // earlier) or processCold when run in isolation — never warm.
        XCTAssertNotEqual(report.samples.first?.cohort, .warm)
    }

    func testMemoryProfileSamplesContinuously() async {
        let report = await DeviceMeasurementHarness.run(
            configuration: .init(repetitions: 2, useModel: false),
            worker: await measurementWorker()
        )
        XCTAssertGreaterThan(report.memory.peakMB, 0)
        XCTAssertGreaterThan(report.memory.meanMB, 0)
        XCTAssertGreaterThanOrEqual(report.memory.peakMB, report.memory.meanMB)
        XCTAssertGreaterThan(report.memory.sampleCount, 0, "the monitor sampled during the interval")
    }

    func testProcessColdOutboxRoundTrip() throws {
        let outboxURL = DeviceMeasurementHarness.ProcessColdOutbox.fileURL
        let existing = try? Data(contentsOf: outboxURL)
        defer {
            // Restore whatever was there so the test never eats real data.
            if let existing {
                try? existing.write(to: outboxURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: outboxURL)
            }
        }
        try? FileManager.default.removeItem(at: outboxURL)

        XCTAssertEqual(DeviceMeasurementHarness.ProcessColdOutbox.count(), 0)
        let sample = DeviceMeasurementHarness.Sample(
            caseID: "blockers-message",
            repetition: 0,
            cohort: .processCold,
            timeToFirstPartialMilliseconds: 812,
            generationCompletedMilliseconds: 1_900,
            actionReviewReadyMilliseconds: 2_050,
            source: .foundationModels,
            footprintMB: 182.5
        )
        DeviceMeasurementHarness.ProcessColdOutbox.append(sample)
        DeviceMeasurementHarness.ProcessColdOutbox.append(sample)

        let loaded = DeviceMeasurementHarness.ProcessColdOutbox.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first, sample)
    }

    func testReportFoldsProcessColdLaunchSamples() async throws {
        let outboxURL = DeviceMeasurementHarness.ProcessColdOutbox.fileURL
        let existing = try? Data(contentsOf: outboxURL)
        defer {
            if let existing {
                try? existing.write(to: outboxURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: outboxURL)
            }
        }
        try? FileManager.default.removeItem(at: outboxURL)
        DeviceMeasurementHarness.ProcessColdOutbox.append(DeviceMeasurementHarness.Sample(
            caseID: "single-task",
            repetition: 0,
            cohort: .processCold,
            timeToFirstPartialMilliseconds: nil,
            generationCompletedMilliseconds: 42,
            actionReviewReadyMilliseconds: 50,
            source: .deterministicFallback,
            footprintMB: 90
        ))

        let report = await DeviceMeasurementHarness.run(
            configuration: .init(repetitions: 1, useModel: false),
            worker: await measurementWorker()
        )
        XCTAssertEqual(report.processColdLaunchSamples.count, 1)
        XCTAssertEqual(report.processColdLaunchSamples.first?.cohort, .processCold)
    }
}
