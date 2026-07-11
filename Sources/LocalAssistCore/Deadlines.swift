import Foundation
import Synchronization

/// Bounded-deadline execution for the stages that talk to system services or
/// the on-device model: generation, tool calls, action preparation,
/// persistence, and drains.
///
/// The caller is released at the deadline even when the operation cannot
/// respond to cancellation — a synchronous XPC call blocked inside tccd or
/// containermanagerd never checks `Task.isCancelled`, and a structured
/// task group would keep awaiting it forever. So the race is unstructured
/// on purpose: the losing operation is cancelled *and abandoned*, the same
/// float-it policy the mic stop-drain uses for a wedged analyzer. The
/// abandoned task's result is discarded when it eventually returns.
public enum LocalAssistDeadline {
    /// Runs `operation` with a deadline. When the budget elapses first the
    /// operation task is cancelled, `DeadlineExceeded` is thrown, and the
    /// caller proceeds without waiting for a non-cooperative operation to
    /// notice. Cancellation of the surrounding task propagates into
    /// `operation` and surfaces as `CancellationError`.
    public static func run<T: Sendable>(
        _ budget: Duration,
        stage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let resumed = Mutex(false)
        // First-to-claim wins; the loser's outcome is dropped.
        let claim: @Sendable () -> Bool = {
            resumed.withLock { alreadyResumed in
                if alreadyResumed {
                    return false
                }
                alreadyResumed = true
                return true
            }
        }

        let holder = Mutex<(operation: Task<Void, Never>?, timeout: Task<Void, Never>?)>((nil, nil))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let operationTask = Task {
                    do {
                        let value = try await operation()
                        if claim() {
                            continuation.resume(returning: value)
                        }
                    } catch {
                        if claim() {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                let timeoutTask = Task {
                    try? await Task.sleep(for: budget)
                    guard !Task.isCancelled else {
                        return
                    }
                    if claim() {
                        operationTask.cancel()
                        continuation.resume(throwing: DeadlineExceeded(stage: stage, budget: budget))
                    }
                }
                holder.withLock { tasks in
                    tasks = (operationTask, timeoutTask)
                }
                // The cancellation handler may have fired before the tasks
                // existed (outer task cancelled before or during setup) —
                // it would have seen nils and cancelled nothing. Re-check
                // now that both tasks are registered; unstructured tasks do
                // not inherit cancellation, so without this the operation
                // would run to completion despite the cancelled caller.
                if Task.isCancelled {
                    operationTask.cancel()
                    timeoutTask.cancel()
                }
            }
        } onCancel: {
            // Outer cancellation: forward into the operation (it reports
            // its own CancellationError through the continuation) and stop
            // the timer.
            let tasks = holder.withLock { $0 }
            tasks.operation?.cancel()
            tasks.timeout?.cancel()
        }
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
