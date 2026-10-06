import XCTest

@MainActor final class ImageOpenUITests: XCTestCase {
    private func app(exists: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--missing-image-fixture"] + (exists ? ["--image-exists"] : [])
        app.launch()
        return app
    }
    private func text(_ value: String, in element: XCUIElement) -> XCUIElement {
        element.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }
    private func viewerError(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["remote-image-viewer-error"]
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testOpenFileShowsMissingExpectedPathAndRetryThenReturnsToAudit() {
        continueAfterFailure = false
        let app = app()
        XCTAssertTrue(text("outside the document", in: app).waitForExistence(timeout: 10))
        app.buttons["Open file"].tap()
        let error = viewerError(in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("File not found at:"))
        XCTAssertTrue(error.label.contains("/old/wardrobe/02-item-before.png"))
        XCTAssertFalse(error.label.contains("outside the document"))
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertFalse(app.buttons["Share"].isEnabled)
        capture("Missing image shows expected path", app)
        app.buttons["remote-image-viewer-retry"].tap()
        XCTAssertTrue(viewerError(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(viewerError(in: app).label.contains("File not found at:"))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["audit.md"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open file"].exists)
    }
    func testExistingOutsideFileKeepsFolderRestrictionAndCannotShare() {
        continueAfterFailure = false
        let app = app(exists: true)
        XCTAssertTrue(text("outside the document", in: app).waitForExistence(timeout: 10))
        app.buttons["Open file"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        let error = viewerError(in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("outside the document"))
        XCTAssertFalse(error.label.contains("File not found at:"))
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertFalse(app.buttons["Share"].isEnabled)
        capture("Existing outside image keeps folder restriction", app)
    }
}
