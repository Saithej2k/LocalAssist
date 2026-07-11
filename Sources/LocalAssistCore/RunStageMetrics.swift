import Foundation

/// Per-stage latency for one run, measured with `ContinuousClock` offsets
/// from the moment generation started. Every field is optional: a stage
/// that never ran (no fallback, no model pass) stays nil rather than
/// recording a fabricated zero.
public struct RunStageTimings: Codable, Equatable, Sendable {
    /// First structured partial visible to the UI — the TTFT the user feels.
    public var timeToFirstPartialMilliseconds: Double?
    public var validationMilliseconds: Double?
    public var availabilityMilliseconds: Double?
    /// Model streaming duration (first streaming update → stream end).
    public var modelResponseMilliseconds: Double?
    public var normalizationMilliseconds: Double?
    /// Offset at which the run handed off to the deterministic fallback.
    public var fallbackHandoffMilliseconds: Double?
    /// Fallback duration (handoff → completion).
    public var fallbackCompletionMilliseconds: Double?
    /// Offset at which the final summary arrived.
    public var generationCompletedMilliseconds: Double?
    public var actionPreparationMilliseconds: Double?
    /// Offset at which review cards were ready to render — the full
    /// experience the user waits for.
    public var actionReviewReadyMilliseconds: Double?
    /// History write duration. Stamped by the worker around the append.
    public var persistenceMilliseconds: Double?

    public init() {}
}

/// Where a run happened: enough to interpret its numbers, nothing that
/// identifies content.
public struct RunEnvironment: Codable, Equatable, Sendable {
    public var deviceModel: String
    public var osVersion: String
    /// "debug" or "release".
    public var buildMode: String
    /// Short commit SHA when the build stamped one (Info.plist
    /// `LocalAssistCommitSHA` or LOCALASSIST_COMMIT_SHA env); nil otherwise.
    public var commitSHA: String?
    public var thermalState: String
    public var lowPowerMode: Bool
    /// First generation in this process — cold — versus warm.
    public var coldStart: Bool

    public init(
        deviceModel: String,
        osVersion: String,
        buildMode: String,
        commitSHA: String?,
        thermalState: String,
        lowPowerMode: Bool,
        coldStart: Bool
    ) {
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.buildMode = buildMode
        self.commitSHA = commitSHA
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.coldStart = coldStart
    }

    /// Snapshot of the current process/device state.
    public static func current(coldStart: Bool) -> RunEnvironment {
        let process = ProcessInfo.processInfo
        #if DEBUG
            let buildMode = "debug"
        #else
            let buildMode = "release"
        #endif
        let commit = Bundle.main.object(forInfoDictionaryKey: "LocalAssistCommitSHA") as? String
            ?? process.environment["LOCALASSIST_COMMIT_SHA"]
        return RunEnvironment(
            deviceModel: hardwareModel(),
            osVersion: process.operatingSystemVersionString,
            buildMode: buildMode,
            commitSHA: commit?.nilIfEmpty,
            thermalState: thermalStateName(process.thermalState),
            lowPowerMode: process.isLowPowerModeEnabled,
            coldStart: coldStart
        )
    }

