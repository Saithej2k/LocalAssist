import Foundation

/// Pure dictation-quality signals, framework-free so XCTest covers them
/// without Speech or AVFoundation. Two independent signals feed one
/// user-facing verdict:
///
/// - **Audio energy** (`AudioLevelMeter`): did the microphone actually hear
///   voice-level input? Distinguishes "recognition struggled" from "the
///   room was silent / the mic was covered" — different problems with
///   different user remedies.
/// - **Recognizer confidence** (`transcriptionConfidence` attributes on
///   finalized results): how sure the on-device model is about the words it
///   committed. Low confidence with healthy audio usually means noise,
///   crosstalk, or an accent/domain mismatch — the transcript exists but
///   deserves a review before it becomes tasks.
public struct AudioLevelMeter: Equatable, Sendable {
    /// Peak amplitude (0...1) below which a buffer is treated as
    /// silence/room tone. Speech into the built-in mic normally peaks an
    /// order of magnitude above this.
    public static let voicedThreshold: Float = 0.02

    public private(set) var totalBuffers = 0
    public private(set) var voicedBuffers = 0
    public private(set) var maxPeak: Float = 0

    public init() {}

    public mutating func record(peak: Float) {
        totalBuffers += 1
        if peak >= Self.voicedThreshold {
            voicedBuffers += 1
        }
        maxPeak = max(maxPeak, peak)
    }

    /// Fraction of buffers that carried voice-level energy.
    public var voicedRatio: Double {
        totalBuffers == 0 ? 0 : Double(voicedBuffers) / Double(totalBuffers)
    }
}

public enum TranscriptionQualityAssessor {
    /// Below this mean per-final confidence the transcript gets a review
    /// hint. The on-device recognizer reports 0...1; clean speech scores
    /// well above this, heavy noise or crosstalk lands below.
    public static let lowConfidence = 0.45
    /// A session where fewer than this fraction of buffers carried voice
    /// energy was effectively silent.
    public static let quietVoicedRatio = 0.05
    /// Sessions shorter than this many buffers (~1s) are too small to
    /// judge — never hint on them.
    public static let minimumBuffers = 20

    /// One user-facing sentence, or nil when the capture looks healthy.
    /// Silence outranks confidence: a silent session produces no finals,
    /// so its "confidence" is vacuous.
    public static func hint(
        transcriptCharacters: Int,
        averageConfidence: Double?,
        meter: AudioLevelMeter
    ) -> String? {
        guard meter.totalBuffers >= minimumBuffers else {
            return nil
        }
        if meter.voicedRatio < quietVoicedRatio, transcriptCharacters == 0 {
            return "The microphone barely heard anything — check for a covered mic or try speaking closer."
        }
        if transcriptCharacters > 0, let averageConfidence, averageConfidence < lowConfidence {
            return "Some words were hard to make out — review the transcript before generating."
        }
        return nil
    }
}
