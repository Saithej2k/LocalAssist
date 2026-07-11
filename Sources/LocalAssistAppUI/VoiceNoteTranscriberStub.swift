import Foundation
import LocalAssistCore

// Non-iOS stand-in so LocalAssistAppUI builds (and its tests run) on macOS.
// The real transcriber lives in VoiceNoteTranscriber.swift behind
// `#if os(iOS)`.

#if !(os(iOS) && canImport(AVFoundation) && canImport(Speech))
    @MainActor
    public final class VoiceNoteTranscriber: ObservableObject {
        @Published public private(set) var state: VoiceCaptureState = .unavailable("Voice capture requires iPhone.")
        @Published public private(set) var transcript = ""
        @Published public private(set) var errorMessage: String? = "Voice capture requires iPhone."
        @Published public private(set) var qualityHint: String?
        @Published public private(set) var lastSessionTimeline: VoiceSessionTimeline.Snapshot?

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
