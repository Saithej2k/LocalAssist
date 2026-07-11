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

    func testRunProducesOnlyWarmSamplesAfterUnmeasuredWarmup() async {
        let before = ProcessGenerationRegistry.generationsStarted()
        let report = await DeviceMeasurementHarness.run(
            configuration: .init(repetitions: 1, useModel: false),
            worker: await measurementWorker()
        )
        // Deterministic engine: every case succeeds; failure list exists
        // and is empty — the field is part of the contract, not pruned.
        XCTAssertEqual(report.samples.count, EvalDataset.standard.count)
        XCTAssertTrue(report.failedSamples.isEmpty)
        // The warmup consumed the session-cold generation, so the claim
        // "N warm runs" is honest: every sample is warm, none mislabeled.
        XCTAssertTrue(report.unmeasuredWarmupPerformed)
        XCTAssertTrue(report.samples.allSatisfy { $0.cohort == .warm })
        // Warmup generation + one per case hit the process registry.
        XCTAssertGreaterThanOrEqual(
            ProcessGenerationRegistry.generationsStarted() - before,
            EvalDataset.standard.count + 1
        )
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

    // MARK: - Campaign store

    private func withCleanCampaignStore(_ body: () async throws -> Void) async rethrows {
        let files = [ColdLaunchCampaignStore.campaignURL, ColdLaunchCampaignStore.recordsURL]
        let saved = files.map { try? Data(contentsOf: $0) }
        try? ColdLaunchCampaignStore.reset()
        defer {
            try? ColdLaunchCampaignStore.reset()
            for (url, data) in zip(files, saved) {
                if let data {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
        try await body()
    }

    private func sample(source: GenerationSource) -> DeviceMeasurementHarness.Sample {
        DeviceMeasurementHarness.Sample(
            caseID: "blockers-message",
            repetition: 0,
            cohort: .processCold,
            timeToFirstPartialMilliseconds: 812,
            generationCompletedMilliseconds: 1_900,
            actionReviewReadyMilliseconds: 2_050,
            source: source,
            footprintMB: 182.5
        )
    }

    private func record(
        campaignID: String,
        expected: GenerationSource,
        classification: ColdLaunchCampaignStore.Classification,
        source: GenerationSource = .foundationModels
    ) -> ColdLaunchCampaignStore.Record {
        ColdLaunchCampaignStore.Record(
            campaignID: campaignID,
            recordedAt: Date(),
            environment: .current(coldStart: true),
            expectedSource: expected,
            classification: classification,
            sample: classification == .failure ? nil : sample(source: source),
            failure: classification == .failure
                ? DeviceMeasurementHarness.FailedSample(
                    caseID: "blockers-message", repetition: 0,
                    cohort: .processCold, failureCategory: "timedOut"
                )
                : nil
        )
    }

    func testCampaignLifecycleBeginResetFinalize() async throws {
        try await withCleanCampaignStore {
            XCTAssertNil(ColdLaunchCampaignStore.active())
            let campaign = try ColdLaunchCampaignStore.begin(expectedSource: .foundationModels)
            XCTAssertEqual(ColdLaunchCampaignStore.active()?.id, campaign.id)
            XCTAssertFalse(campaign.environment.deviceModel.isEmpty)
            XCTAssertFalse(campaign.environment.osVersion.isEmpty)

            // A second begin must fail — conditions never mutate mid-campaign.
            XCTAssertThrowsError(try ColdLaunchCampaignStore.begin(expectedSource: .foundationModels)) {
                XCTAssertEqual($0 as? ColdLaunchCampaignStore.CampaignError, .activeCampaignExists)
            }

            try ColdLaunchCampaignStore.append(
                self.record(campaignID: campaign.id, expected: .foundationModels, classification: .sample)
            )
            let (finalized, records) = try ColdLaunchCampaignStore.finalize()
            XCTAssertEqual(finalized.id, campaign.id)
            XCTAssertEqual(records.count, 1)
            XCTAssertNil(ColdLaunchCampaignStore.active(), "finalize closes the campaign")
        }
    }

    func testAppendIsThrowingAndValidatesCampaign() async throws {
        try await withCleanCampaignStore {
            // No active campaign: append throws instead of silently writing.
            XCTAssertThrowsError(try ColdLaunchCampaignStore.append(
                self.record(campaignID: "ghost", expected: .foundationModels, classification: .sample)
            )) {
                XCTAssertEqual($0 as? ColdLaunchCampaignStore.CampaignError, .noActiveCampaign)
            }

            let campaign = try ColdLaunchCampaignStore.begin(expectedSource: .foundationModels)
            XCTAssertThrowsError(try ColdLaunchCampaignStore.append(
                self.record(campaignID: "someone-else", expected: .foundationModels, classification: .sample)
            )) {
                XCTAssertEqual(
                    $0 as? ColdLaunchCampaignStore.CampaignError,
                    .recordBelongsToDifferentCampaign
                )
            }
            try ColdLaunchCampaignStore.append(
                self.record(campaignID: campaign.id, expected: .foundationModels, classification: .sample)
            )
            XCTAssertEqual(ColdLaunchCampaignStore.records(for: campaign).count, 1)
        }
    }

    func testForeignCampaignRecordsNeverFold() async throws {
        try await withCleanCampaignStore {
            let campaign = try ColdLaunchCampaignStore.begin(expectedSource: .foundationModels)
            try ColdLaunchCampaignStore.append(
                self.record(campaignID: campaign.id, expected: .foundationModels, classification: .sample)
            )
            // Simulate a stale line from an older campaign on disk.
            var stale = try JSONEncoder().encode(
                self.record(campaignID: "old-campaign", expected: .foundationModels, classification: .sample)
            )
            stale.append(Data("\n".utf8))
            let handle = try FileHandle(forWritingTo: ColdLaunchCampaignStore.recordsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: stale)
            try handle.close()

            XCTAssertEqual(
                ColdLaunchCampaignStore.records(for: campaign).count, 1,
                "records from other campaigns are excluded, never averaged in"
            )
        }
    }

    func testSummaryClassifiesUnexpectedSourceAndFailuresSeparately() async throws {
        try await withCleanCampaignStore {
            let campaign = try ColdLaunchCampaignStore.begin(expectedSource: .foundationModels)
            try ColdLaunchCampaignStore.append(self.record(
                campaignID: campaign.id, expected: .foundationModels, classification: .sample
            ))
            try ColdLaunchCampaignStore.append(self.record(
                campaignID: campaign.id, expected: .foundationModels,
                classification: .unexpectedSource, source: .deterministicFallback
            ))
            try ColdLaunchCampaignStore.append(self.record(
                campaignID: campaign.id, expected: .foundationModels, classification: .failure
            ))

            let summary = try XCTUnwrap(ColdLaunchCampaignStore.summaryOfActiveCampaign())
            XCTAssertEqual(summary.samples.count, 1)
            XCTAssertEqual(summary.unexpectedSourceSamples.count, 1)
            XCTAssertEqual(
                summary.unexpectedSourceSamples.first?.source, .deterministicFallback,
                "a fallback answer in a model campaign is kept but never counted as a cold model sample"
            )
            XCTAssertEqual(summary.failures.count, 1)
            XCTAssertEqual(summary.failures.first?.failureCategory, "timedOut")
        }
    }

    func testReportEmbedsActiveCampaignOnly() async throws {
        try await withCleanCampaignStore {
            let campaign = try ColdLaunchCampaignStore.begin(expectedSource: .deterministicFallback)
            try ColdLaunchCampaignStore.append(self.record(
                campaignID: campaign.id, expected: .deterministicFallback,
                classification: .sample, source: .deterministicFallback
            ))

            let report = await DeviceMeasurementHarness.run(
                configuration: .init(repetitions: 1, useModel: false),
                worker: await measurementWorker()
            )
            let embedded = try XCTUnwrap(report.coldLaunchCampaign)
            XCTAssertEqual(embedded.campaign.id, campaign.id)
            XCTAssertEqual(embedded.samples.count, 1)
        }
    }
}
