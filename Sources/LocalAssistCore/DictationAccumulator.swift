import Foundation

/// Pure dictation-accumulation state machine, extracted from the
/// transcriber so its one invariant is unit-testable without the Speech
/// framework: **finalized words are never lost.**
///
/// Maps SpeechTranscriber's result semantics directly: finalized results
/// are additive and never retracted; a volatile result is the live
/// hypothesis for the audio since the last final and replaces the previous
/// volatile wholesale. Volatile rewrites may shrink or recase ("The
/// landlord…" → "Email the landlord…") — that's the recognizer correcting
/// itself, not new words. The legacy SFSpeechRecognizer shim needed a
/// guess-the-hypothesis-reset heuristic here; applied to SpeechTranscriber
/// volatiles it folded every shrinking rewrite as if it were a finished
/// segment and duplicated whole phrases.
public struct DictationAccumulator: Equatable, Sendable {
    /// Segments the recognizer has finalized, joined in order.
    public private(set) var finalizedText = ""
    /// The live volatile hypothesis since the last final.
    public private(set) var currentSegment = ""

    public init() {}

    /// What the capture box should show right now.
    public var transcript: String {
        Self.joined(finalizedText, currentSegment)
    }

    public mutating func reset() {
        finalizedText = ""
        currentSegment = ""
    }

    /// Volatile result: the live hypothesis replaces the previous one,
    /// shrinking rewrites included.
    public mutating func updatePartial(_ text: String) {
        currentSegment = text
    }

    /// Final result: the segment is settled — fold it and drop the volatile
    /// tail it supersedes, or the same words render twice. Mixed-language
    /// finals sometimes re-score to something shorter than the partial the
    /// user watched appear — whichever preserves more words wins.
    public mutating func finalizeSegment(_ text: String?) {
        let final = text ?? ""
        let segment = final.count >= currentSegment.count ? final : currentSegment
        currentSegment = ""
        fold(segment)
    }

    /// Segment ended without a final (results stream error, or the user
    /// tapping stop). The live partial is all there is — fold it.
    public mutating func endSegmentWithoutFinal() {
        let segment = currentSegment
        currentSegment = ""
        fold(segment)
    }

    private mutating func fold(_ segment: String) {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dedupe exact repeats: the same final can be delivered more than
        // once across callback paths.
        guard !trimmed.isEmpty, !finalizedText.hasSuffix(trimmed) else {
            return
        }
        finalizedText = Self.joined(finalizedText, trimmed)
    }

    public static func joined(_ lhs: String, _ rhs: String) -> String {
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
}
