import Foundation
import XCTest
@testable import LocalAssistCore
@testable import LocalAssistAppIntents

/// Backward decoding of history written by earlier releases, end to end at
/// the `AssistantRun` level — the store-level format contract.
final class LocalAssistLegacyHistoryDecodeTests: XCTestCase {
    func testPreTaxonomyPreIdentityHistoryDecodes() throws {
        // Shape from the earliest saved runs: free-form availability
        // reason, `overview`/`suggestions` keys, no run id, no
        // completedTaskIDs, none of the 2026-07 metrics fields.
        let legacy = """
        [{
            "request": {
                "sourceText": "Call the vendor about the renewed contract terms today.",
                "localeIdentifier": "en_US",
                "maxSuggestions": 5
            },
            "summary": {
                "overview": "Call the vendor",
                "keyPoints": ["Vendor call about contract"],
                "suggestions": [{
                    "id": "call-the-vendor-abc123",
                    "title": "Call the vendor",
                    "priority": "high",
                    "dueHint": "today",
                    "action": "reminder",
                    "rationale": "stated in the note",
                    "confidence": 0.9
                }],
                "actionDrafts": [],
                "source": "deterministicFallback",
                "diagnostics": {
                    "availability": {
                        "unavailable": {"reason": "No adapter configured."}
                    },
                    "fallbackReason": "No adapter configured."
                },
                "generatedAt": "2026-06-20T10:00:00Z"
            },
            "metrics": {
                "startedAt": "2026-06-20T10:00:00Z",
                "finishedAt": "2026-06-20T10:00:01Z",
                "durationMilliseconds": 1000,
                "source": "deterministicFallback",
                "suggestionCount": 1,
                "actionDraftCount": 0,
                "keyPointCount": 1,
                "inputCharacterCount": 55,
                "outputByteCount": 500,
                "cancelled": false
            }
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let runs = try decoder.decode([AssistantRun].self, from: Data(legacy.utf8))

        XCTAssertEqual(runs.count, 1)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.summary.headline, "Call the vendor")
        XCTAssertEqual(run.summary.tasks.count, 1)
        XCTAssertEqual(run.summary.diagnostics.availability.unavailability?.reason, .other)
        XCTAssertNil(run.metrics.stageTimings)
        XCTAssertNil(run.summary.diagnostics.reconcilerFindings)
        XCTAssertTrue(run.id.hasPrefix("run-"), "pre-identity entries derive a stable id")
        XCTAssertTrue(run.completedTaskIDs.isEmpty)

        // And the modern encoder round-trips it without loss of the parts
        // that matter.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reencoded = try encoder.encode(runs)
        let again = try decoder.decode([AssistantRun].self, from: reencoded)
        XCTAssertEqual(again.first?.summary.headline, "Call the vendor")
    }
}

/// The App Intents boundary: entities are pure Sendable values built from
/// runs, and expose no raw source text.
final class LocalAssistRunEntityBoundaryTests: XCTestCase {
    func testEntityMapsRunWithoutExposingSourceText() {
        let run = AssistantRun(
            id: "r1",
            request: AssistantRequest(sourceText: "PRIVATE-NOTE about the dentist"),
            summary: StructuredSummary(
                overview: "Dentist plan",
                keyPoints: ["Book the dentist"],
                suggestions: [
                    TaskSuggestion(
                        id: "t1", title: "Book dentist", priority: .medium,
                        dueHint: "next week", action: .calendarHold,
                        rationale: "r", confidence: 0.8
                    ),
                ],
                actionDrafts: [],
                source: .foundationModels,
                diagnostics: GenerationDiagnostics(availability: .available)
            ),
            metrics: RunMetrics(
                startedAt: Date(), finishedAt: Date(), durationMilliseconds: 900,
                source: .foundationModels, suggestionCount: 1, actionDraftCount: 0
            )
        )

        let entity = AssistantRunEntity(run: run)

        XCTAssertEqual(entity.id, "r1")
        XCTAssertEqual(entity.overview, "Dentist plan")
        XCTAssertEqual(entity.taskTitles, ["Book dentist"])
        XCTAssertEqual(entity.taskCount, 1)
        XCTAssertEqual(entity.source, "On-device model")
        XCTAssertFalse(
            entity.plainText.contains("PRIVATE-NOTE"),
            "the entity surfaces the brief, never the raw capture"
        )
    }
}
