import Foundation
import XCTest
@testable import LocalAssistAppUI

/// Dictation-quality assessment and local experiment bucketing — both pure
/// logic, tested without Speech or AVFoundation.
final class LocalAssistQualityAndExperimentsTests: XCTestCase {
    // MARK: - Audio level metering

    func testMeterSeparatesVoicedFromSilentBuffers() {
        var meter = AudioLevelMeter()
        for _ in 0 ..< 30 {
            meter.record(peak: 0.001) // room tone
        }
        for _ in 0 ..< 10 {
            meter.record(peak: 0.3) // speech
        }
        XCTAssertEqual(meter.totalBuffers, 40)
        XCTAssertEqual(meter.voicedBuffers, 10)
        XCTAssertEqual(meter.voicedRatio, 0.25, accuracy: 0.0001)
        XCTAssertEqual(meter.maxPeak, 0.3)
    }

    // MARK: - Quality verdicts

    func testSilentSessionWithEmptyTranscriptGetsMicHint() {
        var meter = AudioLevelMeter()
        for _ in 0 ..< 100 {
            meter.record(peak: 0.001)
        }
        let hint = TranscriptionQualityAssessor.hint(
            transcriptCharacters: 0,
            averageConfidence: nil,
            meter: meter
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("microphone") == true)
    }

    func testLowConfidenceTranscriptGetsReviewHint() {
        var meter = AudioLevelMeter()
        for _ in 0 ..< 100 {
            meter.record(peak: 0.3)
        }
        let hint = TranscriptionQualityAssessor.hint(
            transcriptCharacters: 42,
            averageConfidence: 0.2,
            meter: meter
        )
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("review") == true)
    }

    func testHealthyCaptureGetsNoHint() {
        var meter = AudioLevelMeter()
        for _ in 0 ..< 100 {
            meter.record(peak: 0.3)
        }
        XCTAssertNil(TranscriptionQualityAssessor.hint(
            transcriptCharacters: 42,
            averageConfidence: 0.9,
            meter: meter
        ))
        // No confidence attributes at all is not evidence of a problem.
        XCTAssertNil(TranscriptionQualityAssessor.hint(
            transcriptCharacters: 42,
            averageConfidence: nil,
            meter: meter
        ))
    }

    func testShortSessionsAreNeverJudged() {
        var meter = AudioLevelMeter()
        for _ in 0 ..< 5 {
            meter.record(peak: 0.001)
        }
        XCTAssertNil(TranscriptionQualityAssessor.hint(
            transcriptCharacters: 0,
            averageConfidence: nil,
            meter: meter
        ))
    }

    // MARK: - Experiment bucketing

    func testBucketingIsDeterministicPerInstallAndExperiment() {
        let experiment = LocalExperiments.Experiment(name: "test-exp", treatmentShare: 0.5)
        let first = LocalExperiments.bucket(installID: "fixed-id", experiment: experiment)
        for _ in 0 ..< 10 {
            XCTAssertEqual(LocalExperiments.bucket(installID: "fixed-id", experiment: experiment), first)
        }
    }

    func testBucketingIsRoughlyUniformAcrossInstalls() {
        let experiment = LocalExperiments.Experiment(name: "uniformity", treatmentShare: 0.5)
        var treatment = 0
        let total = 2000
        for index in 0 ..< total
            where LocalExperiments.bucket(installID: "install-\(index)", experiment: experiment) == .treatment {
            treatment += 1
        }
        let share = Double(treatment) / Double(total)
        XCTAssertEqual(share, 0.5, accuracy: 0.05, "hash bucketing should split ~50/50, got \(share)")
    }

    func testExperimentsReRandomizeIndependently() {
        // The same install must not land in the same variant of every
        // experiment (correlated cohorts poison analysis).
        var differing = 0
        for index in 0 ..< 200 {
            let installID = "install-\(index)"
            let variantA = LocalExperiments.bucket(
                installID: installID,
                experiment: .init(name: "exp-a", treatmentShare: 0.5)
            )
            let variantB = LocalExperiments.bucket(
                installID: installID,
                experiment: .init(name: "exp-b", treatmentShare: 0.5)
            )
            if variantA != variantB {
                differing += 1
            }
        }
        XCTAssertGreaterThan(differing, 50)
    }

    func testPinnedVariantOverridesBucketing() {
        let killed = LocalExperiments.Experiment(name: "kill-switch", treatmentShare: 1.0, pinned: .control)
        XCTAssertEqual(LocalExperiments.variant(for: killed), .control)

        let rollout = LocalExperiments.Experiment(name: "full-rollout", treatmentShare: 0.0, pinned: .treatment)
        XCTAssertEqual(LocalExperiments.variant(for: rollout), .treatment)
    }

    func testInstallIDIsStablePerDefaultsStore() throws {
        let suiteName = "localassist.tests.experiments.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = LocalExperiments.installID(defaults: defaults)
        XCTAssertEqual(LocalExperiments.installID(defaults: defaults), first)
        XCTAssertNotNil(UUID(uuidString: first))
    }
}
