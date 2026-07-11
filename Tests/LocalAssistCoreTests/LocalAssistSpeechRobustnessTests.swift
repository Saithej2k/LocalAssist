import Foundation
import XCTest
@testable import LocalAssistCore
@testable import LocalAssistEvalKit
@testable import LocalAssistAppUI

/// WER alignment: the metric now reports HOW a transcript was wrong —
/// aligned substitutions, deletions, and insertions — not just how much.
final class LocalAssistWERAlignmentTests: XCTestCase {
    func testAlignmentReportsSubstitutedWordPair() {
        let wer = WordErrorRate.measure(
            reference: "text Mira about the blockers",
            hypothesis: "text mirror about the blockers"
        )

        XCTAssertEqual(wer.substitutions, 1)
        let substitution = wer.errors.first { $0.operation == .substitution }
        XCTAssertEqual(substitution?.referenceWord, "mira")
        XCTAssertEqual(substitution?.hypothesisWord, "mirror")
    }

    func testAlignmentReportsDroppedWord() {
        let wer = WordErrorRate.measure(
            reference: "ship the hotfix tonight",
            hypothesis: "ship hotfix tonight"
        )

        XCTAssertEqual(wer.deletions, 1)
        XCTAssertEqual(
            wer.errors.first { $0.operation == .deletion }?.referenceWord, "the"
        )
    }

    func testAlignmentReportsInventedWord() {
        let wer = WordErrorRate.measure(
            reference: "ship hotfix tonight",
            hypothesis: "ship the hotfix tonight"
        )

        XCTAssertEqual(wer.insertions, 1)
        XCTAssertEqual(
            wer.errors.first { $0.operation == .insertion }?.hypothesisWord, "the"
        )
    }

    func testAlignmentIsInReferenceOrderAndCountsAgree() {
        let wer = WordErrorRate.measure(
            reference: "call the vendor about contract terms today",
            hypothesis: "call vendor about the contract firms"
        )

        XCTAssertEqual(
            wer.errors.filter { $0.operation == .substitution }.count,
            wer.substitutions
        )
        XCTAssertEqual(wer.errors.filter { $0.operation == .deletion }.count, wer.deletions)
        XCTAssertEqual(wer.errors.filter { $0.operation == .insertion }.count, wer.insertions)
        XCTAssertEqual(
            wer.alignment.compactMap(\.referenceWord),
            WordErrorRate.normalizedWords("call the vendor about contract terms today"),
            "reference words appear in order across the alignment"
        )
    }

    func testPerfectAlignmentIsAllMatches() {
        let wer = WordErrorRate.measure(reference: "hello world", hypothesis: "Hello, world!")
        XCTAssertTrue(wer.errors.isEmpty)
        XCTAssertEqual(wer.alignment.map(\.operation), [.match, .match])
    }
}

/// ProperNounResolver: contact-aware, evidence-based, never guessing.
final class LocalAssistProperNounResolverTests: XCTestCase {
    private let resolver = ProperNounResolver(contactNames: ["Mira Chen", "Priya Patel", "Rahul"])

    func testMirrorResolvesToMira() {
        XCTAssertEqual(resolver.resolve(token: "mirror"), .corrected("Mira"))
    }

    func testExactNamesStayUnchanged() {
        XCTAssertEqual(resolver.resolve(token: "Mira"), .unchanged)
        XCTAssertEqual(resolver.resolve(token: "priya"), .unchanged)
    }

    func testUnrelatedWordsStayUnchanged() {
        for word in ["groceries", "tomorrow", "meeting", "blockers", "dentist"] {
            XCTAssertEqual(resolver.resolve(token: word), .unchanged, word)
        }
    }

    func testAmbiguityIsReportedNotGuessed() {
        let ambiguous = ProperNounResolver(contactNames: ["Priya", "Preya"])
        guard case .ambiguous(let candidates) = ambiguous.resolve(token: "prya") else {
            return XCTFail("two plausible contacts must be ambiguous")
        }
        XCTAssertEqual(Set(candidates), ["Priya", "Preya"])
    }

