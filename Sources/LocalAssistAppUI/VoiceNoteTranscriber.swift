import Combine
import Foundation
import OSLog

#if os(iOS) && canImport(AVFoundation) && canImport(Speech)
    import AVFoundation
    import Speech
#endif

public enum VoiceCaptureState: Equatable {
    case idle
    case requestingPermission
    case recording
    case unavailable(String)

    public var isRecording: Bool {
        self == .recording
    }

    /// Recording or spinning up — the mic button shows "stop" for both so
    /// the tap feels instant.
    public var isActive: Bool {
        self == .recording || self == .requestingPermission
    }
}

#if os(iOS) && canImport(AVFoundation) && canImport(Speech)
    /// On-device dictation built on iOS 26's SpeechAnalyzer/SpeechTranscriber.
    ///
    /// The legacy SFSpeechRecognizer shim on iOS 26 delivered a chaotic
    /// partial stream — no finals, hypothesis rewrites after pauses — that
    /// required fragile heuristics and still produced duplicated or lost
    /// words. SpeechTranscriber has explicit semantics instead: finalized
    /// results are additive and never retracted; volatile results are the
    /// live tail that replaces itself. `DictationAccumulator` maps onto that
    /// directly, with no guessing.
    ///
    /// Startup latency: `prewarm()` (at launch) verifies locale assets,
    /// resolves the analyzer audio format, and pages the recognition model
    /// in, so a mic tap only has to activate audio and start a fresh
    /// analyzer. The session objects themselves are never prepared ahead
    /// or reused — see `startTranscription` for the ordering the device
    /// actually requires.
    @MainActor
    public final class VoiceNoteTranscriber: ObservableObject {
        /// Lengths, codes, and timings only — transcripts never reach the log.
        /// Nonisolated: the audio and permission phases log from off-main.
        private nonisolated static let log = Logger(subsystem: "com.saithej.localassist", category: "Voice")

        @Published public private(set) var state: VoiceCaptureState = .idle
        @Published public private(set) var transcript = ""
        @Published public private(set) var errorMessage: String?
        /// One-sentence capture-quality verdict set when a session ends —
        /// nil when the capture looked healthy. Combines recognizer
        /// confidence with microphone energy (see VoiceCaptureQuality).
        @Published public private(set) var qualityHint: String?

        private var audioEngine: AVAudioEngine?
        private var analyzer: SpeechAnalyzer?
        private var resultsTask: Task<Void, Never>?
        private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        private var accumulator = DictationAccumulator()
        /// Increments per session; results from a superseded session are
        /// ignored.
        private var sessionGeneration = 0

        /// Locale data warmed by `prewarm()`: assets verified and the
        /// analyzer audio format resolved. Pure data — reused across
        /// sessions, unlike the analyzer, which is built fresh per session
        /// (a prepared-ahead analyzer produced zero results on device,
        /// 2026-07-06).
        private struct PreparedAssets {
            /// What the caller asked for (cache key).
            let localeIdentifier: String
            /// The supported locale actually used. SpeechTranscriber covers
            /// a fixed locale list — unlike SFSpeechRecognizer, an
            /// unsupported locale (e.g. en_IN) doesn't error, it just never
            /// produces a result.
            let resolvedLocale: Locale
            let format: AVAudioFormat
        }

        private var preparedAssets: PreparedAssets?
        private var prewarmTask: Task<Void, Never>?
        /// The previous session's engine/audio-session cleanup. The next
        /// session awaits it before touching audio: the shared
        /// AVAudioSession is a singleton, and a floating deactivation
        /// landing mid-way through the next activation kills its audio
        /// (the 2026-07-06 device logs: second session produced no
        /// results, only "Result accumulator timeout" errors).
        private var audioCleanupTask: Task<Void, Never>?

        /// Audio-timeline watermarks for "start over" (✕ during recording).
        /// The recognizer keeps producing results for audio spoken before
        /// the clear; those must be dropped or the cleared words resurface
        /// the moment their final arrives.
        private var latestResultEnd: CMTime = .zero
        private var discardResultsBefore: CMTime = .zero
        /// Diagnostic: has this session produced any result yet?
        private var sawFirstResult = false
        /// Mean `transcriptionConfidence` of each finalized result, in
        /// arrival order — the recognizer's own certainty about the words
        /// it committed.
        private var finalConfidences: [Double] = []
        /// Microphone energy for the live session, written by the tap
        /// thread and read at drain time.
        private var audioMeter: LockedAudioMeter?

        private nonisolated static let signposter = OSSignposter(
            subsystem: "com.saithej.localassist", category: "Voice"
        )

        public init() {}

        public var isRecording: Bool {
            state.isRecording
        }

        /// Warms everything session-independent before the user taps the
        /// mic: verifies locale assets, resolves the analyzer audio format,
        /// and pages the recognition model in once via a throwaway
        /// prepared analyzer. Best-effort: failures are ignored here and
        /// surface on the real start.
        public func prewarm(localeIdentifier: String = Locale.current.identifier) {
            guard prewarmTask == nil, preparedAssets?.localeIdentifier != localeIdentifier else {
                return
            }
            prewarmTask = Task { [weak self] in
                guard let self else {
                    return
                }
                defer { self.prewarmTask = nil }
                if let assets = try? await Self.makeAssets(localeIdentifier: localeIdentifier) {
                    self.preparedAssets = assets.value
                    Self.log.info("prewarm ready")
                }
            }
        }

        public func start(localeIdentifier: String = Locale.current.identifier) async {
            guard !state.isActive else {
                return
            }

            state = .requestingPermission
            transcript = ""
            accumulator.reset()
            errorMessage = nil
            qualityHint = nil
            latestResultEnd = .zero
            discardResultsBefore = .zero
            sawFirstResult = false
            finalConfidences = []
            audioMeter = nil
            sessionGeneration += 1
            let generation = sessionGeneration
            let clock = ContinuousClock()
            let startedAt = clock.now
            let signpost = Self.signposter.beginInterval("MicStart")
            defer { Self.signposter.endInterval("MicStart", signpost) }

            do {
                try await requestPermissions()
                let permissionsAt = clock.now
                try await startTranscription(localeIdentifier: localeIdentifier, generation: generation)
                guard generation == sessionGeneration else {
                    return
                }
                state = .recording
                let now = clock.now
                // Thermal + power state contextualize latency numbers when
                // comparing devices or hunting regressions in the logs.
                let process = ProcessInfo.processInfo
                Self.log.info("""
                session started: gen=\(generation), \
                permissions=\(Self.milliseconds(permissionsAt - startedAt))ms, \
                pipeline+audio=\(Self.milliseconds(now - permissionsAt))ms, \
                total=\(Self.milliseconds(now - startedAt))ms, \
                thermal=\(process.thermalState.rawValue), \
                lowPower=\(process.isLowPowerModeEnabled)
                """)
                // Watchdog: a healthy session shows its first volatile
                // result within a second or two of speech. Silence past 4s
                // means the recognizer isn't recognizing — say so loudly.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, self.sessionGeneration == generation,
                          self.state.isRecording, !self.sawFirstResult
                    else {
                        return
                    }
                    Self.log.error("no recognition results 4s into gen=\(generation) — locale or audio-path issue")
                }
            } catch {
                guard generation == sessionGeneration else {
                    return
                }
                teardown()
                let message = (error as? VoiceCaptureError)?.description ?? error.localizedDescription
                errorMessage = message
                state = .unavailable(message)
                // Framework error, no user content — safe to log publicly,
                // and essential: without it a failing session is unreadable
                // from Console.
                Self.log.error("session failed to start: gen=\(generation), error=\(String(describing: error), privacy: .public)")
            }
        }

        public func stop() {
            guard state.isActive else {
                return
            }

            let generation = sessionGeneration
            Self.log.info("stop: draining gen=\(generation), \(self.transcript.count) chars so far")

            // Stop feeding audio and release the mic immediately — but keep
            // the results pipeline alive. On-device recognition can lag a
            // short utterance by seconds; tearing down instantly threw away
            // everything the recognizer was about to deliver, which read as
            // "spoke, got nothing".
            inputContinuation?.finish()
            inputContinuation = nil
            let engine = audioEngine
            audioEngine = nil
            scheduleEngineCleanup(engine: engine, generation: generation)

            let analyzerToFinish = analyzer
            analyzer = nil
            state = .idle

            // Drain budget is the app's first A/B-shaped knob: control is
            // the device-proven 3s, treatment would probe 2s. Pinned to
            // control until the shorter budget has on-device evidence.
            let drainVariant = LocalExperiments.variant(for: LocalExperiments.micStopDrain)
            LocalExperiments.logExposure(LocalExperiments.micStopDrain, variant: drainVariant)
            let drainBudget: Duration = drainVariant == .treatment ? .seconds(2) : .seconds(3)

            let drainSignpost = Self.signposter.beginInterval("StopDrain")
            Task { [weak self] in
                if let analyzerToFinish {
                    let box = UncheckedSendable(value: analyzerToFinish)
                    // Finalize drives the remaining results through the
                    // stream; bound it so a wedged analyzer can't hold the
                    // pipeline hostage.
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try? await box.value.finalizeAndFinishThroughEndOfInput()
                        }
                        group.addTask {
                            try? await Task.sleep(for: drainBudget)
                        }
                        await group.next()
                        group.cancelAll()
                    }
                }
                Self.signposter.endInterval("StopDrain", drainSignpost)
                guard let self, self.sessionGeneration == generation else {
                    return
                }
                // Everything is in: freeze finalized text plus whatever
                // volatile tail remains.
                self.accumulator.endSegmentWithoutFinal()
                if !self.accumulator.transcript.isEmpty {
                    self.transcript = self.accumulator.transcript
                }
                self.resultsTask?.cancel()
                self.resultsTask = nil
                self.assessQuality(generation: generation)
            }
        }

        /// Session postmortem: recognizer confidence x microphone energy →
        /// at most one user-facing hint. Runs after the drain so it judges
        /// the final transcript, not an intermediate state.
        private func assessQuality(generation: Int) {
            let meter = audioMeter?.snapshot ?? AudioLevelMeter()
            let confidence = finalConfidences.isEmpty
                ? nil
                : finalConfidences.reduce(0, +) / Double(finalConfidences.count)
            qualityHint = TranscriptionQualityAssessor.hint(
                transcriptCharacters: transcript.count,
                averageConfidence: confidence,
                meter: meter
            )
            Self.log.info("""
            drained: gen=\(generation), transcript=\(self.transcript.count) chars, \
            confidence=\(confidence.map { String(format: "%.2f", $0) } ?? "n/a", privacy: .public), \
            voiced=\(String(format: "%.2f", meter.voicedRatio), privacy: .public), \
            maxPeak=\(String(format: "%.3f", meter.maxPeak), privacy: .public), \
            hint=\(self.qualityHint != nil)
            """)
        }

        /// Clears dictated text while keeping the session alive — the
        /// capture box's ✕ during recording means "start over", so the
        /// accumulated text must go too or the next word brings it back.
        /// Results still in flight for audio spoken before the clear are
        /// dropped when they arrive (see `handleResult`) for the same
        /// reason.
        public func resetDictation() {
            accumulator.reset()
            transcript = ""
            qualityHint = nil
            discardResultsBefore = latestResultEnd
        }

        // MARK: - Pipeline

        /// Session-independent warmup: verify locale assets and resolve the
        /// analyzer audio format. Data only — no analyzer is created here.
        /// A prewarm-time analyzer (kept or throwaway-prepared) left the
        /// recognition service wedged on device: every later session either
        /// produced zero results or failed to start (2026-07-06 logs).
        /// Nonisolated so none of this touches the main thread at launch.
        private nonisolated static func makeAssets(
            localeIdentifier: String
        ) async throws -> UncheckedSendable<PreparedAssets> {
            let clock = ContinuousClock()
            let startedAt = clock.now

            // Read-only permission queries warm the permission service's
            // cache off the critical path — the first status read after a
            // fresh install cost >1s on the first mic tap otherwise.
            _ = SFSpeechRecognizer.authorizationStatus()
            _ = AVAudioApplication.shared.recordPermission

            // Resolve the device locale against what SpeechTranscriber
            // actually supports; fall back to same-language, then en-US.
            let requested = Locale(identifier: localeIdentifier)
            let supported = await SpeechTranscriber.supportedLocales
            let resolved = Self.resolveLocale(requested: requested, supported: supported)
            Self.log.info("""
            locale: requested=\(requested.identifier(.bcp47), privacy: .public), \
            using=\(resolved.identifier(.bcp47), privacy: .public), \
            supported=\(supported.count)
            """)

            let transcriber = Self.makeTranscriber(locale: resolved)

            // Ensure the on-device model for this locale is present. The
            // first-ever use may download assets; afterwards this returns
            // immediately.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let installed = await SpeechTranscriber.installedLocales
                .contains { $0.identifier(.bcp47) == resolved.identifier(.bcp47) }
            let assetsAt = clock.now

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw VoiceCaptureError.recognizerUnavailable
            }
            let now = clock.now
            Self.log.info("""
            assets ready: installed=\(installed), \
            assets=\(Self.milliseconds(assetsAt - startedAt))ms, \
            format=\(Self.milliseconds(now - assetsAt))ms
            """)

            return UncheckedSendable(value: PreparedAssets(
                localeIdentifier: localeIdentifier,
                resolvedLocale: resolved,
                format: format
            ))
        }

        /// Exact BCP-47 match first, then any variant of the same language,
        /// then en-US — dictation in a related variant beats none at all.
        private nonisolated static func resolveLocale(requested: Locale, supported: [Locale]) -> Locale {
            let requestedTag = requested.identifier(.bcp47)
            if let exact = supported.first(where: { $0.identifier(.bcp47) == requestedTag }) {
                return exact
            }
            let language = requested.language.languageCode?.identifier
            if let language,
               let sameLanguage = supported.first(where: { $0.language.languageCode?.identifier == language }) {
                return sameLanguage
            }
            return supported.first { $0.identifier(.bcp47) == "en-US" } ?? Locale(identifier: "en_US")
        }

        private nonisolated static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
            SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                // Per-run confidence on finals feeds the session quality
                // verdict (see VoiceCaptureQuality).
                attributeOptions: [.transcriptionConfidence]
            )
        }

        private func assets(localeIdentifier: String) async throws -> PreparedAssets {
            // An in-flight prewarm is doing exactly this work — let it finish.
            if let prewarmTask {
                await prewarmTask.value
            }
            if let prepared = preparedAssets, prepared.localeIdentifier == localeIdentifier {
                Self.log.info("assets: prewarmed")
                return prepared
            }
            Self.log.info("assets: cold")
            let built = try await Self.makeAssets(localeIdentifier: localeIdentifier).value
            preparedAssets = built
            return built
        }

        private func startTranscription(localeIdentifier: String, generation: Int) async throws {
            teardown()
            // The previous session's engine/audio-session cleanup must be
            // fully done before this one activates audio. It's engine-stop
            // fast: the analyzer finalize runs on its own floating task.
            if let cleanup = audioCleanupTask {
                await cleanup.value
                audioCleanupTask = nil
            }

            let assets = try await assets(localeIdentifier: localeIdentifier)
            // Fresh transcriber + analyzer per session, started only after
            // the engine is up — the exact ordering that transcribes on
            // device. A prepared-ahead analyzer or an analyzer started
            // while the engine was still activating produced zero results
            // (2026-07-06 device logs).
            let transcriber = Self.makeTranscriber(locale: assets.resolvedLocale)
            let sessionAnalyzer = SpeechAnalyzer(modules: [transcriber])
            let (inputSequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

            analyzer = sessionAnalyzer
            inputContinuation = continuation

            let meter = LockedAudioMeter()
            audioMeter = meter

            let clock = ContinuousClock()
            let engineAt = clock.now
            let engineTask = Self.audioEngineTask(
                continuation: continuation,
                analyzerFormat: assets.format,
                meter: meter
            )
            audioEngine = try await engineTask.value.value
            let analyzerAt = clock.now
            try await sessionAnalyzer.start(inputSequence: inputSequence)
            let now = clock.now
            Self.log.info("""
            audio=\(Self.milliseconds(analyzerAt - engineAt))ms, \
            analyzer start=\(Self.milliseconds(now - analyzerAt))ms
            """)

            // Subscribe only after the analyzer is running. Subscribing
            // before start terminated the results sequence on device
            // (2026-07-06 logs: zero transcript, then "attempted to update
            // accumulator after completion" for every real result).
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        let isFinal = result.isFinal
                        let range = result.range
                        let confidence = isFinal ? Self.averageConfidence(of: result.text) : nil
                        await MainActor.run {
                            self?.handleResult(
                                text: text,
                                isFinal: isFinal,
                                range: range,
                                confidence: confidence,
                                generation: generation
                            )
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        self?.handleResultsEnded(message: message, generation: generation)
                    }
                }
            }
        }

        private nonisolated static func audioEngineTask(
            continuation: AsyncStream<AnalyzerInput>.Continuation,
            analyzerFormat: AVAudioFormat,
            meter: LockedAudioMeter
        ) -> Task<UncheckedSendable<AVAudioEngine>, Error> {
            let formatBox = UncheckedSendable(value: analyzerFormat)
            // Everything blocking — session activation, engine startup,
            // converter creation — happens off the main thread. The tap is
            // @Sendable and captures only the continuation + converter box.
            return Task.detached(priority: .userInitiated) { () -> UncheckedSendable<AVAudioEngine> in
                do {
                    let clock = ContinuousClock()
                    let startedAt = clock.now
                    let audioSession = AVAudioSession.sharedInstance()
                    // The exact configuration of the build that transcribed
                    // on device. The category persists, so set it only when
                    // it changed.
                    if audioSession.category != .record || audioSession.mode != .measurement {
                        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
                    }
                    let categoryAt = clock.now
                    do {
                        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                    } catch {
                        // '!pri' (insufficient priority): a call, Siri, or a
                        // screen recording holds the mic. Handoffs are often
                        // transient — cycle the session and retry once
                        // before giving up.
                        Self.log.error("session activation retry after: \(String(describing: error), privacy: .public)")
                        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                        try? await Task.sleep(for: .milliseconds(400))
                        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                    }
                    let activeAt = clock.now

                    let engine = AVAudioEngine()
                    let inputNode = engine.inputNode
                    let recordingFormat = inputNode.outputFormat(forBus: 0)
                    let converterBox = UncheckedSendable(
                        value: AVAudioConverter(from: recordingFormat, to: formatBox.value)
                    )
                    // Scalars only — AVAudioFormat isn't Sendable and the
                    // tap closure must stay @Sendable.
                    let inputRate = recordingFormat.sampleRate
                    let inputChannels = recordingFormat.channelCount
                    let outputRate = formatBox.value.sampleRate
                    let flow = TapFlowCounter()

                    inputNode.installTap(onBus: 0, bufferSize: 2048, format: recordingFormat) { @Sendable buffer, _ in
                        guard buffer.frameLength > 0 else {
                            return
                        }
                        guard let converter = converterBox.value else {
                            continuation.yield(AnalyzerInput(buffer: buffer))
                            return
                        }
                        let ratio = formatBox.value.sampleRate / buffer.format.sampleRate
                        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
                        guard let converted = AVAudioPCMBuffer(pcmFormat: formatBox.value, frameCapacity: capacity) else {
                            return
                        }
                        // The input block is @Sendable in the SDK but runs
                        // synchronously inside convert() on this thread;
                        // the boxes never actually cross threads.
                        let bufferBox = UncheckedSendable(value: buffer)
                        let consumed = MutableFlag()
                        var conversionError: NSError?
                        converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                            if consumed.value {
                                inputStatus.pointee = .noDataNow
                                return nil
                            }
                            consumed.value = true
                            inputStatus.pointee = .haveData
                            return bufferBox.value
                        }
                        guard conversionError == nil, converted.frameLength > 0 else {
                            return
                        }
                        continuation.yield(AnalyzerInput(buffer: converted))
                        // Peak of the raw input: ~0 means the mic route is
                        // delivering silence (a routing/mute problem, not a
                        // recognition problem). Feeds the session quality
                        // verdict.
                        var peak: Float = 0
                        if let samples = buffer.floatChannelData?[0] {
                            for index in 0 ..< Int(buffer.frameLength) {
                                peak = max(peak, abs(samples[index]))
                            }
                        }
                        meter.record(peak: peak)

                        // Tap callbacks are serial; plain increments are safe.
                        flow.buffers += 1
                        flow.frames += Int(converted.frameLength)
                        if flow.buffers == 1 || flow.buffers == 50 {
                            Self.log.info("""
                            tap: buffer \(flow.buffers), \
                            \(Int(inputRate))Hz/\(inputChannels)ch -> \(Int(outputRate))Hz, \
                            \(flow.frames) frames converted, peak=\(peak)
                            """)
                        }
                    }

                    engine.prepare()
                    try engine.start()
                    let now = clock.now
                    Self.log.info("""
                    audio up: category=\(Self.milliseconds(categoryAt - startedAt))ms, \
                    activate=\(Self.milliseconds(activeAt - categoryAt))ms, \
                    engine=\(Self.milliseconds(now - activeAt))ms
                    """)
                    return UncheckedSendable(value: engine)
                } catch {
                    Self.log.error("audio engine failed: \(String(describing: error), privacy: .public)")
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    let nsError = error as NSError
                    if nsError.domain == NSOSStatusErrorDomain, nsError.code == 561_017_449 {
                        throw VoiceCaptureError.microphoneBusy
                    }
                    throw error
                }
            }
        }

        /// Mean of the recognizer's per-run confidence attributes across a
        /// finalized result; nil when the recognizer attached none.
        private nonisolated static func averageConfidence(of text: AttributedString) -> Double? {
            var total = 0.0
            var count = 0
            for run in text.runs {
                if let value = run.transcriptionConfidence {
                    total += value
                    count += 1
                }
            }
            return count > 0 ? total / Double(count) : nil
        }

        private func handleResult(
            text: String,
            isFinal: Bool,
            range: CMTimeRange,
            confidence: Double?,
            generation: Int
        ) {
            // Generation-only guard: results arriving after stop() are the
            // drain delivering the user's words — they must still fold in.
            // A new session bumps the generation and cuts stale ones off.
            guard generation == sessionGeneration else {
                return
            }
            if !sawFirstResult {
                sawFirstResult = true
                Self.log.info("first result: gen=\(generation), final=\(isFinal), \(text.count) chars")
            }
            if range.isValid {
                latestResultEnd = max(latestResultEnd, range.end)
                // ✕ during recording: this result is for audio spoken
                // before the clear — the user already discarded those words.
                if discardResultsBefore > .zero, range.start < discardResultsBefore {
                    return
                }
            }
            if isFinal {
                accumulator.finalizeSegment(text)
                if let confidence {
                    finalConfidences.append(confidence)
                }
                Self.log.info("""
                finalized: \(text.count) chars, total=\(self.accumulator.transcript.count), \
                confidence=\(confidence.map { String(format: "%.2f", $0) } ?? "n/a", privacy: .public)
                """)
            } else {
                accumulator.updatePartial(text)
            }
            transcript = accumulator.transcript
        }

        private func handleResultsEnded(message: String, generation: Int) {
            guard state.isActive, generation == sessionGeneration else {
                return
            }
            Self.log.info("results stream ended with error: gen=\(generation)")
            accumulator.endSegmentWithoutFinal()
            if !accumulator.transcript.isEmpty {
                transcript = accumulator.transcript
            }
            teardown()
            errorMessage = message
            state = .unavailable(message)
        }

        // MARK: - Teardown

        /// Heavy teardown detaches so stopping feels instant, split in two:
        ///
        /// - The analyzer finalize floats freely — it can block for seconds
        ///   (a 3s "Result accumulator timeout" when the session got little
        ///   audio) and nothing downstream depends on it; the next session
        ///   uses a fresh analyzer.
        /// - Engine stop + session deactivation go into `audioCleanupTask`,
        ///   which the next start awaits — and deactivation is skipped
        ///   entirely if a newer session already took over the shared
        ///   audio session.
        private func teardown() {
            inputContinuation?.finish()
            inputContinuation = nil
            resultsTask?.cancel()
            resultsTask = nil

            let engine = audioEngine
            let analyzer = self.analyzer
            audioEngine = nil
            self.analyzer = nil

            if let analyzer {
                let analyzerBox = UncheckedSendable(value: analyzer)
                Task.detached(priority: .utility) {
                    try? await analyzerBox.value.finalizeAndFinishThroughEndOfInput()
                }
            }

            scheduleEngineCleanup(engine: engine, generation: sessionGeneration)
        }

        private func scheduleEngineCleanup(engine: AVAudioEngine?, generation: Int) {
            guard engine != nil else {
                return
            }
            let engineBox = UncheckedSendable(value: engine)
            audioCleanupTask = Task.detached(priority: .userInitiated) { [weak self] in
                let engine = engineBox.value
                if engine?.isRunning == true {
                    engine?.stop()
                }
                engine?.inputNode.removeTap(onBus: 0)
                let superseded = await self?.isSessionSuperseded(by: generation) ?? false
                if !superseded {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
        }

        /// True once a newer session owns the shared audio session — the
        /// old cleanup must then leave deactivation alone.
        private func isSessionSuperseded(by generation: Int) -> Bool {
            sessionGeneration != generation || state.isActive
        }

        // MARK: - Permissions

        /// Nonisolated: the status reads are synchronous permission-service
        /// calls that can stall (fresh install, busy tccd) — on the main
        /// actor they froze the UI ("Gesture: System gesture gate timed
        /// out" in the 2026-07-06 device logs). Off main they cost the same
        /// but block nobody. The async prompting APIs run only on first use.
        private nonisolated func requestPermissions() async throws {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                break
            case .notDetermined:
                Self.log.info("permissions: prompting for speech recognition")
                guard await requestSpeechAuthorization() == .authorized else {
                    throw VoiceCaptureError.speechDenied
                }
            case .denied:
                throw VoiceCaptureError.speechDenied
            case .restricted:
                throw VoiceCaptureError.speechRestricted
            @unknown default:
                throw VoiceCaptureError.speechDenied
            }

            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                break
            case .undetermined:
                Self.log.info("permissions: prompting for microphone")
                guard await AVAudioApplication.requestRecordPermission() else {
                    throw VoiceCaptureError.microphoneDenied
                }
            case .denied:
                throw VoiceCaptureError.microphoneDenied
            @unknown default:
                throw VoiceCaptureError.microphoneDenied
            }
        }

        // The permission prompt's callback arrives on a background TCC
        // queue. This helper is nonisolated with a @Sendable callback so the
        // closure carries no MainActor isolation — otherwise the Swift
        // runtime traps with dispatch_assert_queue_fail the moment TCC
        // replies.
        private nonisolated func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status)
                }
            }
        }

        private nonisolated static func milliseconds(_ duration: Duration) -> Int {
            Int(duration.components.seconds) * 1000
                + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        }
    }

    /// Carries a non-Sendable value across a boundary the caller has
    /// verified safe (engine/converter handed between setup contexts).
    private struct UncheckedSendable<T>: @unchecked Sendable {
        let value: T
    }

    /// One-shot flag for the converter input block (see the tap closure).
    private final class MutableFlag: @unchecked Sendable {
        var value = false
    }

    /// Diagnostic counters mutated only from the serial tap callback.
    private final class TapFlowCounter: @unchecked Sendable {
        var buffers = 0
        var frames = 0
    }

    /// AudioLevelMeter shared between the tap thread (writes) and the main
    /// actor (reads at drain time), guarded by a lock.
    private final class LockedAudioMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var meter = AudioLevelMeter()

        func record(peak: Float) {
            lock.lock()
            meter.record(peak: peak)
            lock.unlock()
        }

        var snapshot: AudioLevelMeter {
            lock.lock()
            defer { lock.unlock() }
            return meter
        }
    }

    private enum VoiceCaptureError: Error, CustomStringConvertible {
        case microphoneDenied
        case microphoneBusy
        case speechDenied
        case speechRestricted
        case recognizerUnavailable

        var description: String {
            switch self {
            case .microphoneDenied:
                "Microphone access is off for LocalAssist."
            case .microphoneBusy:
                "The microphone is in use — end any call or screen recording, then try again."
            case .speechDenied:
                "Speech recognition access is off for LocalAssist."
            case .speechRestricted:
                "Speech recognition is restricted on this device."
            case .recognizerUnavailable:
                "Speech recognition is unavailable for the current language."
            }
        }
    }
#else
    @MainActor
    public final class VoiceNoteTranscriber: ObservableObject {
        @Published public private(set) var state: VoiceCaptureState = .unavailable("Voice capture requires iPhone.")
        @Published public private(set) var transcript = ""
        @Published public private(set) var errorMessage: String? = "Voice capture requires iPhone."
        @Published public private(set) var qualityHint: String?

        public init() {}

        public var isRecording: Bool {
            false
        }

        public func prewarm(localeIdentifier _: String = Locale.current.identifier) {}

        public func start(localeIdentifier _: String = Locale.current.identifier) async {
            errorMessage = "Voice capture requires iPhone."
            state = .unavailable("Voice capture requires iPhone.")
        }

        public func stop() {
            state = .idle
        }

        public func resetDictation() {
            transcript = ""
            qualityHint = nil
        }
    }
#endif
