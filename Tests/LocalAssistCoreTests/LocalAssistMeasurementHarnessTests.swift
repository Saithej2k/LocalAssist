import Foundation
import Synchronization
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

/// Model client whose stream dies with a cancellation — the one failure the
/// service rethrows instead of absorbing into the deterministic fallback,
/// so `summarize` genuinely throws.
private struct CancellingModelClient: StructuredModelClient {
    func availability() async -> ModelAvailability {
        .available
    }

    func streamSummary(for _: AssistantRequest) -> AsyncThrowingStream<StructuredSummaryPartial, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: CancellationError())
        }
    }
}

/// Warmup succeeds through the requested model, then every measured request
/// hits a typed model failure and completes through deterministic fallback.
/// This catches the old bug where those later responses entered model p95s.
private final class FirstSuccessThenFailureModelClient: StructuredModelClient, Sendable {
    private let callCount = Mutex(0)

    func availability() async -> ModelAvailability {
        .available
    }

    func streamSummary(for request: AssistantRequest) -> AsyncThrowingStream<StructuredSummaryPartial, Error> {
        let call = callCount.withLock { count in
            defer { count += 1 }
            return count
        }
        if call == 0 {
            let complete = StructuredSummaryPartial(
                overview: "A modeled warmup.",
                keyPoints: ["Warmup"],
                suggestions: [],
                isComplete: true
            )
            return StaticStructuredModelClient.completing(with: complete).streamSummary(for: request)
        }
        return StaticStructuredModelClient(
            failure: .guardrailViolation(detail: "scripted")
        ).streamSummary(for: request)
    }
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

    func testRunProducesOnlyWarmSamplesAfterSuccessfulWarmup() async {
        let before = ProcessGenerationRegistry.generationsStarted()
        let report = await DeviceMeasurementHarness.run(
            configuration: .init(repetitions: 1, useModel: false),
            worker: await measurementWorker()
        )
        // Deterministic engine: every case succeeds; failure list exists
        // and is empty — the field is part of the contract, not pruned.
        XCTAssertEqual(report.samples.count, EvalDataset.standard.count)
        XCTAssertTrue(report.failedSamples.isEmpty)
        // The warmup succeeded from the expected engine, so the claim
        // "N warm runs" is honest: every sample is warm, none mislabeled.
        XCTAssertEqual(report.warmupOutcome, .succeeded(source: .deterministicFallback))
        XCTAssertTrue(report.samples.allSatisfy { $0.cohort == .warm })
        // Warmup generation + one per case hit the process registry.
        XCTAssertGreaterThanOrEqual(
            ProcessGenerationRegistry.generationsStarted() - before,
            EvalDataset.standard.count + 1
        )
    }

    func testWrongSourceWarmupAbortsWarmCohort() async {
        // Configuration says Foundation Models, but the injected service
        // answers deterministically — the exact shape of measuring "warm
        // model latency" on a device where the model silently fell back.
        // No sample may carry a warm-model label.
        let report = await DeviceMeasurementHarness.run(
            configuration: .init(repetitions: 1, useModel: true),
            worker: await measurementWorker(),
            service: LocalAssistService()
        )
        XCTAssertEqual(
            report.warmupOutcome,
            .wrongSource(expected: .foundationModels, actual: .deterministicFallback)
        )
        XCTAssertTrue(report.samples.isEmpty, "no claimable samples from a wrong-source warmup")
        XCTAssertTrue(report.failedSamples.isEmpty, "the cohort was aborted, not failed")
        XCTAssertFalse(report.warmupOutcome.isClaimable)
    }

    func testFailedWarmupAbortsWarmCohortWithTypedCategory() async {
        // A model whose stream dies with a cancellation rethrows out of
        // summarize — the one failure the service does not absorb into the
        // deterministic fallback.
        let cancellingService = LocalAssistService(
            model: CancellingModelClient()
        )
        let report = await DeviceMeasurementHarness.run(
            configuration: .init(repetitions: 1, useModel: true),
            worker: await measurementWorker(),
            service: cancellingService
        )
        XCTAssertEqual(report.warmupOutcome, .failed(category: "cancelled"))
        XCTAssertTrue(report.samples.isEmpty)
        XCTAssertFalse(report.warmupOutcome.isClaimable)
    }