    func testHighConfidenceDemandsStrongerEvidence() {
        // "mirror" vs "Mira": phonetic match but similarity 0.5 — right at
        // the strong-evidence floor, so a confident recognizer keeps it only
        // with both signals; a weaker pair must not flip.
        let resolver = ProperNounResolver(contactNames: ["Mo"])
        XCTAssertEqual(
            resolver.resolve(token: "mango", confidence: 0.99),
            .unchanged,
            "a confident, weakly-similar token is not second-guessed"
        )
    }

    func testTranscriptPassCorrectsAndReports() {
        let (corrected, resolutions) = resolver.resolveTranscript(
            "text mirror about the design sync",
            confidence: 0.6
        )
        XCTAssertEqual(corrected, "text Mira about the design sync")
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions.first?.token, "mirror")
    }

    func testTranscriptPassKeepsPunctuation() {
        let (corrected, _) = resolver.resolveTranscript("say hi to mirror, please")
        XCTAssertEqual(corrected, "say hi to Mira, please")
    }

    func testSkeletonAndSimilarityPrimitives() {
        XCTAssertEqual(ProperNounResolver.consonantSkeleton("mirror"), "mr")
        XCTAssertEqual(ProperNounResolver.consonantSkeleton("mira"), "mr")
        XCTAssertEqual(ProperNounResolver.consonantSkeleton("priya"), "pr")
        XCTAssertEqual(ProperNounResolver.levenshtein("mirror", "mira"), 3)
        XCTAssertEqual(ProperNounResolver.similarity("same", "same"), 1)
    }
}

/// The dictation accumulator under the stress patterns the requirement
/// names; the transcriber-level behaviors that need real audio hardware are
/// exercised on device.
final class LocalAssistDictationStressTests: XCTestCase {
    func testImmediateSpeechFinalWithoutPriorPartial() {
        // On-device finals can arrive with no volatile before them when the
        // user starts talking the instant the pipeline is up.
        var accumulator = DictationAccumulator()
        accumulator.finalizeSegment("Call mom tonight.")
        XCTAssertEqual(accumulator.transcript, "Call mom tonight.")
    }

    func testShortUtteranceSurvivesStopDrain() {
        // A one-word capture whose only content is the volatile at stop time.
        var accumulator = DictationAccumulator()
        accumulator.updatePartial("Groceries")
        accumulator.endSegmentWithoutFinal()
        XCTAssertEqual(accumulator.transcript, "Groceries")
    }

    func testNoiseOnlySessionStaysEmpty() {
        var accumulator = DictationAccumulator()
        accumulator.updatePartial("")
        accumulator.finalizeSegment("")
        accumulator.endSegmentWithoutFinal()
        XCTAssertEqual(accumulator.transcript, "")
    }

    func testNumeralsPassThroughUnaltered() {
        var accumulator = DictationAccumulator()
        accumulator.finalizeSegment("Meet at 11:30 with 3 people")
        XCTAssertEqual(accumulator.transcript, "Meet at 11:30 with 3 people")
    }

    func testRapidStopStartDoesNotDuplicateAcrossSessions() {
        var accumulator = DictationAccumulator()
        accumulator.updatePartial("First thought")
        accumulator.endSegmentWithoutFinal()
        let firstTranscript = accumulator.transcript

        // A new session resets; nothing from the previous session leaks in.
        accumulator.reset()
        accumulator.updatePartial("Second thought")
        accumulator.finalizeSegment("Second thought.")

        XCTAssertEqual(firstTranscript, "First thought")
        XCTAssertEqual(accumulator.transcript, "Second thought.")
    }

