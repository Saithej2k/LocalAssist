import Foundation

public struct GenerationClock: Sendable {
    private let nowProvider: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date) {
        nowProvider = now
    }

    public func now() -> Date {
        nowProvider()
    }

    public static let system = GenerationClock { Date() }

    /// Wednesday, July 1, 2026 12:00 UTC. Tests and deterministic fixtures use
    /// this so relative deadlines resolve byte-for-byte the same way.
    public static let frozenReferenceDate = Date(timeIntervalSince1970: 1_782_907_200)

    public static let frozen = GenerationClock { frozenReferenceDate }
}
