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
/// not in the CI smoke lane. Run with:
///
///     LOCALASSIST_COLD_LAUNCHES=20 xcodebuild test \
///       -project LocalAssist.xcodeproj -scheme LocalAssist \
///       -destination 'platform=iOS,name=<your iPhone>' \
///       -only-testing:LocalAssistUITests/MeasurementColdLaunchTests
///
/// Afterwards, Settings → Measurement → Run device measurement embeds the
/// active campaign — and only that campaign — in the exported report.
final class MeasurementColdLaunchTests: XCTestCase {
    @MainActor
    func testRepeatedProcessColdLaunchesCollectSamples() throws {
        let requested = Int(ProcessInfo.processInfo.environment["LOCALASSIST_COLD_LAUNCHES"] ?? "") ?? 0
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
            app.launch()

            XCTAssertTrue(
                app.otherElements["measurement-cold-done"].waitForExistence(timeout: 180),
                "cold launch \(launch)/\(requested) should durably record its sample"
            )
            app.terminate()
        }
    }
}
