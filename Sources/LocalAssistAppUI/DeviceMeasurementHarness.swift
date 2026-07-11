#if DEBUG
    import Foundation
    import LocalAssistCore
    import LocalAssistEvalKit
    import LocalAssistFoundationModels
    import LocalAssistSystemTools
    import Synchronization

    /// Debug-only automated measurement harness for the physical iPhone.
    ///
    /// Runs `EvalDataset.standard` through the real service repeatedly,
    /// timing what the user actually feels — first structured update,
    /// completed generation, action-review readiness through the same
    /// `LocalAssistWorker` path production uses — plus the injected
    /// fallback path. App-process memory is sampled continuously on a
    /// background task for the whole measurement interval, not just at
    /// sample boundaries. Export is stable JSON with full device/build
    /// metadata, so runs on different days or devices compare honestly.
    ///
    /// Cohorts are facts, not labels:
    /// - `processCold`: no generation had started in this process before
    ///   the sample (grounded in `ProcessGenerationRegistry`) — at most one
    ///   per launch, and only when nothing else generated first.
    /// - `sessionCold`: first sample on this harness run's fresh service —
    ///   sessions and prewarm state cold, process already warm.
    /// - `warm`: everything else.
    ///
    /// Genuine process-cold statistics need repeated launches: the
    /// `LOCALASSIST_MEASURE_PROCESS_COLD` launch argument makes the app run
    /// exactly one sample at startup and append it to a JSONL outbox in
    /// Documents; the `MeasurementColdLaunchTests` XCUITest drives 20 such
    /// launches on a connected device. `run()` folds any accumulated
    /// process-cold samples into its report.
    ///
    /// Failures are data: a sample that throws or never completes is kept
    /// as a `FailedSample` with its typed failure category — silently
    /// dropping errors would make a flaky device look fast.
    public enum DeviceMeasurementHarness {
        public struct Configuration: Sendable {
            /// Repetitions per case. 20 over the 8-case dataset = the
            /// 160-warm-run floor for stable percentiles.
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

        /// Continuous footprint statistics over the measurement interval.
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
            /// Samples collected by prior `LOCALASSIST_MEASURE_PROCESS_COLD`
            /// launches and folded into this report from the JSONL outbox.
            public var processColdLaunchSamples: [Sample]
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
        /// service sits in the loop on a headless runner.
        public static func run(
            configuration: Configuration = Configuration(),
            worker: LocalAssistWorker = LocalAssistWorker()
        ) async -> Report {
            let startedAt = Date()
            let service: LocalAssistService = configuration.useModel
                ? LocalAssistLiveFactory.makeService(tools: LocalAssistToolkit.liveTools())
                : LocalAssistService()

            let monitor = MemoryMonitor()
            monitor.start()

            var samples: [Sample] = []
            var failures: [FailedSample] = []
            var sampleIndex = 0
            for evalCase in EvalDataset.standard {
                for repetition in 0 ..< configuration.repetitions {
                    let cohort = cohort(
                        sampleIndex: sampleIndex,
                        priorProcessGenerations: ProcessGenerationRegistry.generationsStarted()
                    )
                    sampleIndex += 1
                    switch await measureOne(
                        evalCase: evalCase,
                        repetition: repetition,
                        cohort: cohort,
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
                processColdLaunchSamples: ProcessColdOutbox.load(),
                caveats: [
                    "processCold requires nothing to have generated earlier in the launch; "
                        + "collect ≥20 via the LOCALASSIST_MEASURE_PROCESS_COLD launch argument "
                        + "(MeasurementColdLaunchTests drives this on a connected device)",
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

        private enum MeasureOutcome {
            case success(Sample)
            case failure(FailedSample)
        }

        /// One repetition of one case: TTFT, completed generation, and
        /// action-review readiness through the production worker path.
        private static func measureOne(
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
        /// process — and appends it to the JSONL outbox. Call from the app's
        /// launch path before anything else can generate. Returns true when
        /// a sample was collected (the XCUITest waits on this via UI state).
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

            // Rotate through the dataset across launches so 20 launches
            // spread over the cases instead of hammering one.
            let launchIndex = ProcessColdOutbox.count()
            let evalCase = EvalDataset.standard[launchIndex % EvalDataset.standard.count]
            let useModel = info.environment["LOCALASSIST_FORCE_OFFLINE"] != "1"
            let service: LocalAssistService = useModel
                ? LocalAssistLiveFactory.makeService(tools: LocalAssistToolkit.liveTools())
                : LocalAssistService()

            switch await measureOne(
                evalCase: evalCase,
                repetition: launchIndex,
                cohort: .processCold,
                service: service,
                worker: LocalAssistWorker()
            ) {
            case .success(let sample):
                ProcessColdOutbox.append(sample)
                return true
            case .failure:
                return false
            }
        }

        /// Durable JSONL outbox for process-cold samples, one object per
        /// line, in Documents so it survives relaunches and ships with the
        /// container.
        enum ProcessColdOutbox {
            static var fileURL: URL {
                let documents = FileManager.default.urls(
                    for: .documentDirectory,
                    in: .userDomainMask
                ).first ?? FileManager.default.temporaryDirectory
                return documents.appendingPathComponent("localassist-process-cold.jsonl")
            }

            static func append(_ sample: Sample) {
                guard let line = try? JSONEncoder().encode(sample) else {
                    return
                }
                var data = line
                data.append(Data("\n".utf8))
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: fileURL, options: [.atomic])
                }
            }

            static func load() -> [Sample] {
                guard let data = try? Data(contentsOf: fileURL) else {
                    return []
                }
                let decoder = JSONDecoder()
                return data
                    .split(separator: UInt8(ascii: "\n"))
                    .compactMap { try? decoder.decode(Sample.self, from: $0) }
            }

            static func count() -> Int {
                load().count
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

    /// Samples `phys_footprint` on a background task for the whole
    /// measurement interval — a spike between sample boundaries is
    /// exactly the kind of number Jetsam cares about and a
    /// point-in-time read misses.
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
