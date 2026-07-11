import Foundation
import LocalAssistCore
import LocalAssistEvalKit
import LocalAssistFoundationModels
#if canImport(AVFoundation) && canImport(Speech)
    import AVFoundation
    import Speech
#endif

/// End-to-end speech eval: every text eval case is spoken by the system
/// synthesizer, transcribed back through the same SpeechAnalyzer stack the
/// app's mic path uses, scored for word error rate against what was spoken,
/// and then pushed through the task pipeline so recognition errors show up
/// as the downstream task-accuracy hit they actually cause. The text-input
/// composite runs alongside as the ceiling: the delta is the price of the
/// speech front end, isolated from summarization quality.
///
/// Synthetic audio is the honest caveat, stated on every report: TTS is
/// cleaner than a human in a kitchen, so treat these numbers as an upper
/// bound on recognition and a regression tripwire, not a field measurement.
@main
struct LocalAssistSpeechEvalCommand {
    static func main() {
        let arguments = SpeechEvalArguments(CommandLine.arguments.dropFirst())
        if arguments.helpRequested {
            print(usage)
            return
        }

        #if canImport(AVFoundation) && canImport(Speech)
            run(arguments: arguments)
        #else
            FileHandle.standardError.write(Data(
                "localassist-speecheval: this platform has no Speech/AVFoundation stack.\n".utf8
            ))
            exit(2)
        #endif
    }

    #if canImport(AVFoundation) && canImport(Speech)
        private static func run(arguments: SpeechEvalArguments) {
            // Phase 1 — synthesis, on the main thread with an explicit run
            // loop pump: AVSpeechSynthesizer delivers its write buffers via
            // the main run loop, and a blocked main thread starves them
            // (measured: the callback simply never fires).
            let workDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("localassist-speecheval-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: workDirectory)
            }

            var utterances: [PreparedUtterance] = []
            for evalCase in EvalDataset.standard {
                let spoken = SpokenForm.render(evalCase.input)
                let url = workDirectory.appendingPathComponent("\(evalCase.id).caf")
                let start = ContinuousClock.now
                guard synthesize(spoken, to: url) else {
                    FileHandle.standardError.write(Data(
                        "localassist-speecheval: synthesis failed for \(evalCase.id)\n".utf8
                    ))
                    exit(1)
                }
                utterances.append(PreparedUtterance(
                    evalCase: evalCase,
                    spoken: spoken,
                    audioURL: url,
                    synthMilliseconds: start.millisecondsToNow
                ))
            }

            // Phase 2 — transcription and scoring, async, pumping the run
            // loop while waiting so nothing scheduled on main starves.
            let box = ResultBox()
            let live = arguments.live
            Task {
                do {
                    box.report = try await score(utterances: utterances, live: live)
                } catch {
                    box.failure = String(describing: error)
                }
                box.finished = true
            }
            while !box.finished {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }

            if let failure = box.failure {
                FileHandle.standardError.write(Data("localassist-speecheval: \(failure)\n".utf8))
                exit(1)
            }
            guard let report = box.report else {
                exit(1)
            }

            print(report.renderedMarkdown())

            if let outputDirectory = arguments.outputDirectory {
                do {
                    let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let suffix = arguments.live ? "live" : "fallback"
                    let stamp = SpeechEvalReport.dateStamp(from: report.completedAt)
                    try report.jsonData().write(
                        to: directory.appendingPathComponent("\(stamp)-speecheval-\(suffix).json"),
                        options: [.atomic]
                    )
                    try Data(report.renderedMarkdown().utf8).write(
                        to: directory.appendingPathComponent("\(stamp)-speecheval-\(suffix).md"),
                        options: [.atomic]
                    )
                } catch {
                    FileHandle.standardError.write(Data("localassist-speecheval: report write failed: \(error)\n".utf8))
                    exit(1)
                }
            }

            if let maxWordErrorRate = arguments.maxWordErrorRate,
               report.meanWordErrorRate > maxWordErrorRate {
                FileHandle.standardError.write(Data(
                    "localassist-speecheval: mean WER \(report.meanWordErrorRate.scoreString) exceeds \(maxWordErrorRate)\n".utf8
                ))
                exit(1)
            }
        }

