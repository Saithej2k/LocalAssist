import XCTest

/// Drives genuine process-cold measurement launches on a connected device:
/// the first iteration resets the cold-launch campaign (a fresh envelope
/// pinning device/OS/build/commit/expected source), then each iteration
/// terminates and relaunches the app with `LOCALASSIST_MEASURE_PROCESS_COLD`.
/// The app runs exactly one sample as its first-ever generation of that
/// process, classifies it against the campaign's expected source, appends
/// it durably (fsync) to the campaign records, and only then shows the
/// completion marker — a launch whose write failed shows nothing and fails
/// this test loudly. Failures are recorded into the campaign too.
///
/// Statistics honesty: the default 20 launches support an **aggregate**
/// cold p95 only. Per-case cold percentiles need 20 launches per case —
/// `LOCALASSIST_COLD_LAUNCHES=160` over the 8-case dataset.
///
/// Opt-in only — relaunches take minutes and belong on a physical phone,
/// not in the CI smoke lane. Run with (SHA forwarding included — a
/// campaign without a commit SHA is not claim-ready):
///
///     TEST_RUNNER_LOCALASSIST_COMMIT_SHA=$(git rev-parse --short HEAD) \
///     TEST_RUNNER_LOCALASSIST_COLD_LAUNCHES=20 \
///     xcodebuild test \
///       -project LocalAssist.xcodeproj -scheme LocalAssist \
///       -destination 'platform=iOS,name=<your iPhone>' \
///       -only-testing:LocalAssistUITests/MeasurementColdLaunchTests
///
/// (`xcodebuild` forwards only `TEST_RUNNER_`-prefixed variables to the
/// test runner; the app build also stamps `LocalAssistCommitSHA` into its
/// Info.plist, so Settings-button runs carry the SHA too.)
///
/// Afterwards, Settings → Measurement → Run device measurement embeds the
/// active campaign — and only that campaign — in the exported report.
final class MeasurementColdLaunchTests: XCTestCase {
    @MainActor
    func testRepeatedProcessColdLaunchesCollectSamples() throws {
        let environment = ProcessInfo.processInfo.environment
        let requested = Int(environment["LOCALASSIST_COLD_LAUNCHES"] ?? "") ?? 0
        try XCTSkipIf(requested < 1, "set LOCALASSIST_COLD_LAUNCHES to run cold-launch collection")

        for launch in 1 ... requested {
            let app = XCUIApplication()
            app.launchArguments.append("LOCALASSIST_MEASURE_PROCESS_COLD")
            if launch == 1 {
                // Fresh campaign: never mix these samples with a previous
                // build's or day's collection.
                app.launchArguments.append("LOCALASSIST_COLD_CAMPAIGN_RESET")
            }
            // Keep the run dialog-free like every automation launch.
            app.launchEnvironment["LOCALASSIST_AUTO_RUN"] = "1"
            // Same SHA on every launch: the campaign refuses claim-ready
            // status without one. The device build's plist stamp is the
            // primary source; this env forwarding covers builds where the
            // stamping script could not run.
            if let commitSHA = environment["LOCALASSIST_COMMIT_SHA"], !commitSHA.isEmpty {
                app.launchEnvironment["LOCALASSIST_COMMIT_SHA"] = commitSHA
            }
            app.launch()

            XCTAssertTrue(
                app.otherElements["measurement-cold-done"].waitForExistence(timeout: 180),
                "cold launch \(launch)/\(requested) should durably record its sample"
            )
            app.terminate()
        }
    }
}