    private static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(bytes: buffer.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "unknown"
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// Context-window bookkeeping for one run, read from the model adapter
/// after generation: how big the prompt was believed to be, what the
/// session retained, and whether overflow handling fired.
public struct ContextWindowDiagnostics: Codable, Equatable, Sendable {
    /// Rough characters in this run's prompt.
    public var estimatedPromptCharacters: Int
    /// Rough characters the session transcript held after the run.
    public var estimatedTranscriptCharacters: Int
    /// Compressed exchanges `ConversationMemory` retained.
    public var retainedExchanges: Int
    /// Sessions rebuilt ahead of a projected overflow, this conversation.
    public var proactiveRebuildCount: Int
    /// Actual `exceededContextWindowSize` errors hit, this conversation.
    public var overflowCount: Int
    /// Outcome of the single post-overflow retry: nil when no overflow
    /// happened, true when the retry produced the summary.
    public var overflowRetrySucceeded: Bool?

    public init(
        estimatedPromptCharacters: Int = 0,
        estimatedTranscriptCharacters: Int = 0,
        retainedExchanges: Int = 0,
        proactiveRebuildCount: Int = 0,
        overflowCount: Int = 0,
        overflowRetrySucceeded: Bool? = nil
    ) {
        self.estimatedPromptCharacters = estimatedPromptCharacters
        self.estimatedTranscriptCharacters = estimatedTranscriptCharacters
        self.retainedExchanges = retainedExchanges
        self.proactiveRebuildCount = proactiveRebuildCount
        self.overflowCount = overflowCount
        self.overflowRetrySucceeded = overflowRetrySucceeded
    }
}

/// Collects phase-transition events from the generation stream into
/// `RunStageTimings`. Pure — callers feed (phase, hasPartial, instant)
/// and read the result — so every mapping rule is unit-testable without
/// a model.
public struct StageTimingCollector: Sendable {
    private let startedAt: ContinuousClock.Instant
    private var timings = RunStageTimings()
    private var currentPhase: SummaryGenerationPhase?
    private var phaseEnteredAt: ContinuousClock.Instant
    private var streamingStartedAt: ContinuousClock.Instant?
    private var fallbackStartedAt: ContinuousClock.Instant?

    public init(startedAt: ContinuousClock.Instant = .now) {
        self.startedAt = startedAt
        phaseEnteredAt = startedAt
    }

    public mutating func record(
        phase: SummaryGenerationPhase,
        hasPartial: Bool,
        hasSummary: Bool,
        at instant: ContinuousClock.Instant = .now
    ) {
        // TTFT: the first update carrying any structured partial, exactly once.
        if hasPartial, timings.timeToFirstPartialMilliseconds == nil {
            timings.timeToFirstPartialMilliseconds = offset(of: instant)
        }

        if phase != currentPhase {
            closeCurrentPhase(at: instant)
            switch phase {
            case .streamingModel:
                if streamingStartedAt == nil {
                    streamingStartedAt = instant
                }
            case .fallback:
                if fallbackStartedAt == nil {
                    fallbackStartedAt = instant
                    timings.fallbackHandoffMilliseconds = offset(of: instant)
                }
            default:
                break
            }
            currentPhase = phase
            phaseEnteredAt = instant
        }

        if hasSummary {
            timings.generationCompletedMilliseconds = offset(of: instant)
            if let streamingStartedAt, timings.modelResponseMilliseconds == nil {
                timings.modelResponseMilliseconds = milliseconds(streamingStartedAt.duration(to: instant))
            }
            if let fallbackStartedAt {
                timings.fallbackCompletionMilliseconds = milliseconds(fallbackStartedAt.duration(to: instant))
            }
        }
    }

    public mutating func recordActionPreparation(_ duration: Duration) {
        timings.actionPreparationMilliseconds = milliseconds(duration)
    }

    public mutating func recordActionReviewReady(at instant: ContinuousClock.Instant = .now) {
        timings.actionReviewReadyMilliseconds = offset(of: instant)
    }

    public var collected: RunStageTimings {
        timings
    }

    private mutating func closeCurrentPhase(at instant: ContinuousClock.Instant) {
        guard let currentPhase else {
            return
        }
        let elapsed = milliseconds(phaseEnteredAt.duration(to: instant))
        switch currentPhase {
        case .validating:
            timings.validationMilliseconds = elapsed
        case .checkingAvailability:
            timings.availabilityMilliseconds = elapsed
        case .normalizing:
            timings.normalizationMilliseconds = elapsed
        case .streamingModel, .fallback, .completed:
            break
        }
    }

    private func offset(of instant: ContinuousClock.Instant) -> Double {
        milliseconds(startedAt.duration(to: instant))
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
