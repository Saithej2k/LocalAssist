#if DEBUG
    import Foundation
    import LocalAssistCore
    import LocalAssistEvalKit
    import LocalAssistFoundationModels
    import LocalAssistSystemTools
    import Synchronization

    /// Debug-only automated measurement harness for the physical iPhone.
    ///
    /// Performs one **unmeasured session-cold warmup**, then runs
    /// `EvalDataset.standard` repeatedly through the real service — so the
    /// dataset is exactly cases × repetitions of genuinely warm samples,
    /// with no mislabeled first run. Timing covers what the user actually
    /// feels: first structured update, completed generation, and
    /// action-review readiness through the same `LocalAssistWorker`
    /// orchestration production uses (contact enrichment included).
    ///
    /// Cold numbers never come from this run. They come from the
    /// cold-launch campaign (`ColdLaunchCampaignStore`): launches with
    /// `LOCALASSIST_MEASURE_PROCESS_COLD` record exactly one sample each as
    /// the process's first generation, and the report embeds the active
    /// campaign's records — only that campaign's.
    ///
    /// Failures are data: a repetition that throws or ends without a
    /// summary is preserved as a `FailedSample` with its typed failure
    /// category — silently dropping errors would make a flaky device look
    /// fast. Memory is 100 ms periodic footprint sampling for the whole
    /// interval — periodic, not continuous; true-peak claims require
    /// Instruments VM Tracker.
    public enum DeviceMeasurementHarness {
        public struct Configuration: Sendable {
            /// Repetitions per case. 20 over the 8-case dataset = the
            /// 160-warm-sample floor for stable percentiles.
            public var repetitions: Int
            /// True routes through the on-device model (requires an
            /// eligible device with Apple Intelligence enabled); false
            /// measures the deterministic engine.
            public var useModel: Bool
            /// A small quiet period between live-model samples reduces
            /// self-inflicted rate limiting and thermal escalation. The
            /// deterministic path stays unpaced for fast tests.
            public var interSampleDelay: Duration
            /// A fallback means the attempted model pass already consumed
            /// time and resources. Give the system longer to recover before
            /// the next measured request.
            public var fallbackRecoveryDelay: Duration
            /// Maximum idle wait for serious/critical thermal pressure to
            /// return to nominal/fair before the cohort aborts loudly.
            public var thermalWaitTimeout: Duration
            public var thermalPollInterval: Duration

            public init(
                repetitions: Int = 20,
                useModel: Bool = true,
                interSampleDelay: Duration? = nil,
                fallbackRecoveryDelay: Duration? = nil,
                thermalWaitTimeout: Duration = .seconds(120),
                thermalPollInterval: Duration = .seconds(5)
            ) {
                self.repetitions = max(1, repetitions)
                self.useModel = useModel
                self.interSampleDelay = interSampleDelay ?? (useModel ? .seconds(5) : .zero)
                self.fallbackRecoveryDelay = fallbackRecoveryDelay ?? (useModel ? .seconds(30) : .zero)
                self.thermalWaitTimeout = thermalWaitTimeout
                self.thermalPollInterval = thermalPollInterval
            }
        }

        public enum Cohort: String, Codable, Sendable {
            case processCold
            case sessionCold
            case warm
        }

        public struct Sample: Codable, Equatable, Sendable {
            public var caseID: String
            public var repetition: Int
            public var cohort: Cohort
            public var timeToFirstPartialMilliseconds: Double?
            public var generationCompletedMilliseconds: Double
            public var actionReviewReadyMilliseconds: Double
            public var source: GenerationSource
            /// Stable machine-readable reason when this sample completed
            /// through fallback. Prose fallback reasons are intentionally
            /// excluded because framework errors can contain input text.
            public var fallbackCategory: String?
            public var footprintMB: Double
            /// Per-sample conditions, rather than one optimistic snapshot
            /// taken only when the campaign began.
            public var environment: RunEnvironment?
        }

        /// A sample that failed, preserved with its typed category —
        /// error rate is part of the measurement.
        public struct FailedSample: Codable, Equatable, Sendable {
            public var caseID: String
            public var repetition: Int
            public var cohort: Cohort
            /// `GenerationFailure.category` when the failure was typed,
            /// "incomplete" when the stream ended without a summary,
            /// "untyped" otherwise. Never free-form error text.
            public var failureCategory: String
        }

        public struct FallbackSample: Codable, Equatable, Sendable {
            public var detectionMilliseconds: Double
            public var detectionToCompletionMilliseconds: Double
        }

        /// What the unmeasured warmup actually did. Warm samples are
        /// claimable only after `.succeeded` from the configuration's
        /// expected source — a warmup that failed, or that answered from
        /// the wrong engine (deterministic fallback in a Foundation Models
        /// run), means the "warm" label would be a guess, so the warm
        /// cohort is aborted instead of collected.
        public enum WarmupOutcome: Codable, Equatable, Sendable {
            case succeeded(source: GenerationSource)
            case wrongSource(expected: GenerationSource, actual: GenerationSource)
            case failed(category: String)

            public var isClaimable: Bool {
                if case .succeeded = self {
                    return true
                }
                return false
            }
        }

        /// 100 ms periodic footprint sampling over the measurement
        /// interval. Periodic, not continuous: a spike shorter than the
        /// sampling interval can be missed — the true peak requires
        /// Instruments (Allocations + VM Tracker).
        public struct MemoryProfile: Codable, Equatable, Sendable {
            public var peakMB: Double
            public var meanMB: Double
            public var sampleCount: Int
            public var samplingIntervalMilliseconds: Double
        }

        public struct Report: Codable, Equatable, Sendable {
            public var startedAt: Date
            public var completedAt: Date
            public var environment: RunEnvironment
            public var configurationRepetitions: Int
            public var usedModel: Bool
            public var expectedSource: GenerationSource
            public var samples: [Sample]
            /// Completed responses from an engine other than the requested
            /// one. They remain evidence, but never enter model percentiles.
            public var unexpectedSourceSamples: [Sample]
            public var failedSamples: [FailedSample]
            public var fallbackSamples: [FallbackSample]
            public var memory: MemoryProfile
            /// The unmeasured session-cold warmup's outcome. Samples exist
            /// above only when this is `.succeeded` from the expected
            /// source; otherwise the warm cohort was aborted and this
            /// field says why.
            public var warmupOutcome: WarmupOutcome
            /// True only when the warm cohort has traceable provenance, the
            /// full expected sample count, no wrong-source/failing samples,
            /// stable power, and nominal/fair thermal conditions.
            public var warmClaimReady: Bool
            public var warmClaimBlockingReasons: [String]
            /// The active cold-launch campaign and its records, when one
            /// exists. Only records carrying this campaign's ID are
            /// included — different campaigns never fold together.
            public var coldLaunchCampaign: ColdLaunchCampaignStore.Summary?
            /// What this harness cannot measure by itself, stated in the
            /// artifact so a reader never assumes otherwise.
            public var caveats: [String]

            public func jsonData() throws -> Data {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return try encoder.encode(self)
            }
        }
    }

    extension DeviceMeasurementHarness {
        // MARK: - Main measurement

        /// `worker` defaults to the production configuration — the same
        /// orchestration (contact enrichment + preparation) the app runs
        /// after every generation, not a preparer shortcut. Tests inject a
        /// worker with a static contact resolver so no TCC-gated system
        /// service sits in the loop on a headless runner, and may inject a
        /// scripted `service` to exercise warmup failure paths.
        public static func run(
            configuration: Configuration = Configuration(),
            worker: LocalAssistWorker = LocalAssistWorker(),
            service injectedService: LocalAssistService? = nil
        ) async -> Report {
            let startedAt = Date()
            let campaignEnvironment = RunEnvironment.current(coldStart: false)
            let service: LocalAssistService = injectedService
                ?? (configuration.useModel
                    ? LocalAssistLiveFactory.makeService(tools: LocalAssistToolkit.liveTools())
                    : LocalAssistService())
            let monitor = MemoryMonitor()
            monitor.start()
            let expectedSource: GenerationSource = configuration.useModel
                ? .foundationModels
                : .deterministicFallback
            let warmupOutcome = await performWarmup(
                configuration: configuration,
                expectedSource: expectedSource,
                service: service
            )
            let collection = await collectWarmSamples(
                configuration: configuration,
                expectedSource: expectedSource,
                warmupOutcome: warmupOutcome,
                service: service,
                worker: worker
            )
            let fallbackSamples = await measureFallbacks(
                repetitions: max(configuration.repetitions / 2, 5)
            )
            let memory = monitor.stop()
            let expectedWarmSampleCount = EvalDataset.standard.count * configuration.repetitions
            let warmClaimBlockingReasons = warmClaimBlockers(WarmClaimEvidence(
                expectedSource: expectedSource,
                expectedSampleCount: expectedWarmSampleCount,
                samples: collection.samples,
                unexpectedSourceSamples: collection.unexpectedSourceSamples,
                failures: collection.failures,
                warmupOutcome: warmupOutcome,
                environment: campaignEnvironment,
                memory: memory
            ))

            return Report(
                startedAt: startedAt,
                completedAt: Date(),
                environment: campaignEnvironment,
                configurationRepetitions: configuration.repetitions,
                usedModel: configuration.useModel,
                expectedSource: expectedSource,
                samples: collection.samples,
                unexpectedSourceSamples: collection.unexpectedSourceSamples,
                failedSamples: collection.failures,
                fallbackSamples: fallbackSamples,
                memory: memory,
                warmupOutcome: warmupOutcome,
                warmClaimReady: warmClaimBlockingReasons.isEmpty,
                warmClaimBlockingReasons: warmClaimBlockingReasons,
                coldLaunchCampaign: ColdLaunchCampaignStore.summaryOfActiveCampaign(),
                caveats: [
                    "warm samples exist only when warmupOutcome is .succeeded from the expected "
                        + "engine; a failed or wrong-source warmup aborts the warm cohort. "
                        + "Later wrong-source responses are preserved in unexpectedSourceSamples "
                        + "and never enter model percentiles. "
                        + "Cold statistics come from the cold-launch campaign "
                        + "(LOCALASSIST_MEASURE_PROCESS_COLD launches, MeasurementColdLaunchTests)",
                    "20 cold launches support an aggregate cold p95 only; "
                        + "per-case cold percentiles need 20 launches per case (160 total)",
                    "memory is 100 ms periodic footprint sampling, not a continuous record — "
                        + "the true peak requires Instruments (Allocations + VM Tracker)",
                    "microphone startup/drain timings come from real captures (VoiceSessionTimeline), not this harness",
                    "text inputs from EvalDataset.standard; real-speech numbers require the physical speech corpus",
                ]
            )
        }

        private struct WarmCollection {
            var samples: [Sample] = []
            var unexpectedSourceSamples: [Sample] = []
            var failures: [FailedSample] = []
        }

        /// Consumes the session-cold generation without admitting it to the
        /// warm cohort. A wrong-source or failed warmup aborts collection.
        private static func performWarmup(
            configuration: Configuration,
            expectedSource: GenerationSource,
            service: LocalAssistService
        ) async -> WarmupOutcome {
            if let category = await thermalFailureCategory(configuration: configuration) {
                return .failed(category: category)
            }
            do {
                let evalCase = EvalDataset.standard[0]
                let summary = try await service.summarize(AssistantRequest(
                    sourceText: evalCase.input,
                    maxSuggestions: evalCase.maxSuggestions
                ))
                return summary.source == expectedSource
                    ? .succeeded(source: summary.source)
                    : .wrongSource(expected: expectedSource, actual: summary.source)
            } catch let failure as GenerationFailure {
                return .failed(category: failure.category)
            } catch {
                return .failed(category: error is CancellationError ? "cancelled" : "untyped")
            }
        }

        private static func collectWarmSamples(
            configuration: Configuration,
            expectedSource: GenerationSource,
            warmupOutcome: WarmupOutcome,
            service: LocalAssistService,
            worker: LocalAssistWorker
        ) async -> WarmCollection {
            guard warmupOutcome.isClaimable else {
                return WarmCollection()
            }
            var collection = WarmCollection()
            measurementLoop: for evalCase in EvalDataset.standard {
                for repetition in 0 ..< configuration.repetitions {
                    guard !Task.isCancelled else {
                        collection.failures.append(FailedSample(
                            caseID: evalCase.id, repetition: repetition,
                            cohort: .warm, failureCategory: "cancelled"
                        ))
                        break measurementLoop
                    }
                    if let category = await thermalFailureCategory(configuration: configuration) {
                        collection.failures.append(FailedSample(
                            caseID: evalCase.id, repetition: repetition,
                            cohort: .warm, failureCategory: category
                        ))
                        break measurementLoop
                    }

                    switch await measureOne(
                        evalCase: evalCase, repetition: repetition, cohort: .warm,
                        service: service, worker: worker
                    ) {
                    case .success(let sample):
                        if sample.source == expectedSource {
                            collection.samples.append(sample)
                        } else {
                            collection.unexpectedSourceSamples.append(sample)
                        }
                        let delay = sample.source == expectedSource
                            ? configuration.interSampleDelay
                            : configuration.fallbackRecoveryDelay
                        if delay > .zero {
                            try? await Task.sleep(for: delay)
                        }
                    case .failure(let failure):
                        collection.failures.append(failure)
                        if configuration.fallbackRecoveryDelay > .zero {
                            try? await Task.sleep(for: configuration.fallbackRecoveryDelay)
                        }
                    }
                }
            }
            return collection
        }

        private static func thermalFailureCategory(
            configuration: Configuration
        ) async -> String? {
            guard configuration.useModel else {
                return nil
            }
            let ready = await MeasurementClaimPolicy.waitForThermalEligibility(
                timeout: configuration.thermalWaitTimeout,
                pollInterval: configuration.thermalPollInterval
            )
            guard !ready else {
                return nil
            }
            return Task.isCancelled ? "cancelled" : "thermalBudgetExceeded"
        }

        private struct WarmClaimEvidence {
            var expectedSource: GenerationSource
            var expectedSampleCount: Int
            var samples: [Sample]
            var unexpectedSourceSamples: [Sample]
            var failures: [FailedSample]
            var warmupOutcome: WarmupOutcome
            var environment: RunEnvironment
            var memory: MemoryProfile
        }

        private static func warmClaimBlockers(_ evidence: WarmClaimEvidence) -> [String] {
            warmRunBlockers(evidence) + warmSampleBlockers(evidence)
        }

        private static func warmRunBlockers(_ evidence: WarmClaimEvidence) -> [String] {
            var blockers: [String] = []
            if !MeasurementClaimPolicy.hasTraceableCommit(evidence.environment) {
                blockers.append("missing or dirty commit SHA")
            }
            if !MeasurementClaimPolicy.hasStablePower(evidence.environment) {
                blockers.append("Low Power Mode was enabled")
            }
            if !MeasurementClaimPolicy.isThermallyEligible(evidence.environment) {
                blockers.append("campaign started at thermal state \(evidence.environment.thermalState)")
            }
            if evidence.warmupOutcome != .succeeded(source: evidence.expectedSource) {
                blockers.append("warmup did not succeed from \(evidence.expectedSource.rawValue)")
            }
            if evidence.samples.count != evidence.expectedSampleCount {
                blockers.append(
                    "expected \(evidence.expectedSampleCount) warm samples, "
                        + "recorded \(evidence.samples.count)"
                )
            }
            if !evidence.unexpectedSourceSamples.isEmpty {
                blockers.append(
                    "\(evidence.unexpectedSourceSamples.count) warm samples used an unexpected source"
                )
            }
            if !evidence.failures.isEmpty {
                blockers.append("\(evidence.failures.count) warm samples failed")
            }
            if evidence.memory.sampleCount == 0 {
                blockers.append("memory sampler recorded no observations")
            }
            return blockers
        }

        private static func warmSampleBlockers(_ evidence: WarmClaimEvidence) -> [String] {
            var blockers: [String] = []
            let mislabeledSourceCount = evidence.samples.filter {
                $0.source != evidence.expectedSource
            }.count
            if mislabeledSourceCount > 0 {
                blockers.append("\(mislabeledSourceCount) expected-source samples were mislabeled")
            }

            let measuredSamples = evidence.samples + evidence.unexpectedSourceSamples
            let missingEnvironments = measuredSamples.filter { $0.environment == nil }.count
            if missingEnvironments > 0 {
                blockers.append("\(missingEnvironments) warm samples lack per-sample environment data")
            }
            let thermallyInvalid = measuredSamples.compactMap(\.environment)
                .filter { !MeasurementClaimPolicy.isThermallyEligible($0) }.count
            if thermallyInvalid > 0 {
                blockers.append("\(thermallyInvalid) warm samples exceeded the thermal budget")
            }
            let environmentMismatches = measuredSamples.compactMap(\.environment)
                .filter {
                    !MeasurementClaimPolicy.matchesPinnedEnvironment(
                        $0,
                        campaign: evidence.environment
                    )
                }.count
            if environmentMismatches > 0 {
                blockers.append("\(environmentMismatches) warm samples changed pinned environment")
            }
            return blockers
        }

        /// Cohort assignment is pure so it is unit-testable: the first
        /// sample of a run is processCold only when the process had
        /// generated nothing before it; otherwise it is sessionCold
        /// (fresh service, warm process). Everything after is warm.
        static func cohort(sampleIndex: Int, priorProcessGenerations: Int) -> Cohort {
            guard sampleIndex == 0 else {
                return .warm
            }
            return priorProcessGenerations == 0 ? .processCold : .sessionCold
        }

        enum MeasureOutcome {
            case success(Sample)
            case failure(FailedSample)
        }

        /// One repetition of one case: TTFT, completed generation, and
        /// action-review readiness through the production worker path.
        static func measureOne(
            evalCase: EvalCase,
            repetition: Int,
            cohort: Cohort,
            service: LocalAssistService,
            worker: LocalAssistWorker
        ) async -> MeasureOutcome {
            let request = AssistantRequest(
                sourceText: evalCase.input,
                maxSuggestions: evalCase.maxSuggestions
            )
            let clock = ContinuousClock()
            let started = clock.now
            var firstPartialAt: ContinuousClock.Instant?
            var summary: StructuredSummary?

            do {
                for try await update in service.streamSummary(request) {
                    if update.partial != nil, firstPartialAt == nil {
                        firstPartialAt = clock.now
                    }
                    if let final = update.summary {
                        summary = final
                    }
                }
            } catch let failure as GenerationFailure {
                return .failure(FailedSample(
                    caseID: evalCase.id,
                    repetition: repetition,
                    cohort: cohort,
                    failureCategory: failure.category
                ))
            } catch {
                return .failure(FailedSample(
                    caseID: evalCase.id,
                    repetition: repetition,
                    cohort: cohort,
                    failureCategory: error is CancellationError ? "cancelled" : "untyped"
                ))
            }
            guard let summary else {
                return .failure(FailedSample(
                    caseID: evalCase.id,
                    repetition: repetition,
                    cohort: cohort,
                    failureCategory: "incomplete"
                ))
            }
            let generationDone = clock.now
            _ = try? await worker.prepareActions(summary.actionDrafts)
            let reviewReady = clock.now
            let environment = RunEnvironment.current(coldStart: cohort == .processCold)

            return .success(Sample(
                caseID: evalCase.id,
                repetition: repetition,
                cohort: cohort,
                timeToFirstPartialMilliseconds: firstPartialAt.map {
                    started.duration(to: $0).milliseconds
                },
                generationCompletedMilliseconds: started.duration(to: generationDone).milliseconds,
                actionReviewReadyMilliseconds: started.duration(to: reviewReady).milliseconds,
                source: summary.source,
                fallbackCategory: summary.diagnostics.failureCategory,
                footprintMB: footprintMB(),
                environment: environment
            ))
        }

        /// Injected fallback latency, same shape as the CLI benchmark:
        /// incomplete stream → deterministic completion.
        private static func measureFallbacks(repetitions: Int) async -> [FallbackSample] {
            var fallbackSamples: [FallbackSample] = []
            for _ in 0 ..< repetitions {
                let failing = LocalAssistService(model: StaticStructuredModelClient(script: [
                    StructuredSummaryPartial(overview: "half", isComplete: false)
                ]))
                let clock = ContinuousClock()
                let started = clock.now
                var detectedAt: ContinuousClock.Instant?
                var completedAt: ContinuousClock.Instant?
                do {
                    let request = AssistantRequest(sourceText: EvalDataset.standard[0].input)
                    for try await update in failing.streamSummary(request) {
                        if update.phase == .fallback, detectedAt == nil {
                            detectedAt = clock.now
                        }
                        if update.summary != nil {
                            completedAt = clock.now
                        }
                    }
                } catch {
                    continue
                }
                if let detectedAt, let completedAt {
                    fallbackSamples.append(FallbackSample(
                        detectionMilliseconds: started.duration(to: detectedAt).milliseconds,
                        detectionToCompletionMilliseconds: detectedAt.duration(to: completedAt).milliseconds
                    ))
                }
            }
            return fallbackSamples
        }

    }

    extension DeviceMeasurementHarness {
        // MARK: - Process-cold launches

        /// When the app was launched with `LOCALASSIST_MEASURE_PROCESS_COLD`,
        /// runs exactly one sample — the true first generation of this
        /// process — classifies it against the campaign's expected source,
        /// and appends it durably to the campaign records. Call from the
        /// app's launch path before anything else can generate. Returns
        /// true only after the record's durable write succeeded — the
        /// XCUITest completion marker keys off this, so a launch whose
        /// write failed shows no marker and fails loudly.
        @discardableResult
        public static func runProcessColdSampleIfRequested() async -> Bool {
            let info = ProcessInfo.processInfo
            guard info.arguments.contains("LOCALASSIST_MEASURE_PROCESS_COLD")
                || info.environment["LOCALASSIST_MEASURE_PROCESS_COLD"] == "1"
            else {
                return false
            }
            guard ProcessGenerationRegistry.generationsStarted() == 0 else {
                return false
            }

            if info.arguments.contains("LOCALASSIST_COLD_CAMPAIGN_RESET") {
                try? ColdLaunchCampaignStore.reset()
            }

            let useModel = info.environment["LOCALASSIST_FORCE_OFFLINE"] != "1"
            let expectedSource: GenerationSource = useModel
                ? .foundationModels
                : .deterministicFallback
            guard let campaign = activeOrNewCampaign(expectedSource: expectedSource) else {
                return false
            }

            // Rotate through the dataset across launches so a campaign
            // spreads over the cases instead of hammering one.
            let launchIndex = ColdLaunchCampaignStore.records(for: campaign).count
            let evalCase = EvalDataset.standard[launchIndex % EvalDataset.standard.count]
            guard await coldThermalReady(useModel: useModel) else {
                let category = Task.isCancelled ? "cancelled" : "thermalBudgetExceeded"
                return appendColdRecord(coldFailureRecord(
                    campaign: campaign,
                    evalCase: evalCase,
                    launchIndex: launchIndex,
                    category: category
                ))
            }
            let service: LocalAssistService = useModel
                ? LocalAssistLiveFactory.makeService(tools: LocalAssistToolkit.liveTools())
                : LocalAssistService()
            let record = await coldMeasurementRecord(
                campaign: campaign,
                evalCase: evalCase,
                launchIndex: launchIndex,
                service: service
            )
            return appendColdRecord(record)
        }

        private static func activeOrNewCampaign(
            expectedSource: GenerationSource
        ) -> ColdLaunchCampaignStore.Campaign? {
            do {
                if let active = ColdLaunchCampaignStore.active() {
                    return active
                }
                return try ColdLaunchCampaignStore.begin(expectedSource: expectedSource)
            } catch {
                return nil
            }
        }

        private static func coldThermalReady(useModel: Bool) async -> Bool {
            guard useModel else {
                return true
            }
            return await MeasurementClaimPolicy.waitForThermalEligibility(
                timeout: .seconds(120),
                pollInterval: .seconds(5)
            )
        }

        private static func coldMeasurementRecord(
            campaign: ColdLaunchCampaignStore.Campaign,
            evalCase: EvalCase,
            launchIndex: Int,
            service: LocalAssistService
        ) async -> ColdLaunchCampaignStore.Record {
            switch await measureOne(
                evalCase: evalCase,
                repetition: launchIndex,
                cohort: .processCold,
                service: service,
                worker: LocalAssistWorker()
            ) {
            case .success(let sample):
                let classification: ColdLaunchCampaignStore.Classification =
                    sample.source == campaign.expectedSource ? .sample : .unexpectedSource
                return ColdLaunchCampaignStore.Record(
                    campaignID: campaign.id,
                    recordedAt: Date(),
                    environment: sample.environment ?? .current(coldStart: true),
                    expectedSource: campaign.expectedSource,
                    classification: classification,
                    sample: sample,
                    failure: nil
                )
            case .failure(let failed):
                return ColdLaunchCampaignStore.Record(
                    campaignID: campaign.id,
                    recordedAt: Date(),
                    environment: .current(coldStart: true),
                    expectedSource: campaign.expectedSource,
                    classification: .failure,
                    sample: nil,
                    failure: failed
                )
            }
        }

        private static func coldFailureRecord(
            campaign: ColdLaunchCampaignStore.Campaign,
            evalCase: EvalCase,
            launchIndex: Int,
            category: String
        ) -> ColdLaunchCampaignStore.Record {
            let failure = FailedSample(
                caseID: evalCase.id,
                repetition: launchIndex,
                cohort: .processCold,
                failureCategory: category
            )
            return ColdLaunchCampaignStore.Record(
                campaignID: campaign.id,
                recordedAt: Date(),
                environment: .current(coldStart: true),
                expectedSource: campaign.expectedSource,
                classification: .failure,
                sample: nil,
                failure: failure
            )
        }

        private static func appendColdRecord(_ record: ColdLaunchCampaignStore.Record) -> Bool {
            do {
                try ColdLaunchCampaignStore.append(record)
                return true
            } catch {
                return false
            }
        }

        /// App-process physical footprint — the number Xcode's memory gauge
        /// and Jetsam decisions track, not RSS.
        static func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
                }
            }
            guard result == KERN_SUCCESS else {
                return 0
            }
            return Double(info.phys_footprint) / 1_048_576
        }
    }

    // MARK: - Memory

    /// Samples `phys_footprint` on a background task at a 100 ms cadence
    /// for the whole measurement interval — periodic sampling, not a
    /// continuous record. A spike between samples can be missed; the true
    /// peak requires Instruments VM Tracker.
    final class MemoryMonitor: Sendable {
        private struct State {
            var peakMB: Double = 0
            var totalMB: Double = 0
            var count = 0
            var task: Task<Void, Never>?
        }

        private let state = Mutex(State())
        private let interval: Duration

        init(interval: Duration = .milliseconds(100)) {
            self.interval = interval
        }

        func start() {
            let interval = interval
            let sampler = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    self?.recordSample()
                    try? await Task.sleep(for: interval)
                }
            }
            state.withLock { $0.task = sampler }
        }

        private func recordSample() {
            let footprint = DeviceMeasurementHarness.footprintMB()
            state.withLock { current in
                current.peakMB = max(current.peakMB, footprint)
                current.totalMB += footprint
                current.count += 1
            }
        }

        func stop() -> DeviceMeasurementHarness.MemoryProfile {
            let snapshot = state.withLock { current -> State in
                current.task?.cancel()
                return current
            }
            return DeviceMeasurementHarness.MemoryProfile(
                peakMB: snapshot.peakMB,
                meanMB: snapshot.count > 0 ? snapshot.totalMB / Double(snapshot.count) : 0,
                sampleCount: snapshot.count,
                samplingIntervalMilliseconds: Double(interval.components.seconds) * 1_000
                    + Double(interval.components.attoseconds) / 1_000_000_000_000_000
            )
        }
    }

    private extension Duration {
        var milliseconds: Double {
            Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }
    }
#endif
