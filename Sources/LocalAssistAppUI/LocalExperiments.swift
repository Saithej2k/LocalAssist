import Foundation
import OSLog

/// Local A/B experiment scaffolding: deterministic assignment from a stable
/// per-install identity, exposure logging, and a per-experiment pin that
/// doubles as kill switch and staged-rollout control.
///
/// Deliberately serverless: assignment must work offline, and the app's
/// privacy stance rules out shipping cohort data anywhere. The pieces a
/// backend would add plug in at two seams — a remote config source replaces
/// `pinned`, and a telemetry uploader consumes the exposure log. Until
/// then, exposures land in the unified log so on-device analysis can join
/// behavior to assignment.
public enum LocalExperiments {
    public enum Variant: String, Sendable {
        case control
        case treatment
    }

    public struct Experiment: Sendable {
        public let name: String
        /// Fraction of installs bucketed into treatment (0...1).
        public let treatmentShare: Double
        /// Non-nil overrides bucketing for every install: `.control` is
        /// the kill switch, `.treatment` is full rollout.
        public let pinned: Variant?

        public init(name: String, treatmentShare: Double, pinned: Variant? = nil) {
            self.name = name
            self.treatmentShare = treatmentShare
            self.pinned = pinned
        }
    }

    /// Mic-stop drain budget: control keeps the device-proven 3s wait for
    /// late finals; treatment would test whether 2s loses any words.
    /// Pinned to control until the treatment has on-device evidence.
    public static let micStopDrain = Experiment(
        name: "mic-stop-drain-2s",
        treatmentShare: 0.5,
        pinned: .control
    )

    private static let log = Logger(subsystem: "com.saithej.localassist", category: "Experiments")
    private static let installIDKey = "localassist.experiments.installID"
    private static let exposures = ExposureLedger()

    public static func variant(for experiment: Experiment, defaults: UserDefaults = .standard) -> Variant {
        if let pinned = experiment.pinned {
            return pinned
        }
        return bucket(installID: installID(defaults: defaults), experiment: experiment)
    }

    /// Log once per process per experiment; repeated calls are free.
    public static func logExposure(_ experiment: Experiment, variant: Variant) {
        guard exposures.markExposed(experiment.name) else {
            return
        }
        log.info("exposure: \(experiment.name, privacy: .public)=\(variant.rawValue, privacy: .public)")
    }

    /// Stable anonymous identity: a per-install UUID that never leaves the
    /// device and resets with reinstall — deliberately not a hardware ID.
    static func installID(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: installIDKey) {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: installIDKey)
        return fresh
    }

    /// Deterministic, uniform bucketing: FNV-1a over "installID:experiment"
    /// so each experiment re-randomizes independently of the others.
    static func bucket(installID: String, experiment: Experiment) -> Variant {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in "\(installID):\(experiment.name)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let unit = Double(hash % 10_000) / 10_000
        return unit < experiment.treatmentShare ? .treatment : .control
    }

    /// Once-per-process exposure dedupe, callable from any isolation.
    private final class ExposureLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<String> = []

        func markExposed(_ name: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return seen.insert(name).inserted
        }
    }
}
