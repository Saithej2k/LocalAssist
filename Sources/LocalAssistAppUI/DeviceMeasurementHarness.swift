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

            public init(repetitions: Int = 20, useModel: Bool = true) {
                self.repetitions = max(1, repetitions)
                self.useModel = useModel
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
            public var footprintMB: Double
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
            public var samples: [Sample]
            public var failedSamples: [FailedSample]
            public var fallbackSamples: [FallbackSample]
            public var memory: MemoryProfile
            /// The unmeasured session-cold warmup's outcome. Samples exist
            /// above only when this is `.succeeded` from the expected
            /// source; otherwise the warm cohort was aborted and this
            /// field says why.
            public var warmupOutcome: WarmupOutcome
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
            let service: LocalAssistService = injectedService
                ?? (configuration.useModel
                    ? LocalAssistLiveFactory.makeService(tools: LocalAssistToolkit.liveTools())
                    : LocalAssistService())

            let monitor = MemoryMonitor()
            monitor.start()

            // One unmeasured warmup consumes the session-cold (or
            // process-cold) first generation. Only a warmup that SUCCEEDS
            // from the expected engine earns the samples their "warm"
            // label — a failed or wrong-source warmup aborts the warm
            // cohort instead of collecting numbers the label would lie
            // about. Cold statistics come from the cold-launch campaign,
            // not from here.
            let expectedSource: GenerationSource = configuration.useModel
                ? .foundationModels
                : .deterministicFallback
            let warmupOutcome: WarmupOutcome
            do {
                let warmupSummary = try await service.summarize(AssistantRequest(
                    sourceText: EvalDataset.standard[0].input,
                    maxSuggestions: EvalDataset.standard[0].maxSuggestions
                ))
                warmupOutcome = warmupSummary.source == expectedSource
                    ? .succeeded(source: warmupSummary.source)
                    : .wrongSource(expected: expectedSource, actual: warmupSummary.source)
            } catch let failure as GenerationFailure {
                warmupOutcome = .failed(category: failure.category)
            } catch {
                warmupOutcome = .failed(
                    category: error is CancellationError ? "cancelled" : "untyped"
                )
            }

            var samples: [Sample] = []
            var failures: [FailedSample] = []
            if warmupOutcome.isClaimable {
                for evalCase in EvalDataset.standard {
                    for repetition in 0 ..< configuration.repetitions {
                        switch await measureOne(
                            evalCase: evalCase,
                            repetition: repetition,
                            cohort: .warm,
                            service: service,
                            worker: worker
                        ) {
                        case .success(let sample):
                            samples.append(sample)
                        case .failure(let failed):
                            failures.append(failed)
                        }
                    }
                }
            }

            let fallbackSamples = await measureFallbacks(
                repetitions: max(configuration.repetitions / 2, 5)
            )
            let memory = monitor.stop()

            return Report(
                startedAt: startedAt,
                completedAt: Date(),
                environment: .current(coldStart: false),
                configurationRepetitions: configuration.repetitions,
                usedModel: configuration.useModel,
                samples: samples,
                failedSamples: failures,
                fallbackSamples: fallbackSamples,
                memory: memory,
                warmupOutcome: warmupOutcome,
                coldLaunchCampaign: ColdLaunchCampaignStore.summaryOfActiveCampaign(),
                caveats: [
                    "warm samples exist only when warmupOutcome is .succeeded from the expected "
                        + "engine; a failed or wrong-source warmup aborts the warm cohort. "
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
                footprintMB: footprintMB()
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
            let expectedSource: GenerationSource = useModel ? .foundationModels : .deterministicFallback
            let campaign: ColdLaunchCampaignStore.Campaign
            do {
                // Explicit begin exists (`ColdLaunchCampaignStore.begin`);
                // the launch hook begins one automatically when none is
                // active so the first cold launch of a fresh campaign
                // needs no separate setup step.
                if let active = ColdLaunchCampaignStore.active() {
                    campaign = active
                } else {
                    campaign = try ColdLaunchCampaignStore.begin(expectedSource: expectedSource)
                }
            } catch {
                return false
            }

            // Rotate through the dataset across launches so a campaign
            // spreads over the cases instead of hammering one.
            let launchIndex = ColdLaunchCampaignStore.records(for: campaign).count
            let evalCase = EvalDataset.standard[launchIndex % EvalDataset.standard.count]
            let service: LocalAssistService = useModel
                ? LocalAssistLiveFactory.makeService(tools: LocalAssistToolkit.liveTools())
                : LocalAssistService()

            let record: ColdLaunchCampaignStore.Record
            switch await measureOne(
                evalCase: evalCase,
                repetition: launchIndex,
                cohort: .processCold,
                service: service,
                worker: LocalAssistWorker()
            ) {
            case .success(let sample):
                // A deterministic-fallback answer in a campaign meant to
                // measure Foundation Models is not a cold model number —
                // classified separately, never mixed into the samples.
                let classification: ColdLaunchCampaignStore.Classification =
                    sample.source == campaign.expectedSource ? .sample : .unexpectedSource
                record = ColdLaunchCampaignStore.Record(
                    campaignID: campaign.id,
                    recordedAt: Date(),
                    environment: .current(coldStart: true),
                    expectedSource: campaign.expectedSource,
                    classification: classification,
                    sample: sample,
                    failure: nil
                )
            case .failure(let failed):
                // Cold-launch failures are campaign data too.
                record = ColdLaunchCampaignStore.Record(
                    campaignID: campaign.id,
                    recordedAt: Date(),
                    environment: .current(coldStart: true),
                    expectedSource: campaign.expectedSource,
                    classification: .failure,
                    sample: nil,
                    failure: failed
                )
            }

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
