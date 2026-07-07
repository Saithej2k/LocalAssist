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

    /// Parses a direct command ("text Priya that brunch works") into routed
    /// actions. Returning nil means the client doesn't support routing and
    /// the service should use the deterministic router instead; throwing a
    /// `GenerationFailure` means routing was attempted and failed.
    func routeCommand(for request: AssistantRequest) async throws -> [RoutedAction]?
}

public extension StructuredModelClient {
    func prewarm() async {}

    func routeCommand(for _: AssistantRequest) async throws -> [RoutedAction]? {
        nil
    }
}

/// Scriptable model double for tests, benchmarks, and previews.
public struct StaticStructuredModelClient: StructuredModelClient {
    public var state: ModelAvailability
    public var script: [StructuredSummaryPartial]
    public var failure: GenerationFailure?
    public var initialDelayNanoseconds: UInt64
    public var chunkDelayNanoseconds: UInt64
    /// Scripted answer for `routeCommand`; nil keeps the protocol default
    /// ("routing unsupported"), which exercises the deterministic path.
    public var routedActions: [RoutedAction]?
    public var routingFailure: GenerationFailure?

    public init(
        state: ModelAvailability = .available,
        script: [StructuredSummaryPartial] = [],
        failure: GenerationFailure? = nil,
        initialDelayNanoseconds: UInt64 = 0,
        chunkDelayNanoseconds: UInt64 = 0,
        routedActions: [RoutedAction]? = nil,
        routingFailure: GenerationFailure? = nil
    ) {
        self.state = state
        self.script = script
        self.failure = failure
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
        self.routedActions = routedActions
        self.routingFailure = routingFailure
    }

    public func routeCommand(for _: AssistantRequest) async throws -> [RoutedAction]? {
        if let routingFailure {
            throw routingFailure
        }
        return routedActions
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
