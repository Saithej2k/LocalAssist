import Foundation
import OSLog

// Support types for the voice-capture pipeline, shared between the tap
// thread and the main actor. Internal to the module; the transcriber is the
// only consumer.

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

/// Stage offsets in one Console line — numbers only, no content.
func logVoiceTimeline(_ snapshot: VoiceSessionTimeline.Snapshot, generation: Int) {
    let log = Logger(subsystem: "com.saithej.localassist", category: "Voice")
    func text(_ value: Double?) -> String {
        value.map { String(Int($0)) } ?? "-"
    }
    log.info("""
    timeline gen=\(generation): audioReady=\(text(snapshot.audioReadyMilliseconds), privacy: .public)ms, \
    firstFrame=\(text(snapshot.firstFrameMilliseconds), privacy: .public)ms, \
    analyzerStart=\(text(snapshot.analyzerStartMilliseconds), privacy: .public)ms, \
    firstPartial=\(text(snapshot.firstPartialMilliseconds), privacy: .public)ms, \
    lastFrame=\(text(snapshot.lastFrameMilliseconds), privacy: .public)ms, \
    finalResult=\(text(snapshot.finalResultMilliseconds), privacy: .public)ms, \
    drainCompleted=\(text(snapshot.drainCompletedMilliseconds), privacy: .public)ms
    """)
}

#if os(iOS) && canImport(AVFoundation) && canImport(Speech)
/// Carries a non-Sendable value across a boundary the caller has
/// verified safe (engine/converter handed between setup contexts).
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

/// One-shot flag for the converter input block (see the tap closure).
final class MutableFlag: @unchecked Sendable {
    var value = false
}

/// Diagnostic counters mutated only from the serial tap callback.
final class TapFlowCounter: @unchecked Sendable {
    var buffers = 0
    var frames = 0
}

/// AudioLevelMeter shared between the tap thread (writes) and the main
/// actor (reads at drain time), guarded by a lock.
final class LockedAudioMeter: @unchecked Sendable {
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

enum VoiceCaptureError: Error, CustomStringConvertible {
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
#endif