        /// Main-thread synthesis with a bounded run-loop pump.
        private static func synthesize(_ text: String, to url: URL) -> Bool {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            let synthesizer = AVSpeechSynthesizer()
            let state = SynthesisState()
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    return
                }
                if pcm.frameLength == 0 {
                    state.done = true
                    return
                }
                do {
                    if state.file == nil {
                        state.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
                    }
                    try state.file?.write(from: pcm)
                } catch {
                    state.done = true
                }
            }
            let deadline = Date().addingTimeInterval(30)
            while !state.done, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            state.file = nil
            return state.done && FileManager.default.fileExists(atPath: url.path)
        }

        private static func score(
            utterances: [PreparedUtterance],
            live: Bool
        ) async throws -> SpeechEvalReport {
            let startedAt = Date()
            let service: LocalAssistService
            let label: String
            if live {
                service = LocalAssistLiveFactory.makeService()
                let availability = await service.availability()
                guard availability.isAvailable else {
                    throw SpeechEvalFailure.modelUnavailable(availability.reason ?? "unknown")
                }
                label = "speech + foundation-models (live on-device)"
            } else {
                service = LocalAssistService()
                label = "speech + deterministic-fallback"
            }

            let locale = await resolvedLocale()
            try await installAssetsIfNeeded(locale: locale)

            var results: [SpeechCaseResult] = []
            for utterance in utterances {
                let transcription = try await transcribe(
                    url: utterance.audioURL,
                    locale: locale
                )
                // Ablation ladder, one variable at a time:
                //   gold text → full accumulator → name-corrected → finals-only.
                // The accumulator output is the app path; the corrected pass
                // measures what a contact-aware resolver claws back; the
                // finals-only pass prices a lost volatile tail.
                let accumulatorTranscript = transcription.accumulator
                let finalOnlyTranscript = transcription.finalsOnly
                let resolver = ProperNounResolver(contactNames: utterance.evalCase.properNouns)
                let correctedTranscript = resolver.resolveTranscript(accumulatorTranscript).text

                let wordErrorRate = WordErrorRate.measure(
                    reference: utterance.spoken,
                    hypothesis: accumulatorTranscript
                )
                let correctedWordErrorRate = WordErrorRate.measure(
                    reference: utterance.spoken,
                    hypothesis: correctedTranscript
                )
                let finalOnlyWordErrorRate = WordErrorRate.measure(
                    reference: utterance.spoken,
                    hypothesis: finalOnlyTranscript
                )

                func composite(of text: String) async throws -> Double {
                    let summary = try await service.summarize(AssistantRequest(
                        sourceText: text.isEmpty ? " " : text,
                        maxSuggestions: utterance.evalCase.maxSuggestions
                    ))
                    return EvalScorer.score(
                        summary: summary,
                        against: utterance.evalCase,
                        latencyMilliseconds: 0
                    ).composite
                }

                results.append(SpeechCaseResult(
                    caseID: utterance.evalCase.id,
                    wordErrorRate: wordErrorRate.rate,
                    substitutions: wordErrorRate.substitutions,
                    deletions: wordErrorRate.deletions,
                    insertions: wordErrorRate.insertions,
                    transcript: accumulatorTranscript,
                    synthMilliseconds: utterance.synthMilliseconds,
                    asrMilliseconds: transcription.asrMilliseconds,
                    speechComposite: try await composite(of: accumulatorTranscript),
                    textComposite: try await composite(of: utterance.spoken),
                    correctedWordErrorRate: correctedWordErrorRate.rate,
                    correctedComposite: try await composite(of: correctedTranscript),
                    finalOnlyWordErrorRate: finalOnlyWordErrorRate.rate,
                    finalOnlyComposite: try await composite(of: finalOnlyTranscript)
                ))
            }

            return SpeechEvalReport(
                startedAt: startedAt,
                completedAt: Date(),
                configurationLabel: label,
                caseResults: results
            )
        }

        private static func resolvedLocale() async -> Locale {
            let supported = await SpeechTranscriber.supportedLocales
            return supported.first { $0.identifier(.bcp47) == "en-US" } ?? Locale(identifier: "en_US")
        }

        private static func installAssetsIfNeeded(locale: Locale) async throws {
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: []
            )
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        /// One transcription pass, two views of it: finals folded through
        /// `DictationAccumulator` exactly as the mic path does (volatile
        /// results included, trailing volatile folded at end-of-stream), and
        /// the finals-only ablation that prices a lost volatile tail.
        struct TranscriptionResult: Sendable {
            var accumulator: String
            var finalsOnly: String
            var asrMilliseconds: Double
        }

        /// Fresh transcriber and analyzer per utterance — the same lifecycle
        /// rule the mic path learned on device: a reused analyzer yields
        /// nothing.
        private static func transcribe(url: URL, locale: Locale) async throws -> TranscriptionResult {
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let file = try AVAudioFile(forReading: url)
            let start = ContinuousClock.now

            return try await withThrowingTaskGroup(of: (String, String)?.self) { group in
                group.addTask {
                    var accumulator = DictationAccumulator()
                    var finalsOnly = ""
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            accumulator.finalizeSegment(text)
                            finalsOnly += text
                        } else {
                            accumulator.updatePartial(text)
                        }
                    }
                    accumulator.endSegmentWithoutFinal()
                    return (accumulator.transcript, finalsOnly)
                }
                group.addTask {
                    if let last = try await analyzer.analyzeSequence(from: file) {
                        try await analyzer.finalizeAndFinish(through: last)
                    }
                    return nil
                }
                var accumulated = ""
                var finals = ""
                for try await value in group {
                    if let value {
                        (accumulated, finals) = value
                    }
                }
                return TranscriptionResult(
                    accumulator: accumulated.trimmingCharacters(in: .whitespacesAndNewlines),
                    finalsOnly: finals.trimmingCharacters(in: .whitespacesAndNewlines),
                    asrMilliseconds: start.millisecondsToNow
                )
            }
        }

        /// One eval case, spoken: what the synthesizer said, where the
        /// audio landed, and how long rendering took.
        private struct PreparedUtterance: Sendable {
            let evalCase: EvalCase
            let spoken: String
            let audioURL: URL
            let synthMilliseconds: Double
        }

        /// Reference-typed bridge between the pumped main thread and the
        /// async scoring task; only touched from main before/after the pump.
        private final class ResultBox: @unchecked Sendable {
            var report: SpeechEvalReport?
            var failure: String?
            var finished = false
        }

        private final class SynthesisState {
            var file: AVAudioFile?
            var done = false
        }

        private enum SpeechEvalFailure: Error, CustomStringConvertible {
            case modelUnavailable(String)

            var description: String {
                switch self {
                case .modelUnavailable(let reason):
                    "--live requested but the model is unavailable: \(reason)"
                }
            }
        }
    #endif

    private static let usage = """
    localassist-speecheval — end-to-end speech accuracy harness

    Speaks every eval case with the system synthesizer, transcribes it back
    through the SpeechAnalyzer stack the mic path uses, scores word error
    rate against what was spoken, and runs the transcript through the task
    pipeline next to a text-input baseline — so recognition errors show up
    as the downstream task-accuracy cost they actually cause.

    Synthetic audio is an upper bound on recognition, not a field number:
    use it as a regression tripwire between builds.

    USAGE:
      localassist-speecheval [--live] [--output docs/evals] [--max-wer 0.3]

    OPTIONS:
      --live            Route the downstream pipeline through the on-device
                        model. Default is the deterministic fallback, which
                        isolates the speech front end from model variance.
      --output <dir>    Write dated JSON + markdown reports into <dir>.
      --max-wer <rate>  Exit non-zero if mean WER exceeds this. Off by
                        default until baselines exist in docs/evals.
      --help            Show this help text.
    """
}

