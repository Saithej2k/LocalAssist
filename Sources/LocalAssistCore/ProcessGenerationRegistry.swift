import Foundation
import Synchronization

/// Process-wide count of generation runs, bumped by the service at the
/// start of every summarize stream. Exists so cold/warm classification is
/// grounded in what the process actually did — "no generation has happened
/// yet in this process" is a fact this counter states directly, instead of
/// each component guessing from its own partial view.
public enum ProcessGenerationRegistry {
    private static let count = Mutex(0)

    /// Records one generation start and returns how many came before it.
    @discardableResult
    public static func recordGenerationStart() -> Int {
        count.withLock { value in
            defer { value += 1 }
            return value
        }
    }

    /// Generations started so far in this process.
    public static func generationsStarted() -> Int {
        count.withLock { $0 }
    }
}
