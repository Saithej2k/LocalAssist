import Darwin
import Foundation
import LocalAssistCore

@main
struct LocalAssistBenchmarks {
    static func main() async {
        do {
            let arguments = BenchmarkArguments(CommandLine.arguments.dropFirst())
            let request = AssistantRequest(
                sourceText: Self.sampleText,
                maxSuggestions: 5
            )
            let service = LocalAssistService()

            for _ in 0..<arguments.warmupIterations {
                _ = try await service.summarize(request)
            }

            let startedAt = Date()
            let peakBefore = peakMemoryMB()
            let runStarted = ContinuousClock.now
            let measured = try await measure(
                iterations: arguments.iterations,
                concurrency: arguments.concurrency,
                service: service,
                request: request
            )
            let totalDurationMS = runStarted.duration(to: ContinuousClock.now).milliseconds
            let peakAfter = peakMemoryMB()
            let cancellation = await measureCancellation(cancelAfterMS: arguments.cancelAfterMS)

            let report = BenchmarkReport(
                startedAt: startedAt,
                completedAt: Date(),
                configuration: BenchmarkConfiguration(
                    iterations: arguments.iterations,
                    warmupIterations: arguments.warmupIterations,
                    concurrency: arguments.concurrency,
                    cancelAfterMS: arguments.cancelAfterMS
                ),
                latencyMilliseconds: MetricDistribution(samples: measured.latencies),
                totalDurationMilliseconds: totalDurationMS,
                throughputPerSecond: measured.throughput(totalDurationMS: totalDurationMS),
                peakMemoryMB: peakAfter,
                peakMemoryDeltaMB: max(peakAfter - peakBefore, 0),
                cancellationMilliseconds: cancellation.latencyMS,
                cancellationSucceeded: cancellation.succeeded,
                fallbackRate: measured.fallbackRate,
                successCount: measured.successCount,
                failureCount: measured.failureCount
            )

            if let outputPath = arguments.outputPath {
                try report.jsonData().write(to: URL(fileURLWithPath: outputPath), options: [.atomic])
            }

            if arguments.jsonOutput {
                print(String(decoding: try report.jsonData(), as: UTF8.self))
            } else {
                print(report.rendered())
            }
        } catch {
            FileHandle.standardError.write(Data("localassist-bench: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func measure(
        iterations: Int,
        concurrency: Int,
        service: LocalAssistService,
        request: AssistantRequest
    ) async throws -> BenchmarkMeasurements {
        var measurements = BenchmarkMeasurements()
        var remaining = iterations

        while remaining > 0 {
            let batchSize = min(concurrency, remaining)
            let batch = try await withThrowingTaskGroup(of: IterationResult.self) { group in
                for _ in 0..<batchSize {
                    group.addTask {
                        let started = ContinuousClock.now
                        let summary = try await service.summarize(request)
                        return IterationResult(
                            latencyMS: started.duration(to: ContinuousClock.now).milliseconds,
                            source: summary.source
                        )
                    }
                }

                var output: [IterationResult] = []
                for try await result in group {
                    output.append(result)
                }
                return output
            }

            measurements.record(batch)
            remaining -= batchSize
        }

        return measurements
    }

    private static func measureCancellation(cancelAfterMS: Int) async -> (succeeded: Bool, latencyMS: Double) {
        let delayedModel = StaticLanguageModelClient(
            state: .available,
            response: "{}",
            delayNanoseconds: 2_000_000_000
        )
        let service = LocalAssistService(primaryModel: delayedModel)
        let request = AssistantRequest(sourceText: sampleText)

        let task = Task {
            try await service.summarize(request)
        }

        try? await Task.sleep(nanoseconds: UInt64(cancelAfterMS) * 1_000_000)
        let cancelStarted = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            return (false, cancelStarted.duration(to: ContinuousClock.now).milliseconds)
        } catch is CancellationError {
            return (true, cancelStarted.duration(to: ContinuousClock.now).milliseconds)
        } catch {
            return (false, cancelStarted.duration(to: ContinuousClock.now).milliseconds)
        }
    }

    private static let sampleText = """
    Review the onboarding doc and send Mira the open blockers by Friday.
    Schedule a design sync next week, update the launch checklist, and prepare release notes.
    The app must continue working offline when the on-device language model is unavailable.
    """
}

private struct BenchmarkArguments {
    var iterations = 30
    var warmupIterations = 3
    var concurrency = 1
    var cancelAfterMS = 25
    var jsonOutput = false
    var outputPath: String?

    init<S: Sequence>(_ rawArguments: S) where S.Element == String {
        var iterator = rawArguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--iterations":
                if let value = iterator.next(), let parsed = Int(value), parsed > 0 {
                    iterations = parsed
                }
            case "--warmup":
                if let value = iterator.next(), let parsed = Int(value), parsed >= 0 {
                    warmupIterations = parsed
                }
            case "--concurrency":
                if let value = iterator.next(), let parsed = Int(value), parsed > 0 {
                    concurrency = parsed
                }
            case "--cancel-after-ms":
                if let value = iterator.next(), let parsed = Int(value), parsed >= 0 {
                    cancelAfterMS = parsed
                }
            case "--json":
                jsonOutput = true
            case "--output":
                outputPath = iterator.next()
            default:
                continue
            }
        }
    }
}

