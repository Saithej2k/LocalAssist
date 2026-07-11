import Foundation

/// Bounded-deadline execution for the stages that talk to system services or
/// the on-device model: generation, tool calls, action preparation,
/// persistence, and drains. Cooperative — the losing side is cancelled, not
/// abandoned, so an overrunning stage stops doing work instead of racing the
/// caller for shared state.
public enum LocalAssistDeadline {
    /// Runs `operation` with a deadline. When the budget elapses first the
    /// operation task is cancelled and `DeadlineExceeded` is thrown; the
    /// caller decides policy (fall back, retry, surface). Cancellation of
    /// the surrounding task propagates into `operation` unchanged.
    public static func run<T: Sendable>(
        _ budget: Duration,
        stage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: DeadlineOutcome<T>.self) { group in
            group.addTask {
                .finished(try await operation())
            }
            group.addTask {
                try await Task.sleep(for: budget)
                return .deadlineElapsed
            }

            defer {
                group.cancelAll()
            }
            while let outcome = try await group.next() {
                switch outcome {
                case .finished(let value):
                    return value
                case .deadlineElapsed:
                    throw DeadlineExceeded(stage: stage, budget: budget)
                }
            }
            // The group never runs dry before one child returns; reaching
            // here means the operation was cancelled from outside.
            throw CancellationError()
        }
    }

    private enum DeadlineOutcome<T: Sendable>: Sendable {
        case finished(T)
        case deadlineElapsed
    }
}

/// A stage overran its budget. Carries no user content — the stage name is a
/// code-defined constant, safe for logs and diagnostics.
public struct DeadlineExceeded: Error, Equatable, Sendable {
    public var stage: String
    public var budget: Duration

    public init(stage: String, budget: Duration) {
        self.stage = stage
        self.budget = budget
    }
}
