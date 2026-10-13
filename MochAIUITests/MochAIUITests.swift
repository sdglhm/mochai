import XCTest

final class MochAIUITests: XCTestCase {
    func testOnboardingIntroducesMochAI() {
        let app = XCUIApplication()
        app.launchArguments = ["--mochai-ui-testing", "--show-onboarding"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Meet MochAI."].waitForExistence(timeout: 8))
        app.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Detect AI Tools"].waitForExistence(timeout: 4))
    }

    func testDashboardOverviewIsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--mochai-ui-testing", "--show-dashboard"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Overview"].waitForExistence(timeout: 8) || app.buttons["Overview"].waitForExistence(timeout: 2))
    }

    func testSettingsExposeKeepAwake() {
        let app = XCUIApplication()
        app.launchArguments = ["--mochai-ui-testing", "--show-settings"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Launch MochAI at login"].waitForExistence(timeout: 8) || app.checkBoxes["Launch MochAI at login"].waitForExistence(timeout: 2))
    }
}