    func testWrongSourceSamplesAfterWarmupNeverEnterModelCohort() async {
        let service = LocalAssistService(model: FirstSuccessThenFailureModelClient())
        let report = await DeviceMeasurementHarness.run(
            configuration: .init(
                repetitions: 1,
                useModel: true,
                interSampleDelay: .zero,
                fallbackRecoveryDelay: .zero
            ),
            worker: await measurementWorker(),
            service: service
        )

        XCTAssertEqual(report.warmupOutcome, .succeeded(source: .foundationModels))
        XCTAssertTrue(report.samples.isEmpty, "fallback responses must not enter model percentiles")
        XCTAssertEqual(report.unexpectedSourceSamples.count, EvalDataset.standard.count)
        XCTAssertTrue(report.unexpectedSourceSamples.allSatisfy {
            $0.source == .deterministicFallback && $0.fallbackCategory == "guardrailViolation"
        })
        XCTAssertFalse(report.warmClaimReady)
        XCTAssertTrue(report.warmClaimBlockingReasons.contains {
            $0.contains("unexpected source")
        })
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

}

/// Durable cold-campaign storage and claim-readiness policy tests.
final class LocalAssistColdLaunchCampaignTests: XCTestCase {
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

    private func claimEnvironment(
        commitSHA: String? = "abc1234",
        thermalState: String = "nominal",
        lowPowerMode: Bool = false
    ) -> RunEnvironment {
        RunEnvironment(
            deviceModel: "iPhone18,2",
            osVersion: "Version 26.5.2",
            buildMode: "debug",
            commitSHA: commitSHA,
            thermalState: thermalState,
            lowPowerMode: lowPowerMode,
            coldStart: true
        )
    }

    private func sample(
        source: GenerationSource,
        repetition: Int = 0,
        environment: RunEnvironment? = nil,
        fallbackCategory: String? = nil
    ) -> DeviceMeasurementHarness.Sample {
        DeviceMeasurementHarness.Sample(
            caseID: "blockers-message",
            repetition: repetition,
            cohort: .processCold,
            timeToFirstPartialMilliseconds: 812,
            generationCompletedMilliseconds: 1_900,
            actionReviewReadyMilliseconds: 2_050,
            source: source,
            fallbackCategory: fallbackCategory,
            footprintMB: 182.5,
            environment: environment
        )
    }

