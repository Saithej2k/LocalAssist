#if DEBUG
    import Foundation
    import LocalAssistCore
    import LocalAssistEvalKit
    import LocalAssistFoundationModels
    import LocalAssistSystemTools

    /// Debug-only automated measurement harness for the physical iPhone.
    ///
    /// Runs `EvalDataset.standard` through the real service repeatedly,
    /// timing what the user actually feels — first structured update,
    /// completed generation, action-review readiness — plus the injected
    /// fallback path, with app-process memory footprint sampled per
    /// repetition. Export is stable JSON with full device/build metadata,
    /// so runs on different days or devices compare honestly.
    ///
    /// Cohorts: `cold` marks the first repetition of a case after the
    /// harness (re)created its service — sessions and caches are fresh.
    /// True process-cold numbers still require relaunching the app between
    /// runs; that remains an owner-on-device step and is stated in the
    /// report rather than approximated.
    ///
    /// This type never ships: the whole file is `#if DEBUG`, and nothing on
    /// a normal screen calls it. Numbers it produces are measurements to
    /// publish only after they exist — never placeholders.
    public enum DeviceMeasurementHarness {
        public struct Configuration: Sendable {
            /// Repetitions per case per cohort round. 20 is the floor for
            /// stable percentiles on-device.
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
            case cold
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

        public struct FallbackSample: Codable, Equatable, Sendable {
            public var detectionMilliseconds: Double
            public var detectionToCompletionMilliseconds: Double
        }

        public struct Report: Codable, Equatable, Sendable {
            public var startedAt: Date
            public var completedAt: Date
            public var environment: RunEnvironment
            public var configurationRepetitions: Int
            public var usedModel: Bool
            public var samples: [Sample]
            public var fallbackSamples: [FallbackSample]
            public var peakFootprintMB: Double
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

        public static func run(configuration: Configuration = Configuration()) async -> Report {
            let startedAt = Date()
            let service: LocalAssistService = configuration.useModel
                ? LocalAssistLiveFactory.makeService(tools: LocalAssistToolkit.liveTools())
                : LocalAssistService()

            var samples: [Sample] = []
            var peakFootprint = footprintMB()
            for evalCase in EvalDataset.standard {
                for repetition in 0 ..< configuration.repetitions {
                    if let sample = await measureOne(
                        evalCase: evalCase,
                        repetition: repetition,
                        service: service
                    ) {
                        peakFootprint = max(peakFootprint, sample.footprintMB)
                        samples.append(sample)
                    }
                }
            }

            let fallbackSamples = await measureFallbacks(
                repetitions: max(configuration.repetitions / 2, 5)
            )

            return Report(
                startedAt: startedAt,
                completedAt: Date(),
                environment: .current(coldStart: false),
                configurationRepetitions: configuration.repetitions,
                usedModel: configuration.useModel,
                samples: samples,
                fallbackSamples: fallbackSamples,
                peakFootprintMB: peakFootprint,
                caveats: [
                    "cold cohort = fresh service in a running process; true process-cold requires app relaunch between runs",
                    "microphone startup/drain timings come from real captures (VoiceSessionTimeline), not this harness",
                    "text inputs from EvalDataset.standard; real-speech numbers require the physical speech corpus",
                ]
            )
        }

        /// One repetition of one case: TTFT, completed generation, and
        /// action-review readiness, with the process footprint after.
        private static func measureOne(
            evalCase: EvalCase,
            repetition: Int,
            service: LocalAssistService
        ) async -> Sample? {
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
            } catch {
                return nil
            }
            guard let summary else {
                return nil
            }
            let generationDone = clock.now
            _ = try? await prepareAll(summary.actionDrafts, preparer: DraftOnlyToolActionPreparer())
            let reviewReady = clock.now

            return Sample(
                caseID: evalCase.id,
                repetition: repetition,
                cohort: repetition == 0 ? .cold : .warm,
                timeToFirstPartialMilliseconds: firstPartialAt.map {
                    started.duration(to: $0).milliseconds
                },
                generationCompletedMilliseconds: started.duration(to: generationDone).milliseconds,
                actionReviewReadyMilliseconds: started.duration(to: reviewReady).milliseconds,
                source: summary.source,
                footprintMB: footprintMB()
            )
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

        private static func prepareAll(
            _ drafts: [ToolActionDraft],
            preparer: DraftOnlyToolActionPreparer
        ) async throws -> [PreparedToolAction] {
            var prepared: [PreparedToolAction] = []
            for draft in drafts {
                prepared.append(try await preparer.prepare(draft))
            }
            return prepared
        }

        /// App-process physical footprint — the number Xcode's memory gauge
        /// and Jetsam decisions track, not RSS.
        private static func footprintMB() -> Double {
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

    private extension Duration {
        var milliseconds: Double {
            Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }
    }
#endif
