import Foundation
import XCTest
@testable import LocalAssistCore

/// Display mapping for the Settings transcript diagnostics: truncation,
/// whitespace normalization, and role labels. The adapter's per-case walk
/// over the framework transcript is thin by design; the display rules live
/// here where they are testable without a model session.
final class LocalAssistTranscriptSnapshotTests: XCTestCase {
    func testSnapshotNormalizesWhitespaceFromPromptText() {
        let snapshot = TranscriptEntrySnapshot(
            id: 0,
            kind: .prompt,
            rawText: "Today is Friday.\n\nThe note between the triple quotes is   a note."
        )
        XCTAssertEqual(
            snapshot.text,
            "Today is Friday. The note between the triple quotes is a note.",
            "prompt line breaks collapse to single spaces for the one-line preview"
        )
    }

    func testSnapshotTruncatesLongEntriesWithEllipsis() {
        let raw = String(repeating: "tool output ", count: 60)
        let snapshot = TranscriptEntrySnapshot(id: 1, kind: .toolOutput, rawText: raw, maxCharacters: 40)

        XCTAssertEqual(snapshot.text.count, 41, "40 characters plus the ellipsis")
        XCTAssertTrue(snapshot.text.hasSuffix("…"), "a clipped entry never reads as a complete one")
    }

    func testSnapshotKeepsShortEntriesVerbatim() {
        let snapshot = TranscriptEntrySnapshot(id: 2, kind: .response, rawText: "Done.")
        XCTAssertEqual(snapshot.text, "Done.")
        XCTAssertFalse(snapshot.text.contains("…"))
    }

    func testKindDisplayTitlesCoverEveryRole() {
        let titles = TranscriptEntrySnapshot.Kind.allCases.map(\.displayTitle)
        XCTAssertEqual(titles, ["Instructions", "Prompt", "Tool call", "Tool output", "Response"])
    }
}
