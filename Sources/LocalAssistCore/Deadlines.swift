import Foundation
import Synchronization

/// Bounded-deadline execution for the stages that talk to system services or
/// the on-device model: generation, tool calls, action preparation,
/// persistence, and drains.
///
/// The caller is released the moment any of three outcomes wins a shared
/// first-wins gate: the operation finishing (either way), the budget
/// elapsing, or the *outer task being cancelled* — the last one resumes
/// with `CancellationError` directly from the cancellation handler, so a
/// caller is released promptly even when the operation never observes
/// cancellation (a synchronous XPC call blocked inside tccd checks
/// nothing). The losing operation is cancelled and abandoned — the same
/// float-it policy the mic stop-drain uses for a wedged analyzer — and its
/// eventual result is discarded by the gate.
public enum LocalAssistDeadline {
    /// Runs `operation` with a deadline.
    ///
    /// - Operation finishes first → its value/error, and the timeout task
    ///   is cancelled immediately.
    /// - Budget elapses first → `DeadlineExceeded`; the operation is
    ///   cancelled and abandoned.
    /// - Outer task cancelled → `CancellationError` immediately, however
    ///   uncooperative the operation is; both tasks are cancelled.
    public static func run<T: Sendable>(
        _ budget: Duration,
        stage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = DeadlineGate<T>()
        let holder = DeadlineTaskHolder()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.register(continuation)

                let operationTask = Task {
                    let outcome: Result<T, Error>
                    do {
                        outcome = .success(try await operation())
                    } catch {
                        outcome = .failure(error)
                    }
                    if gate.resume(with: outcome) {
                        // The race is settled — stop the timer now instead
                        // of letting it sleep out the rest of the budget.
                        holder.cancelTimeout()
                    }
                }
                let timeoutTask = Task {
                    try? await Task.sleep(for: budget)
                    guard !Task.isCancelled else {
                        return
                    }
                    if gate.resume(with: .failure(DeadlineExceeded(stage: stage, budget: budget))) {
                        holder.cancelOperation()
                    }
                }
                holder.set(operation: operationTask, timeout: timeoutTask)

                // Two install races closed now that both tasks are
                // registered: the outer task may have been cancelled before
                // the handler could see any tasks, and the operation may
                // have finished before the holder was populated (its
                // timeout-cancel would have read nil).
                if Task.isCancelled {
                    if gate.resume(with: .failure(CancellationError())) {
                        operationTask.cancel()
                    }
                    timeoutTask.cancel()
                } else if gate.isSettled {
                    timeoutTask.cancel()
                }
            }
        } onCancel: {
            // Explicit release: the caller gets CancellationError from the
            // gate even when the operation never cooperates.
            if gate.resume(with: .failure(CancellationError())) {
                holder.cancelAll()
            }
        }
    }
}

/// Reference wrapper for the two racing tasks: `Mutex` itself is
/// noncopyable and cannot be captured by multiple concurrent closures, so
/// the closures share this class instead.
private final class DeadlineTaskHolder: Sendable {
    private let tasks = Mutex<(operation: Task<Void, Never>?, timeout: Task<Void, Never>?)>((nil, nil))

    func set(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        tasks.withLock { $0 = (operation, timeout) }
    }

    func cancelTimeout() {
        tasks.withLock { $0.timeout }?.cancel()
    }

    func cancelOperation() {
        tasks.withLock { $0.operation }?.cancel()
    }

    func cancelAll() {
        let current = tasks.withLock { $0 }
        current.operation?.cancel()
        current.timeout?.cancel()
    }
}

/// First-wins resumption gate for one continuation. Whichever of the three
/// racers (operation, timeout, outer cancellation) resumes first wins; the
/// rest are no-ops. Registration and resolution may arrive in either order —
/// an early resolution is buffered and delivered the moment the
/// continuation registers.
private final class DeadlineGate<T: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<T, Error>)
        case resolvedEarly(Result<T, Error>)
        case finished
    }

    private let state = Mutex(State.idle)

    func register(_ continuation: CheckedContinuation<T, Error>) {
        let buffered: Result<T, Error>? = state.withLock { current in
            switch current {
            case .idle:
                current = .waiting(continuation)
                return nil
            case .resolvedEarly(let result):
                current = .finished
                return result
            case .waiting, .finished:
                // A continuation registers exactly once; these are
                // unreachable by construction.
                return nil
            }
        }
        if let buffered {
            continuation.resume(with: buffered)
        }
    }

    private enum ResumeAction {
        case deliver(CheckedContinuation<T, Error>)
        case buffered
        case lost
    }

    /// True when this call won the race; the winner performs the follow-up
    /// cancellation of the losing tasks.
    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        let action: ResumeAction = state.withLock { current in
            switch current {
            case .idle:
                current = .resolvedEarly(result)
                return .buffered
            case .waiting(let continuation):
                current = .finished
                return .deliver(continuation)
            case .resolvedEarly, .finished:
                return .lost
            }
        }
        switch action {
        case .deliver(let continuation):
            continuation.resume(with: result)
            return true
        case .buffered:
            return true
        case .lost:
            return false
        }
    }

    var isSettled: Bool {
        state.withLock { current in
            switch current {
            case .resolvedEarly, .finished:
                return true
            case .idle, .waiting:
                return false
            }
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
