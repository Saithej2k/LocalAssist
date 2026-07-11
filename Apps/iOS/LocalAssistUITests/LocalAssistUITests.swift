import XCTest

/// One smoke test through the real UI: the package tests exercise the
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

        XCTAssertTrue(selectTab("Today", in: app), "the Today tab should become selected")
        XCTAssertTrue(
            screen("today-screen", in: app).waitForExistence(timeout: 5),
            "the Today tab should present its screen"
        )

        XCTAssertTrue(selectTab("History", in: app), "the History tab should become selected")
        XCTAssertTrue(
            screen("history-screen", in: app).waitForExistence(timeout: 5),
            "the History tab should present its screen"
        )

        XCTAssertTrue(selectTab("Settings", in: app), "the Settings tab should become selected")
        XCTAssertTrue(
            screen("settings-screen", in: app).waitForExistence(timeout: 5),
            "the Settings tab should present its screen"
        )
    }

    @MainActor
    private func selectTab(_ name: String, in app: XCUIApplication) -> Bool {
        let button = app.tabBars.buttons[name]
        guard button.waitForExistence(timeout: 5) else {
            return false
        }
        for _ in 0 ..< 2 where !button.isSelected {
            button.tap()
        }
        return button.isSelected
    }

    @MainActor
    private func screen(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