struct SpeechEvalArguments {
    var live = false
    var outputDirectory: String?
    var maxWordErrorRate: Double?
    var helpRequested = false

    init<S: Sequence>(_ rawArguments: S) where S.Element == String {
        var iterator = rawArguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--live":
                live = true
            case "--output":
                outputDirectory = iterator.next()
            case "--max-wer":
                if let value = iterator.next(), let parsed = Double(value) {
                    maxWordErrorRate = parsed
                }
            case "--help", "-h":
                helpRequested = true
            default:
                continue
            }
        }
    }
}

struct SpeechCaseResult: Codable, Equatable, Sendable {
    var caseID: String
    /// Full-accumulator output — the app's actual mic path.
    var wordErrorRate: Double
    var substitutions: Int
    var deletions: Int
    var insertions: Int
    var transcript: String
    var synthMilliseconds: Double
    var asrMilliseconds: Double
    /// Task composite on the full-accumulator transcript.
    var speechComposite: Double
    /// Task composite on the gold (spoken) text — the pipeline ceiling.
    var textComposite: Double
    /// Ablation: accumulator transcript after contact-aware proper-noun
    /// correction.
    var correctedWordErrorRate: Double
    var correctedComposite: Double
    /// Ablation: finalized results only, pricing a lost volatile tail.
    var finalOnlyWordErrorRate: Double
    var finalOnlyComposite: Double
}

