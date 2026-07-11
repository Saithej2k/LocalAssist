import Foundation
import Synchronization

/// Monotonic timestamps for one voice-capture session, recorded with
/// `ContinuousClock` so sleep/clock changes can't corrupt intervals.
///
/// Timing only, never content: the snapshot carries millisecond offsets and
/// counts, so it is safe for logs and the redacted diagnostics export.
public struct VoiceSessionTimeline: Sendable {
    private var tapRequestedAt: ContinuousClock.Instant?
    private var audioReadyAt: ContinuousClock.Instant?
    private var firstFrameAt: ContinuousClock.Instant?
    private var analyzerStartedAt: ContinuousClock.Instant?
    private var firstPartialAt: ContinuousClock.Instant?
    private var lastFrameAt: ContinuousClock.Instant?
    private var finalResultAt: ContinuousClock.Instant?
    private var drainCompletedAt: ContinuousClock.Instant?

    public init() {}

    public mutating func recordTapRequested(now: ContinuousClock.Instant = .now) {
        tapRequestedAt = now
    }

    public mutating func recordAudioReady(now: ContinuousClock.Instant = .now) {
        audioReadyAt = now
    }

    /// Every frame updates the last-frame mark; the first one also sets the
    /// first-frame mark.
    public mutating func recordFrame(now: ContinuousClock.Instant = .now) {
        if firstFrameAt == nil {
            firstFrameAt = now
        }
        lastFrameAt = now
    }

    public mutating func recordAnalyzerStarted(now: ContinuousClock.Instant = .now) {
        analyzerStartedAt = now
    }

    /// Idempotent: only the first partial counts, however many arrive.
    public mutating func recordFirstPartial(now: ContinuousClock.Instant = .now) {
        guard firstPartialAt == nil else {
            return
        }
        firstPartialAt = now
    }

    public mutating func recordFinalResult(now: ContinuousClock.Instant = .now) {
        finalResultAt = now
    }

    public mutating func recordDrainCompleted(now: ContinuousClock.Instant = .now) {
        drainCompletedAt = now
    }

    /// Offsets in milliseconds from the tap request — the user-perceived
    /// zero point. Nil for stages that never happened (no speech, error).
    public var snapshot: Snapshot {
        func offset(_ instant: ContinuousClock.Instant?) -> Double? {
            guard let tapRequestedAt, let instant else {
                return nil
            }
            return (tapRequestedAt.duration(to: instant)).milliseconds
        }
        return Snapshot(
            audioReadyMilliseconds: offset(audioReadyAt),
            firstFrameMilliseconds: offset(firstFrameAt),
            analyzerStartMilliseconds: offset(analyzerStartedAt),
            firstPartialMilliseconds: offset(firstPartialAt),
            lastFrameMilliseconds: offset(lastFrameAt),
            finalResultMilliseconds: offset(finalResultAt),
            drainCompletedMilliseconds: offset(drainCompletedAt)
        )
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var audioReadyMilliseconds: Double?
        public var firstFrameMilliseconds: Double?
        public var analyzerStartMilliseconds: Double?
        public var firstPartialMilliseconds: Double?
        public var lastFrameMilliseconds: Double?
        public var finalResultMilliseconds: Double?
        public var drainCompletedMilliseconds: Double?
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

/// The timeline shared between the audio tap thread (frame marks) and the
/// main actor (everything else). `Mutex` expresses the ownership directly —
/// no `@unchecked Sendable`.
public final class LockedVoiceTimeline: Sendable {
    private let state = Mutex(VoiceSessionTimeline())

    public init() {}

    public func reset() {
        state.withLock { $0 = VoiceSessionTimeline() }
    }

    public func recordTapRequested() {
        state.withLock { $0.recordTapRequested() }
    }

    public func recordAudioReady() {
        state.withLock { $0.recordAudioReady() }
    }

    public func recordFrame() {
        state.withLock { $0.recordFrame() }
    }

    public func recordAnalyzerStarted() {
        state.withLock { $0.recordAnalyzerStarted() }
    }

    public func recordFirstPartial() {
        state.withLock { $0.recordFirstPartial() }
    }

    public func recordFinalResult() {
        state.withLock { $0.recordFinalResult() }
    }

    public func recordDrainCompleted() {
        state.withLock { $0.recordDrainCompleted() }
    }

    public var snapshot: VoiceSessionTimeline.Snapshot {
        state.withLock { $0.snapshot }
    }
}
