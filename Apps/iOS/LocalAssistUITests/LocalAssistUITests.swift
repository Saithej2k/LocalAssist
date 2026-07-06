import XCTest

/// One smoke test through the real UI: the 43 package tests exercise the
/// engine through view models, but only a UI test catches a broken button
/// binding, a missing tab, or a view that stopped rendering.
final class LocalAssistUITests: XCTestCase {
    @MainActor
    func testOfflineAutoRunProducesReviewableBriefAndTabsNavigate() throws {
        let app = XCUIApplication()
        // Deterministic offline pipeline, no onboarding sheet, sample input
        // auto-submitted — the same automation hooks the screenshot flow uses.
        app.launchEnvironment["LOCALASSIST_AUTO_RUN"] = "1"
        app.launchEnvironment["LOCALASSIST_FORCE_OFFLINE"] = "1"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Review next actions"].waitForExistence(timeout: 30),
            "the offline pipeline should produce an editable action review"
        )

        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(
            app.navigationBars["Today"].waitForExistence(timeout: 5),
            "the Today tab should present its screen"
        )

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(
            app.navigationBars["History"].waitForExistence(timeout: 5),
            "the History tab should present its screen"
        )

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 5),
            "the Settings tab should present its screen"
        )
    }
}