struct SpeechEvalReport: Codable, Equatable, Sendable {
    var startedAt: Date
    var completedAt: Date
    var configurationLabel: String
    var caseResults: [SpeechCaseResult]

    var meanWordErrorRate: Double {
        guard !caseResults.isEmpty else {
            return 0
        }
        return caseResults.map(\.wordErrorRate).reduce(0, +) / Double(caseResults.count)
    }

    var meanSpeechComposite: Double {
        guard !caseResults.isEmpty else {
            return 0
        }
        return caseResults.map(\.speechComposite).reduce(0, +) / Double(caseResults.count)
    }

    var meanTextComposite: Double {
        guard !caseResults.isEmpty else {
            return 0
        }
        return caseResults.map(\.textComposite).reduce(0, +) / Double(caseResults.count)
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func renderedMarkdown() -> String {
        var lines: [String] = [
            "# LocalAssist Speech Eval Report",
            "",
            "- Configuration: \(configurationLabel)",
            "- Completed: \(ISO8601DateFormatter().string(from: completedAt))",
            "- Mean word error rate: \(meanWordErrorRate.scoreString)",
            "- Mean task composite — speech input: \(meanSpeechComposite.scoreString)",
            "- Mean task composite — text input: \(meanTextComposite.scoreString)",
            "- Synthetic audio caveat: TTS is cleaner than a human speaker;"
                + " treat WER as an upper bound and a regression tripwire.",
            "",
            "Ablations per case: gold text (ceiling) → full accumulator (app"
                + " path) → proper-name-corrected → finals-only (lost volatile"
                + " tail).",
            "",
            "| Case | WER | Corr WER | Final WER | Sub | Del | Ins | ASR (ms) "
                + "| Speech | Corrected | Final-only | Gold |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]

        for result in caseResults {
            lines.append(
                "| \(result.caseID) | \(result.wordErrorRate.scoreString) "
                    + "| \(result.correctedWordErrorRate.scoreString) "
                    + "| \(result.finalOnlyWordErrorRate.scoreString) "
                    + "| \(result.substitutions) | \(result.deletions) | \(result.insertions) "
                    + "| \(result.asrMilliseconds.formatted2) "
                    + "| \(result.speechComposite.scoreString) "
                    + "| \(result.correctedComposite.scoreString) "
                    + "| \(result.finalOnlyComposite.scoreString) "
                    + "| \(result.textComposite.scoreString) |"
            )
        }

        lines.append("")
        lines.append("## Transcripts")
        for result in caseResults {
            lines.append("- \(result.caseID): \(result.transcript)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func dateStamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

private extension ContinuousClock.Instant {
    var millisecondsToNow: Double {
        let elapsed = duration(to: ContinuousClock.now)
        return Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
    }
}