    private func record(
        campaignID: String,
        expected: GenerationSource,
        classification: ColdLaunchCampaignStore.Classification,
        source: GenerationSource = .foundationModels,
        repetition: Int = 0,
        environment: RunEnvironment? = nil
    ) -> ColdLaunchCampaignStore.Record {
        let environment = environment ?? claimEnvironment()
        return ColdLaunchCampaignStore.Record(
            campaignID: campaignID,
            recordedAt: Date(),
            environment: environment,
            expectedSource: expected,
            classification: classification,
            sample: classification == .failure ? nil : sample(
                source: source,
                repetition: repetition,
                environment: environment,
                fallbackCategory: source == expected ? nil : "scriptedFallback"
            ),
            failure: classification == .failure
                ? DeviceMeasurementHarness.FailedSample(
                    caseID: "blockers-message", repetition: repetition,
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
            // Simulate a stale line from an older campaign on disk, encoded
            // exactly as the store encodes (.iso8601 dates) — the point is
            // that the CAMPAIGN-ID FILTER excludes it, not a decode failure.
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var stale = try encoder.encode(
                self.record(campaignID: "old-campaign", expected: .foundationModels, classification: .sample)
            )
            // Prove the stale line is decodable with the store's decoder
            // settings before relying on exclusion.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decodedStale = try decoder.decode(ColdLaunchCampaignStore.Record.self, from: stale)
            XCTAssertEqual(decodedStale.campaignID, "old-campaign")

            stale.append(Data("\n".utf8))
            let handle = try FileHandle(forWritingTo: ColdLaunchCampaignStore.recordsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: stale)
            try handle.close()

            XCTAssertEqual(
                ColdLaunchCampaignStore.records(for: campaign).count, 1,
                "the decodable foreign record is excluded by campaign ID, never averaged in"
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
            XCTAssertFalse(summary.claimReady)
            XCTAssertTrue(summary.claimBlockingReasons.contains { $0.contains("unexpected source") })
        }
    }

    func testClaimReadinessRequiresTwentyCleanThermallyEligibleSamples() async throws {
        try await withCleanCampaignStore {
            let environment = self.claimEnvironment()
            let campaign = try ColdLaunchCampaignStore.begin(
                expectedSource: .foundationModels,
                environment: environment
            )
            for repetition in 0 ..< MeasurementClaimPolicy.minimumP95SampleCount - 1 {
                try ColdLaunchCampaignStore.append(self.record(
                    campaignID: campaign.id,
                    expected: .foundationModels,
                    classification: .sample,
                    repetition: repetition,
                    environment: environment
                ))
            }

            var summary = try XCTUnwrap(ColdLaunchCampaignStore.summaryOfActiveCampaign())
            XCTAssertFalse(summary.claimReady)
            XCTAssertTrue(summary.claimBlockingReasons.contains { $0.contains("at least 20") })

            try ColdLaunchCampaignStore.append(self.record(
                campaignID: campaign.id,
                expected: .foundationModels,
                classification: .sample,
                repetition: MeasurementClaimPolicy.minimumP95SampleCount - 1,
                environment: environment
            ))
            summary = try XCTUnwrap(ColdLaunchCampaignStore.summaryOfActiveCampaign())
            XCTAssertTrue(summary.claimReady, summary.claimBlockingReasons.joined(separator: ", "))
            XCTAssertTrue(summary.claimBlockingReasons.isEmpty)
        }
    }

    func testClaimPolicyRequiresARealHexCommitSHA() {
        XCTAssertTrue(MeasurementClaimPolicy.hasTraceableCommit(claimEnvironment(commitSHA: "abc1234")))
        XCTAssertTrue(MeasurementClaimPolicy.hasTraceableCommit(claimEnvironment(commitSHA: "ABC1234")))
        XCTAssertFalse(MeasurementClaimPolicy.hasTraceableCommit(claimEnvironment(commitSHA: nil)))
        XCTAssertFalse(MeasurementClaimPolicy.hasTraceableCommit(claimEnvironment(commitSHA: "unknown")))
        XCTAssertFalse(MeasurementClaimPolicy.hasTraceableCommit(claimEnvironment(commitSHA: "abc1234-dirty")))
        XCTAssertFalse(MeasurementClaimPolicy.hasTraceableCommit(claimEnvironment(commitSHA: "abc123")))
    }

    func testClaimReadinessIndependentlyRejectsMislabeledSources() async throws {
        try await withCleanCampaignStore {
            let environment = self.claimEnvironment()
            let campaign = try ColdLaunchCampaignStore.begin(
                expectedSource: .foundationModels,
                environment: environment
            )
            for repetition in 0 ..< MeasurementClaimPolicy.minimumP95SampleCount {
                try ColdLaunchCampaignStore.append(self.record(
                    campaignID: campaign.id,
                    expected: .foundationModels,
                    classification: .sample,
                    source: .deterministicFallback,
                    repetition: repetition,
                    environment: environment
                ))
            }

            let summary = try XCTUnwrap(ColdLaunchCampaignStore.summaryOfActiveCampaign())
            XCTAssertFalse(summary.claimReady)
            XCTAssertTrue(summary.claimBlockingReasons.contains { $0.contains("mislabeled") })
        }
    }

    func testClaimReadinessRejectsDirtyAndThermallyInvalidCampaigns() async throws {
        try await withCleanCampaignStore {
            let environment = self.claimEnvironment(
                commitSHA: "abc1234-dirty",
                thermalState: "serious"
            )
            let campaign = try ColdLaunchCampaignStore.begin(
                expectedSource: .foundationModels,
                environment: environment
            )
            for repetition in 0 ..< MeasurementClaimPolicy.minimumP95SampleCount {
                try ColdLaunchCampaignStore.append(self.record(
                    campaignID: campaign.id,
                    expected: .foundationModels,
                    classification: .sample,
                    repetition: repetition,
                    environment: environment
                ))
            }

            let summary = try XCTUnwrap(ColdLaunchCampaignStore.summaryOfActiveCampaign())
            XCTAssertFalse(summary.claimReady)
            XCTAssertTrue(summary.claimBlockingReasons.contains { $0.contains("dirty commit") })
            XCTAssertTrue(summary.claimBlockingReasons.contains { $0.contains("thermal budget") })
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
