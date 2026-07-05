import Foundation

/// Abstraction over an on-device model that produces typed summary partials.
///
/// The Foundation Models adapter conforms with real guided generation;
/// `StaticStructuredModelClient` scripts snapshots for deterministic tests.
public protocol StructuredModelClient: Sendable {
    func availability() async -> ModelAvailability

    /// Loads model resources ahead of the first request to cut time-to-first-token.
    func prewarm() async

    /// Streams typed snapshots. The final element must have `isComplete == true`.
    /// Failures are surfaced as `GenerationFailure` values.
    func streamSummary(for request: AssistantRequest) -> AsyncThrowingStream<StructuredSummaryPartial, Error>
}

public extension StructuredModelClient {
    func prewarm() async {}
}

/// Scriptable model double for tests, benchmarks, and previews.
public struct StaticStructuredModelClient: StructuredModelClient {
    public var state: ModelAvailability
    public var script: [StructuredSummaryPartial]
    public var failure: GenerationFailure?
    public var initialDelayNanoseconds: UInt64
    public var chunkDelayNanoseconds: UInt64

    public init(
        state: ModelAvailability = .available,
        script: [StructuredSummaryPartial] = [],
        failure: GenerationFailure? = nil,
        initialDelayNanoseconds: UInt64 = 0,
        chunkDelayNanoseconds: UInt64 = 0
    ) {
        self.state = state
        self.script = script
        self.failure = failure
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }

    /// Convenience client that streams towards one complete summary partial.
    public static func completing(
        with partial: StructuredSummaryPartial,
        initialDelayNanoseconds: UInt64 = 0
    ) -> StaticStructuredModelClient {
        var overviewOnly = StructuredSummaryPartial(overview: partial.overview)
        overviewOnly.isComplete = false
        var complete = partial
        complete.isComplete = true
        return StaticStructuredModelClient(
            script: [overviewOnly, complete],
            initialDelayNanoseconds: initialDelayNanoseconds
        )
    }

    public func availability() async -> ModelAvailability {
        state
    }

    public func streamSummary(for _: AssistantRequest) -> AsyncThrowingStream<StructuredSummaryPartial, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if initialDelayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: initialDelayNanoseconds)
                    }

                    for chunk in script {
                        if chunkDelayNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: chunkDelayNanoseconds)
                        }
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }

                    if let failure {
                        continuation.finish(throwing: failure)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
