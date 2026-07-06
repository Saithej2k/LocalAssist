import Foundation

/// Pure dictation-accumulation state machine, extracted from the
/// transcriber so its one invariant is unit-testable without the Speech
/// framework: **finalized words are never lost.**
///
/// The on-device recognizer works in utterance segments. A segment ends in
/// one of two ways — a final result, or an error such as "no speech
/// detected" after a pause. Both paths must fold the words the user watched
/// appear into the running transcript before the next segment starts;
/// missing the error path was the bug where continuing to speak after a
/// pause erased everything said before it.
public struct DictationAccumulator: Equatable, Sendable {
    /// Segments the recognizer has completed, joined in order.
    public private(set) var finalizedText = ""
    /// The live partial hypothesis for the segment in progress.
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

    /// A revised partial hypothesis for the current segment. Partials may
    /// shrink as the recognizer corrects itself; finalized text never does.
    ///
    /// The on-device recognizer can also reset its hypothesis to a fresh
    /// utterance after a pause without ever sending a final or an error —
    /// the new phrase simply starts overwriting the old one. A reset shows
    /// up as a shorter partial that is not a prefix-revision of the current
    /// text (new utterances stream word by word, so their first partial is
    /// short). Fold the old words before accepting it, or every pause
    /// would erase everything said before it.
    public mutating func updatePartial(_ text: String) {
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let old = currentSegment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !old.isEmpty, !new.isEmpty, new.count < old.count, !old.hasPrefix(new) {
            fold(currentSegment)
        }
        currentSegment = text
    }

    /// Segment ended with a final result. Mixed-language finals sometimes
    /// re-score to something shorter than the partial the user watched —
    /// whichever preserves more words wins.
    public mutating func finalizeSegment(_ text: String?) {
        let final = text ?? ""
        let segment = final.count >= currentSegment.count ? final : currentSegment
        currentSegment = ""
        fold(segment)
    }

    /// A final that arrived late, from a segment the pipeline has already
    /// moved past. On iOS 26 the on-device recognizer often sends the
    /// pause error first and the utterance's only text afterwards — these
    /// late finals are the sole carrier of the words and must fold in.
    public mutating func foldCompletedSegment(_ text: String) {
        fold(text)
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

    /// Segment ended without a final (pause "no speech detected", transient
    /// recognizer error, or the user tapping stop). The live partial is all
    /// there is — fold it.
    public mutating func endSegmentWithoutFinal() {
        finalizedText = Self.joined(finalizedText, currentSegment)
        currentSegment = ""
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
