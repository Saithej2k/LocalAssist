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

            var latencies: [Double] = []
            var fallbackCount = 0

            for _ in 0..<arguments.iterations {
                let started = DispatchTime.now().uptimeNanoseconds
                let summary = try await service.summarize(request)
                let ended = DispatchTime.now().uptimeNanoseconds
                latencies.append(Double(ended - started) / 1_000_000)
                if summary.source == .deterministicFallback {
                    fallbackCount += 1
                }
            }

            let cancellation = await Self.measureCancellation(cancelAfterMS: arguments.cancelAfterMS)
            let report = BenchmarkReport(
                iterations: arguments.iterations,
                p50MS: percentile(latencies, 0.50),
                p95MS: percentile(latencies, 0.95),
                peakMemoryMB: peakMemoryMB(),
                cancellationMS: cancellation.latencyMS,
                cancellationSucceeded: cancellation.succeeded,
                fallbackRate: Double(fallbackCount) / Double(arguments.iterations)
            )

            print(report.rendered())
        } catch {
            FileHandle.standardError.write(Data("localassist-bench: \(error)\n".utf8))
            exit(1)
        }
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
        let cancelStarted = DispatchTime.now().uptimeNanoseconds
        task.cancel()

        do {
            _ = try await task.value
            let cancelEnded = DispatchTime.now().uptimeNanoseconds
            return (false, Double(cancelEnded - cancelStarted) / 1_000_000)
        } catch is CancellationError {
            let cancelEnded = DispatchTime.now().uptimeNanoseconds
            return (true, Double(cancelEnded - cancelStarted) / 1_000_000)
        } catch {
            let cancelEnded = DispatchTime.now().uptimeNanoseconds
            return (false, Double(cancelEnded - cancelStarted) / 1_000_000)
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
    var cancelAfterMS = 25

    init<S: Sequence>(_ rawArguments: S) where S.Element == String {
        var iterator = rawArguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--iterations":
                if let value = iterator.next(), let parsed = Int(value), parsed > 0 {
                    iterations = parsed
                }
            case "--cancel-after-ms":
                if let value = iterator.next(), let parsed = Int(value), parsed >= 0 {
                    cancelAfterMS = parsed
                }
            default:
                continue
            }
        }
    }
}

private struct BenchmarkReport {
    var iterations: Int
    var p50MS: Double
    var p95MS: Double
    var peakMemoryMB: Double
    var cancellationMS: Double
    var cancellationSucceeded: Bool
    var fallbackRate: Double

    func rendered() -> String {
        """
        LocalAssist Benchmark
        iterations: \(iterations)
        p50 latency: \(p50MS.roundedString) ms
        p95 latency: \(p95MS.roundedString) ms
        peak memory: \(peakMemoryMB.roundedString) MB
        cancellation: \(cancellationSucceeded ? "passed" : "failed") in \(cancellationMS.roundedString) ms
        fallback rate: \((fallbackRate * 100).roundedString)%
        """
    }
}

private func percentile(_ values: [Double], _ percentile: Double) -> Double {
    guard !values.isEmpty else {
        return 0
    }

    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * percentile).rounded(.toNearestOrAwayFromZero))
    return sorted[min(max(index, 0), sorted.count - 1)]
}

private func peakMemoryMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

private extension Double {
    var roundedString: String {
        String(format: "%.2f", self)
    }
}
