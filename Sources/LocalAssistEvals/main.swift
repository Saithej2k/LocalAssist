import Foundation
import LocalAssistCore
import LocalAssistEvalKit
import LocalAssistFoundationModels

@main
struct LocalAssistEvalCommand {
    static func main() async {
        do {
            let arguments = EvalArguments(CommandLine.arguments.dropFirst())
            if arguments.helpRequested {
                print(usage)
                return
            }

            let service: LocalAssistService
            let label: String
            if arguments.live {
                service = LocalAssistLiveFactory.makeService()
                let availability = await service.availability()
                guard availability.isAvailable else {
                    FileHandle.standardError.write(Data(
                        "localassist-eval: --live requested but the model is unavailable: \(availability.reason ?? "unknown")\n".utf8
                    ))
                    exit(2)
                }
                label = "foundation-models (live on-device)"
            } else {
                service = LocalAssistService()
                label = "deterministic-fallback"
            }

            let report = try await EvalRunner.run(service: service, configurationLabel: label)
            print(report.renderedMarkdown())

            if let outputDirectory = arguments.outputDirectory {
                let dateStamp = ISO8601DateFormatter.dateStamp(from: report.completedAt)
                let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                let suffix = arguments.live ? "live" : "fallback"
                try report.jsonData().write(
                    to: directory.appendingPathComponent("\(dateStamp)-eval-\(suffix).json"),
                    options: [.atomic]
                )
                try Data(report.renderedMarkdown().utf8).write(
                    to: directory.appendingPathComponent("\(dateStamp)-eval-\(suffix).md"),
                    options: [.atomic]
                )
            }

            if report.meanComposite < arguments.minScore {
                FileHandle.standardError.write(Data(
                    "localassist-eval: mean composite \(report.meanComposite.scoreString) is below threshold \(arguments.minScore)\n".utf8
                ))
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("localassist-eval: \(error)\n".utf8))
            exit(1)
        }
    }

    private static let usage = """
    localassist-eval — deterministic output-quality harness

    Runs the fixed eval dataset through the summarization pipeline and scores
    task recall, due-hint accuracy, action mapping, structure compliance, and
    hallucination probes. Scores are reproducible and safe to gate CI on.

    USAGE:
      localassist-eval [--live] [--output docs/evals] [--min-score 0.8]

    OPTIONS:
      --live               Use the on-device Foundation Models pipeline (requires
                           an eligible device with Apple Intelligence enabled).
                           Default runs the deterministic offline fallback.
      --output <dir>       Write dated JSON + markdown reports into <dir>.
      --min-score <value>  Exit non-zero if the mean composite drops below this.
                           Default: 0.75.
      --help               Show this help text.
    """
}

private struct EvalArguments {
    var live = false
    var outputDirectory: String?
    var minScore = 0.75
    var helpRequested = false

    init<S: Sequence>(_ rawArguments: S) where S.Element == String {
        var iterator = rawArguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--live":
                live = true
            case "--output":
                outputDirectory = iterator.next()
            case "--min-score":
                if let value = iterator.next(), let parsed = Double(value) {
                    minScore = parsed
                }
            case "--help", "-h":
                helpRequested = true
            default:
                continue
            }
        }
    }
}

private extension ISO8601DateFormatter {
    static func dateStamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
