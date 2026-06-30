import Foundation

public struct MetricDistribution: Codable, Equatable, Sendable {
    public var count: Int
    public var minimum: Double
    public var maximum: Double
    public var mean: Double
    public var standardDeviation: Double
    public var p50: Double
    public var p75: Double
    public var p90: Double
    public var p95: Double
    public var p99: Double

    public init(samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        minimum = sorted.first ?? 0
        maximum = sorted.last ?? 0

        if sorted.isEmpty {
            mean = 0
            standardDeviation = 0
            p50 = 0
            p75 = 0
            p90 = 0
            p95 = 0
            p99 = 0
            return
        }

        let meanValue = sorted.reduce(0, +) / Double(sorted.count)
        let variance = sorted.reduce(0) { partial, value in
            let delta = value - meanValue
            return partial + delta * delta
        } / Double(sorted.count)
        mean = meanValue
        standardDeviation = sqrt(variance)
        p50 = Self.percentile(sorted, 0.50)
        p75 = Self.percentile(sorted, 0.75)
        p90 = Self.percentile(sorted, 0.90)
        p95 = Self.percentile(sorted, 0.95)
        p99 = Self.percentile(sorted, 0.99)
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else {
            return 0
        }

        let index = Int((Double(sorted.count - 1) * percentile).rounded(.toNearestOrAwayFromZero))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

public struct AggregateRunMetrics: Codable, Equatable, Sendable {
    public var runCount: Int
    public var latencyMilliseconds: MetricDistribution
    public var foundationModelRuns: Int
    public var fallbackRuns: Int
    public var averageSuggestions: Double
    public var averageActionDrafts: Double
    public var latestRunAt: Date?

    public init(runs: [AssistantRun]) {
        runCount = runs.count
        latencyMilliseconds = MetricDistribution(samples: runs.map(\.metrics.durationMilliseconds))
        foundationModelRuns = runs.filter { $0.summary.source == .foundationModels }.count
        fallbackRuns = runs.filter { $0.summary.source == .deterministicFallback }.count
        averageSuggestions = Self.average(runs.map { Double($0.metrics.suggestionCount) })
        averageActionDrafts = Self.average(runs.map { Double($0.metrics.actionDraftCount) })
        latestRunAt = runs.map(\.metrics.finishedAt).max()
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }
}
