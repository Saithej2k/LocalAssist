import Combine
import Foundation

#if os(iOS) && canImport(AVFoundation) && canImport(Speech)
    import AVFoundation
    // Speech's callbacks predate strict concurrency; the framework's types
    // are used carefully across actors below.
    @preconcurrency import Speech
#endif

public enum VoiceCaptureState: Equatable {
    case idle
    case requestingPermission
    case recording
    case unavailable(String)

    public var isRecording: Bool {
        self == .recording
    }
}

#if os(iOS) && canImport(AVFoundation) && canImport(Speech)
    @MainActor
    public final class VoiceNoteTranscriber: ObservableObject {
        @Published public private(set) var state: VoiceCaptureState = .idle
        @Published public private(set) var transcript = ""
        @Published public private(set) var errorMessage: String?

        private var audioEngine: AVAudioEngine?
        private var recognitionTask: SFSpeechRecognitionTask?
        private var speechRecognizer: SFSpeechRecognizer?

        /// The audio tap outlives any single recognition request: the
        /// recognizer finalizes a segment after every ~3s pause, so dictation
        /// is a chain of segment requests all fed by one relay.
        private let requestRelay = RequestRelay()
        /// Segments the recognizer has finalized, joined in order.
        private var finalizedText = ""
        /// The live partial hypothesis for the current segment.
        private var currentSegment = ""
        /// Consecutive error-driven segment restarts with no speech in
        /// between — bounded so a dead recognizer cannot loop forever.
        private var errorRestartCount = 0
        /// Increments per segment; callbacks from superseded segments are
        /// ignored so one pause can't spawn duplicate recognition chains.
        private var segmentGeneration = 0

        public init() {}

        public var isRecording: Bool {
            state.isRecording
        }

        public func start(localeIdentifier: String = Locale.current.identifier) async {
            guard !isRecording else {
                return
            }

            state = .requestingPermission
            transcript = ""
            finalizedText = ""
            currentSegment = ""
            errorRestartCount = 0
            errorMessage = nil

            do {
                try await requestPermissions()
                try startAudioRecognition(localeIdentifier: localeIdentifier)
                state = .recording
            } catch {
                stopAudio(cancelRecognition: true)
                let message = (error as? VoiceCaptureError)?.description ?? error.localizedDescription
                errorMessage = message
                state = .unavailable(message)
            }
        }

        public func stop() {
            guard isRecording || state == .requestingPermission else {
                return
            }

            // Freeze exactly what the user watched appear. Cancelling the
            // recognition (instead of waiting for a final) prevents the
            // recognizer's post-hoc re-scoring from replacing a long
            // transcript with a shorter final hypothesis.
            finalizedText = Self.joined(finalizedText, currentSegment)
            currentSegment = ""
            if !finalizedText.isEmpty {
                transcript = finalizedText
            }
            stopAudio(cancelRecognition: true)
            state = .idle
        }

        private func requestPermissions() async throws {
            switch await speechAuthorizationStatus() {
            case .authorized:
                break
            case .denied:
                throw VoiceCaptureError.speechDenied
            case .restricted:
                throw VoiceCaptureError.speechRestricted
            case .notDetermined:
                throw VoiceCaptureError.speechDenied
            @unknown default:
                throw VoiceCaptureError.speechDenied
            }

            guard await microphoneAccessGranted() else {
                throw VoiceCaptureError.microphoneDenied
            }
        }

        // Permission callbacks arrive on a background TCC queue. These
        // helpers are nonisolated with @Sendable callbacks so the closures
        // carry no MainActor isolation — otherwise the Swift runtime traps
        // with dispatch_assert_queue_fail the moment TCC replies.
        private nonisolated func speechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status)
                }
            }
        }

        private nonisolated func microphoneAccessGranted() async -> Bool {
            await AVAudioApplication.requestRecordPermission()
        }

        private func startAudioRecognition(localeIdentifier: String) throws {
            stopAudio(cancelRecognition: true)

            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
            guard let recognizer else {
                throw VoiceCaptureError.recognizerUnavailable
            }
            guard recognizer.isAvailable else {
                throw VoiceCaptureError.recognizerUnavailable
            }
            guard recognizer.supportsOnDeviceRecognition else {
                throw VoiceCaptureError.onDeviceRecognitionUnavailable
            }

            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            // The audio tap fires on a realtime audio thread. Without
            // @Sendable the closure inherits MainActor isolation from this
            // class and Swift 6 traps in dispatch_assert_queue_fail the
            // instant a buffer arrives. The relay is the tap's only capture,
            // and always points at the current segment's request.
            let relay = requestRelay
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { @Sendable buffer, _ in
                // Engine teardown can deliver one empty buffer; appending it
                // makes CoreAudio log a zero-byte-size complaint.
                guard buffer.frameLength > 0 else {
                    return
                }
                relay.request?.append(buffer)
            }

            engine.prepare()
            try engine.start()

            speechRecognizer = recognizer
            audioEngine = engine
            beginRecognitionSegment(recognizer: recognizer)
        }

        /// One recognition request per utterance segment: the recognizer
        /// finalizes after every pause (~3s of silence), so continuous
        /// dictation chains segments until the user taps stop. Nothing is
        /// lost across pauses.
        private func beginRecognitionSegment(recognizer: SFSpeechRecognizer) {
            segmentGeneration += 1
            let generation = segmentGeneration

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            requestRelay.request = request

            // Results arrive off-main; the handler must be @Sendable, with
            // only Sendable values crossing to the MainActor.
            recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let latestTranscript = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let nsError = error as NSError?
                let errorCode = nsError?.code
                let failureMessage = nsError?.localizedDescription

                Task { @MainActor [weak self] in
                    self?.handleRecognition(
                        generation: generation,
                        latest: latestTranscript,
                        isFinal: isFinal,
                        errorCode: errorCode,
                        failureMessage: failureMessage
                    )
                }
            }
        }

        private func handleRecognition(
            generation: Int,
            latest: String?,
            isFinal: Bool,
            errorCode: Int?,
            failureMessage: String?
        ) {
            // Callbacks from a superseded segment (late finals, cancel
            // errors) must not touch the transcript or spawn restarts.
            guard isRecording, generation == segmentGeneration else {
                return
            }

            if let latest {
                errorRestartCount = 0
                if isFinal {
                    // Mixed-language finals sometimes re-score to something
                    // shorter than the partial the user watched appear —
                    // keep whichever preserves more of their words.
                    let segment = latest.count >= currentSegment.count ? latest : currentSegment
                    finalizedText = Self.joined(finalizedText, segment)
                    currentSegment = ""
                    transcript = finalizedText
                } else {
                    currentSegment = latest
                    transcript = Self.joined(finalizedText, latest)
                }
            }

            guard isFinal || errorCode != nil else {
                return
            }

            if !isFinal {
                // The recognizer often ends a pause with "no speech
                // detected" instead of a final result. No final means
                // nothing folded the live partial — fold it here, or the
                // next segment would overwrite everything already said.
                let heardNothing = currentSegment.isEmpty && latest == nil
                finalizedText = Self.joined(finalizedText, currentSegment)
                currentSegment = ""
                if !finalizedText.isEmpty {
                    transcript = finalizedText
                }
                if heardNothing {
                    errorRestartCount += 1
                }
            }

            // Segment ended: if audio is still flowing, chain straight into
            // the next segment; a dead engine or a recognizer stuck in an
            // error loop ends the session.
            if let recognizer = speechRecognizer,
               audioEngine?.isRunning == true,
               errorRestartCount <= 3 {
                beginRecognitionSegment(recognizer: recognizer)
            } else if let failureMessage {
                stopAudio(cancelRecognition: true)
                errorMessage = failureMessage
                state = .unavailable(failureMessage)
            }
        }

        private static func joined(_ lhs: String, _ rhs: String) -> String {
            let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
            if left.isEmpty {
                return right
            }
            if right.isEmpty {
                return left
            }
            return left + " " + right
        }

        private func stopAudio(cancelRecognition: Bool) {
            if audioEngine?.isRunning == true {
                audioEngine?.stop()
            }
            audioEngine?.inputNode.removeTap(onBus: 0)
            requestRelay.request?.endAudio()
            if cancelRecognition {
                recognitionTask?.cancel()
            }
            recognitionTask = nil
            requestRelay.request = nil
            audioEngine = nil
            speechRecognizer = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Hands the current segment's recognition request to the realtime audio
    /// tap. Mutated only on the main actor; the tap only appends buffers —
    /// the documented usage pattern for SFSpeechAudioBufferRecognitionRequest.
    private final class RequestRelay: @unchecked Sendable {
        var request: SFSpeechAudioBufferRecognitionRequest?
    }

    private enum VoiceCaptureError: Error, CustomStringConvertible {
        case microphoneDenied
        case speechDenied
        case speechRestricted
        case recognizerUnavailable
        case onDeviceRecognitionUnavailable

        var description: String {
            switch self {
            case .microphoneDenied:
                "Microphone access is off for LocalAssist."
            case .speechDenied:
                "Speech recognition access is off for LocalAssist."
            case .speechRestricted:
                "Speech recognition is restricted on this device."
            case .recognizerUnavailable:
                "Speech recognition is unavailable for the current language."
            case .onDeviceRecognitionUnavailable:
                "On-device speech recognition is unavailable for the current language."
            }
        }
    }
#else
    @MainActor
    public final class VoiceNoteTranscriber: ObservableObject {
        @Published public private(set) var state: VoiceCaptureState = .unavailable("Voice capture requires iPhone.")
        @Published public private(set) var transcript = ""
        @Published public private(set) var errorMessage: String? = "Voice capture requires iPhone."

        public init() {}

        public var isRecording: Bool {
            false
        }

        public func start(localeIdentifier _: String = Locale.current.identifier) async {
            errorMessage = "Voice capture requires iPhone."
            state = .unavailable("Voice capture requires iPhone.")
        }

        public func stop() {
            state = .idle
        }
    }
#endif
