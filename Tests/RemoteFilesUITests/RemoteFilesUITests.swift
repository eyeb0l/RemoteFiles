import XCTest

@MainActor
final class RemoteFilesUITests: XCTestCase {
    func testBrowseReadRefreshAndReturn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        // Profiling attaches to a freshly launched process before XCTest drives the journey.
        // Normal test runs still own launch; only the explicit profiling harness reuses it.
        if ProcessInfo.processInfo.environment["REMOTEFILES_PROFILE_EXISTING_APP"] == "1" {
            app.activate()
        } else {
            app.launch()
        }

        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Mac")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        projects.tap()
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Latest report")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        if !report.isHittable { app.swipeUp() }
        report.tap()
        let rendered = app.scrollViews["Rendered Markdown document"]
        XCTAssertTrue(rendered.waitForExistence(timeout: 15))
        attachScreenshot("Physical reader")

        app.buttons["Source"].tap()
        XCTAssertTrue(app.scrollViews["Markdown source"].waitForExistence(timeout: 5))
        app.buttons["Rendered"].tap()
        XCTAssertTrue(rendered.waitForExistence(timeout: 5))
        app.buttons["Document actions"].tap()
        app.buttons["Refresh"].tap()
        XCTAssertTrue(rendered.waitForExistence(timeout: 10))
        app.navigationBars.buttons["Projects"].tap()
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        attachScreenshot("Physical folder after back")
        app.navigationBars.buttons["RemoteFiles"].tap()
        XCTAssertTrue(projects.waitForExistence(timeout: 5))
    }

    func testNormalLaunchOffersUsableConnectionSetup() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let add = app.buttons["Add Connection"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        XCTAssertTrue(add.isHittable)
        XCTAssertLessThan(add.frame.height, 150, "The setup action must not expand into an unreadable vertical capsule.")
        attachScreenshot("Physical normal Home")
        add.tap()
        XCTAssertTrue(app.textFields["Hostname or IP address"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