private struct BenchmarkConfiguration: Codable, Equatable, Sendable {
    var iterations: Int
    var warmupIterations: Int
    var concurrency: Int
    var cancelAfterMS: Int
}

private struct BenchmarkReport: Codable, Equatable, Sendable {
    var startedAt: Date
    var completedAt: Date
    var configuration: BenchmarkConfiguration
    var latencyMilliseconds: MetricDistribution
    var totalDurationMilliseconds: Double
    var throughputPerSecond: Double
    var peakMemoryMB: Double
    var peakMemoryDeltaMB: Double
    var cancellationMilliseconds: Double
    var cancellationSucceeded: Bool
    var fallbackRate: Double
    var successCount: Int
    var failureCount: Int

    func rendered() -> String {
        """
        LocalAssist Benchmark
        iterations: \(configuration.iterations)
        warmup iterations: \(configuration.warmupIterations)
        concurrency: \(configuration.concurrency)
        successes: \(successCount)
        failures: \(failureCount)
        latency min / mean / max: \(latencyMilliseconds.minimum.roundedString) / \(latencyMilliseconds.mean.roundedString) / \(latencyMilliseconds.maximum.roundedString) ms
        latency p50 / p75 / p90 / p95 / p99: \(latencyMilliseconds.p50.roundedString) / \(latencyMilliseconds.p75.roundedString) / \(latencyMilliseconds.p90.roundedString) / \(latencyMilliseconds.p95.roundedString) / \(latencyMilliseconds.p99.roundedString) ms
        throughput: \(throughputPerSecond.roundedString) requests/sec
        peak memory: \(peakMemoryMB.roundedString) MB
        peak memory delta: \(peakMemoryDeltaMB.roundedString) MB
        cancellation: \(cancellationSucceeded ? "passed" : "failed") in \(cancellationMilliseconds.roundedString) ms
        fallback rate: \((fallbackRate * 100).roundedString)%
        """
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

private struct BenchmarkMeasurements {
    var latencies: [Double] = []
    var fallbackCount = 0
    var successCount = 0
    var failureCount = 0

    var fallbackRate: Double {
        guard successCount > 0 else {
            return 0
        }
        return Double(fallbackCount) / Double(successCount)
    }

    mutating func record(_ results: [IterationResult]) {
        for result in results {
            latencies.append(result.latencyMS)
            successCount += 1
            if result.source == .deterministicFallback {
                fallbackCount += 1
            }
        }
    }

    func throughput(totalDurationMS: Double) -> Double {
        guard totalDurationMS > 0 else {
            return 0
        }
        return Double(successCount) / (totalDurationMS / 1_000)
    }
}

private struct IterationResult: Sendable {
    var latencyMS: Double
    var source: GenerationSource
}

private func peakMemoryMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

private extension Duration {
    var milliseconds: Double {
        let components = components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private extension Double {
    var roundedString: String {
        String(format: "%.2f", self)
    }
}
