import Foundation
import XCTest
@testable import LocalAssistEvalKit

/// The ASR accuracy metric the speech eval gates on: word-level edit
/// distance with an operation breakdown, plus the spoken-form rendering
/// that turns written eval cases into what a synthesizer actually says.
final class LocalAssistWordErrorRateTests: XCTestCase {
    func testPerfectTranscriptScoresZero() {
        let wer = WordErrorRate.measure(
            reference: "text amma that Sunday brunch works",
            hypothesis: "Text amma, that Sunday brunch works."
        )
        XCTAssertEqual(wer.rate, 0, "case and punctuation are normalization, not errors")
        XCTAssertEqual(wer.errorCount, 0)
    }

    func testSubstitutionCountsAgainstReferenceLength() {
        // The live probe's actual failure: "amma" came back as "Dom of".
        let wer = WordErrorRate.measure(
            reference: "text amma that Sunday brunch works at eleven",
            hypothesis: "Text Dom of that Sunday brunch works at 11."
        )
        // amma → Dom (substitution), "of" inserted, eleven → 11 (substitution).
        XCTAssertEqual(wer.substitutions, 2)
        XCTAssertEqual(wer.insertions, 1)
        XCTAssertEqual(wer.deletions, 0)
        XCTAssertEqual(wer.referenceWordCount, 8)
        XCTAssertEqual(wer.rate, 3.0 / 8.0, accuracy: 0.0001)
    }

    func testDeletionsAndEmptyHypothesis() {
        let dropped = WordErrorRate.measure(
            reference: "call the vendor today",
            hypothesis: "call vendor today"
        )
        XCTAssertEqual(dropped.deletions, 1)
        XCTAssertEqual(dropped.errorCount, 1)

        let silent = WordErrorRate.measure(reference: "call the vendor", hypothesis: "")
        XCTAssertEqual(silent.deletions, 3)
        XCTAssertEqual(silent.rate, 1.0)

        let bothEmpty = WordErrorRate.measure(reference: "", hypothesis: "")
        XCTAssertEqual(bothEmpty.rate, 0)
    }

    func testNumeralsAreDeliberatelyNotNormalized() {
        // "eleven" vs "11" changes what the due-date parser sees downstream,
        // so the metric surfaces it instead of papering over it.
        let wer = WordErrorRate.measure(reference: "at eleven", hypothesis: "at 11")
        XCTAssertEqual(wer.substitutions, 1)
    }

    func testSpokenFormFlattensBulletsIntoSentences() {
        let spoken = SpokenForm.render("""
        - draft release notes for 2.4
        - send the beta invite email on Monday
        - review open crash reports
        """)
        XCTAssertEqual(
            spoken,
            "draft release notes for 2.4. send the beta invite email on Monday. review open crash reports."
        )
        XCTAssertFalse(spoken.contains("-"), "nobody dictates a hyphen")
    }

    func testSpokenFormKeepsExistingSentencePunctuation() {
        let spoken = SpokenForm.render("Ship the hotfix tonight.\nConfirm with Dana!")
        XCTAssertEqual(spoken, "Ship the hotfix tonight. Confirm with Dana!")
    }
}
