import Foundation

/// Counts model-initiated tool calls during a generation so diagnostics can
/// report how often the summary was grounded in real system data.
public actor ToolInvocationCounter {
    public private(set) var count = 0

    public init() {}

    public func increment() {
        count += 1
    }

    public func reset() {
        count = 0
    }
}
