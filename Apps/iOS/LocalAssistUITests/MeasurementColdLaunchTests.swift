import XCTest

/// Drives genuine process-cold measurement launches on a connected device:
/// each iteration terminates and relaunches the app with
/// `LOCALASSIST_MEASURE_PROCESS_COLD`, the app runs exactly one sample as
/// its first-ever generation of that process and appends it to the JSONL
/// outbox in Documents, and the test waits on the completion marker.
///
/// Opt-in only — 20 relaunches take minutes and belong on a physical
/// phone, not in the CI smoke lane. Run with:
///
///     LOCALASSIST_COLD_LAUNCHES=20 xcodebuild test \
///       -project LocalAssist.xcodeproj -scheme LocalAssist \
///       -destination 'platform=iOS,name=<your iPhone>' \
///       -only-testing:LocalAssistUITests/MeasurementColdLaunchTests
///
/// Afterwards, Settings → Measurement → Run device measurement folds the
/// accumulated process-cold samples into the exported report.
final class MeasurementColdLaunchTests: XCTestCase {
    @MainActor
    func testRepeatedProcessColdLaunchesCollectSamples() throws {
        let requested = Int(ProcessInfo.processInfo.environment["LOCALASSIST_COLD_LAUNCHES"] ?? "") ?? 0
        try XCTSkipIf(requested < 1, "set LOCALASSIST_COLD_LAUNCHES to run cold-launch collection")

        for launch in 1 ... requested {
            let app = XCUIApplication()
            app.launchArguments.append("LOCALASSIST_MEASURE_PROCESS_COLD")
            // Keep the run dialog-free like every automation launch.
            app.launchEnvironment["LOCALASSIST_AUTO_RUN"] = "1"
            app.launch()

            XCTAssertTrue(
                app.otherElements["measurement-cold-done"].waitForExistence(timeout: 180),
                "cold launch \(launch)/\(requested) should record its sample"
            )
            app.terminate()
        }
    }
}
