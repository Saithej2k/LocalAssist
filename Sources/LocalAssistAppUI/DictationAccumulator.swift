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
    public mutating func updatePartial(_ text: String) {
        currentSegment = text
    }

    /// Segment ended with a final result. Mixed-language finals sometimes
    /// re-score to something shorter than the partial the user watched —
    /// whichever preserves more words wins.
    public mutating func finalizeSegment(_ text: String?) {
        let final = text ?? ""
        let segment = final.count >= currentSegment.count ? final : currentSegment
        finalizedText = Self.joined(finalizedText, segment)
        currentSegment = ""
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