    func testInterruptionMidVolatileKeepsWordsViaEndSegment() {
        // The interruption handler drains: whatever volatile is live folds.
        var accumulator = DictationAccumulator()
        accumulator.finalizeSegment("Email the landlord about the lease.")
        accumulator.updatePartial("Also ask about")
        accumulator.endSegmentWithoutFinal()
        XCTAssertEqual(
            accumulator.transcript,
            "Email the landlord about the lease. Also ask about"
        )
    }

    func testDuplicateFinalDeliveredTwiceFoldsOnce() {
        var accumulator = DictationAccumulator()
        accumulator.finalizeSegment("Pick up the cake Saturday.")
        accumulator.finalizeSegment("Pick up the cake Saturday.")
        XCTAssertEqual(accumulator.transcript, "Pick up the cake Saturday.")
    }
}

/// Monotonic session timeline: offsets are relative to the tap request,
/// first-partial is idempotent, and unset stages stay nil.
final class LocalAssistVoiceTimelineTests: XCTestCase {
    func testOffsetsAreRelativeToTapRequest() {
        var timeline = VoiceSessionTimeline()
        let clock = ContinuousClock()
        let start = clock.now
        timeline.recordTapRequested(now: start)
        timeline.recordAudioReady(now: start.advanced(by: .milliseconds(120)))
        timeline.recordFrame(now: start.advanced(by: .milliseconds(150)))
        timeline.recordAnalyzerStarted(now: start.advanced(by: .milliseconds(180)))
        timeline.recordFirstPartial(now: start.advanced(by: .milliseconds(900)))
        timeline.recordFrame(now: start.advanced(by: .milliseconds(2_000)))
        timeline.recordFinalResult(now: start.advanced(by: .milliseconds(2_400)))
        timeline.recordDrainCompleted(now: start.advanced(by: .milliseconds(2_900)))

        let snapshot = timeline.snapshot
        XCTAssertEqual(snapshot.audioReadyMilliseconds ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(snapshot.firstFrameMilliseconds ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(snapshot.analyzerStartMilliseconds ?? 0, 180, accuracy: 0.01)
        XCTAssertEqual(snapshot.firstPartialMilliseconds ?? 0, 900, accuracy: 0.01)
        XCTAssertEqual(snapshot.lastFrameMilliseconds ?? 0, 2_000, accuracy: 0.01)
        XCTAssertEqual(snapshot.finalResultMilliseconds ?? 0, 2_400, accuracy: 0.01)
        XCTAssertEqual(snapshot.drainCompletedMilliseconds ?? 0, 2_900, accuracy: 0.01)
    }

    func testFirstPartialRecordsExactlyOnce() {
        var timeline = VoiceSessionTimeline()
        let clock = ContinuousClock()
        let start = clock.now
        timeline.recordTapRequested(now: start)
        timeline.recordFirstPartial(now: start.advanced(by: .milliseconds(500)))
        timeline.recordFirstPartial(now: start.advanced(by: .milliseconds(1_500)))
        XCTAssertEqual(timeline.snapshot.firstPartialMilliseconds ?? 0, 500, accuracy: 0.01)
    }

    func testUnsetStagesAreNil() {
        var timeline = VoiceSessionTimeline()
        timeline.recordTapRequested()
        let snapshot = timeline.snapshot
        XCTAssertNil(snapshot.firstPartialMilliseconds)
        XCTAssertNil(snapshot.finalResultMilliseconds)
        XCTAssertNil(snapshot.drainCompletedMilliseconds)
    }

    func testLockedTimelineIsUsableAcrossThreads() async {
        let locked = LockedVoiceTimeline()
        locked.recordTapRequested()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    locked.recordFrame()
                    locked.recordFirstPartial()
                }
            }
        }
        let snapshot = locked.snapshot
        XCTAssertNotNil(snapshot.firstFrameMilliseconds)
        XCTAssertNotNil(snapshot.firstPartialMilliseconds)
        XCTAssertNotNil(snapshot.lastFrameMilliseconds)
    }
}
