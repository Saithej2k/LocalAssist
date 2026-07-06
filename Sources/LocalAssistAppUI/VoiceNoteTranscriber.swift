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
        private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        private var recognitionTask: SFSpeechRecognitionTask?
        private var speechRecognizer: SFSpeechRecognizer?

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

            stopAudio(cancelRecognition: false)
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

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true

            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            // The audio tap fires on a realtime audio thread. Without
            // @Sendable the closure inherits MainActor isolation from this
            // class and Swift 6 traps in dispatch_assert_queue_fail the
            // instant a buffer arrives. The request crosses into the tap in
            // an unchecked box: appending audio buffers off-main is the
            // documented usage pattern for SFSpeechAudioBufferRecognitionRequest.
            let boxedRequest = UncheckedSendable(value: request)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { @Sendable buffer, _ in
                boxedRequest.value.append(buffer)
            }

            engine.prepare()
            try engine.start()

            speechRecognizer = recognizer
            audioEngine = engine
            recognitionRequest = request
            // Recognition results also arrive off-main; the handler must be
            // @Sendable, with all state mutation hopping to the MainActor.
            recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                // Pull Sendable values out before hopping actors — the raw
                // SFSpeechRecognitionResult must not cross the boundary.
                let latestTranscript = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failureMessage = error?.localizedDescription

                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }

                    if let latestTranscript {
                        transcript = latestTranscript
                        if isFinal {
                            stop()
                        }
                    }

                    if let failureMessage, isRecording {
                        stopAudio(cancelRecognition: true)
                        errorMessage = failureMessage
                        state = .unavailable(failureMessage)
                    }
                }
            }
        }

        private func stopAudio(cancelRecognition: Bool) {
            if audioEngine?.isRunning == true {
                audioEngine?.stop()
            }
            audioEngine?.inputNode.removeTap(onBus: 0)
            recognitionRequest?.endAudio()
            if cancelRecognition {
                recognitionTask?.cancel()
            }
            recognitionTask = nil
            recognitionRequest = nil
            audioEngine = nil
            speechRecognizer = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Carries a non-Sendable value across an actor boundary the caller has
    /// verified safe (e.g. audio-tap buffer appends).
    private struct UncheckedSendable<T>: @unchecked Sendable {
        let value: T
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
