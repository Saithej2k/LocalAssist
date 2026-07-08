import Foundation
import XCTest
@testable import LocalAssistCore

/// Sentence-splitting semantics for the map-reduce chunker. The main
/// end-to-end chunker test lives in `LocalAssistCoreTests`; this file
/// pins the specific correctness rules `NLTokenizer` gives us over a
/// naive punctuation split.
final class LocalAssistChunkerTests: XCTestCase {
    func testChunkerKeepsAbbreviationsWhole() {
        // A naive `.!?` split would break "Dr. Smith" into two fragments;
        // NLTokenizer treats the abbreviation as part of the sentence.
        let text = "Dr. Smith reviewed the plan. He signed off before lunch."
        let chunks = TranscriptChunker.chunks(from: text, targetCharacters: 2800)
        XCTAssertFalse(chunks.contains(where: { $0.hasSuffix("Dr.") }))
        XCTAssertTrue(chunks.contains(where: { $0.contains("Dr. Smith") }))
    }

    func testChunkerKeepsDecimalsAndCurrencyWhole() {
        // "$3.14M" is one token; a naive split would call it two.
        let text = "Q3 revenue was $3.14M this quarter. The board celebrated."
        let chunks = TranscriptChunker.chunks(from: text, targetCharacters: 2800)
        XCTAssertTrue(chunks.contains(where: { $0.contains("$3.14M") }))
    }

    func testChunkerStillPacksAcrossSentencesForLongInput() {
        // The `NLTokenizer` change must not regress the packing behavior:
        // long input still splits into ≤ target-sized chunks.
        let text = String(
            repeating: "Review the launch checklist before Friday. ",
            count: 20
        )
        let chunks = TranscriptChunker.chunks(from: text, targetCharacters: 120)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 130 })
    }
}
